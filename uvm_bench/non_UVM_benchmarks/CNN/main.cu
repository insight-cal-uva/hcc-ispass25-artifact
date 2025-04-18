#define USE_MNIST_LOADER
#define MNIST_DOUBLE
#include "layer.h"
#include "mnist.h"

#include <cstdio>
#include <cuda.h>
#include <time.h>

#include "../../common/file_op.h"

static mnist_data *train_set, *test_set;
static unsigned int train_cnt, test_cnt;

// Define layers of CNN
static Layer l_input = Layer(0, 0, 28 * 28);
static Layer l_c1 = Layer(5 * 5, 6, 24 * 24 * 6);
static Layer l_s1 = Layer(4 * 4, 1, 6 * 6 * 6);
static Layer l_f = Layer(6 * 6 * 6, 10, 10);

static void learn();
static unsigned int classify(double data[28][28]);
static void test();
static double forward_pass(double data[28][28]);
static double back_pass();

static inline void loaddata() {
  mnist_load("/shared/uvm_bench/non_UVM_benchmarks/CNN/data/train-images.idx3-ubyte", "/shared/uvm_bench/non_UVM_benchmarks/CNN/data/train-labels.idx1-ubyte",
             &train_set, &train_cnt);
  mnist_load("/shared/uvm_bench/non_UVM_benchmarks/CNN/data/t10k-images.idx3-ubyte", "/shared/uvm_bench/non_UVM_benchmarks/CNN/data/t10k-labels.idx1-ubyte",
             &test_set, &test_cnt);
  printf("Data loading done!\n");
}

float bt_malloc;
float bt_memcpy_h2d;
float bt_lauch;
float bt_kernel;
float bt_memcpy_d2h;
float bt_free;
float bt_memset;

int main(int argc, const char **argv) {
  srand(time(NULL));

  CUresult err = cuInit(0);
  if (err != CUDA_SUCCESS) {
    fprintf(stderr, "CUDA initialisation failed with error code - %d\n", err);
    return 1;
  }

  loaddata();
  learn();

  bt_malloc = l_input.bt_malloc + l_c1.bt_malloc + l_s1.bt_malloc + l_f.bt_malloc;
  bt_memcpy_h2d = l_input.bt_memcpy_h2d + l_c1.bt_memcpy_h2d + l_s1.bt_memcpy_h2d + l_f.bt_memcpy_h2d;
  float cp_bt_lauch = bt_lauch;
  float cp_bt_kernel = bt_kernel;
  test();

  l_input.cudafree();
  l_c1.cudafree();
  l_s1.cudafree();
  l_f.cudafree();
  bt_free = l_input.bt_free + l_c1.bt_free + l_s1.bt_free + l_f.bt_free;
	save_log("cnn.cu", "nor-brk", NULL, "%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f,%0.6f\n", bt_malloc, bt_memcpy_h2d, cp_bt_lauch, cp_bt_kernel, bt_memcpy_d2h, bt_free, bt_memset);

  return 0;
}

// Forward propagation of a single row in dataset
static double forward_pass(double data[28][28]) {
  float input[28][28];

  for (int i = 0; i < 28; ++i) {
    for (int j = 0; j < 28; ++j) {
      input[i][j] = data[i][j];
    }
  }

  // memset
  l_input.clear();
  l_c1.clear();
  l_s1.clear();
  l_f.clear();
  bt_memset += l_input.bt_memset + l_c1.bt_memset + l_s1.bt_memset + l_f.bt_memset;
  
  // h2d
  l_input.setOutput((float *)input);
  
  clock_t start, end;
  start = clock();
  fp_preact_c1<<<64, 64>>>((float(*)[28])l_input.output,
                           (float(*)[24][24])l_c1.preact,
                           (float(*)[5][5])l_c1.weight);
  fp_bias_c1<<<64, 64>>>((float(*)[24][24])l_c1.preact, l_c1.bias);
  apply_step_function<<<64, 64>>>(l_c1.preact, l_c1.output, l_c1.O);

  fp_preact_s1<<<64, 64>>>((float(*)[24][24])l_c1.output,
                           (float(*)[6][6])l_s1.preact,
                           (float(*)[4][4])l_s1.weight);
  fp_bias_s1<<<64, 64>>>((float(*)[6][6])l_s1.preact, l_s1.bias);
  apply_step_function<<<64, 64>>>(l_s1.preact, l_s1.output, l_s1.O);

  fp_preact_f<<<64, 64>>>((float(*)[6][6])l_s1.output, l_f.preact,
                          (float(*)[6][6][6])l_f.weight);
  fp_bias_f<<<64, 64>>>(l_f.preact, l_f.bias);
  apply_step_function<<<64, 64>>>(l_f.preact, l_f.output, l_f.O);
  clock_t tlaunch = clock();
  cudaDeviceSynchronize();
  end = clock();

  bt_lauch += ((double)(tlaunch - start)) / CLOCKS_PER_SEC;
  bt_kernel += ((double)(end - tlaunch)) / CLOCKS_PER_SEC;

  return ((double)(end - tlaunch)) / CLOCKS_PER_SEC;
}

