# Stress-ng stability validation

Validates bounded CPU/matrix, memory and file-I/O loads using image-provided
`stress-ng`, `taskset` and `setsid` on Yocto, Debian, Ubuntu and CentOS.
Missing tools skip. No packages are installed at runtime.

The default selection runs CPU/matrix for 60 seconds, then VM/HDD for 60 seconds.
`--sets vm` isolates memory, `--sets io` isolates file I/O, and `--sets mixed`
runs CPU, memory and file I/O concurrently. CPU/matrix retains one worker of
**each** type per allowed online CPU. VM/HDD use one worker each, avoiding
version-dependent multiplication of memory and file-size budgets.

```sh
./run.sh --sets cpu --p1 300
./run.sh --sets vm --p2 3600 --repeat 8 --mem-frac 35
./run.sh --sets mixed --p2 28800 --mem-frac 50 --scratch-dir /path/to/scratch
./run.sh --sets vm --p2 300 --vm-keep 0 --stability 8
```

Memory uses current availability and cgroup headroom, with `--mem-frac`,
`--mem-headroom-mb` and optional `--mem-cap-mb`. File I/O needs a writable,
disk-backed `--scratch-dir` or a discovered suitable mount. `--disk-frac` and
optional `--disk-cap-mb` bound file space while retaining filesystem headroom.
Only test-owned scratch data is removed. `--cpu-list` restricts allowed CPUs.

`--p1` controls CPU phase seconds and `--p2` controls other phase seconds.
`--repeat` repeats the selection, while `--stability` selects a total load
window in hours. LAVA action/job and controller deadlines must allow the
requested time plus setup/cleanup. The default per-invocation margin is 120
seconds, configurable with `--timeout-margin`.

Native options can follow `--`, or use `--stressng-args` with quoted arguments.
`--autosize` adds missing VM/HDD budgets, `--append-defaults` adds verification
and metrics, and `--by-class` selects explicit native classes. Use
`--command-timeout` to bound a custom sequential run across multiple stressors.
`--temp-limit` requires native tool support and otherwise skips explicitly.

`--dry-run` validates arguments but reports SKIP because no load ran. Normal
PASS requires native completion, positive operations from every built-in
stressor and no captured kernel faults. Logs remain under `logs/`, separated
by invocation, iteration and workload. `Stress-ng.res` contains the final
PASS/FAIL/SKIP verdict, and shared LAVA orchestration exits zero after publication.
Use `--help` for the complete CLI.
