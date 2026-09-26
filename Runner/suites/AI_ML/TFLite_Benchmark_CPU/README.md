# TFLite CPU Benchmark

Runs a user-provisioned TFLite graph through the image-provided
`benchmark_model` using three CPU threads, operator profiling, and 100 measured
runs. CPU benchmarking is supported on both Config 1/base and Config 2/overlay.

The primary image package is `tensorflow-lite-qcom-apps`. The suite never adds
PPAs or installs packages. On Yocto, provision the selected `.tflite` model on
the device and pass its path with `--model` or `TFLITE_MODEL`.

On Debian, Ubuntu, CentOS, RHEL, Fedora, Rocky Linux, or AlmaLinux, an operator
may explicitly request the official Qualcomm AI Hub Models Inception V3
TFLite `w8a8` asset. The reviewed default is release `0.63.0`, which was the
latest public tag when this suite was added. Retrieval uses an already
installed `qai-hub-models` CLI, or image-provided `curl`/`wget` and `unzip`.
The suite never installs those tools.

```sh
# Automatic Config 1/Config 2 detection
./run.sh --model /home/qcom/AIML/inception_v3_quantized.tflite

# Assert the expected image configuration
./run.sh --config1 --model /home/qcom/AIML/inception_v3_quantized.tflite
./run.sh --config2 --model /home/qcom/AIML/inception_v3_quantized.tflite

# Other side-loaded graphs
./run.sh --auto --model /tmp/yolov8_det_w8a8.tflite
./run.sh --auto --model /tmp/yolox.tflite

# Desktop distributions only, never used automatically on Yocto
./run.sh --fetch-model
./run.sh --fetch-model --ai-hub-version 0.63.0

# Environment form
TFLITE_CONFIGURATION=auto \
TFLITE_MODEL=/home/qcom/AIML/inception_v3_quantized.tflite \
TFLITE_TIMEOUT=120 \
./run.sh
```

Configuration examples:

- On Config 1, use `--auto` or `--config1`.
- On Config 2, use `--auto` or `--config2`.
- An explicit configuration that is unavailable on the image produces SKIP.
- CPU execution is supported on both configurations.

PASS requires at least 100 timing samples, a positive end-to-end average
inference time, and a positive profiled-node count. The average is logged in
microseconds and milliseconds and retained in `performance.tsv`. An omitted
model or missing automatically discovered benchmark tool produces SKIP. An
invalid supplied model path or runtime failure produces FAIL. Logs are retained
below `results/<test-name>/run-<timestamp>-<pid>/`.

The primary performance fields are available with:

```sh
find results -name performance.tsv -type f -print -exec cat {} \;
```

Reference: [Qualcomm AI Hub Models Inception V3](https://github.com/qualcomm/ai-hub-models/tree/v0.63.0/src/qai_hub_models/models/inception_v3).
