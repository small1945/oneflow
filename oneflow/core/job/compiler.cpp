/*
Copyright 2020 The OneFlow Authors. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
#include "oneflow/core/job/compiler.h"
#include "oneflow/core/job/global_for.h"
#include "oneflow/core/job/intra_job_mem_sharing_util.h"
#include "oneflow/core/job/plan_util.h"
#include "oneflow/core/persistence/tee_persistent_log_stream.h"
#include "oneflow/core/graph/op_graph.h"
#include "oneflow/core/job_rewriter/job_completer.h"
#include "oneflow/core/thread/thread_pool.h"
#include "oneflow/core/common/blocking_counter.h"

namespace oneflow {

void CreateOpAttributeRef(Plan* plan, int64_t job_id, TaskProto* task_proto) {
  auto* job_id2op_attribute_ref_table = plan->mutable_job_id2op_attribute_ref_table();
  CHECK(task_proto->exec_sequence().exec_node_size() == 1);
  auto* exec_node = task_proto->mutable_exec_sequence()->mutable_exec_node(0);
  CHECK(exec_node->kernel_conf().has_op_attribute());
  const std::string op_name = exec_node->kernel_conf().op_attribute().op_conf().name();
  auto* op_name2op_attribute =
      (*job_id2op_attribute_ref_table)[job_id].mutable_op_name2op_attribute();
  auto find_it = op_name2op_attribute->find(op_name);
  if (find_it == op_name2op_attribute->end()) {
    op_name2op_attribute->insert(
        {op_name, task_proto->exec_sequence().exec_node(0).kernel_conf().op_attribute()});
  }
  auto* kernel_conf =
      task_proto->mutable_exec_sequence()->mutable_exec_node(0)->mutable_kernel_conf();
  kernel_conf->set_op_attribute_ref(op_name);
  // NOTE(levi): memory of op_attribute_ is released here.
  kernel_conf->set_allocated_op_attribute(nullptr);
}

void Compiler::Compile(Job* job, Plan* plan, bool need_job_complete) const {
  // Step1: ensure job is completed.
  if (need_job_complete) { CHECK_JUST(JobCompleter().Complete(job)); }

  // Step2: new Global<OpGraph> and set log configs.
  Global<OpGraph>::New(*job);
  const JobDesc& job_desc = GlobalJobDesc();
  if (Global<ResourceDesc, ForSession>::Get()->enable_debug_mode()
      || Global<ResourceDesc, ForSession>::Get()->enable_dry_run()) {
    TeePersistentLogStream::Create(StrCat("optimized_job", job_desc.job_id()))->Write(*job);
    Global<OpGraph>::Get()->ToDotWithFilePath("optimized_dlnet_" + std::to_string(job_desc.job_id())
                                              + "_op_graph.dot");
  }

  // Step3: build task_gph.
  // TODO(levi): we can rewrite this part of code in visitor pattern.
  auto task_gph =
      std::make_unique<TaskGraph>(job->job_conf().disable_straighten_algorithm_in_task_graph());
  using std::placeholders::_1;
  task_gph->ForEachNode(std::bind(&TaskNode::ProduceAllRegstsAndBindEdges, _1));
  task_gph->ForEachNode(std::bind(&TaskNode::ConsumeAllRegsts, _1));
  task_gph->ForEachNode(std::bind(&TaskNode::PinConsumedRegst, _1));
  task_gph->TopoForEachNode(&TaskNode::Build);
  task_gph->RemoveEmptyRegsts();
  task_gph->MergeChainAndAddOrderingCtrlEdgeInSameChain();
  auto IsReachable = Global<OpGraph>::Get()->MakePredicatorIsOpNameDataOrCtrlReachable();
  if (job_desc.enable_inplace()) { task_gph->EnableInplaceMemSharing(IsReachable); }
  task_gph->TopoForEachNode(&TaskNode::InferTimeShapeIfMeaningful);
  task_gph->ForEachEdge([&](TaskEdge* task_edge) { task_edge->CheckRegstLbiValid(); });

  // Step4: put infomation from task_gph into plan.
  const int64_t node_num = task_gph->node_num();
  const int64_t cpu_num = std::thread::hardware_concurrency();
  const int64_t thread_pool_size = std::min(node_num, cpu_num);
  BlockingCounter counter(node_num);
  std::mutex mtx;
  ThreadPool thread_pool(thread_pool_size);
  task_gph->ForEachNode([&](TaskNode* task_node) {
    thread_pool.AddWork([task_node, plan, &job_desc, &counter, &mtx]() {
      if (!task_node->IsMeaningLess()) {
        TaskProto task_proto;
        task_node->ToProto(&task_proto);
        {
          std::unique_lock<std::mutex> guard(mtx);
          if (task_node->GetTaskType() == kNormalForward || task_node->GetTaskType() == kRepeat
              || task_node->GetTaskType() == kAcc) {
            CreateOpAttributeRef(plan, job_desc.job_id(), &task_proto);
          }
          plan->mutable_task()->Add(std::move(task_proto));
        }  // guard(mtx)
      }
      counter.Decrease();
    } /* thread_pool.AddWork */);
  } /* task_gph->ForEachNode */);
  counter.WaitForeverUntilCntEqualZero();
  // NOTE(levi): release task_gph here to decrise memory peak.
  task_gph.reset();

  // Step5: post-process for plan and delete Global<OpGraph>.
  auto* job_id2job_conf = plan->mutable_job_confs()->mutable_job_id2job_conf();
  (*job_id2job_conf)[GlobalJobDesc().job_id()] = GlobalJobDesc().job_conf();
  // NOTE(chengcheng): infer mem blob id & set inplace & add ctrl
  IntraJobMemSharingUtil::InferMemBlockId4MemReusedRegst(plan, IsReachable);
  PlanUtil::SetUniqueMemBlockId4UnreusedMemRegst(plan);
  Global<OpGraph>::Delete();
}

}  // namespace oneflow
