/**
 * 2DConvolution.cu: This file is part of the PolyBench/GPU 1.0 test suite.
 *
 *
 * Contact: Scott Grauer-Gray <sgrauerg@gmail.com>
 * Louis-Noel Pouchet <pouchet@cse.ohio-state.edu>
 * Web address: http://www.cse.ohio-state.edu/~pouchet/software/polybench/GPU
 */

#include <unistd.h>
#include <stdio.h>
#include <time.h>
#include <sys/time.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <cuda.h>

#include "../../../common/polybenchUtilFuncts.h"

//define the error threshold for the results "not matching"
#define PERCENT_DIFF_ERROR_THRESHOLD 0.05

#define GPU_DEVICE 0

/* Problem size */
#define NI 4096
#define NJ 4096

/* Thread block dimensions */
#define DIM_THREAD_BLOCK_X 32
#define DIM_THREAD_BLOCK_Y 8

/* Can switch DATA_TYPE between float and double */
typedef float DATA_TYPE;

double t_lauch;
double t_kernel;

void conv2D(DATA_TYPE* A, DATA_TYPE* B)
{
	int i, j;
	DATA_TYPE c11, c12, c13, c21, c22, c23, c31, c32, c33;

	c11 = +0.2;  c21 = +0.5;  c31 = -0.8;
	c12 = -0.3;  c22 = +0.6;  c32 = -0.9;
	c13 = +0.4;  c23 = +0.7;  c33 = +0.10;


	for (i = 1; i < NI - 1; ++i) // 0
	{
		for (j = 1; j < NJ - 1; ++j) // 1
		{
			B[i*NJ + j] = c11 * A[(i - 1)*NJ + (j - 1)]  +  c12 * A[(i + 0)*NJ + (j - 1)]  +  c13 * A[(i + 1)*NJ + (j - 1)]
				+ c21 * A[(i - 1)*NJ + (j + 0)]  +  c22 * A[(i + 0)*NJ + (j + 0)]  +  c23 * A[(i + 1)*NJ + (j + 0)] 
				+ c31 * A[(i - 1)*NJ + (j + 1)]  +  c32 * A[(i + 0)*NJ + (j + 1)]  +  c33 * A[(i + 1)*NJ + (j + 1)];
		}
	}
}



void init(DATA_TYPE* A, DATA_TYPE* A_gpu)
{
	int i, j;

	for (i = 0; i < NI; ++i)
    	{
		for (j = 0; j < NJ; ++j)
		{
			float temp =  (float)rand()/RAND_MAX;
			A[i*NJ + j] = temp;
			A_gpu[i*NJ + j] = temp;
        	}
    	}
}


void compareResults(DATA_TYPE* B, DATA_TYPE* B_outputFromGpu)
{
	int i, j, fail;
	fail = 0;
	
	// Compare a and b
	for (i=1; i < (NI-1); i++) 
	{
		for (j=1; j < (NJ-1); j++) 
		{
			if (percentDiff(B[i*NJ + j], B_outputFromGpu[i*NJ + j]) > PERCENT_DIFF_ERROR_THRESHOLD) 
			{
				fail++;
			}
		}
	}
	
	// Print results
	printf("Non-Matching CPU-GPU Outputs Beyond Error Threshold of %4.2f Percent: %d\n", PERCENT_DIFF_ERROR_THRESHOLD, fail);
	
}


void GPU_argv_init()
{
	cudaDeviceProp deviceProp;
	cudaGetDeviceProperties(&deviceProp, GPU_DEVICE);
	printf("setting device %d with name %s\n",GPU_DEVICE,deviceProp.name);
	cudaSetDevice( GPU_DEVICE );
}


__global__ void Convolution2D_kernel(DATA_TYPE *A, DATA_TYPE *B)
{
	int j = blockIdx.x * blockDim.x + threadIdx.x;
	int i = blockIdx.y * blockDim.y + threadIdx.y;

	DATA_TYPE c11, c12, c13, c21, c22, c23, c31, c32, c33;

	c11 = +0.2;  c21 = +0.5;  c31 = -0.8;
	c12 = -0.3;  c22 = +0.6;  c32 = -0.9;
	c13 = +0.4;  c23 = +0.7;  c33 = +0.10;

	if ((i < NI-1) && (j < NJ-1) && (i > 0) && (j > 0))
	{
		B[i * NJ + j] =  c11 * A[(i - 1) * NJ + (j - 1)]  + c21 * A[(i - 1) * NJ + (j + 0)] + c31 * A[(i - 1) * NJ + (j + 1)] 
			+ c12 * A[(i + 0) * NJ + (j - 1)]  + c22 * A[(i + 0) * NJ + (j + 0)] +  c32 * A[(i + 0) * NJ + (j + 1)]
			+ c13 * A[(i + 1) * NJ + (j - 1)]  + c23 * A[(i + 1) * NJ + (j + 0)] +  c33 * A[(i + 1) * NJ + (j + 1)];
	}
}



