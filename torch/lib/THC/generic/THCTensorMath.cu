#ifndef THC_GENERIC_FILE
#define THC_GENERIC_FILE "generic/THCTensorMath.cu"
#else

THC_API void
THCTensor_(fill)(THCState* state, THCTensor *self_, real value)
{
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 1, self_));

  if (!THC_pointwiseApply1(
        state, self_, TensorFillOp<real>(value))) {
    THArgCheck(false, 1, CUTORCH_DIM_WARNING);
  }

  THCudaCheck(cudaGetLastError());
}

THC_API void
THCTensor_(zero)(THCState *state, THCTensor *self_)
{
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 1, self_));
  if (THCTensor_(isContiguous)(state, self_)) {
    THCudaCheck(cudaMemsetAsync(THCTensor_(data)(state, self_),
                                0,
                                sizeof(real) * THCTensor_(nElement)(state, self_),
                                THCState_getCurrentStream(state)));
  } else {
    if (!THC_pointwiseApply1(
          state, self_,
          TensorFillOp<real>(ScalarConvert<int, real>::to(0)))) {
      THArgCheck(false, 1, CUTORCH_DIM_WARNING);
    }
  }

  THCudaCheck(cudaGetLastError());
}

THC_API void
THCTensor_(zeros)(THCState *state, THCTensor *r_, THLongStorage *size)
{
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 1, r_));
  THCTensor_(resize)(state, r_, size, NULL);
  THCTensor_(zero)(state, r_);
}

THC_API void
THCTensor_(ones)(THCState *state, THCTensor *r_, THLongStorage *size)
{
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 1, r_));
  THCTensor_(resize)(state, r_, size, NULL);
  THCTensor_(fill)(state, r_, ScalarConvert<int, real>::to(1));
}

THC_API void
THCTensor_(reshape)(THCState *state, THCTensor *r_, THCTensor *t, THLongStorage *size)
{
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 2, r_, t));
  THCTensor_(resize)(state, r_, size, NULL);
  THCTensor_(copy)(state, r_, t);
}

ptrdiff_t
THCTensor_(numel)(THCState *state, THCTensor *t)
{
  return THCTensor_(nElement)(state, t);
}

void THCTensor_(cat)(THCState *state, THCTensor *result,
		     THCTensor *ta, THCTensor *tb, int dimension)
{
  THCTensor* inputs[2];
  inputs[0] = ta;
  inputs[1] = tb;
  THCTensor_(catArray)(state, result, inputs, 2, dimension);
}

