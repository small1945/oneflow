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
#include "oneflow/core/ep/include/primitive/matmul.h"
#include "oneflow/core/common/optional.h"
#include "oneflow/core/device/cuda_util.h"
#include "oneflow/core/ep/cuda/cuda_stream.h"
#include <cuda.h>

namespace oneflow {

namespace {

Optional<cudaDataType_t> OptCudaDataType(DataType data_type) {
  switch (data_type) {
    case kFloat: return CUDA_R_32F;
    case kDouble: return CUDA_R_64F;
    case kFloat16: return CUDA_R_16F;
#if CUDA_VERSION >= 11000
    case kBFloat16: return CUDA_R_16BF;
#endif  // CUDA_VERSION >= 11000
    default: return NullOpt;
  }
}

cudaDataType_t GetCudaDataType(DataType data_type) {
  auto cuda_data_type = OptCudaDataType(data_type);
  CHECK(cuda_data_type.has_value());
  return cuda_data_type.value_or(CUDA_R_32F);
}

cublasComputeType_t GetComputeType(DataType data_type) {
  switch (data_type) {
    case kFloat: return CUBLAS_COMPUTE_32F;
    case kDouble: return CUBLAS_COMPUTE_64F;
    case kFloat16: return CUBLAS_COMPUTE_32F;
    case kBFloat16: return CUBLAS_COMPUTE_32F;
    default: UNIMPLEMENTED(); return CUBLAS_COMPUTE_32F;
  }
}


union CublasScalarParameter {
  double d;
  float s;
};

CublasScalarParameter GetCublasScalarParameter(Scalar scalar, cublasComputeType_t compute_type) {
  CublasScalarParameter sp{};
  if (compute_type == CUBLAS_COMPUTE_64F) {
    sp.d = scalar.Value<double>();
  } else if (compute_type == CUBLAS_COMPUTE_32F) {
    sp.s = scalar.Value<float>();
  } else {
    UNIMPLEMENTED();
  }
  return sp;
}

// void InferMatmulCublasMNK(const MutShapeView* a_shape, const ShapeView& b_shape, 
//                           ep::primitive::BlasTransposeType transpose_a,
//                           ep::primitive::BlasTransposeType transpose_b, 
//                           size_t* cublas_m, size_t* cublas_n, size_t* cublas_k, 
//                           int64_t* cublas_lda, int64_t* cublas_ldb, int64_t* cublas_ldc) {
//   const int64_t num_a_axes = a_shape->NumAxes();
//   CHECK_GE(num_a_axes, 2);
//   const int64_t num_b_axes = b_shape.NumAxes();
//   CHECK_GE(num_b_axes, 2);
//   size_t m = 0, n = 0, k = 0; 
//   if (transpose_a == ep::primitive::BlasTransposeType::N) {
//     m = a_shape->At(num_a_axes - 2);
//     k = a_shape->At(num_a_axes - 1);
//     *cublas_ldb = k;
//   } else if (transpose_a == ep::primitive::BlasTransposeType::T) {
//     m = a_shape->At(num_a_axes - 1);
//     k = a_shape->At(num_a_axes - 2);
//     *cublas_ldb = m;
//   } else {
//     UNIMPLEMENTED();
//   }
//   if (transpose_b == ep::primitive::BlasTransposeType::N) {
//     CHECK_EQ(b_shape.At(num_b_axes - 2), k);
//     n = b_shape.At(num_b_axes - 1);
//     *cublas_lda = n;
//   } else if (transpose_b == ep::primitive::BlasTransposeType::T) {
//     CHECK_EQ(b_shape.At(num_b_axes - 1), k);
//     n = b_shape.At(num_b_axes - 2);
//     *cublas_lda = k;
//   } else {
//     UNIMPLEMENTED();
//   }
//   *cublas_m = n; 
//   *cublas_n = m; 
//   *cublas_k = k; 
//   *cublas_ldc = n;
// }
void InferMatmulCublasMNK(const DimVector& a_shape, const DimVector& b_shape, 
                          ep::primitive::BlasTransposeType transpose_a,
                          ep::primitive::BlasTransposeType transpose_b, 
                          size_t* cublas_m, size_t* cublas_n, size_t* cublas_k, 
                          int64_t* cublas_lda, int64_t* cublas_ldb, int64_t* cublas_ldc) {
    const int64_t num_a_axes = 2;
    // CHECK_GE(num_a_axes, 2);
    const int64_t num_b_axes = 2;
    // CHECK_GE(num_b_axes, 2);
    size_t m = 0, n = 0, k = 0; 
    if (transpose_a == ep::primitive::BlasTransposeType::N) {
      m = a_shape.at(num_a_axes - 2);
      k = a_shape.at(num_a_axes - 1);
      *cublas_ldb = k;
    } else if (transpose_a == ep::primitive::BlasTransposeType::T) {
      m = a_shape.at(num_a_axes - 1);
      k = a_shape.at(num_a_axes - 2);
      *cublas_ldb = m;
    } else {
      UNIMPLEMENTED();
    }
    if (transpose_b == ep::primitive::BlasTransposeType::N) {
      CHECK_EQ(b_shape.at(num_b_axes - 2), k);
      n = b_shape.at(num_b_axes - 1);
      *cublas_lda = n;
    } else if (transpose_b == ep::primitive::BlasTransposeType::T) {
      CHECK_EQ(b_shape.at(num_b_axes - 1), k);
      n = b_shape.at(num_b_axes - 2);
      *cublas_lda = k;
    } else {
      UNIMPLEMENTED();
    }
    *cublas_m = n; 
    *cublas_n = m; 
    *cublas_k = k; 
    *cublas_ldc = n;
  }



class FusedMatmulBiasAddReluKernelCache final : public user_op::OpKernelCache {
 public:
  FusedMatmulBiasAddReluKernelCache() {
// Just for init.
    OF_CUBLAS_CHECK(cublasLtMatmulDescCreate(&operation_desc1, CUBLAS_COMPUTE_32F, CUDA_R_32F));
    OF_CUBLAS_CHECK(cublasLtMatrixLayoutCreate(&cublas_a1_desc, CUDA_R_32F, 1, 1, 1));
    OF_CUBLAS_CHECK(cublasLtMatrixLayoutCreate(&cublas_b1_desc, CUDA_R_32F, 1, 1, 1));
    OF_CUBLAS_CHECK(cublasLtMatrixLayoutCreate(&cublas_c1_desc, CUDA_R_32F, 1, 1, 1));
    
  }
  ~FusedMatmulBiasAddReluKernelCache() override {
    OF_CUBLAS_CHECK(cublasLtMatmulDescDestroy(operation_desc1));
    OF_CUBLAS_CHECK(cublasLtMatrixLayoutDestroy(cublas_a1_desc));
    OF_CUBLAS_CHECK(cublasLtMatrixLayoutDestroy(cublas_b1_desc));
    OF_CUBLAS_CHECK(cublasLtMatrixLayoutDestroy(cublas_c1_desc));
  }
  cublasLtMatmulDesc_t operation_desc1;
  cublasLtMatrixLayout_t cublas_a1_desc;
  cublasLtMatrixLayout_t cublas_b1_desc;
  cublasLtMatrixLayout_t cublas_c1_desc;
};

std::shared_ptr<FusedMatmulBiasAddReluKernelCache> CreateFusedMatmulBiasAddReluKernelCache() {
  std::shared_ptr<FusedMatmulBiasAddReluKernelCache> cache(new FusedMatmulBiasAddReluKernelCache());
  return cache;
}

void SetCublasMatrixLayout(cublasLtMatrixLayout_t layout_desc, cudaDataType_t cuda_data_type,
                           cublasOperation_t cublas_trans, const size_t cublas_m1,
                           const size_t cublas_n1, int64_t cublas_ld) {
  OF_CUBLAS_CHECK(cublasLtMatrixLayoutSetAttribute(layout_desc, CUBLASLT_MATRIX_LAYOUT_TYPE,
                                                   &cuda_data_type, sizeof(cuda_data_type)));
  OF_CUBLAS_CHECK(cublasLtMatrixLayoutSetAttribute(
      layout_desc, CUBLASLT_MATRIX_LAYOUT_ROWS, cublas_trans == CUBLAS_OP_N ? &cublas_m1 : &cublas_n1,
      sizeof(cublas_m1)));
  OF_CUBLAS_CHECK(cublasLtMatrixLayoutSetAttribute(
      layout_desc, CUBLASLT_MATRIX_LAYOUT_COLS, cublas_trans == CUBLAS_OP_N ? &cublas_n1 : &cublas_m1,
      sizeof(cublas_m1)));
  OF_CUBLAS_CHECK(cublasLtMatrixLayoutSetAttribute(layout_desc, CUBLASLT_MATRIX_LAYOUT_LD,
                                                   &cublas_ld, sizeof(cublas_ld)));
}

void SetCublasEpilogue(const FusedMatmulBiasAddReluKernelCache* matmul_cache, 
                       cublasLtEpilogue_t epilogue, 
                       const void* bias_ptr, 
                       const void* aux_ptr){
  // if(epilogue == CUBLASLT_EPILOGUE_RELU_BIAS || epilogue == CUBLASLT_EPILOGUE_RELU_AUX_BIAS){
  //   // Set bias ptr
  //   OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(matmul_cache->operation_desc1,
  //     CUBLASLT_MATMUL_DESC_BIAS_POINTER, &bias_ptr,
  //     sizeof(bias_ptr)));
  // }
  if(epilogue == CUBLASLT_EPILOGUE_RELU_BIAS || epilogue == CUBLASLT_EPILOGUE_BIAS){
    // Set epilogue
    OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(
      matmul_cache->operation_desc1, CUBLASLT_MATMUL_DESC_EPILOGUE, &epilogue, sizeof(epilogue)));
    // Set bias ptr
    OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(matmul_cache->operation_desc1,
      CUBLASLT_MATMUL_DESC_BIAS_POINTER, &bias_ptr,
      sizeof(bias_ptr)));
  }
  // // TODO: GELU_AUX_BIAS
  // if(epilogue == CUBLASLT_EPILOGUE_RELU_AUX_BIAS){
  //   // Set aux ptr for backward. 
  //   OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(matmul_cache->operation_desc1,
  //     CUBLASLT_MATMUL_DESC_AUX_POINTER, &aux_ptr,
  //     sizeof(aux_ptr)));
  // }
}

