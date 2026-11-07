# Boot health check

Invoke `./run.sh` from this directory, or its absolute path from Runner.
This existing check confirms that the image booted to a root shell. It does
not replace a reboot-cycle, networking or filesystem functional test.
`Reboot_health_check.res` is always written beside `run.sh` on completion.

The existing retry counter remains at `/var/reboot_health` to survive reboot.
The root-shell success path resets it and publishes PASS. The non-root retry
path retains its existing bounded retry policy and reboot request, publishing
FAIL before the request and when retries or the reboot command fail.
Use the image-provided tools, no systemd setup or runtime installation is needed.
