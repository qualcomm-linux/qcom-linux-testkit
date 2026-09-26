# TFLite QNN HTP Benchmark

Runs a user-provisioned TFLite graph through `libQnnTFLiteDelegate.so` with
`backend_type:htp;`, one thread, operator profiling, and 100 measured runs.
This QNN HTP benchmark is supported only on Config 2/overlay.

The runner inventories `tensorflow-lite-qcom-apps`, `qnn-tools`, and
`libqnn-dev`. The separate `QNN_Net_Run_Version` suite validates
`qnn-net-run --version`.

The target image must provide the QNN delegate, `libQnnHtp.so`, FastRPC runtime,
and matching HTP skels. Provision `yolov8_det_w8a8.tflite` separately and pass
its path with `--model` or `TFLITE_MODEL`. The suite does not add PPAs, install
packages, download models, copy files from a network share, or sideload QAIRT
components.

Qualcomm AI Hub Models `0.63.0` does not publish a directly fetchable YOLOv8
asset because of upstream licensing restrictions. Therefore this profile
requires a user-provisioned graph on Yocto and desktop distributions. An
explicit `--fetch-model` request fails with that explanation rather than
silently selecting a different model.

```sh
# Automatic detection, Config 2 is required
./run.sh --auto --model /home/qcom/AIML/yolov8_det_w8a8.tflite

# Assert Config 2 and use an explicit delegate path
./run.sh \
    --config2 \
    --model /home/qcom/AIML/yolov8_det_w8a8.tflite \
    --delegate /usr/lib/libQnnTFLiteDelegate.so

# Additional side-loaded graph
./run.sh --auto --model /tmp/yolox.tflite

# Confirm Config 1 is rejected before model execution
./run.sh --config1 --model /tmp/yolox.tflite

# Environment form
TFLITE_CONFIGURATION=config2 \
TFLITE_MODEL=/tmp/yolox.tflite \
TFLITE_DELEGATE_LIBRARY=/usr/lib/libQnnTFLiteDelegate.so \
TFLITE_DELEGATE_OPTIONS='backend_type:htp;' \
./run.sh
```

With `--auto`, the suite detects Config 2 from the installed QNN TFLite
delegate and HTP backend libraries. `--config1` produces SKIP before the model
is executed. A Config 1 request on a Config 2 image also produces SKIP because
the requested environment is unavailable.

PASS requires creation of the QNN external delegate, confirmation that the
complete graph executes through the delegate, `TfLiteQnnDelegate` profiling
evidence, at least 100 timing samples, and a positive end-to-end average
inference time. The test does not require exactly one delegate partition
because the number of profiled nodes depends on the supplied graph. The average
is logged in microseconds and milliseconds and retained in `performance.tsv`.
An omitted model or missing automatically discovered tool produces SKIP, while
CPU fallback, an invalid supplied path, incomplete installed QNN runtime, or
failed execution produces FAIL.

A valid HTP run contains all of the following evidence:

```text
EXTERNAL delegate created.
Explicitly applied EXTERNAL delegate, and the model graph will be completely executed by the delegate.
TfLiteQnnDelegate
```

Inspect the retained metric and complete benchmark output with:

```sh
find results -name performance.tsv -type f -print -exec cat {} \;
find results -name benchmark.log -type f -print
```

Reference: [Qualcomm AI Hub Models YOLOv8 Detection](https://github.com/qualcomm/ai-hub-models/tree/v0.63.0/src/qai_hub_models/models/yolov8_det).
