# Hardware Probe (hw-probe) Runner

Modular, POSIX-`sh` runner to install/update and execute **[hw-probe](https://github.com/linuxhw/hw-probe)** on **Debian/Ubuntu**, with optional **Docker** mode.  
Works offline (save locally) or online (upload to linux-hardware.org), and can auto-extract generated reports.

- Uses your existing `functestlib.sh` for logging, `check_dependencies`, and `check_network_status`.
- All helpers live in `Runner/utils/` and are shared across tools.

---

## Folder layout

```
Runner/
├─ utils/
│  ├─ lib_common.sh      # tiny helpers (root/sudo, OS detect, ensure_dir, network check)
│  ├─ lib_apt.sh         # apt install/update/version helpers
│  ├─ lib_docker.sh      # docker presence/launch helpers
│  └─ lib_hwprobe.sh     # hw-probe install/update/run (local & docker) + extraction
└─ tools/
   └─ hw-probe/
      ├─ run.sh          # main CLI (sources init_env → functestlib → utils/*)
      └─ README.md       # this file
```

> `run.sh` auto-locates and sources your repo’s `init_env` → `${TOOLS}/functestlib.sh` so the libs can call `log_info`, `log_warn`, `log_error`, `log_fail`, `log_skip`, `check_dependencies`, `check_network_status`, etc.

---

## Requirements

- **OS:** Debian/Ubuntu (checked by the script)
- **Privileges:** root required to probe all devices
  - If not root, the runner uses `sudo -E` automatically.
- **APT tools:** `apt-get`, `apt-cache`, `dpkg`
- **Network:** only needed when:
  - Installing/updating packages or pulling Docker images
  - Using `--upload yes`
- **Docker mode:** requires `docker` (the runner can install `docker.io` via apt)

---

## What the runner does

- Checks platform (Debian/Ubuntu) and basic tools
- Optionally installs **hw-probe** (latest or pinned version)
- Optionally updates **hw-probe** to latest
- Ensures recommended dependencies (e.g., `lshw`, `smartmontools`, `nvme-cli`, `hdparm`, `pciutils`, `usbutils`, `dmidecode`, `ethtool`, `lsscsi`, `iproute2`)
- Runs **locally** or via **Docker**
- Saves output to a specified directory (default `./hw-probe_out`) using `hw-probe -save`
- Optionally uploads probe to linux-hardware.org
- Optionally auto-extracts `hw.info.txz` to `OUT/extracted-<timestamp>`
- Prints: saved path, extraction hint, and (when uploaded) the Probe URL

---

## Usage

```sh
cd Runner/tools/hw-probe
./run.sh [OPTIONS]
```

### Options

| Option | Values | Default | Description |
|---|---|---|---|
| `--mode` | `local` \| `docker` | `local` | Run natively or inside the official `linuxhw/hw-probe` image. |
| `--upload` | `yes` \| `no` | `no` | Upload probe to linux-hardware.org and print the URL. Auto-disabled if offline. |
| `--out` | path | `./hw-probe_out` | Directory to save artifacts (`hw.info.txz`) and logs. Created if missing. |
| `--extract` | `yes` \| `no` | `no` | Auto-extract the saved archive to `OUT/extracted-<ts>`. Requires `tar` (xz support preferred). |
| `--install` | – | – | Ensure **hw-probe** is installed (latest) if missing. |
| `--version` | string | – | Install a specific version (implies `--install`). |
| `--update` | – | – | Update **hw-probe** to the latest available version. |
| `--list-versions` | – | – | Show available versions from APT (policy/madison). |
| `--deps-only` | – | – | Install recommended dependencies only (no hw-probe). |
| `--probe-args` | quoted args | – | Extra args forwarded to `hw-probe` (both modes). |
| `--dry-run` | – | – | Print intended actions without installing/running. |
| `--verbose` | – | – | Increase logging verbosity (handled by functestlib). |
| `-h`, `--help` | – | – | Show usage. |

> The runner uses `check_network_status` before any download (APT/Docker). If offline and `--upload yes`, it downgrades to `--upload no` for that run.

---

## Quick starts

### 1) Local run, save only (no upload), then auto-extract
```sh
./run.sh --mode local --upload no --extract yes
```

### 2) Local run, upload + auto-extract
```sh
./run.sh --mode local --upload yes --extract yes
```

### 3) Docker run, save only, custom output dir
```sh
./run.sh --mode docker --upload no --out ./out --extract yes
```

### 4) Install/update workflows
```sh
# Ensure deps + latest hw-probe (if missing), then run
./run.sh --install --mode local

# Install a specific version
./run.sh --install --version 1.6

# Update to latest
./run.sh --update
```

### 5) List available package versions
```sh
./run.sh --list-versions
```

---

## Artifacts & Logs

- **Saved report:** `OUT/hw.info.txz` (xz-compressed tar)
- **Local run log:** `OUT/.hw-probe-run-<timestamp>.log`
- **Docker run log:** `OUT/.hw-probe-docker-<timestamp>.log`
- **Auto-extraction (if `--extract yes`):** `OUT/extracted-<timestamp>/`

To manually inspect or extract:

```sh
# list
tar -tJf OUT/hw.info.txz

# extract
mkdir -p OUT/extracted
tar -xJf OUT/hw.info.txz -C OUT/extracted

# fallbacks if your tar lacks -J:
# bsdtar -xf OUT/hw.info.txz -C OUT/extracted
# xz -dc OUT/hw.info.txz | tar -xf - -C OUT/extracted
```

When `--upload yes`, the runner prints the **Probe URL** returned by hw-probe (e.g., `https://linux-hardware.org/?probe=<id>`).

---

## Docker notes

The runner:
- Installs `docker.io` via APT if missing (Debian/Ubuntu)
- Pulls `linuxhw/hw-probe` if online; if offline it requires the image to exist locally
- Runs with:
  - `--privileged --net=host --pid=host`
  - Read-only binds: `/dev`, `/lib/modules`, `/etc/os-release`, `/var/log`
  - Output bind: `-v "$OUT":/out` so `-save /out` persists artifacts on the host

Your original run line is respected, and the script captures container stdout to a host log for URL parsing.

---

## Extra hw-probe arguments

Pass through to `hw-probe` via `--probe-args`, e.g.:

```sh
# Quiet logging level (example)
./run.sh --mode local --probe-args "-log-level minimal"

# Add ACPI table dump & decode (requires acpica-tools)
./run.sh --mode local --probe-args "-dump-acpi -decode-acpi"
```

---

## X11 warning

If you see:
```
WARNING: X11-related logs are not collected (try to run 'sudo -E hw-probe ...')
```
It usually means `DISPLAY`/`XAUTHORITY` aren’t accessible to root (common on servers). To include X11 logs:

```sh
xhost +local:root
sudo -E env DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" hw-probe -all -save ./hw-probe_out
```

(Our runner already uses `sudo -E`; you just might need `xhost` on desktop systems.)

---

## Offline use

- Use `--upload no` (default); artifacts are saved locally.
- You can upload later when online:
  ```sh
  # Example: upload a saved probe
  sudo -E hw-probe -upload -src /path/to/hw.info.txz
  ```

---

## Security & privacy

- `--upload yes` sends probe data to linux-hardware.org over HTTPS (see upstream privacy notes).
- Docker mode uses `--privileged` to access host hardware; run only on trusted systems.
- The runner uses `sudo -E` when needed to collect device info.

---

## Exit codes

- `0` on success
- Non-zero on failures (unsupported OS, missing critical tools, network required but offline, Docker not runnable, extraction failure ignored unless critical, etc.)

---

## Troubleshooting

- **“Unknown option: dump”** → We use `-save`, not `-dump`. If you call `hw-probe` manually, be sure to use `-save`.
- **“not in gzip format” when opening `hw.info.txz`** → It’s xz, not gzip. Use `tar -tJf` / `tar -xJf` (or `bsdtar`, or `xz -dc | tar -xf -`).
- **Offline + Docker first-time** → Ensure the image `linuxhw/hw-probe` is already present locally or run once online.
- **Network checks** → The runner calls `check_network_status` (from `functestlib.sh`) before any download; offline runs still work with `--upload no`.

---

## Dev notes

- All scripts are **POSIX `sh`**, shellcheck-friendly (only dynamic-source warnings suppressed).
- No duplicated infra—logging and basic checks come from your **`functestlib.sh`**.
- To extend behavior, prefer adding to `lib_hwprobe.sh` and surface flags via `run.sh`.
