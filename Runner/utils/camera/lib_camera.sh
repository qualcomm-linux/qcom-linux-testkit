#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Shared libcamera helpers
# ---------- Sensor & index helpers ----------

# Return the number of sensors visible in `cam -l`
libcam_list_sensors_count() {
    out="$(cam -l 2>&1 || true)"
    printf '%s\n' "$out" | awk '
        BEGIN { c=0; inlist=0 }
        /^Available cameras:/ { inlist=1; next }
        /^[[:space:]]*[0-9]+:[[:space:]]/ { if (inlist) c++ }
        END { print c+0 }
    '
}

# List all camera indices seen in `cam -l` (space-separated)
libcam_list_indices() {
    command -v cam >/dev/null 2>&1 || { printf '\n'; return 1; }
    cam -l 2>/dev/null \
      | sed -n -E 's/^[[:space:]]*\[([0-9]+)\].*$/\1/p; s/^[[:space:]]*([0-9]+):.*/\1/p'
}

# Resolve requested indices:
# - "auto" (default): first index from cam -l
# - "all": all indices space-separated
# - "0,2,5": comma-separated list (validated against cam -l)
# Outputs space-separated indices to stdout.
libcam_resolve_indices() {
    want="${1:-auto}"
    all="$(libcam_list_indices | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//')"
    [ -n "$all" ] || { printf '\n'; return 1; }

    case "$want" in
        ""|"auto")
            printf '%s\n' "$(printf '%s' "$all" | awk '{print $1}')"
            ;;
        "all")
            printf '%s\n' "$all"
            ;;
        *)
            good=""
            IFS=','; set -- "$want"; IFS=' '
            for idx in "$@"; do
                if printf '%s\n' "$all" | grep -qx "$idx"; then
                    good="$good $idx"
                fi
            done
            printf '%s\n' "$(printf '%s' "$good" | sed 's/^ //')"
            ;;
    esac
}

# Pick first camera index (helper used by older paths)
libcam_pick_cam_index() {
    want="${1:-auto}"
    if [ "$want" != "auto" ]; then
        printf '%s\n' "$want"
        return 0
    fi
    libcam_list_indices | head -n1
}

# ---------- Log parsing ----------

# Extract sequences from a cam run log
# Usage: libcam_log_seqs "<run_log_path>"
libcam_log_seqs() {
    sed -n 's/.*seq:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1"
}

# Extract bytesused from a cam run log
# Usage: libcam_log_bytesused "<run_log_path>"
libcam_log_bytesused() {
    sed -n 's/.*bytesused:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$1"
}

# Check contiguous sequence numbers on stdin; prints a summary and sets exit code
# Usage: libcam_check_contiguous
libcam_check_contiguous() {
    awk '
      {
        v=$1+0
        a[v]=1
        if(n==0 || v<min) min=v
        if(n==0 || v>max) max=v
        n++
      }
      END{
        if(n==0){ print "EMPTY"; exit 1 }
        missing=0
        for(i=min;i<=max;i++){ if(!(i in a)) missing++ }
        printf "N=%d MIN=%06d MAX=%06d MISSING=%d\n", n, min, max, missing
        exit (missing==0 ? 0 : 2)
      }'
}

# List captured files and their inferred sequence (from filename)
# Usage: libcam_file_list_and_seq "<out_dir>"
libcam_file_list_and_seq() {
    find "$1" -maxdepth 1 -type f \( -name 'frame-*.bin' -o -name 'frame-*.ppm' \) -print \
        | awk '
            {
              f=$0; seq=-1
              if (match(f, /[^0-9]([0-9]+)\.(bin|ppm)$/, m)) seq=m[1]
              print f, seq
            }' | sort
}

