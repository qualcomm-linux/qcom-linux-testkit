# Kodiak NHX configurations

These four files configure `NativeHalX.OmniTest`. They can be selected through
an NHX wrapper or a nativehaltest client supporting JSON basenames via `--test`.
The runner passes the selected configuration without translating its settings
into an unrelated native testcase.

| JSON | Streams configured |
| --- | --- |
| `Preview_YUVNV12_MaxResolution_NHX.json` | One format-35 preview output |
| `Video_YUVNV12_MaxResolution_NHX.json` | One format-34 video output |
| `Prev_plus_Video_YUVNV12_MaxResolution_NHX.json` | Format-35 preview and format-34 video outputs |
| `Snapshot_YUVNV12_MaxResolution_NHX.json` | Format-35 preview and format-33 snapshot outputs |

All four retain their existing camera `0`, 150-frame, maximum-resolution,
stream usage/data-space and image-dump settings. In particular, the video JSON
uses format 34 despite its historical YUVNV12 filename. Renaming or translating
these fields would change existing coverage and is not part of native-HAL
support.

Use the same JSON selection with either an NHX wrapper or a native executable:

```sh
./run.sh --json Preview_YUVNV12_MaxResolution_NHX.json --target Kodiak
./run.sh --json Video_YUVNV12_MaxResolution_NHX.json --target Kodiak
./run.sh --json Prev_plus_Video_YUVNV12_MaxResolution_NHX.json --target Kodiak
./run.sh --json Snapshot_YUVNV12_MaxResolution_NHX.json --target Kodiak
```

Run these commands from the parent `Camera_NHX` directory. The folder name is
an explicit JSON selection, not automatic board or camera detection.

When only `nativehaltest` is installed, the runner stages the selected JSON at
`/etc/camera/test/NHX/<basename>.json` and invokes `--test <basename>` without
the extension. To choose native execution when a wrapper is also installed:

```sh
./run.sh --json Preview_YUVNV12_MaxResolution_NHX.json --target Kodiak --native-bin /usr/libexec/camx-kodiak/nativehaltest
```

The executable path above is an explicit override, automatic discovery does
not hardcode Kodiak. JSON settings, including camera and frame count, are not
overridden by native CLI defaults. Do not combine JSON with `--native-test`,
`--native-camera` or `--native-frames`. Wrapper staging and arguments remain
unchanged. Native execution still requires a successful report and fresh,
nonempty capture dumps with valid checksums.