void SetCublasAttr(const FusedMatmulBiasAddReluKernelCache* matmul_cache, 
                   const cublasComputeType_t cublas_compute_dtype, 
                   const cudaDataType_t cuda_data_type, 
                   cublasLtEpilogue_t epilogue, 
                   const void* bias_ptr, 
                   const void* aux_ptr, 
                   size_t cublas_m, 
                   size_t cublas_n, 
                   size_t cublas_k, 
                   int64_t cublas_lda, 
                   int64_t cublas_ldb, 
                   int64_t cublas_ldc
                   ){
  OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(
    matmul_cache->operation_desc1, CUBLASLT_MATMUL_DESC_COMPUTE_TYPE, &cublas_compute_dtype,
    sizeof(cublas_compute_dtype)));

  // For best performance when using the bias vector, specify beta == 0 and
  // CUBLASLT_POINTER_MODE_HOST.(from
  // https://docs.nvidia.com/cuda/cublas/index.html#cublasLtPointerMode_t)
  cublasLtPointerMode_t mode = CUBLASLT_POINTER_MODE_HOST;
  OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(
      matmul_cache->operation_desc1, CUBLASLT_MATMUL_DESC_POINTER_MODE, &mode, sizeof(mode)));
  
  // transpose_a = False, transpose_b = True. But in cublas is reversed. 
  const cublasOperation_t cublas_trans_a = CUBLAS_OP_T;
  const cublasOperation_t cublas_trans_b = CUBLAS_OP_N;
  OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(matmul_cache->operation_desc1,
                                                CUBLASLT_MATMUL_DESC_TRANSA, &cublas_trans_a,
                                                sizeof(cublas_trans_a)));
  OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(matmul_cache->operation_desc1,
                                                CUBLASLT_MATMUL_DESC_TRANSB, &cublas_trans_b,
                                                sizeof(cublas_trans_b)));
  
  // Set epilogue
  // OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(
  //     matmul_cache->operation_desc1, CUBLASLT_MATMUL_DESC_EPILOGUE, &epilogue, sizeof(epilogue)));
  SetCublasEpilogue(matmul_cache, epilogue, bias_ptr, aux_ptr);

  // // Set bias ptr
  // OF_CUBLAS_CHECK(cublasLtMatmulDescSetAttribute(matmul_cache->operation_desc1,
  //                                                CUBLASLT_MATMUL_DESC_BIAS_POINTER, &bias_ptr,
  //                                                sizeof(bias_ptr)));
  
  // Set matrix layout
  SetCublasMatrixLayout(matmul_cache->cublas_a1_desc, cuda_data_type, cublas_trans_a, cublas_m,
                        cublas_k, cublas_lda);
  SetCublasMatrixLayout(matmul_cache->cublas_b1_desc, cuda_data_type, cublas_trans_b, cublas_k,
                        cublas_n, cublas_ldb);
  SetCublasMatrixLayout(matmul_cache->cublas_c1_desc, cuda_data_type, CUBLAS_OP_N, cublas_m,
                        cublas_n, cublas_ldc);
}

}  // namespace

