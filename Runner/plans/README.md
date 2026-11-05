# Meta-qcom nightly plans

`meta-qcom-nightly_config1.yaml` and `meta-qcom-nightly_config2.yaml` target
multimedia rootfs images. Config1 additionally runs OpenCV. These plans do not
establish kernel-only ramdisk coverage.

Each test runs from its own suite directory, with `TMPDIR` set to that working
directory. The plan removes the expected result before invocation and publishes
it immediately afterwards. A missing, empty or malformed result produces a
separate `<testcase>_result_publication` failure, while later tests continue.
An ordinary test FAIL or SKIP remains a test result, not a publication failure.

Config2 finalizes after the individual results have been published. It does
not run a final result parser or add an aggregate summary testcase. Failed
testcases and missing or malformed result files remain visible through the
individual result and publication-failure signals described above.

Config1 retains its final result parser. A nonzero parser exit publishes
`meta-qcom-nightly_config1_result_summary` as FAIL through `lava-test-case`,
then allows LAVA to finalize normally. A successful parser adds no summary
testcase. The parser's behavior for other plans and direct callers is unchanged.

The existing result sender supports opt-in validation:

```sh
TMPDIR="$PWD" "$REPO_PATH/Runner/utils/send-to-lava.sh" AudioRecord_config1.res --strict
```

Strict mode requires one or more two-field `testcase PASS|FAIL|SKIP` records.
Blank lines and comments are ignored. Invalid files emit no partial results and
return nonzero. Callers without `--strict` retain permissive publication.
`--legacy-testcase-id Audio_Playback` explicitly supplies the testcase name for
the GStreamer audio runner's single-field result format. It does not rename
records that already contain a testcase name.

Audio playback and recording publish separate IDs such as
`AudioPlayback_config1` and `AudioRecord_config1` through `config10`. Dashboards
that previously matched only `AudioPlayback` or `AudioRecord` need to include
these configuration suffixes. The existing route and duration selections are
preserved. Audio stack discovery selects the installed base or overlay runtime.

LAVA supplies `/Lava_binaries/AudioClips.tar.gz` and
`/Lava_binaries/video_clips_iris.tar.gz`. Audio runners receive the extracted
audio directory explicitly. Iris JSON configurations remain exclusive to
`Video_V4L2_Runner`. GStreamer uses its own CLI and the optional
`/Lava_binaries/video_clips_gst.tar.gz`, containing `VP9_640x480_10s.webm` at its
root. If that fixture is absent, the GStreamer runner retains its existing
download fallback. Fixture permissions allow reading and directory traversal
without granting world-write access. The plans do not install packages.

The stale DMA-BUF paths now invoke the existing IGT `dmabuf` suite and
`DMA_BUF_Heap_Validation`. The latter validates runtime heap allocation and
mapping, it is not a replacement for every upstream DMA-BUF selftest.
The nonexistent `cacheflush`, `hrtimer` and `ipi` runner entries are removed.
Existing Timer, GIC and Interrupts tests remain, but dedicated cache-flush,
high-resolution timer and IPI selftest coverage remains a separate gap.

For reproducible validation, pin the test definition to the intended commit and
compare the deployed image's running kernel with the job description. A passing
result on one image does not validate a different kernel or rootfs.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

SPDX-License-Identifier: BSD-3-Clause
