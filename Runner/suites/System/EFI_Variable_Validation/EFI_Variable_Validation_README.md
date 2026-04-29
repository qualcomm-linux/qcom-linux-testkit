# EFI_Variable_Validation

Validates required EFI-related kernel configuration and EFI variable runtime behavior on the target.

## What this test checks

The test verifies that the following kernel configs are present with the exact expected values:

- `CONFIG_EFI=y`
- `CONFIG_EFI_ESRT=y`
- `CONFIG_EFIVAR_FS=y`

It also validates the EFI runtime path by checking:

- `/sys/firmware/efi`
- `/sys/firmware/efi/efivars`
- EFI variable enumeration through `efivar -l`

## EFI variable validation flow

The test performs two variable checks.

### 1. `OsTrialBootStatus`

The test writes the following payload to:

- `8be4df61-93ca-11d2-aa0d-00e098032b8c-OsTrialBootStatus`

Payload written:

- `01 77 01 00 00 00 00 00`

The test then reads the variable back and validates:

- GUID
- variable name
- attributes:
  - `Non-Volatile`
  - `Boot Service Access`
  - `Runtime Service Access`
- payload bytes:
  - `01 77 01 00 00 00 00 00`

### 2. `OsIndicationsSupported`

The test reads:

- `8be4df61-93ca-11d2-aa0d-00e098032b8c-OsIndicationsSupported`

The test validates:

- GUID
- variable name
- attributes:
  - `Boot Service Access`
  - `Runtime Service Access`
- expected value:
  - `04 00 00 00 00 00 00 00`

## ESRT behavior

The test checks that `CONFIG_EFI_ESRT=y` is enabled.

If `/sys/firmware/efi/esrt` is not exposed by firmware, the test logs a warning rather than failing. This avoids false failures when kernel support is present but the firmware does not publish an ESRT table.

## Result semantics

- `PASS` when EFI kernel config, `OsTrialBootStatus` write or read validation, and `OsIndicationsSupported` attribute or value checks pass
- `FAIL` when a required config is missing, EFI runtime directories are unavailable, variable listing fails, write fails, readback fails, or attributes or values do not match the expected output
- `SKIP` when required userspace dependency `efivar` is not available

## Output

The test writes its final result to:

- `EFI_Variable_Validation.res`

It also stores temporary command output in:

- `efi_vars.list`
- `efi_var_write.log`
- `efi_trial_boot_status_print.log`
- `efi_os_indications_supported_print.log`
- `efi_trial_boot_status.bin`