template<typename T>
class FusedMatmulBiasAddReluKernel final : public user_op::OpKernel {
 public:
  FusedMatmulBiasAddReluKernel() = default;
  ~FusedMatmulBiasAddReluKernel() override = default;

  bool AlwaysComputeWhenAllOutputsEmpty() const override { return false; }
  std::shared_ptr<user_op::OpKernelCache> InitOpKernelCache(
      user_op::KernelCacheContext* ctx) const override {
    return CreateFusedMatmulBiasAddReluKernelCache();
  }

 private:
  void Compute(user_op::KernelComputeContext* ctx, user_op::OpKernelState*,
               const user_op::OpKernelCache* cache) const override {
    printf("Enter here \n"); 
    /*
    Fused Dense+Activation+Dense Layer. 
    A: (m, k)
    B: (n, k) need transpose
    C: (j, n) need transpose
    tmp: A matmul B(transpose), its shape is (m, n)
    out: tmp matmul C(transpose), its shape is (m, j)
    */
    const int32_t weight_size = ctx->input_size("weights"); 
    const int32_t bias_size = ctx->input_size("biases"); 
    CHECK_EQ(weight_size, bias_size) << "The number of weight and bias is not equal!. "; 
    printf("weight size is: %d \n", weight_size); 
    printf("111 \n"); 
    auto* cuda_stream = ctx->stream()->As<ep::CudaStream>();
    const auto* matmul_cache =
        CHECK_NOTNULL(dynamic_cast<const FusedMatmulBiasAddReluKernelCache*>(cache));
    
    user_op::Tensor* x = ctx->Tensor4ArgNameAndIndex("x", 0); 
    user_op::Tensor* out = ctx->Tensor4ArgNameAndIndex("out", 0);
    printf("221 \n"); 

    const DataType data_type = out->data_type();
    const cublasComputeType_t cublas_compute_dtype = GetComputeType(data_type);
    const cudaDataType_t cuda_data_type = GetCudaDataType(data_type);
    size_t cublas_m = 0, cublas_n = 0, cublas_k = 0; 
    int64_t cublas_lda = 0, cublas_ldb = 0, cublas_ldc = 0; 
    printf("1133331 \n"); 
     

    const double alpha1 = 1.0;
    const auto sp_alpha1 = GetCublasScalarParameter(alpha1, cublas_compute_dtype);
    const double beta1 = 0.0;
    const auto sp_beta1 = GetCublasScalarParameter(beta1, cublas_compute_dtype);
    printf("1114444 \n"); 

    const int64_t batch_size = ctx->Tensor4ArgNameAndIndex("x", 0)->shape().At(0); 
    int64_t in_feature = ctx->Tensor4ArgNameAndIndex("x", 0)->shape().At(1); 
    printf("1114443123213123 \n"); 
    
    // MutShapeView* x_shape = x->mut_shape(); 
    // MutShapeView tmp_shape(*x_shape);
    DimVector x_shape(2); 
    x->shape().ToDimVector(&x_shape); 
    // MutShapeView tmp_shape(*x_shape);
    DimVector tmp_shape(2); 
    tmp_shape.at(0) = x_shape.at(0); 
    printf("111000000000"); 
    DimVector weight_shape(2); 
    
    int64_t out_feature = 0; 
    // user_op::Tensor* tmp_buffer = ctx->Tensor4ArgNameAndIndex("tmp_buffer", 0);
    user_op::Tensor* tmp_buffer = ctx->Tensor4ArgNameAndIndex("tmp_buffer", 0);
    printf("1118889999999"); 
    void* tmp_x_buffer = nullptr;
    T* tmp_y_buffer = tmp_buffer->mut_dptr<T>();
    printf("11188888"); 
    void* x_ptr = nullptr; 
    void* y_ptr = nullptr; 
    printf("1117777 \n"); 

    for(int idx = 0; idx < weight_size; idx++){
      const user_op::Tensor* weight = ctx->Tensor4ArgNameAndIndex("weights", idx);
      const user_op::Tensor* bias = ctx->Tensor4ArgNameAndIndex("biases", idx);
      out_feature = weight->shape().At(0); 
      weight->shape().ToDimVector(&weight_shape); 
      if(idx == 0){
        x_ptr = x->mut_dptr();
        InferMatmulCublasMNK(x_shape, weight_shape, 
                            /*transpose_a=*/ep::primitive::BlasTransposeType::N, 
                            /*transpose_b=*/ep::primitive::BlasTransposeType::T, 
                            &cublas_m, &cublas_n, &cublas_k, 
                            &cublas_lda, &cublas_ldb, &cublas_ldc);
      }else{
        // can be remove. 
        x_ptr = tmp_x_buffer; 
        InferMatmulCublasMNK(tmp_shape, weight_shape, 
                            /*transpose_a=*/ep::primitive::BlasTransposeType::N, 
                            /*transpose_b=*/ep::primitive::BlasTransposeType::T, 
                            &cublas_m, &cublas_n, &cublas_k, 
                            &cublas_lda, &cublas_ldb, &cublas_ldc);
      }
      if(idx == weight_size-1){
        printf("here??? \n"); 
        y_ptr = ctx->Tensor4ArgNameAndIndex("out", 0)->mut_dptr();
      }else{
        y_ptr = tmp_y_buffer; 
      }

      cublasLtEpilogue_t epilogue = CUBLASLT_EPILOGUE_RELU_BIAS;
      SetCublasAttr(matmul_cache, 
                    cublas_compute_dtype, 
                    cuda_data_type, 
                    epilogue, 
                    bias->dptr(), 
                    nullptr, 
                    cublas_m, 
                    cublas_n, 
                    cublas_k, 
                    cublas_lda, 
                    cublas_ldb, 
                    cublas_ldc); 

      OF_CUBLAS_CHECK(cublasLtMatmul(
          cuda_stream->cublas_lt_handle(), matmul_cache->operation_desc1, &sp_alpha1, weight->dptr(),
          matmul_cache->cublas_a1_desc, x_ptr, matmul_cache->cublas_b1_desc, &sp_beta1,
          y_ptr, matmul_cache->cublas_c1_desc, y_ptr, matmul_cache->cublas_c1_desc,
          nullptr, cuda_stream->cublas_workspace(), cuda_stream->cublas_workspace_size(),
          cuda_stream->cuda_stream()));
      
      tmp_x_buffer = tmp_y_buffer; 
      tmp_y_buffer += batch_size * out_feature; 
      // tmp_shape.Set(1, out_feature); 
      tmp_shape.at(1) = out_feature; 

    }
  }
};