void THCTensor_(catArray)(THCState *state, THCTensor *result,
			  THCTensor **inputs, int numInputs, int dimension)
{
  THLongStorage *size;
  int i, j, cohortMax;
  int64_t offset;
  bool hasEmptyInput = false;

  // Even in the case where dimension is negative (i.e. when we want
  // to cat along the last dimension), this logic still works, as the
  // loop below will overwrite the value
  int maxDim = dimension + 1;

  // cat_dimension is the actual dimension we cat along
  int cat_dimension = dimension;

  for (i = 0; i < numInputs; i++)
  {
    int inputDim = THCTensor_(nDimension)(state, inputs[i]);
    hasEmptyInput |= !inputDim;
    maxDim = THMax(maxDim, inputDim);
  }

  // In the event that the user specified -1 as the concat dimension, then
  // we want to pick the maxDim  as dimension to cat along (and thus maxDim - 1 as the
  // value due to 0-based indexing). If the maxDim is // 0 (i.e. we are catting all
  // empty tensors), then we set cat_dimension to be 0
  if (dimension + TH_INDEX_BASE == -1) {
    cat_dimension = maxDim ? (maxDim - 1) : 0;
  }

  THArgCheck(numInputs > 0, 3, "invalid number of inputs %d", numInputs);
  THArgCheck(cat_dimension >= 0, 4, "invalid dimension %d", dimension + TH_INDEX_BASE);

  size = THLongStorage_newWithSize(maxDim);
  for(i = 0; i < maxDim; i++)
  {
    // dimSize is either the size of the dim if it exists, either 1 if #dim > 0, otherwise 0
    int64_t dimSize = i < THCTensor_(nDimension)(state, inputs[0])
                       ? THCTensor_(size)(state, inputs[0], i)
                       : THMin(THCTensor_(nDimension)(state, inputs[0]), 1);
    if (i == cat_dimension)
    {
      for (j = 1; j < numInputs; j++)
      {
        // accumulate the size over the dimension we want to cat on.
        // Empty tensors are allowed
        dimSize += i < THCTensor_(nDimension)(state, inputs[j])
                       ? THCTensor_(size)(state, inputs[j], i)
                       : THMin(THCTensor_(nDimension)(state, inputs[j]), 1);
      }
    }
    else
    {
      for (j = 1; j < numInputs; j++)
      {
        int64_t sz = i < THCTensor_(nDimension)(state, inputs[j])
                      ? THCTensor_(size)(state, inputs[j], i)
                      : THMin(THCTensor_(nDimension)(state, inputs[j]), 1);

        // If it's a dimension we're not catting on
        // Then fail if sizes are different AND > 0
        if (dimSize != sz && dimSize && sz) {
          THLongStorage_free(size);
          THError("inconsistent tensor sizes");
        }
        else if(!dimSize)
        {
          dimSize = sz;
        }
      }
    }
    size->data[i] = dimSize;
  }

  THCTensor_(resize)(state, result, size, NULL);
  THLongStorage_free(size);

  // We parallelize the copy if all 6 conditions pass:
  //
  // 1. There is more than one input tensor
  // 2. No empty inputs
  // 3. The result tensor is 32-bit indexable
  // 4. The number of dimensions is <= 4
  // 5. All input tensors are contiguous (output tensor may be non-contig)
  // 6. All input tensors can use 32-bit indexing
  // 7. All input tensors are on the same device

  if (numInputs > 1 &&
      !hasEmptyInput &&
      THCTensor_(nDimension)(state, result) <= CAT_ARRAY_MAX_INPUT_DIMS &&
      TensorUtils<THCTensor>::canUse32BitIndexMath(state, result) &&
      TensorUtils<THCTensor>::allContiguous(state, inputs, numInputs) &&
      TensorUtils<THCTensor>::all32BitIndexable(state, inputs, numInputs) &&
      TensorUtils<THCTensor>::allSameDevice(state, inputs, numInputs)) {

    // First, let's set up our kernel parameters. We start with a raw pointer to the storage
    // for the output Tensor.
    real *data = THCTensor_(data)(state, result);

    // Kernel Parameter
    CatArrInputTensor<real, unsigned int> stackInputs[CAT_ARRAY_BATCH_SIZE];
    CatArrInputTensor<real, unsigned int> *d_inputs;

    // Attempt to re-use stream's scratch space for the input metadata
    bool usedScratch = false;
    size_t tensorMetadataSize = sizeof(CatArrInputTensor<real, unsigned int>) * CAT_ARRAY_BATCH_SIZE;
    if (THCState_getCurrentDeviceScratchSpaceSize(state) > tensorMetadataSize) {
      void* space = THCState_getCurrentDeviceScratchSpace(state);
      if (space) {
        d_inputs = (CatArrInputTensor<real, unsigned int> *) space;
        usedScratch = true;
      }
    }
    if (!usedScratch) {
      // Fallback to allocating GPU memory
      THCudaCheck(THCudaMalloc(state, (void**) &d_inputs, tensorMetadataSize));
    }

    OutputTensorSizeStride<unsigned int, CAT_ARRAY_MAX_INPUT_DIMS> param;

    // Next, let's initialize the size, stride arrays for the output Tensor.
    for (i = 0; i < maxDim; ++i) {
      param.outputSize[i] = THCTensor_(size)(state, result, i);
      param.outputStride[i] = THCTensor_(stride)(state, result, i);
    }

    // Template Declarations for dim = 1, 2, 3, 4
#define HANDLE_CASE(DIMS) \
  CatArrayBatchedCopy<real, unsigned int, DIMS><<<applyGrid, applyBlock>>>(data, d_inputs, param, cat_dimension, param.outputStride[cat_dimension]);

    // Now we loop
    offset = 0;
    for (i = 0; i < numInputs; i += CAT_ARRAY_BATCH_SIZE) {
      cohortMax = 0;
      for (j = 0; j < CAT_ARRAY_BATCH_SIZE && (i+j) < numInputs; ++j) {
        int64_t dimSize = cat_dimension < THCTensor_(nDimension)(state, inputs[i+j])
          ? THCTensor_(size)(state, inputs[i+j], cat_dimension)
          : 1;

        stackInputs[j].input = THCTensor_(data)(state, inputs[i+j]);
        stackInputs[j].offset = offset;
        stackInputs[j].dimSize = dimSize;
        stackInputs[j].nElements = THCTensor_(nElement)(state, inputs[i+j]);
        cohortMax = cohortMax > stackInputs[j].nElements ? cohortMax : stackInputs[j].nElements;

        // update offset
        offset += dimSize;
      }
      THCudaCheck(cudaMemcpy(d_inputs, stackInputs, j * sizeof(CatArrInputTensor<real, unsigned int>), cudaMemcpyHostToDevice));

      // Next, let's consider how we set our kernel launch parameters.
      // We borrow from THCApply, which the kernel's internal indexing
      // is based on.
      dim3 applyBlock = getApplyBlock();

      // We also re-use the applyGrid - but note that we use the maximum number of
      // elements for a given tensor in this grouping to determine the count
      dim3 applyGrid;
      getApplyGrid(state, cohortMax, applyGrid);

      // Next, we set our grid's y component to be the number of tensors in
      // the batch. This will allow the kernel to determine which input
      // tensor it is responsible for copying
      applyGrid.y = j;

      switch (maxDim) {
        case 1:
          HANDLE_CASE(1);
          break;
        case 2:
          HANDLE_CASE(2);
          break;
        case 3:
          HANDLE_CASE(3);
          break;
        case 4:
          HANDLE_CASE(4);
          break;
      }
      THCudaCheck(cudaGetLastError());
    }
    if (!usedScratch) {
      THCudaCheck(THCudaFree(state, (void *)d_inputs));
    }
#undef HANDLE_CASE
  } else {
    offset = 0;
    for (j = 0; j < numInputs; j++)
    {
      // No reason to copy when input is empty
      if (!THCTensor_(nDimension)(state, inputs[j])) continue;

      int64_t dimSize = cat_dimension < THCTensor_(nDimension)(state, inputs[j])
               ? THCTensor_(size)(state, inputs[j], cat_dimension)
               : 1;

      THCTensor *nt = THCTensor_(newWithTensor)(state, result);
      THCTensor_(narrow)(state, nt, NULL, cat_dimension, offset, dimSize);
      THCTensor_(copy)(state, nt, inputs[j]);
      THCTensor_(free)(state, nt);
      offset += dimSize;
    }
  }
}

