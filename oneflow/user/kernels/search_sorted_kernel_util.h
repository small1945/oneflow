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
#include "oneflow/core/framework/framework.h"
#include "oneflow/core/kernel/new_kernel_util.h"

template<typename T, typename K>
OF_DEVICE_FUNC K cus_lower_bound(K start, K end, const T val, const T* bd) {
  const K orig_start = start;
  while (start < end) {
    const K mid = start + ((end - start) >> 1);
    const T mid_val = bd[mid];
    if (!(mid_val >= val)) {
      start = mid + 1;
    } else {
      end = mid;
    }
  }
  return start;
}

template<typename T, typename K>
OF_DEVICE_FUNC K cus_upper_bound(K start, K end, const T val, const T* bd) {
  const K orig_start = start;
  while (start < end) {
    const K mid = start + ((end - start) >> 1);
    const T mid_val = bd[mid];
    if (!(mid_val > val)) {
      start = mid + 1;
    } else {
      end = mid;
    }
  }
  return start;
}