# Sample the first N bytes and count unique values (to detect constant content)
# Usage: libcam_sample_uniques "<file>" "<N>"
libcam_sample_uniques() {
    f="$1"; n="$2"
 
    # Prefer BusyBox-compatible od -b
    if command -v od >/dev/null 2>&1; then
        dd if="$f" bs=1 count="$n" status=none 2>/dev/null \
        | od -v -b 2>/dev/null \
        | awk '
            {
              for (i=2;i<=NF;i++) {
                if ($i ~ /^[0-7]{3}$/) {
                  v = strtonum("0"$i)
                  if (!(v in seen)) { seen[v]=1; cnt++ }
                }
              }
            }
            END { print (cnt+0) }
        '
        return
    fi
 
    # Fallback: hexdump (some BusyBox builds lack -e)
    if command -v hexdump >/dev/null 2>&1; then
        dd if="$f" bs=1 count="$n" status=none 2>/dev/null \
        | hexdump -v -C 2>/dev/null \
        | awk '
            {
              # Parse canonical dump: hex bytes in columns 2..17
              for (i=2;i<=17;i++) {
                h = $i
                if (h ~ /^[0-9A-Fa-f]{2}$/) {
                  v = strtonum("0x"h)
                  if (!(v in seen)) { seen[v]=1; cnt++ }
                }
              }
            }
            END { print (cnt+0) }
        '
        return
    fi
 
    # Last-chance optimistic fallback
    echo 256
}

# Return a hashing command if available (sha256sum preferred)
# Usage: cmd="$(libcam_hash_command)"
libcam_hash_command() {
    if command -v sha256sum >/dev/null 2>&1; then
        echo sha256sum
    elif command -v md5sum >/dev/null 2>&1; then
        echo md5sum
    else
        echo ""
    fi
}

# ---------- Files & sequence mapping ----------

# Build file→seq map and (optionally) check contiguous sequences across files.
# Usage: libcam_files_and_seq "<out_dir>" "<seq_strict: yes|no>"
# Side-effects: writes "$out_dir/.file_seq_map.txt"
# Returns: 0 = OK, 1 = failed strict check
libcam_files_and_seq() {
    dir="$1"; strict="$2"
    MAP="$dir/.file_seq_map.txt"
    : > "$MAP"
 
    for f in "$dir"/frame-*.bin "$dir"/frame-*.ppm; do
        [ -e "$f" ] || continue
        base="${f##*/}"
        seq="${base%.*}"
        seq="${seq##*-}"
        printf '%s %s\n' "$f" "$seq" >> "$MAP"
    done
 
    if [ "$strict" = "yes" ]; then
        awk '{print $2+0}' "$MAP" | sort -n | libcam_check_contiguous >/dev/null 2>&1 || {
            log_warn "non-contiguous sequences in files"
            return 1
        }
    fi
    return 0
}

# ---------- Content validation (PPM & BIN) ----------

# Validate PPM frames under OUT_DIR.
# Usage: libcam_validate_ppm "<out_dir>" "<ppm_sample_bytes>"
# Returns: 0 = OK, 1 = problems found
libcam_validate_ppm() {
    out_dir="$1"
    ppm_bytes="$2"
    count=$(find "$out_dir" -maxdepth 1 -type f -name 'frame-*.ppm' | wc -l | tr -d ' ')
    [ "$count" -gt 0 ] || return 0

    BAD_PPM=0
    ppm_list="$out_dir/.ppm_list.txt"
    find "$out_dir" -maxdepth 1 -type f -name 'frame-*.ppm' -print > "$ppm_list"

    while IFS= read -r f; do
        [ -f "$f" ] || continue

        magic="$(LC_ALL=C head -c 2 "$f" 2>/dev/null || true)"
        if [ "$magic" != "P6" ]; then
            log_warn "PPM magic not P6: $f"
            BAD_PPM=$((BAD_PPM+1))
            continue
        fi

        hdr="$(dd if="$f" bs=1 count=256 status=none 2>/dev/null)"
        hdr_clean="$(printf '%s' "$hdr" \
          | sed 's/#.*$//g' \
          | tr '\n' ' ' \
          | tr -s ' ' \
          | sed 's/^P6 *//')"

        IFS=' ' read -r W H M _ <<EOF
$hdr_clean
EOF

        if ! printf '%s' "$W" | grep -Eq '^[0-9]+$' \
           || ! printf '%s' "$H" | grep -Eq '^[0-9]+$' \
           || ! printf '%s' "$M" | grep -Eq '^[0-9]+$'; then
            log_warn "PPM header tokens bad: $f"
            BAD_PPM=$((BAD_PPM+1))
            continue
        fi

        datasz=$((W * H * 3))
        fsz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || echo 0)
        if [ "$fsz" -lt "$datasz" ]; then
            log_warn "PPM smaller than payload ($fsz < $datasz): $f"
            BAD_PPM=$((BAD_PPM+1))
            continue
        fi

        u=$(libcam_sample_uniques "$f" "$ppm_bytes")
        if [ "${u:-0}" -le 4 ]; then
            log_warn "PPM looks constant/near-constant (uniques=$u): $f"
            BAD_PPM=$((BAD_PPM+1))
        fi
    done < "$ppm_list"

    [ "${BAD_PPM:-0}" -eq 0 ]
}

