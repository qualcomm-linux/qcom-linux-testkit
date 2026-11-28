# docker_service_status

Checks whether the optional Docker systemd service is active and running on a
systemd DUT. The test runs locally on the DUT.

## What this test checks

The test queries the unit's structured properties:

```sh
systemctl show docker.service --property=LoadState \
  --property=ActiveState --property=SubState --no-pager
```

PASS requires `LoadState=loaded`, `ActiveState=active`, and `SubState=running`.
The test SKIPs when the DUT is not running systemd or the optional Docker unit
is not provided by the image. Set the LAVA parameter
`REQUIRE_DOCKER_SERVICE=true` to FAIL when the selected plan requires a missing
unit. It FAILS when an installed, applicable Docker unit is not running. The
query has a 5-second deadline, and its output is saved to
`docker_service_status.log` in the invocation's current directory.

## Run and result

Run `./run.sh` from this directory. The result is written to
`docker_service_status.res`.
