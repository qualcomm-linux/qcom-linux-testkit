# libvirt_presence

Checks whether the `virsh` libvirt client is executable and can report its
version. The test runs locally on the DUT and does not use `adb`.

## Result semantics

- **PASS** when `virsh --version` completes successfully within five seconds.
- **SKIP** when `virsh` is not available and libvirt is optional
  (`REQUIRE_LIBVIRT=false`).
- **FAIL** when `virsh` is not available but required (`REQUIRE_LIBVIRT=true`),
  or when the version query fails or times out.

The LAVA parameter `REQUIRE_LIBVIRT` defaults to `false`. Set it to `true` on
DUTs where the libvirt client must be installed.

## Output

The test writes its result to `libvirt_presence.res`.