#define REGISTER_MATMUL_BIAS_ADD_RELU_KERNEL_GPU(cpp_type, data_type)  \
  REGISTER_USER_KERNEL("fused_matmul_bias_add_relu")                   \
      .SetCreateFn<FusedMatmulBiasAddReluKernel<cpp_type>>()           \
      .SetIsMatchedHob((user_op::HobDeviceType() == DeviceType::kCUDA) \
                       && (user_op::HobDataType("out", 0) == data_type)) \
      .SetInferTmpSizeFn([](user_op::InferContext* ctx) {                               \
        int64_t tmp_size = 0; \
        const Shape& x_shape = ctx->InputShape("x", 0); \
        int64_t batch_size = x_shape.At(0); \
        int32_t weight_size = ctx->input_size("weights"); \
        for(int i = 0; i < weight_size; i++){ \
          tmp_size += batch_size * ctx->InputShape("weights", i).At(0); \
        }          \
        printf("Tmp size is: %ld \n", tmp_size); \
        const int64_t tmp_buffer_size = GetCudaAlignedSize(tmp_size);    \
        return tmp_buffer_size;                                          \
    });

REGISTER_MATMUL_BIAS_ADD_RELU_KERNEL_GPU(double, DataType::kDouble);
REGISTER_MATMUL_BIAS_ADD_RELU_KERNEL_GPU(float, DataType::kFloat);
REGISTER_MATMUL_BIAS_ADD_RELU_KERNEL_GPU(half, DataType::kFloat16);
#if CUDA_VERSION >= 11000
// REGISTER_MATMUL_BIAS_ADD_RELU_KERNEL_GPU(nv_bfloat16, DataType::kBFloat16);
#endif

}  // namespace oneflow
