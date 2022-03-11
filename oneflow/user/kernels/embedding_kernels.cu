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
#include "oneflow/core/embedding/key_value_store.h"
#include "oneflow/core/device/cuda_util.h"
#include "oneflow/core/ep/include/primitive/memcpy.h"
#include "oneflow/core/embedding/embedding_manager.h"
#include "oneflow/core/common/str_util.h"
#include "oneflow/user/kernels/random_mask_generator.h"
#include "oneflow/core/framework/random_generator_impl.h"
#include "oneflow/core/cuda/atomic.cuh"
#include "oneflow/core/embedding/embedding_options.h"
#include "oneflow/core/ep/include/primitive/copy_nd.h"
#include "oneflow/core/ep/include/primitive/cast.h"

namespace oneflow {

namespace {

template<typename T, typename G, typename IDX>
__global__ void SGDUpdateKernel(const int64_t embedding_size, T scale, const IDX* num_unique_ids,
                                const float* learning_rate, const T* scale_by_ptr,
                                const int64_t* skip_if, const G* model_diff, const T* model,
                                T* updated_model) {
  if (skip_if != nullptr && *skip_if != 0) {
    const int64_t n = *num_unique_ids * embedding_size;
    CUDA_1D_KERNEL_LOOP(i, n) { updated_model[i] = model[i]; }
  } else {
    if (scale_by_ptr != nullptr) { scale /= *scale_by_ptr; }
    float learning_rate_val = *learning_rate;
    const int64_t n = *num_unique_ids * embedding_size;
    CUDA_1D_KERNEL_LOOP(i, n) {
      const T model_val = model[i];
      updated_model[i] = model_val - learning_rate_val * (scale * static_cast<T>(model_diff[i]));
    }
  }
}

template<typename T, typename G, typename IDX>
__global__ void MomentumUpdateKernel(const int64_t line_size, const int64_t embedding_size, T scale,
                                     float beta, const IDX* num_unique_ids,
                                     const float* learning_rate, const T* scale_by_ptr,
                                     const int64_t* skip_if, const G* model_diff,
                                     const T* unique_values, T* updated_unique_values) {
  if (skip_if != nullptr && *skip_if != 0) { return; }
  if (scale_by_ptr != nullptr) { scale *= *scale_by_ptr; }
  float learning_rate_val = *learning_rate;
  const int64_t rows = *num_unique_ids;
  for (int row = blockIdx.x; row < rows; row += gridDim.x) {
    const int64_t row_offset = row * line_size;
    for (int col = threadIdx.x; col < embedding_size; col += blockDim.x) {
      const int64_t offset = row_offset + col;
      const int64_t momentum_offset = row_offset + embedding_size + col;
      const T model_val = unique_values[offset];
      const T momentum = unique_values[momentum_offset];
      const T model_diff_val = scale * static_cast<T>(model_diff[offset]);
      const T next_momentum = beta * momentum - learning_rate_val * model_diff_val;
      const T next_model = model_val + next_momentum;
      updated_unique_values[offset] = next_model;
      updated_unique_values[momentum_offset] = next_momentum;
    }
  }
}

template<typename T, typename G, typename IDX>
__global__ void AdamUpdateKernel(const int64_t line_size, const int64_t embedding_size, T scale,
                                 float beta1, float beta2, float epsilon,
                                 const float* bias_correction1_ptr,
                                 const float* bias_correction2_ptr, const IDX* num_unique_ids,
                                 const float* learning_rate, const T* scale_by_ptr,
                                 const int64_t* skip_if, const G* model_diff,
                                 const T* unique_values, T* updated_unique_values) {
  if (skip_if != nullptr && *skip_if != 0) { return; }
  if (scale_by_ptr != nullptr) { scale *= *scale_by_ptr; }
  float learning_rate_val = *learning_rate;
  float bias_correction1_val = 1.0;
  float bias_correction2_val = 1.0;
  if (bias_correction1_ptr != nullptr) { bias_correction1_val = *bias_correction1_ptr; }
  if (bias_correction2_ptr != nullptr) { bias_correction2_val = *bias_correction2_ptr; }
  const int64_t rows = *num_unique_ids;
  for (int row = blockIdx.x; row < rows; row += gridDim.x) {
    const int64_t row_offset = row * line_size;
    for (int col = threadIdx.x; col < embedding_size; col += blockDim.x) {
      const int64_t offset = row_offset + col;
      const int64_t m_offset = row_offset + embedding_size + col;
      const int64_t v_offset = row_offset + 2 * embedding_size + col;

      const T model_val = unique_values[offset];
      const T m = unique_values[m_offset];
      const T v = unique_values[v_offset];
      const T model_diff_value = scale * static_cast<T>(model_diff[offset]);
      const T next_m = beta1 * m + (1 - beta1) * model_diff_value;
      const T next_v = beta2 * v + (1 - beta2) * model_diff_value * model_diff_value;
      T denom = (sqrt(next_v) / sqrt(bias_correction2_val)) + epsilon;
      const T step_size = learning_rate_val / bias_correction1_val;
      updated_unique_values[offset] = model_val - step_size * (next_m / denom);
      updated_unique_values[m_offset] = next_m;
      updated_unique_values[v_offset] = next_v;
    }
  }
}

}  // namespace

template<typename T, typename G, typename IDX>
class SgdEmbeddingUpdateKernel final : public user_op::OpKernel {
 public:
  SgdEmbeddingUpdateKernel() = default;
  ~SgdEmbeddingUpdateKernel() = default;

