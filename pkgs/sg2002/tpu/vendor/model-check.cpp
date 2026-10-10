// SPDX-License-Identifier: MIT
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <vector>
#include "sg2002_forward.h"

int main(int argc, char **argv) {
  if (argc != 4 && argc != 5) {
    fprintf(stderr, "usage: sg2002-tpu-model-check MODEL INPUT.raw REFERENCE.f32 [REPEATS]\n");
    return 2;
  }
  CVI_MODEL_HANDLE model = nullptr;
  if (CVI_NN_RegisterModel(argv[1], &model) != CVI_RC_SUCCESS)
    return 1;
  CVI_TENSOR *inputs, *outputs;
  int input_num, output_num;
  bool ok = false;
  if (CVI_NN_GetInputOutputTensors(model, &inputs, &input_num, &outputs, &output_num) !=
      CVI_RC_SUCCESS || input_num != 1) {
    fprintf(stderr, "Reference checker requires one model input\n");
    CVI_NN_CleanupModel(model);
    return 1;
  }
  std::ifstream input(argv[2], std::ios::binary), reference(argv[3], std::ios::binary);
  if (!input || !reference ||
      !input.read(static_cast<char *>(CVI_NN_TensorPtr(inputs)), inputs[0].mem_size) ||
      input.peek() != std::ifstream::traits_type::eof()) {
    fprintf(stderr, "Input file must contain exactly %zu bytes\n", inputs[0].mem_size);
    CVI_NN_CleanupModel(model);
    return 1;
  }
  if (sg2002_forward(model, inputs, input_num, outputs, output_num,
                     argc == 5 ? argv[4] : nullptr)) {
    ok = true;
    for (int i = 0; i < output_num; i++) {
      const CVI_TENSOR &tensor = outputs[i];
      if (tensor.fmt != CVI_FMT_FP32) {
        fprintf(stderr, "Reference checker requires FP32 outputs\n");
        ok = false;
        break;
      }
      std::vector<float> expected(tensor.count);
      if (!reference.read(reinterpret_cast<char *>(expected.data()), expected.size() * 4)) {
        fprintf(stderr, "Reference file is too short\n");
        ok = false;
        break;
      }
      auto actual = static_cast<const float *>(CVI_NN_TensorPtr(&outputs[i]));
      float max_error = 0;
      size_t mismatches = 0;
      for (size_t j = 0; j < expected.size(); j++) {
        float error = std::abs(actual[j] - expected[j]);
        max_error = std::max(max_error, error);
        if (!std::isfinite(actual[j]) || !std::isfinite(expected[j]) ||
            error > 1e-6f * std::max(1.0f, std::abs(expected[j])))
          mismatches++;
      }
      printf("%s: %zu values, max absolute error %.9g, %zu mismatches\n",
             tensor.name, expected.size(), max_error, mismatches);
      ok &= mismatches == 0;
    }
    if (reference.peek() != std::ifstream::traits_type::eof()) {
      fprintf(stderr, "Reference file has trailing data\n");
      ok = false;
    }
  }
  CVI_NN_CleanupModel(model);
  return ok ? 0 : 1;
}
