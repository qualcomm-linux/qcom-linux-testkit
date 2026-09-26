# AI/ML Validation Suites

The benchmark coverage is split into focused suites so each command publishes
an independent result.

- Config 1/base supports only `TFLite_Benchmark_CPU`.
- Config 2/overlay supports `TFLite_Benchmark_CPU`, `TFLite_Benchmark_GPU`,
  and `TFLite_Benchmark_QNNHTP`. `QNN_Net_Run_Version` separately validates
  QNN tool readiness.
- `TFLite_Benchmark_GPU` uses TFLite's built-in GPU delegate and is not
  reported as QNN coverage.

Models are external test assets. Provision the required `.tflite` file on the
device and pass its path through `--model` or `TFLITE_MODEL`. This is the
required Yocto workflow.

On supported desktop distributions, the Inception CPU and GPU suites can
explicitly download the official Qualcomm AI Hub Models TFLite `w8a8` asset
with `--fetch-model`. The default release is `0.63.0`, the latest public tag
reviewed when this code was written. The test uses only preinstalled download
tools and never installs packages. YOLOv8 remains side-loaded because that
release does not publish a directly fetchable asset due to upstream licensing.

The primary executable package is `tensorflow-lite-qcom-apps`. QNN coverage
also needs the image-provided QNN delegate and backend runtime. GStreamer
packages are not required by these `benchmark_model` suites and remain the
responsibility of the separate GStreamer AI/ML coverage.

Debian and Ubuntu package mappings are defined as:

- `ai-ml-tflite`: `tensorflow-lite-qcom-apps`
- `ai-ml-qnn`: `tensorflow-lite-qcom-apps libqnn-dev qnn-tools`
- `benchmark_model`: `tensorflow-lite-qcom-apps`
- `qnn-net-run`: `qnn-tools`

The mappings are used for dependency reporting only. The suites never install
packages at runtime. CentOS mappings remain intentionally undefined until its
exact RPM package names are confirmed.

The benchmark runners accept `--config1`/`--base`, `--config2`/`--overlay`, or
`--auto`. Auto mode identifies Config 2 when both `libQnnTFLiteDelegate.so` and
`libQnnHtp.so` are installed; otherwise it selects Config 1. GPU and HTP suites
skip before model execution when Config 1 is active. CPU remains valid on both
configurations. Explicit configuration selection is useful when CI already
knows which image configuration was deployed. An explicit selection that does
not match the installed runtime evidence produces SKIP because the requested
test environment is unavailable on that image.

Each benchmark publishes the end-to-end `Inference (avg)` value in microseconds
and milliseconds. Older benchmark builds that expose only a
`Timings (microseconds)` summary remain supported. A run cannot pass when the
average timing value is absent, malformed, or zero. GPU and QNN HTP runs must
also confirm complete accelerator delegation and fail if CPU fallback occurs.

## Yocto validation

Yocto requires models to be side-loaded by the user. For example:

```sh
ls -lh \
    /tmp/inception_v3_quantized.tflite \
    /tmp/yolov8_det_w8a8.tflite \
    /tmp/yolox.tflite
```

Run all four focused tests from the repository root:

```sh
# Config 2 QNN tool readiness
cd Runner/suites/AI_ML/QNN_Net_Run_Version
./run.sh

# Config 1 or Config 2 CPU inference
cd ../TFLite_Benchmark_CPU
./run.sh --auto --model /tmp/inception_v3_quantized.tflite

# Config 2 GPU inference
cd ../TFLite_Benchmark_GPU
./run.sh --auto --model /tmp/inception_v3_quantized.tflite

# Config 2 QNN HTP inference
cd ../TFLite_Benchmark_QNNHTP
./run.sh --auto --model /tmp/yolox.tflite
```

Additional model coverage can be run by replacing `--model` with any readable
`.tflite` graph. For example:

```sh
./run.sh --auto --model /tmp/yolov8_det_w8a8.tflite
./run.sh --auto --model /tmp/yolox.tflite
```

Use `--config1` or `--config2` when the expected image configuration is known.
The explicit value is checked against the installed QNN runtime evidence:

```sh
./run.sh --config1 --model /tmp/inception_v3_quantized.tflite
./run.sh --config2 --model /tmp/inception_v3_quantized.tflite
```

Expected configuration behavior:

| Suite | Config 1/base | Config 2/overlay |
| --- | --- | --- |
| `QNN_Net_Run_Version` | Not applicable | Supported |
| `TFLite_Benchmark_CPU` | Supported | Supported |
| `TFLite_Benchmark_GPU` | SKIP | Supported, CPU fallback is FAIL |
| `TFLite_Benchmark_QNNHTP` | SKIP | Supported, complete QNN delegation required |

Useful negative checks:

```sh
# No model: SKIP
./run.sh --auto

# Invalid explicit model: FAIL
./run.sh --auto --model /tmp/missing-model.tflite

# Invalid explicit benchmark executable: FAIL
./run.sh --benchmark /tmp/missing-benchmark \
    --model /tmp/inception_v3_quantized.tflite

# Invalid configuration value: FAIL
./run.sh --configuration invalid \
    --model /tmp/inception_v3_quantized.tflite
```

Requesting a valid but unavailable configuration produces SKIP:

```sh
# Config 1 request on a Config 2 image, or the reverse
./run.sh --config1 --model /tmp/inception_v3_quantized.tflite
./run.sh --config2 --model /tmp/inception_v3_quantized.tflite
```

Inspect the final metric and retained evidence after each benchmark:

```sh
find results -name performance.tsv -type f -print -exec cat {} \;
find results -name benchmark.log -type f -print
```