 private:
  using user_op::OpKernel::Compute;
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* num_unique_ids = ctx->Tensor4ArgNameAndIndex("num_unique_ids", 0);
    const user_op::Tensor* unique_embeddings = ctx->Tensor4ArgNameAndIndex("unique_embeddings", 0);
    const user_op::Tensor* embedding_grad = ctx->Tensor4ArgNameAndIndex("embedding_grad", 0);
    user_op::Tensor* updated_unique_embeddings =
        ctx->Tensor4ArgNameAndIndex("updated_unique_embeddings", 0);
    const int64_t embedding_size = ctx->Attr<int64_t>("embedding_size");
    const auto scale = ctx->Attr<double>("scale");

    const user_op::Tensor* learning_rate = ctx->Tensor4ArgNameAndIndex("learning_rate", 0);
    const float* learning_rate_ptr = learning_rate->dptr<float>();
    const T* scale_by_ptr = nullptr;
    if (ctx->has_input("scale_by_tensor", 0)) {
      const user_op::Tensor* scale_by_tensor = ctx->Tensor4ArgNameAndIndex("scale_by_tensor", 0);
      CHECK_EQ(scale_by_tensor->data_type(), unique_embeddings->data_type());
      CHECK_EQ(scale_by_tensor->shape().elem_cnt(), 1);
      scale_by_ptr = scale_by_tensor->dptr<T>();
    }
    const int64_t* skip_if_ptr = nullptr;
    if (ctx->has_input("skip_if", 0)) {
      const user_op::Tensor* skip_if = ctx->Tensor4ArgNameAndIndex("skip_if", 0);
      CHECK_EQ(skip_if->shape().elem_cnt(), 1);
      skip_if_ptr = skip_if->dptr<int64_t>();
    }
    // update kernel
    SGDUpdateKernel<T, G, IDX>
        <<<BlocksNum4ThreadsNum(embedding_grad->shape().elem_cnt()), kCudaThreadsNumPerBlock, 0,
           ctx->stream()->As<ep::CudaStream>()->cuda_stream()>>>(
            embedding_size, scale, num_unique_ids->dptr<IDX>(), learning_rate_ptr, scale_by_ptr,
            skip_if_ptr, embedding_grad->dptr<G>(), unique_embeddings->dptr<T>(),
            updated_unique_embeddings->mut_dptr<T>());
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_CUDA_SGD_EMBEDDING_UPDATE_KERNEL(t_dtype, g_type, idx_dtype)             \
  REGISTER_USER_KERNEL("sgd_embedding_update")                                            \
      .SetCreateFn<SgdEmbeddingUpdateKernel<t_dtype, g_type, idx_dtype>>()                \
      .SetIsMatchedHob(                                                                   \
          (user_op::HobDeviceType() == DeviceType::kCUDA)                                 \
          && (user_op::HobDataType("num_unique_ids", 0) == GetDataType<idx_dtype>::value) \
          && (user_op::HobDataType("embedding_grad", 0) == GetDataType<g_type>::value)    \
          && (user_op::HobDataType("unique_embeddings", 0) == GetDataType<t_dtype>::value));

REGISTER_CUDA_SGD_EMBEDDING_UPDATE_KERNEL(float, half, int32_t)
REGISTER_CUDA_SGD_EMBEDDING_UPDATE_KERNEL(float, float, int32_t)

template<typename T, typename G, typename IDX>
class MomentumEmbeddingUpdateKernel final : public user_op::OpKernel {
 public:
  MomentumEmbeddingUpdateKernel() = default;
  ~MomentumEmbeddingUpdateKernel() = default;

