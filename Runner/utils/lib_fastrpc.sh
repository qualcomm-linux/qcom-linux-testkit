#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# FastRPC runtime layout helpers.
#
# Supports both Yocto/current and Debian package layouts.
#
# Yocto/current:
# libs : /usr/local/lib
# test libs : /usr/local/lib/fastrpc_test
# skeletons : /usr/local/share/fastrpc_test/v75, v68
#
# Debian:
# libs : /usr/lib/<multiarch>
# test libs : /usr/lib/<multiarch>/fastrpc_test
# skeletons : /usr/share/fastrpc_test/v75, v68
#
# Optional environment overrides:
# FASTRPC_LIB_SYS_DIR
# FASTRPC_LIB_TEST_DIR
# FASTRPC_SKEL_BASE

fastrpc_append_word_unique() {
    current="$1"
    new="$2"

    [ -n "$new" ] || {
        printf '%s' "$current"
        return 0
    }

    for word in $current; do
        if [ "$word" = "$new" ]; then
            printf '%s' "$current"
            return 0
        fi
    done

    if [ -n "$current" ]; then
        printf '%s %s' "$current" "$new"
    else
        printf '%s' "$new"
    fi
}

fastrpc_append_colon_dir() {
    current_path="$1"
    new_dir="$2"

    [ -n "$new_dir" ] || {
        printf '%s' "$current_path"
        return 0
    }

    [ -d "$new_dir" ] || {
        printf '%s' "$current_path"
        return 0
    }

    case ":$current_path:" in
        *":$new_dir:"*)
            printf '%s' "$current_path"
            ;;
        *)
            if [ -n "$current_path" ]; then
                printf '%s:%s' "$current_path" "$new_dir"
            else
                printf '%s' "$new_dir"
            fi
            ;;
    esac
}

fastrpc_first_existing_word_dir() {
    candidate_dirs="$1"

    for candidate_dir in $candidate_dirs; do
        [ -n "$candidate_dir" ] || continue

        if [ -d "$candidate_dir" ]; then
            printf '%s\n' "$candidate_dir"
            return 0
        fi
    done

    return 1
}

# Returns the first directory in the space-separated candidate_dirs list that
# contains at least one FastRPC system library (libadsprpc, libcdsprpc, or
# libsdsprpc).  Generic directories like /usr/lib that exist without FastRPC
# installed are skipped.
fastrpc_first_dir_with_fastrpc_syslib() {
    candidate_dirs="$1"
    for candidate_dir in $candidate_dirs; do
        [ -d "$candidate_dir" ] || continue
        for lib in libadsprpc libcdsprpc libsdsprpc; do
            if find "$candidate_dir" -maxdepth 1 -name "${lib}.so*" 2>/dev/null \
               | grep -qm1 .; then
                printf '%s\n' "$candidate_dir"
                return 0
            fi
        done
    done
    return 1
}

# Returns the first directory in the space-separated candidate_dirs list that
# contains at least one known FastRPC test library (libcalculator, libhap_example,
# or libmultithreading).  Matches both unversioned (.so) and versioned (.so.N)
# forms so Debian runtime-only installs are detected correctly.
fastrpc_first_dir_with_testlib() {
    candidate_dirs="$1"
    for candidate_dir in $candidate_dirs; do
        [ -d "$candidate_dir" ] || continue
        for lib in libcalculator libhap_example libmultithreading; do
            if find "$candidate_dir" -maxdepth 1 -name "${lib}.so*" 2>/dev/null \
               | grep -qm1 .; then
                printf '%s\n' "$candidate_dir"
                return 0
            fi
        done
    done
    return 1
}