void THCTensor_(nonzero)(THCState* state, THCudaLongTensor *tensor,
                          THCTensor *self)
{
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 1, self  ));
  THCAssertSameGPU(THCudaLongTensor_checkGPU(state, 1, tensor));


  using namespace thrust::placeholders;
  THCThrustAllocator thrustAlloc(state);
  self = THCTensor_(newContiguous)(state, self);
  thrust::device_ptr<real> self_data(THCTensor_(data)(state, self));

  int num_dim = THCTensor_(nDimension)(state, self);
  int64_t N = THCTensor_(nElement)(state, self);

  THCudaLongTensor_resize2d(state, tensor, N, num_dim);
  tensor = THCudaLongTensor_newContiguous(state, tensor);
  thrust::device_ptr<int64_t> tensor_data(THCudaLongTensor_data(state, tensor));

  thrust::counting_iterator<int64_t> idxfirst(0);
  thrust::counting_iterator<int64_t> idxlast = idxfirst + N;

  typedef thrust::device_ptr<int64_t> Iter;
  strided_range<Iter> strided_tensor(tensor_data,
                                     tensor_data+N*num_dim, num_dim);

#if CUDA_VERSION >= 7000
  cudaStream_t stream = THCState_getCurrentStream(state);
#endif

  strided_range<Iter>::iterator dend = thrust::copy_if(
#if CUDA_VERSION >= 7000
    thrust::cuda::par(thrustAlloc).on(stream),
#endif
    idxfirst,
    idxlast,
    self_data,
    strided_tensor.begin(),
    NonZeroOp<real>()
  );

  int64_t num_nonzeros = thrust::distance(strided_tensor.begin(), dend);

  int64_t div = 1;
  for (int dim = num_dim-1; dim >= 0; dim--) {
    strided_range<Iter> stride_dim(tensor_data+dim,
                                   tensor_data+N*num_dim, num_dim);
    thrust::transform(
#if CUDA_VERSION >= 7000
      thrust::cuda::par(thrustAlloc).on(stream),
#endif
      strided_tensor.begin(),
      strided_tensor.end(),
      stride_dim.begin(),
      idx_functor(div, self->size[dim])
    );
    div *= self->size[dim];
  }

  THCudaLongTensor_resize2d(state, tensor, num_nonzeros, num_dim);

  THCTensor_(free)(state, self);
  THCudaLongTensor_free(state, tensor);

  THCudaCheck(cudaGetLastError());
}

