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
#ifndef ONEFLOW_CORE_VM_VM_OBJECT_H_
#define ONEFLOW_CORE_VM_VM_OBJECT_H_

#include "oneflow/core/common/maybe.h"
#include "oneflow/core/intrusive/flat_msg.h"
#include "oneflow/core/intrusive/intrusive.h"
#include "oneflow/core/intrusive/object_pool.h"
#include "oneflow/core/vm/id_util.h"
#include "oneflow/core/job/parallel_desc.h"

namespace oneflow {

namespace vm {

struct Instruction;
struct MirroredObject;

enum OperandAccessType {
  kConstOperandAccess = 0,
  kMutableOperandAccess,
};

class DependenceAccess final
    : public intrusive::Base,
      public intrusive::EnableObjectPool<DependenceAccess,
                                         intrusive::kThreadUnsafeAndDisableDestruct> {
 public:
  void __Init__();
  // Getters
  OperandAccessType access_type() const { return access_type_; }
  bool has_instruction() const { return instruction_ != nullptr; }
  bool has_mirrored_object() const { return mirrored_object_ != nullptr; }
  const Instruction& instruction() const { return *instruction_; }
  const MirroredObject& mirrored_object() const { return *mirrored_object_; }
  const intrusive::ListHook& rw_mutexed_object_access_hook() const {
    return rw_mutexed_object_access_hook_;
  }

  // Setters
  void set_access_type(OperandAccessType val) { access_type_ = val; }
  void set_instruction(Instruction* val) { instruction_ = val; }
  void set_mirrored_object(MirroredObject* val) { mirrored_object_ = val; }
  void clear_instruction() { instruction_ = nullptr; }
  void clear_mirrored_object() { mirrored_object_ = nullptr; }
  Instruction* mut_instruction() { return instruction_; }
  MirroredObject* mut_mirrored_object() { return mirrored_object_; }

  // methods
  void __Init__(Instruction* instruction, MirroredObject* mirrored_object,
                OperandAccessType access_type);

  bool is_const_operand() const { return kConstOperandAccess == access_type(); }
  bool is_mut_operand() const { return kMutableOperandAccess == access_type(); }

  intrusive::Ref::RefCntType ref_cnt() const { return intrusive_ref_.ref_cnt(); }
  intrusive::Ref* mut_intrusive_ref() { return &intrusive_ref_; }  // NOLINT

 private:
  friend class intrusive::Ref;

  DependenceAccess()
      : intrusive_ref_(),
        access_type_(),
        instruction_(),
        mirrored_object_(),
        instruction_access_hook_(),
        rw_mutexed_object_access_hook_() {}
  intrusive::Ref intrusive_ref_;
  // fields
  OperandAccessType access_type_;
  Instruction* instruction_;
  MirroredObject* mirrored_object_;

 public:
  // list hooks
  intrusive::ListHook instruction_access_hook_;
  intrusive::ListHook rw_mutexed_object_access_hook_;
};  // NOLINT

class MirroredObject final : public intrusive::Base {
 public:
  // types
  using DependenceAccessList =
      intrusive::List<INTRUSIVE_FIELD(DependenceAccess, rw_mutexed_object_access_hook_)>;

  // Setters
  DependenceAccessList* mut_access_list() { return &access_list_; }

  // methods
  void __Init__() {}

  intrusive::Ref::RefCntType ref_cnt() const { return intrusive_ref_.ref_cnt(); }

 private:
  friend class intrusive::Ref;
  intrusive::Ref* mut_intrusive_ref() { return &intrusive_ref_; }

  MirroredObject() : intrusive_ref_(), access_list_() {}

  intrusive::Ref intrusive_ref_;
  // list hooks
  DependenceAccessList access_list_;
};

}  // namespace vm

}  // namespace oneflow

#endif  // ONEFLOW_CORE_VM_VM_OBJECT_H_