fastrpc_detect_multiarch_triplet() {
    triplet=""

    if command -v gcc >/dev/null 2>&1; then
        triplet="$(gcc -dumpmachine 2>/dev/null || true)"
    fi

    if [ -z "$triplet" ] && command -v dpkg-architecture >/dev/null 2>&1; then
        triplet="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
    fi

    if [ -z "$triplet" ]; then
        case "$(uname -m 2>/dev/null || true)" in
            aarch64|arm64)
                triplet="aarch64-linux-gnu"
                ;;
            armv7l|armv8l)
                triplet="arm-linux-gnueabihf"
                ;;
            x86_64)
                triplet="x86_64-linux-gnu"
                ;;
        esac
    fi

    printf '%s\n' "$triplet"
}

fastrpc_discover_runtime_layout() {
    FASTRPC_MULTIARCH_TRIPLET="$(fastrpc_detect_multiarch_triplet)"

    FASTRPC_LIB_SYS_DIRS_CHECKED=""
    FASTRPC_LIB_TEST_DIRS_CHECKED=""
    FASTRPC_SKEL_BASES_CHECKED=""

    # Explicit overrides first.
    [ -n "${FASTRPC_LIB_SYS_DIR:-}" ] &&
        FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "$FASTRPC_LIB_SYS_DIR")"

    [ -n "${FASTRPC_LIB_TEST_DIR:-}" ] &&
        FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "$FASTRPC_LIB_TEST_DIR")"

    [ -n "${FASTRPC_SKEL_BASE:-}" ] &&
        FASTRPC_SKEL_BASES_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_SKEL_BASES_CHECKED" "$FASTRPC_SKEL_BASE")"

    # Yocto/current layout.
    FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/local/lib")"
    FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/local/lib/fastrpc_test")"
    FASTRPC_SKEL_BASES_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_SKEL_BASES_CHECKED" "/usr/local/share/fastrpc_test")"

    # Debian/multiarch layout.
    if [ -n "$FASTRPC_MULTIARCH_TRIPLET" ]; then
        FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/lib/$FASTRPC_MULTIARCH_TRIPLET")"
        FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/lib/$FASTRPC_MULTIARCH_TRIPLET/fastrpc_test")"
    fi

    # Generic fallbacks.
    FASTRPC_LIB_SYS_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_SYS_DIRS_CHECKED" "/usr/lib")"
    FASTRPC_LIB_TEST_DIRS_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_LIB_TEST_DIRS_CHECKED" "/usr/lib/fastrpc_test")"
    FASTRPC_SKEL_BASES_CHECKED="$(fastrpc_append_word_unique "$FASTRPC_SKEL_BASES_CHECKED" "/usr/share/fastrpc_test")"

    FASTRPC_RESOLVED_LIB_SYS_DIR="$(fastrpc_first_dir_with_fastrpc_syslib "$FASTRPC_LIB_SYS_DIRS_CHECKED" || true)"
    FASTRPC_RESOLVED_LIB_TEST_DIR="$(fastrpc_first_dir_with_testlib "$FASTRPC_LIB_TEST_DIRS_CHECKED" || true)"
    FASTRPC_RESOLVED_SKEL_BASE="$(fastrpc_first_existing_word_dir "$FASTRPC_SKEL_BASES_CHECKED" || true)"

    FASTRPC_RESOLVED_SKEL_PATH=""
    if [ -n "$FASTRPC_RESOLVED_SKEL_BASE" ]; then
        FASTRPC_RESOLVED_SKEL_PATH="$(fastrpc_append_colon_dir "$FASTRPC_RESOLVED_SKEL_PATH" "$FASTRPC_RESOLVED_SKEL_BASE/v75")"
        FASTRPC_RESOLVED_SKEL_PATH="$(fastrpc_append_colon_dir "$FASTRPC_RESOLVED_SKEL_PATH" "$FASTRPC_RESOLVED_SKEL_BASE/v68")"
    fi
}