void convolution2DCuda(DATA_TYPE* A_gpu, DATA_TYPE* B_gpu)
{


	double t_start, t_end;
	
	dim3 block(DIM_THREAD_BLOCK_X, DIM_THREAD_BLOCK_Y);
	dim3 grid((size_t)ceil( ((float)NI) / ((float)block.x) ), (size_t)ceil( ((float)NJ) / ((float)block.y)) );
	t_start = rtclock();

	#ifdef PREF
	cudaStream_t stream1;
	cudaStream_t stream2;
	cudaStreamCreate(&stream1);
	cudaStreamCreate(&stream2);

	for (int i = 0; i < 1; i++)
	{
		cudaMemPrefetchAsync(A_gpu,NI*NJ*sizeof(DATA_TYPE), GPU_DEVICE, stream1 );
		cudaStreamSynchronize(stream1);
		cudaMemPrefetchAsync(B_gpu,NI*NJ*sizeof(DATA_TYPE), GPU_DEVICE, stream2 );
		cudaStreamSynchronize(stream2);
		// cudaMemset(B_gpu,0 ,NI*NJ*sizeof(DATA_TYPE));
		Convolution2D_kernel<<<grid,block, 0,stream2>>>(A_gpu,B_gpu);
		cudaDeviceSynchronize();
	}
	t_end = rtclock();
	fprintf(stdout, "GPU Runtime: %0.6lfs\n", t_end - t_start);//);
		save_log(__FILE__,"uvm_pref",NULL, "%0.6lf\n", t_end - t_start);
	#else
		for (int i = 0; i < 1; i++)
		{
			double l_s = rtclock();
			Convolution2D_kernel<<<grid,block>>>(A_gpu,B_gpu);
			double l_e = rtclock();
			cudaDeviceSynchronize();
			double k_e = rtclock();

			t_lauch = l_e - l_s;
			t_kernel = k_e - l_e;
		}

		// t_end = rtclock();
		fprintf(stdout, "GPU Runtime: %0.6lfs\n", t_kernel+t_lauch);//);
		// save_log(__FILE__,"uvm",NULL, "%0.6lf\n", t_end - t_start);
	#endif


}


int main(int argc, char *argv[])
{
	double t_start, t_end;

	DATA_TYPE* A;
	DATA_TYPE* B;  
	DATA_TYPE *A_gpu;
	DATA_TYPE *B_gpu;


	A = (DATA_TYPE*)malloc(NI*NJ*sizeof(DATA_TYPE));
	B = (DATA_TYPE*)malloc(NI*NJ*sizeof(DATA_TYPE));

	
	double  malloc_s = rtclock();
	cudaMallocManaged(&A_gpu, sizeof(DATA_TYPE) * NI * NJ);
	cudaMallocManaged(&B_gpu, sizeof(DATA_TYPE) * NI * NJ);
	double malloc_e = rtclock();



	// B_outputFromGpu = (DATA_TYPE*)malloc(NI*NJ*sizeof(DATA_TYPE));

	//initialize the arrays
	init(A, A_gpu);
	
	GPU_argv_init();

	convolution2DCuda(A_gpu, B_gpu);
	
	// t_start = rtclock();
	// conv2D(A, B);
	// t_end = rtclock();
	// fprintf(stdout, "CPU Runtime: %0.6lfs\n", t_end - t_start);//);
	
	// compareResults(B, B_gpu);	

	printf("B[0] = %f\n", B_gpu[0]);

	free(A);
	free(B);
	
	double free_s = rtclock();
	cudaFree(A_gpu);
	cudaFree(B_gpu);
	double free_e = rtclock();


	double bt_malloc = malloc_e - malloc_s;
	double bt_memcpy_h2d = 0.0;
	double bt_lauch = t_lauch;
	double bt_kernel = t_kernel;
	double bt_memcpy_d2h = 0.0;
	double bt_free = free_e - free_s;
	double bt_memset = 0.0;
	save_log(__FILE__, "uvm-brk", NULL, "%0.6lf,%0.6lf,%0.6lf,%0.6lf,%0.6lf,%0.6lf,%0.6lf\n", bt_malloc, bt_memcpy_h2d, bt_lauch, bt_kernel, bt_memcpy_d2h, bt_free,bt_memset);

	
	return 0;
}