void THCTensor_(diag)(THCState *state, THCTensor *self_, THCTensor *src_, int64_t k){
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 2, self_, src_));
  int nDimension = THCTensor_(nDimension)(state, src_);
  THArgCheck((nDimension == 2) || (nDimension == 1), 1, "expected a matrix or a vector");
  if (nDimension == 2) {
    int64_t stride0 = THCTensor_(stride)(state, src_, 0);
    int64_t stride1 = THCTensor_(stride)(state, src_, 1);
    int64_t size0 = THCTensor_(size)(state, src_, 0);
    int64_t size1 = THCTensor_(size)(state, src_, 1);
    int64_t size = (k > 0) ? min((int64_t)size0, (int64_t)size1 - k) : min((int64_t)size0 + k, (int64_t)size1);
    THCTensor_(resize1d)(state, self_, size);
    int64_t strideSelf = THCTensor_(stride)(state, self_, 0);
    const dim3 threads(min((int64_t)THCState_getCurrentDeviceProperties(state)->maxThreadsPerBlock, (int64_t)size));
    dim3 grid(min((int64_t)1024, (int64_t)THCCeilDiv(size, (int64_t)threads.x)));
    int64_t start = (k >= 0 ? k * stride1 : -k * stride0);
    THCTensor_copyFromDiagonal<real><<<grid, threads, 0, THCState_getCurrentStream(state)>>>
    (THCTensor_(data)(state, self_), THCTensor_(data)(state, src_), start, size, stride0 + stride1, strideSelf);
  } else {
    ptrdiff_t totalElements = THCTensor_(nElement)(state, src_);
    ptrdiff_t size = (k > 0) ? totalElements + k : totalElements - k;
    int64_t strideSrc = THCTensor_(stride)(state, src_, 0);
    THCTensor_(resize2d)(state, self_, size, size);
    THCTensor_(zero)(state, self_);
    int64_t stride0 = THCTensor_(stride)(state, self_, 0);
    int64_t stride1 = THCTensor_(stride)(state, self_, 1);
    const dim3 threads(min((int64_t)THCState_getCurrentDeviceProperties(state)->maxThreadsPerBlock, (int64_t)size));
    dim3 grid(min((int64_t)1024, (int64_t)THCCeilDiv(size, (ptrdiff_t)threads.x)));
    ptrdiff_t start = (k >= 0 ? k * stride1 : -k * stride0);
    THCTensor_copyToDiagonal<real><<<grid, threads, 0, THCState_getCurrentStream(state)>>>
    (THCTensor_(data)(state, self_), THCTensor_(data)(state, src_), start, totalElements, stride0 + stride1, strideSrc);
  }
  THCudaCheck(cudaGetLastError());
}