fastrpc_export_runtime_env() {
    new_ld_library_path=""

    new_ld_library_path="$(fastrpc_append_colon_dir "$new_ld_library_path" "$FASTRPC_RESOLVED_LIB_SYS_DIR")"
    new_ld_library_path="$(fastrpc_append_colon_dir "$new_ld_library_path" "$FASTRPC_RESOLVED_LIB_TEST_DIR")"

    if [ -n "${LD_LIBRARY_PATH:-}" ]; then
        if [ -n "$new_ld_library_path" ]; then
            new_ld_library_path="${new_ld_library_path}:${LD_LIBRARY_PATH}"
        else
            new_ld_library_path="$LD_LIBRARY_PATH"
        fi
    fi

    if [ -n "$new_ld_library_path" ]; then
        export LD_LIBRARY_PATH="$new_ld_library_path"
    fi

    if [ -n "$FASTRPC_RESOLVED_SKEL_PATH" ]; then
        : "${ADSP_LIBRARY_PATH:=$FASTRPC_RESOLVED_SKEL_PATH}"
        : "${CDSP_LIBRARY_PATH:=$FASTRPC_RESOLVED_SKEL_PATH}"
        : "${SDSP_LIBRARY_PATH:=$FASTRPC_RESOLVED_SKEL_PATH}"

        export ADSP_LIBRARY_PATH
        export CDSP_LIBRARY_PATH
        export SDSP_LIBRARY_PATH
    fi
}

fastrpc_log_runtime_layout() {
    log_info "FastRPC multiarch triplet: ${FASTRPC_MULTIARCH_TRIPLET:-<not detected>}"

    if [ -n "$FASTRPC_RESOLVED_LIB_SYS_DIR" ]; then
        log_info "FastRPC system library dir: $FASTRPC_RESOLVED_LIB_SYS_DIR"
    else
        log_warn "No FastRPC system library dir found. Checked: $FASTRPC_LIB_SYS_DIRS_CHECKED"
    fi

    if [ -n "$FASTRPC_RESOLVED_LIB_TEST_DIR" ]; then
        log_info "FastRPC test library dir: $FASTRPC_RESOLVED_LIB_TEST_DIR"
    else
        log_warn "No FastRPC test library dir found. Checked: $FASTRPC_LIB_TEST_DIRS_CHECKED"
    fi

    if [ -n "$FASTRPC_RESOLVED_SKEL_PATH" ]; then
        log_info "FastRPC skeleton path: $FASTRPC_RESOLVED_SKEL_PATH"
    else
        log_warn "No DSP skeleton dirs found. Checked bases: $FASTRPC_SKEL_BASES_CHECKED"
    fi
}

fastrpc_setup_runtime_layout() {
    fastrpc_discover_runtime_layout
    fastrpc_log_runtime_layout
    fastrpc_export_runtime_env

    log_info "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
    [ -n "${ADSP_LIBRARY_PATH:-}" ] && log_info "ADSP_LIBRARY_PATH=${ADSP_LIBRARY_PATH}"
    [ -n "${CDSP_LIBRARY_PATH:-}" ] && log_info "CDSP_LIBRARY_PATH=${CDSP_LIBRARY_PATH}"
    [ -n "${SDSP_LIBRARY_PATH:-}" ] && log_info "SDSP_LIBRARY_PATH=${SDSP_LIBRARY_PATH}"
}

# -------------------- FastRPC test orchestration helpers --------------------

# shellcheck disable=SC2317
log_debug() {
    if [ "${VERBOSE:-0}" -eq 1 ]; then
        log_info "[debug] $*" >&2
    fi
}

cmd_to_string() {
    out=""
    for a in "$@"; do
        case "$a" in
            *[!A-Za-z0-9._:/-]*|"")
                q=$(printf "%s" "$a" | sed "s/'/'\\\\''/g")
                out="$out '$q'"
                ;;
            *)
                out="$out $a"
                ;;
        esac
    done
    printf "%s" "$out"
}

