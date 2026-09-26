# TFLite GPU Benchmark

Runs a user-provisioned TFLite graph with TFLite's built-in GPU delegate using
`--use_gpu=true`, one thread, operator profiling, and 100 measured runs. This
accelerator benchmark is supported only on the Config 2/overlay image.

This is not the QNN external-delegate path. The primary image package is
`tensorflow-lite-qcom-apps`. The suite does not install packages, add the
Carmel PPA, or copy models from a network share. On Yocto, provision
`inception_v3_quantized.tflite` and pass its path with `--model` or
`TFLITE_MODEL`.

Supported desktop distributions may explicitly use `--fetch-model` to obtain
the official Qualcomm AI Hub Models Inception V3 TFLite `w8a8` asset. The
reviewed default is public release `0.63.0`. Retrieval uses existing target
tools and never installs Python or system packages.

```sh
# Automatic detection, Config 2 is required
./run.sh --auto --model /home/qcom/AIML/inception_v3_quantized.tflite

# Assert Config 2 explicitly
./run.sh --config2 --model /home/qcom/AIML/inception_v3_quantized.tflite

# Additional side-loaded models
./run.sh --auto --model /tmp/yolov8_det_w8a8.tflite
./run.sh --auto --model /tmp/yolox.tflite

# Confirm Config 1 is rejected before model execution
./run.sh --config1 --model /home/qcom/AIML/inception_v3_quantized.tflite

# Desktop distributions only
./run.sh --fetch-model

# Environment form
TFLITE_CONFIGURATION=config2 \
TFLITE_MODEL=/home/qcom/AIML/inception_v3_quantized.tflite \
./run.sh
```

With `--auto`, the suite detects Config 2 from the installed QNN TFLite
delegate and HTP backend libraries. `--config1` produces SKIP before the model
is executed. A Config 1 request on a Config 2 image also produces SKIP because
the requested environment is unavailable.

PASS requires successful GPU-mode execution, complete GPU delegation with zero
CPU fallback operations, at least 100 timing samples, a positive end-to-end
average inference time, and a positive profiled-node count. The average is
logged in microseconds and milliseconds and retained in `performance.tsv`.
Models containing operations unsupported by the GPU delegate fail with the
reported GPU and CPU operation counts. An omitted model or missing
automatically discovered benchmark tool produces SKIP. Invalid supplied paths
and runtime failures produce FAIL.

For example, output such as the following is a deliberate FAIL because the
reported latency includes CPU work:

```text
280 operations will run on the GPU, and the remaining 2 operations will run on the CPU.
```

A valid PASS must report complete execution by the GPU delegate and zero CPU
fallback operations. Inspect the retained result with:

```sh
find results -name performance.tsv -type f -print -exec cat {} \;
```

Reference: [Qualcomm AI Hub Models Inception V3](https://github.com/qualcomm/ai-hub-models/tree/v0.63.0/src/qai_hub_models/models/inception_v3).