 private:
  using user_op::OpKernel::Compute;
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* num_unique_ids = ctx->Tensor4ArgNameAndIndex("num_unique_ids", 0);
    const user_op::Tensor* unique_embeddings = ctx->Tensor4ArgNameAndIndex("unique_embeddings", 0);
    const user_op::Tensor* embedding_grad = ctx->Tensor4ArgNameAndIndex("embedding_grad", 0);
    user_op::Tensor* updated_unique_embeddings =
        ctx->Tensor4ArgNameAndIndex("updated_unique_embeddings", 0);
    const int64_t num_axes = unique_embeddings->shape().NumAxes();
    const int64_t line_size = unique_embeddings->shape().At(num_axes - 1);
    const int64_t num_keys = unique_embeddings->shape().elem_cnt() / line_size;
    const int64_t embedding_size = ctx->Attr<int64_t>("embedding_size");
    CHECK_EQ(line_size, embedding_size * 2);
    const auto beta = ctx->Attr<float>("beta");
    const auto scale = ctx->Attr<double>("scale");
    const T* scale_by_ptr = nullptr;
    if (ctx->has_input("scale_by_tensor", 0)) {
      const user_op::Tensor* scale_by_tensor = ctx->Tensor4ArgNameAndIndex("scale_by_tensor", 0);
      CHECK_EQ(scale_by_tensor->data_type(), unique_embeddings->data_type());
      CHECK_EQ(scale_by_tensor->shape().elem_cnt(), 1);
      scale_by_ptr = scale_by_tensor->dptr<T>();
    }
    const user_op::Tensor* learning_rate = ctx->Tensor4ArgNameAndIndex("learning_rate", 0);
    const float* learning_rate_ptr = learning_rate->dptr<float>();
    const int64_t* skip_if_ptr = nullptr;
    if (ctx->has_input("skip_if", 0)) {
      const user_op::Tensor* skip_if = ctx->Tensor4ArgNameAndIndex("skip_if", 0);
      CHECK_EQ(skip_if->shape().elem_cnt(), 1);
      skip_if_ptr = skip_if->dptr<int64_t>();
    }
    // update kernel
    MomentumUpdateKernel<T, G, IDX>
        <<<num_keys, embedding_size, 0, ctx->stream()->As<ep::CudaStream>()->cuda_stream()>>>(
            line_size, embedding_size, scale, beta, num_unique_ids->dptr<IDX>(), learning_rate_ptr,
            scale_by_ptr, skip_if_ptr, embedding_grad->dptr<G>(), unique_embeddings->dptr<T>(),
            updated_unique_embeddings->mut_dptr<T>());
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_CUDA_MOMENTUM_EMBEDDING_UPDATE_KERNEL(t_dtype, g_type, idx_dtype)        \
  REGISTER_USER_KERNEL("momentum_embedding_update")                                       \
      .SetCreateFn<MomentumEmbeddingUpdateKernel<t_dtype, g_type, idx_dtype>>()           \
      .SetIsMatchedHob(                                                                   \
          (user_op::HobDeviceType() == DeviceType::kCUDA)                                 \
          && (user_op::HobDataType("num_unique_ids", 0) == GetDataType<idx_dtype>::value) \
          && (user_op::HobDataType("embedding_grad", 0) == GetDataType<g_type>::value)    \
          && (user_op::HobDataType("unique_embeddings", 0) == GetDataType<t_dtype>::value));

REGISTER_CUDA_MOMENTUM_EMBEDDING_UPDATE_KERNEL(float, half, int32_t)
REGISTER_CUDA_MOMENTUM_EMBEDDING_UPDATE_KERNEL(float, float, int32_t)

template<typename T, typename G, typename IDX>
class AdamEmbeddingUpdateKernel final : public user_op::OpKernel {
 public:
  AdamEmbeddingUpdateKernel() = default;
  ~AdamEmbeddingUpdateKernel() = default;