# Validate BIN frames under OUT_DIR using RUN_LOG for bytesused correlation.
# Usage: libcam_validate_bin "<out_dir>" "<run_log>" "<bin_sample_bytes>" "<bin_tol_pct>" "<dup_max_ratio>"
# Returns: 0 = OK, 1 = problems found
libcam_validate_bin() {
    dir="$1"; run_log="$2"; bin_sample_bytes="$3"; BIN_TOL_PCT="$4"; DUP_MAX_RATIO="$5"
 
    BAD=0
 
    # Extract bytesused lines from the run log (may be 0 lines; that's fine)
    BU_TXT="$dir/.bytesused.txt"
    sed -n 's/.*bytesused:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$run_log" > "$BU_TXT" 2>/dev/null || :
 
    # List BIN files & sizes (BusyBox-compatible: no -printf)
    SIZES_TXT="$dir/.bin_sizes.txt"
    : > "$SIZES_TXT"
    find "$dir" -maxdepth 1 -type f -name 'frame-*.bin' -print 2>/dev/null \
      | while IFS= read -r f; do
            sz="$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null || wc -c <"$f")"
            printf '%s %s\n' "$f" "$sz" >> "$SIZES_TXT"
        done
 
    # Size tolerance check vs. closest bytesused
    if [ -s "$BU_TXT" ] && [ -s "$SIZES_TXT" ]; then
        while IFS= read -r line; do
            f=$(printf '%s\n' "$line" | cut -d' ' -f1)
            sz=$(printf '%s\n' "$line" | cut -d' ' -f2)
            [ -n "$sz" ] || continue
 
            target=$(
                sort -n "$BU_TXT" 2>/dev/null \
                | awk -v S="$sz" '
                    BEGIN{best=-1; diff=1e99}
                    { d=$1-S; if(d<0)d=-d; if(d<diff){ diff=d; best=$1 } }
                    END{ if(best!=-1) print best; }'
            )
            if [ -n "$target" ]; then
                lo=$(awk -v t="$target" -v p="$BIN_TOL_PCT" 'BEGIN{printf "%.0f", t*(1 - p/100.0)}')
                hi=$(awk -v t="$target" -v p="$BIN_TOL_PCT" 'BEGIN{printf "%.0f", t*(1 + p/100.0)}')
                if [ "$sz" -lt "$lo" ] || [ "$sz" -gt "$hi" ]; then
                    log_warn "BIN size $sz out of ±${BIN_TOL_PCT}% vs bytesused $target: $f"
                    BAD=$((BAD+1))
                fi
            fi
        done < "$SIZES_TXT"
    fi
 
    # Content entropy quick check: sample first N bytes, count unique byte values.
    # On BusyBox, avoid 'od -A'; use plain 'od' or 'hexdump' fallback.
    if [ -s "$SIZES_TXT" ]; then
        while IFS= read -r line; do
            f=$(printf '%s\n' "$line" | cut -d' ' -f1)
            u=256
            if command -v od >/dev/null 2>&1; then
                u="$(dd if="$f" bs=1 count="$bin_sample_bytes" status=none 2>/dev/null \
                    | od -An -tu1 -v 2>/dev/null \
                    | tr -s ' ' ' ' | tr ' ' '\n' | sed '/^$/d' \
                    | sort -n | uniq | wc -l | tr -d ' ' )"
            elif command -v hexdump >/dev/null 2>&1; then
                u="$(dd if="$f" bs=1 count="$bin_sample_bytes" status=none 2>/dev/null \
                    | hexdump -v -e '1/1 "%u\n"' 2>/dev/null \
                    | sort -n | uniq | wc -l | tr -d ' ' )"
            fi
            # Warn only; do NOT increment BAD.
            if [ "${u:-0}" -le 4 ] 2>/dev/null; then
                log_warn "BIN looks constant/near-constant (uniques=${u:-0}): $f"
            fi
        done < "$SIZES_TXT"
    fi
 
    # Duplicate detection by hash (optional, best-effort)
    if [ -s "$SIZES_TXT" ]; then
        hash_cmd=""
        if command -v sha256sum >/dev/null 2>&1; then hash_cmd="sha256sum"
        elif command -v md5sum >/dev/null 2>&1; then hash_cmd="md5sum"
        fi
 
        if [ -n "$hash_cmd" ]; then
            DUPS_TXT="$dir/.hashes.txt"
            : > "$DUPS_TXT"
            while IFS= read -r f; do
                [ -f "$f" ] || continue
                $hash_cmd "$f" 2>/dev/null | awk '{print $1}' >> "$DUPS_TXT"
            done <<EOF_HASHLIST
$(awk '{print $1}' "$SIZES_TXT")
EOF_HASHLIST
 
            if [ -s "$DUPS_TXT" ]; then
                SORTED="$dir/.hashes.sorted"
                sort "$DUPS_TXT" > "$SORTED" 2>/dev/null || cp "$DUPS_TXT" "$SORTED"
 
                total=$(wc -l <"$SORTED" 2>/dev/null | tr -d ' ')
                maxdup=$(awk '
                    { cnt[$1]++ }
                    END {
                        m=0; for (k in cnt) if (cnt[k]>m) m=cnt[k];
                        print m+0
                    }' "$SORTED")
 
                if [ "${total:-0}" -gt 0 ] && [ "${maxdup:-0}" -gt 0 ]; then
                    ratio=$(awk -v m="$maxdup" -v t="$total" 'BEGIN{ if(t==0) print "0"; else printf "%.3f", m/t }')
                    if awk -v r="$ratio" -v lim="$DUP_MAX_RATIO" 'BEGIN{ exit !(r>lim) }'; then
                        log_warn "High duplicate ratio in BIN frames (max bucket $maxdup / $total = $ratio > $DUP_MAX_RATIO)"
                        BAD=$((BAD+1))
                    fi
                fi
            fi
        fi
    fi
 
    [ "$BAD" -eq 0 ]
}

# Orchestrate both content checks
# Usage: libcam_validate_content "<out_dir>" "<run_log>" "<ppm_bytes>" "<bin_bytes>" "<bin_tol_pct>" "<dup_max_ratio>"
# Returns: 0 = OK, 1 = problems found
libcam_validate_content() {
    out_dir="$1"; run_log="$2"; ppm_bytes="$3"; bin_bytes="$4"; bin_tol_pct="$5"; dup_max_ratio="$6"
    ok=0
    if ! libcam_validate_ppm "$out_dir" "$ppm_bytes"; then ok=1; fi
    if ! libcam_validate_bin "$out_dir" "$run_log" "$bin_bytes" "$bin_tol_pct" "$dup_max_ratio"; then ok=1; fi
    [ $ok -eq 0 ]
}

# ---------- Error scanning ----------

# Scan run log for serious errors if strict; return non-zero if any found.
# Usage: libcam_scan_errors "<run_log>" "<err_strict: yes|no>"
libcam_scan_errors() {
    run_log="$1"
    strict="$2"
 
    [ "$strict" = "yes" ] || { log_info "[scan] ERR_STRICT=no; skipping fatal scan"; return 0; }
 
    # Build a filtered view that removes known-benign noise we see on imx577 / simple pipeline.
    # We keep this BusyBox/grep-basic-friendly (no PCRE features).
    tmpf="$(mktemp)" || return 1
    # Lines to ignore (noisy but benign for listing/capture):
    #  - CameraSensor legacy WARN/ERROR geometry queries
    #  - IPAProxy config yaml warnings for imx577/simple
    #  - Software ISP / SimplePipeline warnings
    #  - Generic "WARN" lines
    grep -viE \
        'CameraSensor|PixelArray|ActiveAreas|crop rectangle|Rotation control|No sensor delays|CameraSensorProperties|IPAProxy|configuration file.*yaml|SoftwareIsp|IPASoft|SimplePipeline' \
        "$run_log" >"$tmpf" || true
 
    # Fatal patterns: keep simple & portable; focus on truly bad states.
    # (No generic "error" catch-all here.)
    if grep -Eiq \
        'segmentation fault|assert|device[^[:alpha:]]*not[^[:alpha:]]*found|failed to open camera|cannot open camera|stream[^[:alpha:]]*configuration[^[:alpha:]]*failed|request[^[:alpha:]]*timeout|EPIPE|I/O error' \
        "$tmpf"; then
        log_warn "Serious error keywords found in cam run log (fatal)"
        rm -f "$tmpf"
        return 1
    fi
 
    log_info "[scan] No fatal errors after noise suppression"
    rm -f "$tmpf"
    return 0
}
