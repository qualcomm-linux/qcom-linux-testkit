# systemd_reboot_service

Checks that `systemd-reboot.service` is loaded and inactive on the DUT. The
test SKIPs when systemd or the reboot unit is unavailable in the image.

## What this test checks

The test queries systemd for these unit properties:

```text
LoadState=loaded
ActiveState=inactive
SubState=dead
```

The query has a 5-second deadline. Output is saved to
`systemd_reboot_service.log` in the invocation's current directory.

## Run and result

Run `./run.sh` from this directory. The test only reads unit properties; it
does not start the reboot service. The result is written to
`systemd_reboot_service.res`.