accreal THCTensor_(trace)(THCState *state, THCTensor *src_) {
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 1, src_));
  THArgCheck((src_->nDimension == 2), 1, "expected a matrix");
  THCTensor *diag = THCTensor_(new)(state);
  THCTensor_(diag)(state, diag, src_, 0);
  accreal trace = THCTensor_(sumall)(state, diag);
  THCTensor_(free)(state, diag);
  return trace;
}

#if defined(THC_REAL_IS_FLOAT) || defined(THC_REAL_IS_DOUBLE) || defined(THC_REAL_IS_HALF)

void THCTensor_(linspace)(THCState *state, THCTensor *r_, real a, real b, int64_t n) {
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 1, r_));
  THArgCheck(n > 1 || (n == 1 && (a == b)), 3, "invalid number of points");
  if (THCTensor_(nElement)(state, r_) != n) THCTensor_(resize1d)(state, r_, n);
  if (n == 1) THCTensor_(fill)(state, r_, a);
  else {
    THCTensor *r = THCTensor_(isContiguous)(state, r_)
                   ? r_ // if r_ is contiguous we can direct work on it
                   : THCTensor_(newContiguous)(state, r_);
    real step = THCNumerics<real>::div(THCNumerics<real>::sub(b, a),
                                       ScalarConvert<int64_t,real>::to(n - 1));
    LinspaceOp<real> linspace_method(a, step);
    thrust::device_ptr<real> data_(THCTensor_(data)(state, r));
    thrust::tabulate(data_, data_ + n, linspace_method);
    if (!THCTensor_(isContiguous)(state, r_)) { // We need to move data back to r_
      THCTensor_(freeCopyTo)(state, r, r_);
    }
  }
  THCudaCheck(cudaGetLastError());
}

void THCTensor_(logspace)(THCState *state, THCTensor *r_, real a, real b, int64_t n) {
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 1, r_));
  THArgCheck(n > 1 || (n == 1 && (a == b)), 3, "invalid number of points");
  if (THCTensor_(nElement)(state, r_) != n) THCTensor_(resize1d)(state, r_, n);
  if (n == 1) THCTensor_(fill)(state, r_, THCNumerics<real>::exp10(a));
  else {
    THCTensor *r = THCTensor_(isContiguous)(state, r_)
                   ? r_
                   : THCTensor_(newContiguous)(state, r_);
    real step = THCNumerics<real>::div(THCNumerics<real>::sub(b, a),
                                       ScalarConvert<int64_t,real>::to(n - 1));
    LogspaceOp<real> logspace_method(a, step);
    thrust::device_ptr<real> data_(THCTensor_(data)(state, r));
    thrust::tabulate(data_, data_ + n, logspace_method);
    if (!THCTensor_(isContiguous)(state, r_)) {
      THCTensor_(freeCopyTo)(state, r, r_);
    }
  }
  THCudaCheck(cudaGetLastError());
}

#endif

void THCTensor_(range)(THCState *state, THCTensor *r_, accreal xmin, accreal xmax, accreal step) {
  THCAssertSameGPU(THCTensor_(checkGPU)(state, 1, r_));
  THArgCheck(step > 0 || step < 0, 3, "step must be a non-null number");
  THArgCheck(((step > 0) && (xmax >= xmin)) || ((step < 0) && (xmax <= xmin))
              , 2, "upper bound and larger bound incoherent with step sign");
  ptrdiff_t size = (ptrdiff_t) (((xmax - xmin) / step) + 1);
  if (THCTensor_(nElement)(state, r_) != size) THCTensor_(resize1d)(state, r_, size);
  THCTensor *r = THCTensor_(isContiguous)(state, r_)
                 ? r_
                 : THCTensor_(newContiguous)(state, r_);
  LinspaceOp<real,accreal> linspace_method(xmin, step);
  thrust::device_ptr<real> data_(THCTensor_(data)(state, r));
  thrust::tabulate(data_, data_ + size, linspace_method);
  if (!THCTensor_(isContiguous)(state, r_)) THCTensor_(freeCopyTo)(state, r, r_);
  THCudaCheck(cudaGetLastError());
}

#endif
