#include "oneflow/core/graph/compute_task_node.h"
#include "oneflow/core/graph/logical_node.h"
#include "oneflow/core/graph/task_graph.h"

namespace oneflow {

namespace {

const LogicalNode* LogicalNodeOnEdge(
    TaskEdge* edge, TaskNode* (TaskEdge::*GetNode)() const,
    void (TaskNode::*ForEachDataEdge)(const std::function<void(TaskEdge*)>&) const) {
  CompTaskNode* target_node = nullptr;
  do {
    TaskNode* tmp_node = (edge->*GetNode)();
    target_node = dynamic_cast<CompTaskNode*>(tmp_node);
    edge = nullptr;
    (tmp_node->*ForEachDataEdge)([&](TaskEdge* e) {
      if (edge == nullptr) { edge = e; }
    });
  } while (!target_node && edge);
  if (target_node) { return target_node->logical_node(); }
  return nullptr;
}

std::vector<CompTaskNode*> GetCompTaskNodesOnEdge(
    TaskEdge* edge, TaskNode* (TaskEdge::*GetNode)() const,
    void (TaskNode::*ForEachDataEdge)(const std::function<void(TaskEdge*)>&) const) {
  std::queue<TaskNode*> nodes;
  HashSet<TaskNode*> visited_nodes;
  nodes.push((edge->*GetNode)());
  CHECK(visited_nodes.emplace((edge->*GetNode)()).second);
  std::vector<CompTaskNode*> comp_task_nodes;
  while (!nodes.empty()) {
    TaskNode* node = nodes.front();
    nodes.pop();
    CompTaskNode* comp_task_node = dynamic_cast<CompTaskNode*>(node);
    if (comp_task_node) {
      comp_task_nodes.push_back(comp_task_node);
    } else {
      (node->*ForEachDataEdge)([&](TaskEdge* task_edge) {
        if (visited_nodes.find((task_edge->*GetNode)()) == visited_nodes.end()) {
          nodes.push((task_edge->*GetNode)());
          CHECK(visited_nodes.emplace((task_edge->*GetNode)()).second);
        }
      });
    }
  }
  return comp_task_nodes;
}

}  // namespace

void CompTaskNode::ToProto(TaskProto* task_proto) {
  TaskNode::ToProto(task_proto);
  *(task_proto->mutable_parallel_ctx()) = parallel_ctx_;
}

const LogicalNode* CompTaskNode::GetOneSuccLogicalNodeOnEdge(TaskEdge* edge) {
  return LogicalNodeOnEdge(edge, &TaskEdge::dst_node, &TaskNode::ForEachOutDataEdge);
}

const LogicalNode* CompTaskNode::GetOnePredLogicalNodeOnEdge(TaskEdge* edge) {
  return LogicalNodeOnEdge(edge, &TaskEdge::src_node, &TaskNode::ForEachInDataEdge);
}

std::vector<CompTaskNode*> CompTaskNode::GetSuccCompTaskNodesOnEdge(TaskEdge* edge) const {
  return GetCompTaskNodesOnEdge(edge, &TaskEdge::dst_node, &TaskNode::ForEachOutDataEdge);
}

std::vector<CompTaskNode*> CompTaskNode::GetPredCompTaskNodesOnEdge(TaskEdge* edge) const {
  return GetCompTaskNodesOnEdge(edge, &TaskEdge::src_node, &TaskNode::ForEachInDataEdge);
}

std::string CompTaskNode::VisualStr() const {
  std::stringstream ss;
  ss << TaskType_Name(GetTaskType()) << "\\n";
  for (const auto& op : logical_node()->op_vec()) { ss << "[" << op->op_name() << "]\n"; }
  ss << this->machine_id() << ":" << this->thrd_id() << "\\n" << this->task_id();
  return ss.str();
}

}  // namespace oneflow
