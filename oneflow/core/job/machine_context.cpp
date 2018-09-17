#include "oneflow/core/job/machine_context.h"

namespace oneflow {

std::string MachineCtx::GetCtrlAddr(int64_t machine_id) const {
  const Machine& mchn = Global<JobDesc>::Get()->resource().machine(machine_id);
  return mchn.addr() + ":" + std::to_string(mchn.port());
}

MachineCtx::MachineCtx(int64_t this_mchn_id) : this_machine_id_(this_mchn_id) {
  LOG(INFO) << "this machine id: " << this_machine_id_;
}

}  // namespace oneflow