extract_test_summary_counts() {
    log_file="$1"

    total="$(sed -n 's/^[[:space:]]*Total tests run:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"
    passed="$(sed -n 's/^[[:space:]]*Passed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"
    failed="$(sed -n 's/^[[:space:]]*Failed:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"
    skipped="$(sed -n 's/^[[:space:]]*Skipped:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$log_file" | tail -n 1)"

    case "$total" in ''|*[!0-9]*) total=0 ;; esac
    case "$passed" in ''|*[!0-9]*) passed=0 ;; esac
    case "$failed" in ''|*[!0-9]*) failed=0 ;; esac
    case "$skipped" in ''|*[!0-9]*) skipped=0 ;; esac

    printf '%s:%s:%s:%s\n' "$total" "$passed" "$failed" "$skipped"
}

log_dsp_remoteproc_status() {
    fw_list="adsp mdsp sdsp cdsp cdsp0 cdsp1 gdsp0 gdsp1 gpdsp0 gpdsp1"
    any=0

    for fw in $fw_list; do
        if dt_has_remoteproc_fw "$fw" || [ -n "$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null || true)" ]; then
            entries="$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null)" || entries=""

            if [ -n "$entries" ]; then
                any=1

                while IFS='|' read -r rpath rstate rfirm rname; do
                    [ -n "$rpath" ] || continue
                    inst="$(basename "$rpath")"
                    log_info "rproc.$fw: $inst path=$rpath state=$rstate fw=$rfirm name=$rname"
                done <<__RPROC__
$entries
__RPROC__
            fi
        fi
    done

    [ "$any" -eq 0 ] && log_info "rproc: no *dsp remoteproc entries detected via DT"
}

name_to_domain() {
    case "$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')" in
        adsp) echo 0 ;;
        mdsp) echo 1 ;;
        sdsp) echo 2 ;;
        cdsp) echo 3 ;;
        cdsp1) echo 4 ;;
        gpdsp0|gdsp0) echo 5 ;;
        gpdsp1|gdsp1) echo 6 ;;
        *) echo "" ;;
    esac
}

domain_to_name() {
    case "$1" in
        0) echo "ADSP" ;;
        1) echo "MDSP" ;;
        2) echo "SDSP" ;;
        3) echo "CDSP" ;;
        4) echo "CDSP1" ;;
        5) echo "GPDSP0" ;;
        6) echo "GPDSP1" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# Maps a domain number to the DT binding label used by the FastRPC driver
# when naming /dev/fastrpc-<label>.  GPDSP domains use the DT label gdsp0/gdsp1,
# not the presentation names gpdsp0/gpdsp1.
domain_to_endpoint_label() {
    case "$1" in
        0) echo "adsp" ;;
        1) echo "mdsp" ;;
        2) echo "sdsp" ;;
        3) echo "cdsp" ;;
        4) echo "cdsp1" ;;
        5) echo "gdsp0" ;;
        6) echo "gdsp1" ;;
        *) echo "" ;;
    esac
}

# Returns 0 if a usable FastRPC character device exists for the given domain.
# Checks both /dev/fastrpc-<label> and /dev/fastrpc-<label>-secure.
fastrpc_domain_endpoint_available() {
    _label="$(domain_to_endpoint_label "$1")"
    [ -n "$_label" ] || return 1
    [ -c "/dev/fastrpc-${_label}" ] || [ -c "/dev/fastrpc-${_label}-secure" ]
}

append_unique() {
    current="$1"
    new="$2"

    for word in $current; do
        [ "$word" = "$new" ] && {
            printf "%s" "$current"
            return
        }
    done

    [ -n "$current" ] && printf "%s %s" "$current" "$new" || printf "%s" "$new"
}

canonicalize_domain_name() {
    norm="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

    case "$norm" in
        cdsp0) echo "cdsp" ;;
        gdsp0) echo "gpdsp0" ;;
        gdsp1) echo "gpdsp1" ;;
        *) printf "%s" "$norm" ;;
    esac
}