// Back propagation to update weights
static double back_pass() {

  clock_t start, end;
  start = clock();
  bp_weight_f<<<64, 64>>>((float(*)[6][6][6])l_f.d_weight, l_f.d_preact,
                          (float(*)[6][6])l_s1.output);
  bp_bias_f<<<64, 64>>>(l_f.bias, l_f.d_preact);
  bp_output_s1<<<64, 64>>>((float(*)[6][6])l_s1.d_output,
                           (float(*)[6][6][6])l_f.weight, l_f.d_preact);
  bp_preact_s1<<<64, 64>>>((float(*)[6][6])l_s1.d_preact,
                           (float(*)[6][6])l_s1.d_output,
                           (float(*)[6][6])l_s1.preact);
  bp_weight_s1<<<64, 64>>>((float(*)[4][4])l_s1.d_weight,
                           (float(*)[6][6])l_s1.d_preact,
                           (float(*)[24][24])l_c1.output);
  bp_bias_s1<<<64, 64>>>(l_s1.bias, (float(*)[6][6])l_s1.d_preact);
  bp_output_c1<<<64, 64>>>((float(*)[24][24])l_c1.d_output,
                           (float(*)[4][4])l_s1.weight,
                           (float(*)[6][6])l_s1.d_preact);
  bp_preact_c1<<<64, 64>>>((float(*)[24][24])l_c1.d_preact,
                           (float(*)[24][24])l_c1.d_output,
                           (float(*)[24][24])l_c1.preact);
  bp_weight_c1<<<64, 64>>>((float(*)[5][5])l_c1.d_weight,
                           (float(*)[24][24])l_c1.d_preact,
                           (float(*)[28])l_input.output);
  bp_bias_c1<<<64, 64>>>(l_c1.bias, (float(*)[24][24])l_c1.d_preact);
  apply_grad<<<64, 64>>>(l_f.weight, l_f.d_weight, l_f.M * l_f.N);
  apply_grad<<<64, 64>>>(l_s1.weight, l_s1.d_weight, l_s1.M * l_s1.N);
  apply_grad<<<64, 64>>>(l_c1.weight, l_c1.d_weight, l_c1.M * l_c1.N);
  clock_t tlaunch = clock();
  cudaDeviceSynchronize();
  end = clock();

  bt_lauch += ((double)(tlaunch - start)) / CLOCKS_PER_SEC;
  bt_kernel += ((double)(end - tlaunch)) / CLOCKS_PER_SEC;

  return ((double)(end - tlaunch)) / CLOCKS_PER_SEC;
}

// Unfold the input layer
static void unfold_input(double input[28][28],
                         double unfolded[24 * 24][5 * 5]) {
  int a = 0;
  (void)unfold_input;

  for (int i = 0; i < 2; ++i)
    for (int j = 0; j < 2; ++j) {
      int b = 0;
      for (int x = i; x < i + 2; ++x)
        for (int y = j; y < j + 2; ++y)
          unfolded[a][b++] = input[x][y];
      a++;
    }
}

static void learn() {
  static cublasHandle_t blas;
  cublasCreate(&blas);

  float err;
  int iter = 1;

  double time_taken = 0.0;

  fprintf(stdout, "Learning\n");

  while (iter < 0 || iter-- > 0) {
    err = 0.0f;
    train_cnt == 1;
    for (int i = 0; i < train_cnt; ++i) {
      float tmp_err;

      time_taken += forward_pass(train_set[i].data);

      l_f.bp_clear();
      l_s1.bp_clear();
      l_c1.bp_clear();
      bt_memset += l_f.bt_memset + l_s1.bt_memset + l_c1.bt_memset;

      // Euclid distance of train_set[i]
      makeError<<<10, 1>>>(l_f.d_preact, l_f.output, train_set[i].label, 10);
      cublasSnrm2(blas, 10, l_f.d_preact, 1, &tmp_err);
      err += tmp_err;

      time_taken += back_pass();
    }

    err /= train_cnt;
    fprintf(stdout, "error: %e, time_on_gpu: %lf\n", err, time_taken);

    if (err < threshold) {
      fprintf(stdout, "Training complete, error less than threshold\n\n");
      break;
    }
  }
  fprintf(stdout, "Training complete\n\n");
  fprintf(stdout, "\n Time - %lf\n", time_taken);

  // FILE * fp = fopen("/shared/uvm_bench/log/cnn.txt", "a");
	// if (fp == NULL) {
	// 	fprintf(stderr, "Error opening file!\n");
	// 	exit(1);
	// }
	// fprintf(fp, "%lf\n", time_taken);
  // fclose(fp);

}

// Returns label of given data (0-9)
static unsigned int classify(double data[28][28]) {
  float res[10];

  forward_pass(data);

  unsigned int max = 0;

  cudaMemcpy(res, l_f.output, sizeof(float) * 10, cudaMemcpyDeviceToHost);

  for (int i = 1; i < 10; ++i) {
    if (res[max] < res[i]) {
      max = i;
    }
  }

  return max;
}

// Perform forward propagation of test data
static void test() {
  fprintf(stdout, "Testing!\n");
  int error = 0;
  test_cnt = 1;
  for (int i = 0; i < test_cnt; ++i) {
    if (classify(test_set[i].data) != test_set[i].label) {
      ++error;
    }
  }

  fprintf(stdout, "Error Rate: %.2lf%%\n",
          double(error) / double(test_cnt) * 100.0);
}
