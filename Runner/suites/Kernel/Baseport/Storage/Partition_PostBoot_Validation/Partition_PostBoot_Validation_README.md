# Partition_PostBoot_Validation

## Overview

`Partition_PostBoot_Validation` validates that critical partitions and mount points are healthy after boot, before higher-level functional tests are executed.

This test is intended to act as an early post-boot gate and helps detect issues such as:

- missing required mounts
- wrong filesystem type on expected mount points
- partitions mounted read-only when read-write is expected
- autofs mount points that are not accessible
- storage or mount-related kernel errors after boot
- incomplete or degraded boot state due to filesystem or mount failures

The test is CI-friendly and writes a `.res` file with `PASS`, `FAIL`, or `SKIP`.

---

## What the test validates

The test performs the following checks:

1. Confirms required user-space tools are present.
2. Logs platform details.
3. Logs current mount inventory and block device inventory.
4. Verifies boot and mount readiness.
5. Validates expected mount points using a configurable mount matrix.
6. Optionally scans mount/storage-related kernel log errors.

This makes it useful as a post-boot storage sanity gate before running display, multimedia, networking, or application-level tests.

---

## Default validation matrix

By default, the test validates the following mount points:

- `/`
  - allowed filesystems: `ext4`, `erofs`, `squashfs`
  - read-write not required
  - no trigger access required

- `/efi`
  - allowed filesystems: `autofs`, `vfat`
  - read-write not required
  - trigger access required

- `/var/lib/tee`
  - allowed filesystem: `ext4`
  - read-write required
  - no trigger access required

Default matrix:

```sh
/:ext4,erofs,squashfs:0:0;/efi:autofs,vfat:0:1;/var/lib/tee:ext4:1:0
```

---

## Mount matrix format

The mount matrix is provided through `MOUNT_MATRIX` using the format:

```sh
mountpoint:fstype1,fstype2:rw_required:trigger_access
```

Where:

- `mountpoint` = expected mount path
- `fstype1,fstype2` = allowed filesystem types
- `rw_required`
  - `1` = mount must be writable
  - `0` = writable check not required
- `trigger_access`
  - `1` = access the path to trigger automount or autofs behavior
  - `0` = no access trigger needed

Multiple entries are separated by `;`.

Example:

```sh
MOUNT_MATRIX='/:ext4,erofs,squashfs:0:0;/efi:autofs,vfat:0:1;/var/lib/tee:ext4:1:0'
```

---

## Dependencies

The test expects the following tools to be available:

- `findmnt`
- `mount`
- `awk`
- `grep`
- `sed`
- `dmesg`
- `systemctl`
- `lsblk`
- `blkid`

If required dependencies are missing, the test will report `SKIP`.

---

## Parameters

### `ALLOW_DEGRADED`

Controls whether a degraded boot state is acceptable.

Values:

- `0` = degraded boot state is treated as failure
- `1` = degraded boot state is allowed

Default:

```sh
ALLOW_DEGRADED=0
```

---

### `SCAN_DMESG`

Controls whether storage and mount-related kernel logs are scanned.

Values:

- `1` = enable dmesg scan
- `0` = disable dmesg scan

Default:

```sh
SCAN_DMESG=1
```

---

### `MOUNT_MATRIX`

Defines the expected mount points and validation rules.

Default:

```sh
MOUNT_MATRIX='/:ext4,erofs,squashfs:0:0;/efi:autofs,vfat:0:1;/var/lib/tee:ext4:1:0'
```

---

## Usage

Run with defaults:

```sh
./run.sh
```

Run while allowing degraded boot state:

```sh
ALLOW_DEGRADED=1 ./run.sh
```

Run without dmesg scanning:

```sh
SCAN_DMESG=0 ./run.sh
```

Run with a custom mount matrix:

```sh
MOUNT_MATRIX='/:ext4:0:0;/efi:autofs,vfat:0:1;/var/lib/tee:ext4:1:0;/persist:ext4:1:0' ./run.sh
```

---

## Result file

The test generates:

```sh
Partition_PostBoot_Validation.res
```

Possible results:

- `Partition_PostBoot_Validation PASS`
- `Partition_PostBoot_Validation FAIL`
- `Partition_PostBoot_Validation SKIP`

---

## Pass criteria

The test passes when:

- required tools are available
- boot state is acceptable
- all required mount points are present
- each validated mount has an allowed filesystem type
- writable mounts pass writeability checks when required
- autofs or trigger-access mounts are accessible
- no blocking mount/storage-related issues are detected

---

## Fail criteria

The test fails when any of the following occurs:

- boot state is not acceptable
- a required mount point is missing
- filesystem type does not match the expected matrix
- a mount expected to be writable is not writable
- automount or autofs path is inaccessible
- mount/storage validation detects blocking errors
- optional dmesg scan detects relevant storage or mount failures

---

## Skip criteria

The test is skipped when:

- one or more required dependencies are unavailable
- the environment does not support the required validation flow

---

## Notes

- `/efi` may appear as `autofs` before access and transition to a real backing mount after access.
- The test is intended to be lightweight and suitable as an early boot validation gate.
- For platform-specific layouts, adjust `MOUNT_MATRIX` rather than changing the test logic.