discover_supported_domains() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - discover_supported_domains: helper-backed discovery active" >&2

    for fw in adsp mdsp sdsp cdsp cdsp0 cdsp1 gpdsp0 gpdsp1 gdsp0 gdsp1; do
        entries="$(get_remoteproc_by_firmware "$fw" "" all 2>/dev/null || true)"

        if [ -n "$entries" ]; then
            while IFS='|' read -r rpath rstate rfirm rname; do
                nameguess=""

                if [ -n "$rname" ]; then
                    nameguess="$rname"
                elif [ -n "$rfirm" ]; then
                    nameguess=$(basename "$rfirm" 2>/dev/null | sed 's/\.[^.]*$//')
                fi

                [ -n "$nameguess" ] || continue

                canon="$(canonicalize_domain_name "$nameguess")"
                d="$(name_to_domain "$canon")"

                if [ -n "$d" ]; then
                    printf '%s\n' "$d"
                    log_debug "discover: fw=$fw rname=$rname rfirm=$rfirm canon=$canon domain=$d state=$rstate"
                else
                    log_debug "discover: fw=$fw rname=$rname rfirm=$rfirm canon=$canon domain=<none>"
                fi
            done <<EOF
$entries
EOF
        elif dt_has_remoteproc_fw "$fw"; then
            canon="$(canonicalize_domain_name "$fw")"
            d="$(name_to_domain "$canon")"

            if [ -n "$d" ]; then
                printf '%s\n' "$d"
                log_debug "discover: fw=$fw dt-only canon=$canon domain=$d"
            fi
        else
            log_debug "discover: fw=$fw not present"
        fi
    done
}

resolve_domains_to_test() {
    resolved=""

    if [ -n "$CLI_DOMAIN_NAME" ]; then
        resolved="$(name_to_domain "$CLI_DOMAIN_NAME")"
    elif [ -n "$CLI_DOMAIN" ]; then
        resolved="$CLI_DOMAIN"
    elif [ "$DOMAIN_MODE" = "single" ]; then
        if [ -n "${FASTRPC_DOMAIN_NAME:-}" ]; then
            resolved="$(name_to_domain "$FASTRPC_DOMAIN_NAME")"
        elif [ -n "${FASTRPC_DOMAIN:-}" ]; then
            resolved="$FASTRPC_DOMAIN"
        fi
    else
        resolved="$(discover_supported_domains)"
    fi

    log_debug "resolve: raw domains='$resolved'"

    valid=""
    for d in $resolved; do
        case "$d" in
            0|1|2|3|4|5|6)
                case " $valid " in
                    *" $d "*)
                        :
                        ;;
                    *)
                        if [ -n "$valid" ]; then
                            valid="${valid} ${d}"
                        else
                            valid="$d"
                        fi
                        ;;
                esac
                ;;
            *)
                log_warn "Ignoring invalid domain '$d'"
                ;;
        esac
    done

    printf '%s' "$valid"
}

domain_supported_pds() {
    case "$1" in
        0|1|2) printf "%s" "0" ;;
        3|4|5|6) printf "%s" "0 1" ;;
        *) printf "%s" "" ;;
    esac
}

requested_pds() {
    [ "$UNSIGNED_PD_FLAG" -eq 1 ] && {
        printf "%s" "1"
        return
    }

    [ "${FASTRPC_UNSIGNED_PD:-0}" -eq 1 ] && {
        printf "%s" "1"
        return
    }

    case "$PD_MODE" in
        signed-only) printf "%s" "0" ;;
        unsigned-only) printf "%s" "1" ;;
        both) printf "%s" "0 1" ;;
    esac
}

effective_pds_for_domain() {
    domain="$1"
    requested="$(requested_pds)"
    supported="$(domain_supported_pds "$domain")"
    effective=""

    for req in $requested; do
        for sup in $supported; do
            [ "$req" = "$sup" ] && effective="$(append_unique "$effective" "$req")"
        done
    done

    printf "%s" "$effective"
}