 private:
  using user_op::OpKernel::Compute;
  void Compute(user_op::KernelComputeContext* ctx) const override {
    const user_op::Tensor* num_unique_ids = ctx->Tensor4ArgNameAndIndex("num_unique_ids", 0);
    const user_op::Tensor* unique_embeddings = ctx->Tensor4ArgNameAndIndex("unique_embeddings", 0);
    const user_op::Tensor* embedding_grad = ctx->Tensor4ArgNameAndIndex("embedding_grad", 0);
    user_op::Tensor* updated_unique_embeddings =
        ctx->Tensor4ArgNameAndIndex("updated_unique_embeddings", 0);
    const int64_t num_axes = unique_embeddings->shape().NumAxes();
    const int64_t line_size = unique_embeddings->shape().At(num_axes - 1);
    const int64_t num_keys = unique_embeddings->shape().elem_cnt() / line_size;
    const int64_t embedding_size = ctx->Attr<int64_t>("embedding_size");
    CHECK_EQ(line_size, embedding_size * 3);

    const auto beta1 = ctx->Attr<float>("beta1");
    const auto beta2 = ctx->Attr<float>("beta2");
    const auto epsilon = ctx->Attr<float>("epsilon");
    const bool do_bias_correction = ctx->Attr<bool>("do_bias_correction");
    const auto scale = ctx->Attr<double>("scale");
    const T* scale_by_ptr = nullptr;
    if (ctx->has_input("scale_by_tensor", 0)) {
      const user_op::Tensor* scale_by_tensor = ctx->Tensor4ArgNameAndIndex("scale_by_tensor", 0);
      CHECK_EQ(scale_by_tensor->data_type(), unique_embeddings->data_type());
      CHECK_EQ(scale_by_tensor->shape().elem_cnt(), 1);
      scale_by_ptr = scale_by_tensor->dptr<T>();
    }
    const user_op::Tensor* learning_rate = ctx->Tensor4ArgNameAndIndex("learning_rate", 0);
    const float* learning_rate_ptr = learning_rate->dptr<float>();
    const int64_t* skip_if_ptr = nullptr;
    if (ctx->has_input("skip_if", 0)) {
      const user_op::Tensor* skip_if = ctx->Tensor4ArgNameAndIndex("skip_if", 0);
      CHECK_EQ(skip_if->shape().elem_cnt(), 1);
      skip_if_ptr = skip_if->dptr<int64_t>();
    }
    const float* bias_correction1_ptr = nullptr;
    if (ctx->has_input("bias_correction1", 0)) {
      bias_correction1_ptr = ctx->Tensor4ArgNameAndIndex("bias_correction1", 0)->dptr<float>();
    }
    const float* bias_correction2_ptr = nullptr;
    if (ctx->has_input("bias_correction2", 0)) {
      bias_correction2_ptr = ctx->Tensor4ArgNameAndIndex("bias_correction2", 0)->dptr<float>();
    }
    // update kernel
    AdamUpdateKernel<T, G, IDX>
        <<<num_keys, embedding_size, 0, ctx->stream()->As<ep::CudaStream>()->cuda_stream()>>>(
            line_size, embedding_size, static_cast<T>(scale), beta1, beta2, epsilon,
            bias_correction1_ptr, bias_correction2_ptr, num_unique_ids->dptr<IDX>(),
            learning_rate_ptr, scale_by_ptr, skip_if_ptr, embedding_grad->dptr<G>(),
            unique_embeddings->dptr<T>(), updated_unique_embeddings->mut_dptr<T>());
  }
  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
};

#define REGISTER_CUDA_ADAM_EMBEDDING_UPDATE_KERNEL(t_dtype, g_type, idx_dtype)            \
  REGISTER_USER_KERNEL("adam_embedding_update")                                           \
      .SetCreateFn<AdamEmbeddingUpdateKernel<t_dtype, g_type, idx_dtype>>()               \
      .SetIsMatchedHob(                                                                   \
          (user_op::HobDeviceType() == DeviceType::kCUDA)                                 \
          && (user_op::HobDataType("num_unique_ids", 0) == GetDataType<idx_dtype>::value) \
          && (user_op::HobDataType("embedding_grad", 0) == GetDataType<g_type>::value)    \
          && (user_op::HobDataType("unique_embeddings", 0) == GetDataType<t_dtype>::value));

REGISTER_CUDA_ADAM_EMBEDDING_UPDATE_KERNEL(float, half, int32_t)
REGISTER_CUDA_ADAM_EMBEDDING_UPDATE_KERNEL(float, float, int32_t)

}  // namespace oneflow
