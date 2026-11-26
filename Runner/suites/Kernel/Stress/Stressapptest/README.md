# Stressapptest memory validation

Validates checked memory traffic using image-provided `stressapptest`,
`taskset` and `setsid` on Yocto, Debian, Ubuntu and CentOS. Missing tools skip.
No packages are installed and no cpuset controllers are modified.

Normal defaults are 300 seconds, 60% of effective available memory and one
copy worker per allowed online CPU. `--safe` uses 120 seconds, 35% memory,
512 MiB headroom and half the CPUs capped at four workers. The normal reserve
is 256 MiB. Cgroup limits, available memory and required native pages further
bound these choices. Explicit `-M` must fit the budget, zero is rejected.

```sh
./run.sh --safe
./run.sh -s 3600 --loops=8 -W
./run.sh -s 300 -i 1 -c 1 -C 1 --mem-pct=50
./run.sh -s 300 -f /path/to/scratch/new-file --filesize 67108864
```

`-W` uses checked warm copying. `-i`, `-c` and `-C` select invert, check-only
and extra CPU workers. `-m` overrides copy workers. `--mem-pct`, `--mem-cap-mb`,
`--mem-headroom-mb` and `--require-mem-mb` retain their equals-value forms.
`--cpu-list` restricts the allowed online CPUs. Native `--no_affinity` preserves
that externally enforced mask rather than remapping threads to other CPU IDs.

`-f` requires a new file on disk-backed storage, existing files are refused.
`--auto-disk` discovers a suitable mount, or use `--scratch-dir`. The default
file size is 8 MiB, bounded by available scratch space. Only the test-owned
file/directory is cleaned up. `--auto-net`
creates one memory-bounded local listener and checks readiness before the
client. It does not validate a physical NIC. Use `-n IPV4` for an existing
remote listener and `--listen` to serve a separately managed client.
`--auto` combines the two automatic modes. `-F` retains reduced-checking mode.

`-s` and `--loops` support short or endurance jobs. Configure LAVA action/job
and controller deadlines above total load time plus setup/cleanup allowances.
`--timeout-margin` controls the per-invocation allowance, default 120 seconds.
`--loop-delay` separates loops. Existing environment defaults remain supported.

Per-iteration logs remain under `logs/`, with a combined `Stressapptest.log`
or `-l` path. `--json` writes loop evidence and an aggregate. Native failures,
zero completed work and confirmed kernel faults prevent PASS. Unavailable
kernel logs warn, or fail with `--strict`. Dry runs report SKIP. The final
PASS/FAIL/SKIP is in `Stressapptest.res`, shared result publication exits zero.
Use `--help` for the complete CLI.
