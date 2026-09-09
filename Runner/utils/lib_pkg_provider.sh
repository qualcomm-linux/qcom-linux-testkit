#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# Optional package provider abstraction for qcom-linux-testkit.
#
# Provider model:
# apt - apt-get/dpkg-query based systems
# rpm - dnf/yum/rpm based systems, including Yocto images configured with dnf
# opkg - opkg based systems
# check - check-only fallback when no supported package manager is available
#
# Package names are resolved through Runner/config/pkg_command_map.conf.
# The library intentionally avoids command-name guessing because command names
# and distro package names often differ.
#
# For apt systems, optional *.sources artifacts under /opt/qcom-testkit/metadata
# are copied into /etc/apt/sources.list.d/ when present. Optional apt auth is
# created only when secure target-local secret files are present.
#
# Package-manager command output is printed to stdout to simplify CI debugging.

PKG_PROVIDER="auto"
PKG_CHECK_DEPS_RECOVER="1"
PKG_AUTO_INSTALL="1"
PKG_PACKAGE_MAP="config/pkg_command_map.conf"
PKG_PACKAGE_UPGRADE="0"
PKG_DEBUG="0"

PKG_APT_DEBUSINE_SOURCE="${PKG_APT_DEBUSINE_SOURCE:-none}"
PKG_APT_DEBUSINE_SUITE="${PKG_APT_DEBUSINE_SUITE:-auto}"
PKG_PACKAGE_SET_UPGRADE="${PKG_PACKAGE_SET_UPGRADE:-1}"
PKG_DKMS_CHECK_HEADERS="${PKG_DKMS_CHECK_HEADERS:-1}"
PKG_DKMS_MISSING_HEADERS_ACTION="${PKG_DKMS_MISSING_HEADERS_ACTION:-fail}"

PKG_NETWORK_REQUIRED="1"
PKG_NETWORK_RECOVER="1"
PKG_NETWORK_RETRIES="2"
PKG_NETWORK_RETRY_SLEEP="5"

PKG_COMMAND_RETRIES="2"
PKG_COMMAND_RETRY_SLEEP="5"

PKG_APT_GET="apt-get"
PKG_APT_INSTALL_RECOMMENDS="0"
PKG_APT_LOCK_TIMEOUT="120"
PKG_APT_FIX_BROKEN="1"
PKG_APT_FIX_MISSING="1"
PKG_APT_UPDATED_MARK="/tmp/qcom_testkit_apt_updated"
PKG_APT_UPGRADED_MARK="/tmp/qcom_testkit_apt_upgraded"

PKG_APT_SOURCES_ARTIFACT_DIR="/opt/qcom-testkit/metadata"
PKG_APT_AUTH_CONF="/etc/apt/auth.conf.d/debusine-ci-auth.conf"
PKG_APT_AUTH_MACHINE_FALLBACK="deb.debusine.qualcomm.com"
PKG_APT_AUTH_LOGIN_FILE="/run/qcom-testkit/secrets/debusine_login"
PKG_APT_AUTH_PASSWORD_FILE="/run/qcom-testkit/secrets/debusine_api_token"

PKG_RPM_UPDATED_MARK="/tmp/qcom_testkit_rpm_updated"
PKG_RPM_UPGRADED_MARK="/tmp/qcom_testkit_rpm_upgraded"
PKG_RPM_BEST_EFFORT_CLEAN="1"

PKG_OPKG_UPDATED_MARK="/tmp/qcom_testkit_opkg_updated"

__PKG_PROVIDER_INITIALIZED="0"
__PKG_ACTIVE_PROVIDER=""

# Log an informational message using functestlib.sh logging when available.
pkg_log_info() {
    if command -v log_info >/dev/null 2>&1; then
        log_info "$@"
    else
        printf '[INFO] %s\n' "$*"
    fi
}

# Log a PASS message using functestlib.sh logging when available.
pkg_log_pass() {
    if command -v log_pass >/dev/null 2>&1; then
        log_pass "$@"
    else
        printf '[PASS] %s\n' "$*"
    fi
}

# Log a warning message using functestlib.sh logging when available.
pkg_log_warn() {
    if command -v log_warn >/dev/null 2>&1; then
        log_warn "$@"
    else
        printf '[WARN] %s\n' "$*"
    fi
}

# Log a failure message using functestlib.sh logging when available.
pkg_log_fail() {
    if command -v log_fail >/dev/null 2>&1; then
        log_fail "$@"
    else
        printf '[FAIL] %s\n' "$*"
    fi
}

# Print provider debug messages only when debug=1 is enabled.
pkg_debug() {
    if [ "$PKG_DEBUG" = "1" ]; then
        pkg_log_info "[PKG] $*"
    fi
}

# Return success when a config value represents boolean true.
pkg_bool_true() {
    bool_value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

    case "$bool_value" in
        1|yes|true|on|enable|enabled)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Return success when the supplied value is an unsigned integer.
pkg_is_uint() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Normalize a numeric value.
pkg_normalize_uint() {
    uint_value="$1"
    uint_fallback="$2"

    if pkg_is_uint "$uint_value"; then
        printf '%s\n' "$uint_value"
    else
        printf '%s\n' "$uint_fallback"
    fi
}

# Trim whitespace and optional single/double quotes from a config value.
pkg_strip_value() {
    printf '%s' "$1" |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
        sed 's/^"//; s/"$//' |
        sed "s/^'//; s/'$//"
}

# Apply one key=value entry from pkg_provider.conf.
pkg_apply_config_entry() {
    cfg_key="$1"
    cfg_value="$2"

    case "$cfg_key" in
        provider)
            PKG_PROVIDER="$cfg_value"
            ;;
        check_dependencies_recover)
            PKG_CHECK_DEPS_RECOVER="$cfg_value"
            ;;
        auto_install)
            PKG_AUTO_INSTALL="$cfg_value"
            ;;
        package_map)
            PKG_PACKAGE_MAP="$cfg_value"
            ;;
        package_upgrade)
            PKG_PACKAGE_UPGRADE="$cfg_value"
            ;;
        debug)
            PKG_DEBUG="$cfg_value"
            ;;
        apt_debusine_source)
            PKG_APT_DEBUSINE_SOURCE="$cfg_value"
            ;;
        apt_debusine_suite)
            PKG_APT_DEBUSINE_SUITE="$cfg_value"
            ;;
        package_set_upgrade)
            PKG_PACKAGE_SET_UPGRADE="$cfg_value"
            ;;
	dkms_check_headers)
            PKG_DKMS_CHECK_HEADERS="$cfg_value"
            ;;
        dkms_missing_headers_action)
            PKG_DKMS_MISSING_HEADERS_ACTION="$cfg_value"
            ;;
        *)
            pkg_debug "Ignoring unknown package provider config key, $cfg_key"
            ;;
    esac
}

# Load pkg_provider.conf and apply supported key=value entries.
pkg_load_config_file() {
    cfg_file="$1"

    if [ -z "$cfg_file" ] || [ ! -r "$cfg_file" ]; then
        return 1
    fi

    while IFS= read -r cfg_line || [ -n "$cfg_line" ]; do
        case "$cfg_line" in
            ''|'#'*)
                continue
                ;;
            *=*)
                cfg_key="$(printf '%s' "${cfg_line%%=*}" | tr -d '[:space:]')"
                cfg_value="$(pkg_strip_value "${cfg_line#*=}")"
                [ -n "$cfg_key" ] || continue
                pkg_apply_config_entry "$cfg_key" "$cfg_value"
                ;;
            *)
                pkg_debug "Ignoring malformed config line, $cfg_line"
                ;;
        esac
    done < "$cfg_file"

    return 0
}

# Locate the repo-owned package provider config file.
pkg_default_config_path() {
    if [ -n "${ROOT_DIR:-}" ] && [ -r "$ROOT_DIR/config/pkg_provider.conf" ]; then
        printf '%s\n' "$ROOT_DIR/config/pkg_provider.conf"
        return 0
    fi

    if [ -n "${TOOLS:-}" ] && [ -r "$TOOLS/../config/pkg_provider.conf" ]; then
        printf '%s\n' "$TOOLS/../config/pkg_provider.conf"
        return 0
    fi

    return 1
}

# Initialize the package provider once per shell process.
pkg_provider_init() {
    if [ "$__PKG_PROVIDER_INITIALIZED" = "1" ]; then
        return 0
    fi

    provider_cfg_file="$(pkg_default_config_path || true)"
    if [ -n "$provider_cfg_file" ]; then
        pkg_load_config_file "$provider_cfg_file" || true
    else
        pkg_debug "No package provider config found, using built-in defaults"
    fi

    __PKG_PROVIDER_INITIALIZED="1"
    __PKG_ACTIVE_PROVIDER=""
    return 0
}

# Return success when dependency recovery is enabled.
pkg_check_dependencies_recover_enabled() {
    pkg_provider_init
    pkg_bool_true "$PKG_CHECK_DEPS_RECOVER"
}

# Return success when package installation is allowed and current user is root.
pkg_can_install() {
    pkg_provider_init

    if ! pkg_bool_true "$PKG_AUTO_INSTALL"; then
        pkg_debug "auto_install disabled"
        return 1
    fi

    current_uid="$(id -u 2>/dev/null || echo 1)"
    if [ "$current_uid" -ne 0 ] 2>/dev/null; then
        pkg_log_warn "Package install requested but current user is not root"
        return 1
    fi

    return 0
}

# Read a normalized value from /etc/os-release.
pkg_os_release_value() {
    os_key="$1"

    if [ ! -r /etc/os-release ]; then
        return 1
    fi

    sed -n "s/^${os_key}=//p" /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//; s/"$//' |
        tr '[:upper:]' '[:lower:]'
}

# Detect OS ID for logging and package-map override lookup.
pkg_detect_os_id() {
    detected_os_id="$(pkg_os_release_value ID || true)"

    if [ -n "$detected_os_id" ]; then
        printf '%s\n' "$detected_os_id"
        return 0
    fi

    printf '%s\n' "unknown"
    return 0
}

# Detect package-manager provider.
pkg_detect_provider() {
    if command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
        printf '%s\n' "apt"
        return 0
    fi

    if command -v rpm >/dev/null 2>&1; then
        if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            printf '%s\n' "rpm"
            return 0
        fi
    fi

    if command -v opkg >/dev/null 2>&1; then
        printf '%s\n' "opkg"
        return 0
    fi

    printf '%s\n' "check"
    return 0
}

# Return effective provider.
pkg_effective_provider() {
    pkg_provider_init

    if [ "$PKG_PROVIDER" = "auto" ]; then
        pkg_detect_provider
        return 0
    fi

    printf '%s\n' "$PKG_PROVIDER"
    return 0
}

# Return cached active provider.
pkg_active_provider() {
    pkg_provider_init

    if [ -z "$__PKG_ACTIVE_PROVIDER" ]; then
        __PKG_ACTIVE_PROVIDER="$(pkg_effective_provider)"
        pkg_debug "active provider=$__PKG_ACTIVE_PROVIDER"
    fi

    printf '%s\n' "$__PKG_ACTIVE_PROVIDER"
}

# Return success when a command is available.
pkg_have_command() {
    command -v "$1" >/dev/null 2>&1
}

# Resolve absolute or repo-relative path.
pkg_resolve_path() {
    resolve_path="$1"

    case "$resolve_path" in
        /*)
            printf '%s\n' "$resolve_path"
            ;;
        *)
            if [ -n "${ROOT_DIR:-}" ] && [ -e "$ROOT_DIR/$resolve_path" ]; then
                printf '%s\n' "$ROOT_DIR/$resolve_path"
                return 0
            fi

            if [ -n "${TOOLS:-}" ] && [ -e "$TOOLS/../$resolve_path" ]; then
                printf '%s\n' "$TOOLS/../$resolve_path"
                return 0
            fi

            if [ -n "${ROOT_DIR:-}" ]; then
                printf '%s\n' "$ROOT_DIR/$resolve_path"
            else
                printf '%s\n' "$resolve_path"
            fi
            ;;
    esac
}

# Look up exact key in command-to-package map.
pkg_lookup_key_in_map() {
    lookup_map_file="$1"
    lookup_map_key="$2"

    while IFS= read -r lookup_line || [ -n "$lookup_line" ]; do
        case "$lookup_line" in
            ''|'#'*)
                continue
                ;;
            *=*)
                lookup_key="$(printf '%s' "${lookup_line%%=*}" | tr -d '[:space:]')"
                lookup_value="$(pkg_strip_value "${lookup_line#*=}")"

                if [ "$lookup_key" = "$lookup_map_key" ]; then
                    printf '%s\n' "$lookup_value"
                    return 0
                fi
                ;;
        esac
    done < "$lookup_map_file"

    return 1
}

# Resolve command to package names using map.
pkg_lookup_packages_for_command() {
    lookup_cmd="$1"
    lookup_provider="$(pkg_active_provider)"
    lookup_os_id="$(pkg_detect_os_id)"
    lookup_testname="${TESTNAME:-}"
    lookup_map_file="$(pkg_resolve_path "$PKG_PACKAGE_MAP")"

    if [ ! -r "$lookup_map_file" ]; then
        pkg_log_warn "Package map file is not readable, $lookup_map_file"
        return 1
    fi

    if [ -n "$lookup_testname" ]; then
        lookup_value="$(pkg_lookup_key_in_map "$lookup_map_file" "${lookup_os_id}:${lookup_testname}:${lookup_cmd}" || true)"
        if [ -n "$lookup_value" ]; then
            printf '%s\n' "$lookup_value"
            return 0
        fi

        lookup_value="$(pkg_lookup_key_in_map "$lookup_map_file" "${lookup_provider}:${lookup_testname}:${lookup_cmd}" || true)"
        if [ -n "$lookup_value" ]; then
            printf '%s\n' "$lookup_value"
            return 0
        fi
    fi

    lookup_value="$(pkg_lookup_key_in_map "$lookup_map_file" "${lookup_os_id}:${lookup_cmd}" || true)"
    if [ -n "$lookup_value" ]; then
        printf '%s\n' "$lookup_value"
        return 0
    fi

    lookup_value="$(pkg_lookup_key_in_map "$lookup_map_file" "${lookup_provider}:${lookup_cmd}" || true)"
    if [ -n "$lookup_value" ]; then
        printf '%s\n' "$lookup_value"
        return 0
    fi

    pkg_log_warn "No package mapping found for command, os=$lookup_os_id provider=$lookup_provider cmd=$lookup_cmd"
    return 1
}

# Look up a named package set from OS/provider package map without logging to stdout.
pkg_lookup_package_set() {
    set_name="$1"
    set_provider="$(pkg_active_provider)"
    set_os_id="$(pkg_detect_os_id)"
    set_map_file="$(pkg_resolve_path "$PKG_PACKAGE_MAP")"

    [ -n "$set_name" ] || return 1
    [ -r "$set_map_file" ] || return 1

    set_value="$(pkg_lookup_key_in_map "$set_map_file" "${set_os_id}:package-set:${set_name}" || true)"
    if [ -n "$set_value" ]; then
        printf '%s\n' "$set_value"
        return 0
    fi

    set_value="$(pkg_lookup_key_in_map "$set_map_file" "${set_provider}:package-set:${set_name}" || true)"
    if [ -n "$set_value" ]; then
        printf '%s\n' "$set_value"
        return 0
    fi

    return 1
}

# Return success when the current test invocation explicitly requests optional
# overlay package-set recovery.
#
# Default is base mode: optional package-sets are not installed unless the user
# or LAVA job passes one of the overlay flags.
#
# Supported args:
#   --overlay
#   --qcom-overlay
#   --enable-overlay
#   --base
#   --no-overlay
#
# Last matching option wins.
pkg_overlay_requested_from_args() {
    overlay_requested=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --overlay|--qcom-overlay|--enable-overlay)
                overlay_requested=1
                ;;
            --base|--no-overlay)
                overlay_requested=0
                ;;
        esac

        shift
    done

    [ "$overlay_requested" -eq 1 ]
}

# Return success when optional overlay package-set recovery is applicable.
#
# Yocto/qcom-distro and other embedded images must not regress. They should keep
# their existing image-provided packages and skip optional overlay package-set
# recovery unless explicitly supported later.
pkg_optional_package_set_supported_os() {
    optional_os_id="$1"

    case "$optional_os_id" in
        debian|ubuntu|centos)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Ensure an optional package-set only when overlay mode is explicitly requested.
#
# This is used by tests that support both:
#   base    - upstream distro/rootfs packages only
#   overlay - Qualcomm package-set installed over the base distro/rootfs
#
# Args:
#   $1 - package-set name, for example: graphics, audio, video, display
#   $2 - apt Debusine source for overlay packages, default: qli-staging
#   $3 - apt Debusine suite, default: auto
#   $4... - original run.sh arguments
#
# Return:
#   0 - overlay not requested, unsupported OS skipped, no mapping, or set ready
#   1 - overlay requested but package-set recovery failed
pkg_ensure_optional_package_set() {
    optional_set_name="$1"
    optional_apt_source="${2:-qli-staging}"
    optional_apt_suite="${3:-auto}"

    if [ "$#" -ge 3 ]; then
        shift 3
    else
        shift "$#"
    fi

    if [ -z "$optional_set_name" ]; then
        pkg_log_warn "pkg_ensure_optional_package_set called with empty set name"
        return 1
    fi

    # Yocto-safe default behavior:
    # no --overlay means no optional package-set work at all.
    if ! pkg_overlay_requested_from_args "$@"; then
        pkg_log_info "Optional package-set recovery not requested, set=$optional_set_name mode=base"
        return 0
    fi

    pkg_provider_init || true

    optional_provider="$(pkg_active_provider)"
    optional_os_id="$(pkg_detect_os_id)"

    if ! pkg_optional_package_set_supported_os "$optional_os_id"; then
        pkg_log_info "Optional package-set recovery not applicable, os=$optional_os_id provider=$optional_provider set=$optional_set_name"
        return 0
    fi

    optional_packages="$(pkg_lookup_package_set "$optional_set_name" || true)"
    if [ -z "$optional_packages" ]; then
        pkg_log_info "Optional package-set mapping not found, os=$optional_os_id provider=$optional_provider set=$optional_set_name"
        return 0
    fi

    case "$optional_provider" in
        apt)
            old_optional_source="${PKG_APT_DEBUSINE_SOURCE:-none}"
            old_optional_suite="${PKG_APT_DEBUSINE_SUITE:-auto}"

            case "$old_optional_source" in
                ""|none|disabled)
                    PKG_APT_DEBUSINE_SOURCE="$optional_apt_source"
                    ;;
            esac

            case "$old_optional_suite" in
                ""|auto)
                    PKG_APT_DEBUSINE_SUITE="$optional_apt_suite"
                    ;;
            esac

            if [ "${PKG_APT_DEBUSINE_SOURCE:-none}" != "$old_optional_source" ] ||
               [ "${PKG_APT_DEBUSINE_SUITE:-auto}" != "$old_optional_suite" ]; then
                rm -f "${PKG_APT_UPDATED_MARK:-/tmp/qcom_testkit_apt_updated}" 2>/dev/null || true
            fi
            ;;
    esac

    pkg_log_info "Optional package-set recovery requested, os=$optional_os_id provider=$optional_provider set=$optional_set_name packages=$optional_packages"

    pkg_ensure_package_set "$optional_set_name"
}

# Check whether the running kernel has headers/build tree available for DKMS.
#
# DKMS packages require a matching kernel build directory for the active kernel
# returned by uname -r. Without this, apt/rpm can leave the package in a
# half-configured state during postinst/autoinstall.
#
# Return:
#   0 - matching kernel headers/build tree found
#   1 - missing kernel version or no usable headers/build tree found
pkg_have_dkms_kernel_headers() {
    dkms_kernel="$(uname -r 2>/dev/null || true)"

    [ -n "$dkms_kernel" ] || return 1

    if [ -e "/lib/modules/${dkms_kernel}/build/Makefile" ] ||
       [ -e "/usr/src/linux-headers-${dkms_kernel}/Makefile" ] ||
       [ -e "/usr/src/kernels/${dkms_kernel}/Makefile" ]; then
        return 0
    fi

    return 1
}

# Detect whether a package is a DKMS package.
#
# First handles common DKMS package naming patterns, then for apt providers
# checks package metadata for a Depends/PreDepends relation on "dkms".
#
# Return:
#   0 - package appears to be DKMS-backed
#   1 - package is not detected as DKMS-backed or cannot be inspected
pkg_is_dkms_package() {
    dkms_pkg="$1"

    [ -n "$dkms_pkg" ] || return 1

    case "$dkms_pkg" in
        *-dkms|dkms-*)
            return 0
            ;;
    esac

    if [ "$(pkg_active_provider 2>/dev/null || true)" = "apt" ] &&
       command -v apt-cache >/dev/null 2>&1; then
        apt-cache depends "$dkms_pkg" 2>/dev/null |
            grep -Eq '^[[:space:]]*(Depends|PreDepends):[[:space:]]*dkms([[:space:]]|$)' &&
            return 0
    fi

    return 1
}

# Preflight DKMS package install/upgrade operations.
#
# This prevents package recovery from attempting to install or upgrade DKMS
# packages when matching kernel headers are missing. That avoids leaving dpkg/rpm
# in a broken or half-configured state.
#
# Controlled by:
#   PKG_DKMS_CHECK_HEADERS=1|0
#   PKG_DKMS_MISSING_HEADERS_ACTION=skip|fail
#
# Return:
#   0 - not a DKMS package, DKMS check disabled, or headers are available
#   1 - DKMS headers are missing and policy is "fail"
#   2 - DKMS headers are missing and policy is "skip"
pkg_dkms_preflight() {
    dkms_pkg="$1"
    dkms_action="$2"

    [ "${PKG_DKMS_CHECK_HEADERS:-1}" = "1" ] || return 0
    pkg_is_dkms_package "$dkms_pkg" || return 0
    pkg_have_dkms_kernel_headers && return 0

    dkms_kernel="$(uname -r 2>/dev/null || true)"
    [ -n "$dkms_kernel" ] || dkms_kernel="unknown"

    pkg_log_warn "DKMS package ${dkms_action:-operation} skipped - missing kernel headers, pkg=$dkms_pkg kernel=$dkms_kernel"
    pkg_log_warn "Install linux-headers-${dkms_kernel} or provide /lib/modules/${dkms_kernel}/build before installing DKMS packages"

    case "${PKG_DKMS_MISSING_HEADERS_ACTION:-skip}" in
        fail)
            return 1
            ;;
        skip|*)
            return 2
            ;;
    esac
}

# Clean up a failed DKMS package installation so package-manager state is not
# left half-configured after a postinst/autoinstall failure.
#
# This is best-effort only. The original install failure is still returned to
# the caller.
pkg_cleanup_failed_dkms_package() {
    cleanup_pkg="$1"
    cleanup_provider="$(pkg_active_provider)"

    [ -n "$cleanup_pkg" ] || return 0
    pkg_is_dkms_package "$cleanup_pkg" || return 0

    pkg_log_warn "Attempting cleanup for failed DKMS package, pkg=$cleanup_pkg provider=$cleanup_provider"

    case "$cleanup_provider" in
        apt)
            if command -v "$PKG_APT_GET" >/dev/null 2>&1; then
                pkg_run_cmd_retry "apt-purge-failed-dkms-$cleanup_pkg" \
                    env DEBIAN_FRONTEND=noninteractive \
                    "$PKG_APT_GET" purge -y \
                    -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                    "$cleanup_pkg" || true

                pkg_run_cmd_retry "apt-fix-after-failed-dkms-$cleanup_pkg" \
                    env DEBIAN_FRONTEND=noninteractive \
                    "$PKG_APT_GET" -f install -y \
                    -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" || true
            fi
            ;;
        rpm)
            rpm_tool="$(pkg_rpm_tool || true)"
            if [ -n "$rpm_tool" ]; then
                pkg_run_cmd_retry "$rpm_tool-remove-failed-dkms-$cleanup_pkg" \
                    "$rpm_tool" remove -y "$cleanup_pkg" || true
            fi
            ;;
        opkg)
            if command -v opkg >/dev/null 2>&1; then
                pkg_run_cmd_retry "opkg-remove-failed-dkms-$cleanup_pkg" \
                    opkg remove "$cleanup_pkg" || true
            fi
            ;;
    esac

    return 0
}

# Return installed package version for the active package provider.
pkg_installed_package_version() {
    version_pkg="$1"
    version_provider="$(pkg_active_provider)"

    [ -n "$version_pkg" ] || return 1

    case "$version_provider" in
        apt)
            dpkg-query -W -f='${Version}\n' "$version_pkg" 2>/dev/null | sed -n '1p'
            ;;
        rpm)
            rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$version_pkg" 2>/dev/null | sed -n '1p'
            ;;
        opkg)
            opkg status "$version_pkg" 2>/dev/null |
                sed -n 's/^Version:[[:space:]]*//p' |
                sed -n '1p'
            ;;
        *)
            return 1
            ;;
    esac
}

# Log package presence and include installed version when available.
pkg_log_package_present() {
    present_pkg="$1"
    present_version="$(pkg_installed_package_version "$present_pkg" || true)"

    if [ -n "$present_version" ]; then
        pkg_log_pass "Package already installed, $present_pkg version=$present_version"
    else
        pkg_log_pass "Package already installed, $present_pkg"
    fi
}

# Return success when package is installed.
pkg_have_package() {
    have_pkg="$1"
    have_provider="$(pkg_active_provider)"

    [ -n "$have_pkg" ] || return 1

    case "$have_provider" in
        apt)
            dpkg-query -W -f='${Status}\n' "$have_pkg" 2>/dev/null |
                grep -q "install ok installed"
            ;;
        rpm)
            rpm -q "$have_pkg" >/dev/null 2>&1
            ;;
        opkg)
            opkg status "$have_pkg" 2>/dev/null |
                grep -q "Status:.* installed"
            ;;
        *)
            return 1
            ;;
    esac
}

# Run command and print result.
pkg_run_cmd() {
    cmd_label="$1"
    shift

    pkg_log_info "Running command [$cmd_label]: $*"

    "$@"
    cmd_rc=$?

    if [ "$cmd_rc" -eq 0 ]; then
        pkg_log_pass "Command passed [$cmd_label]"
    else
        pkg_log_warn "Command failed [$cmd_label], rc=$cmd_rc"
    fi

    return "$cmd_rc"
}

# Run command with bounded retries.
pkg_run_cmd_retry() {
    retry_label="$1"
    shift

    retry_count="$(pkg_normalize_uint "$PKG_COMMAND_RETRIES" 2)"
    retry_sleep="$(pkg_normalize_uint "$PKG_COMMAND_RETRY_SLEEP" 5)"

    if [ "$retry_count" -lt 1 ]; then
        retry_count=1
    fi

    retry_attempt=1
    while [ "$retry_attempt" -le "$retry_count" ]; do
        pkg_log_info "Command attempt [$retry_label], ${retry_attempt}/${retry_count}"

        if pkg_run_cmd "$retry_label" "$@"; then
            return 0
        fi

        if [ "$retry_attempt" -lt "$retry_count" ]; then
            pkg_log_warn "Retrying command [$retry_label] after ${retry_sleep}s"
            sleep "$retry_sleep"
        fi

        retry_attempt=$((retry_attempt + 1))
    done

    pkg_log_fail "Command failed after ${retry_count} attempt(s) [$retry_label]"
    return 1
}

# Check network using functestlib helpers when available.
pkg_network_status() {
    if command -v check_network_status >/dev/null 2>&1; then
        check_network_status
        net_rc=$?

        if [ "$net_rc" -eq 0 ]; then
            return 0
        fi

        if [ "$net_rc" -eq 2 ]; then
            pkg_log_warn "Network has IP but internet probe failed; internal mirrors may still work"
            return 0
        fi

        return 1
    fi

    if command -v ip >/dev/null 2>&1; then
        if ip -4 route get 1.1.1.1 >/dev/null 2>&1; then
            pkg_log_pass "Network route exists"
            return 0
        fi
    fi

    pkg_log_warn "Unable to confirm network availability"
    return 1
}

# Try network recovery using existing functestlib helpers.
pkg_try_network_recovery_once() {
    pkg_log_info "Attempting package-provider network recovery"

    if command -v ensure_network_online >/dev/null 2>&1; then
        ensure_network_online || true
        return 0
    fi

    if command -v get_ethernet_interfaces >/dev/null 2>&1 &&
       command -v bringup_interface >/dev/null 2>&1; then
        net_interfaces="$(get_ethernet_interfaces 2>/dev/null || true)"

        for net_iface in $net_interfaces; do
            [ -n "$net_iface" ] || continue
            pkg_log_info "Trying Ethernet bring-up, iface=$net_iface"
            bringup_interface "$net_iface" || true

            if pkg_network_status; then
                return 0
            fi
        done
    fi

    pkg_log_warn "No supported network recovery helper succeeded"
    return 1
}

# Ensure network before package operations.
pkg_ensure_network_ready() {
    if ! pkg_bool_true "$PKG_NETWORK_REQUIRED"; then
        return 0
    fi

    if pkg_network_status; then
        pkg_log_pass "Network is ready for package operations"
        return 0
    fi

    if ! pkg_bool_true "$PKG_NETWORK_RECOVER"; then
        pkg_log_fail "Network is not ready and recovery is disabled"
        return 1
    fi

    net_retries="$(pkg_normalize_uint "$PKG_NETWORK_RETRIES" 2)"
    net_retry_sleep="$(pkg_normalize_uint "$PKG_NETWORK_RETRY_SLEEP" 5)"

    if [ "$net_retries" -lt 1 ]; then
        net_retries=1
    fi

    net_attempt=1
    while [ "$net_attempt" -le "$net_retries" ]; do
        pkg_log_warn "Network recovery attempt ${net_attempt}/${net_retries}"

        pkg_try_network_recovery_once || true
        sleep "$net_retry_sleep"

        if pkg_network_status; then
            pkg_log_pass "Network recovered successfully"
            return 0
        fi

        net_attempt=$((net_attempt + 1))
    done

    pkg_log_fail "Network is still not ready after recovery attempts"
    return 1
}

# Read first line from file.
pkg_read_first_line() {
    read_file_path="$1"

    if [ -z "$read_file_path" ] || [ ! -r "$read_file_path" ]; then
        return 1
    fi

    sed -n '1p' "$read_file_path" 2>/dev/null |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Detect apt auth machine from *.sources, fallback to configured hostname.
pkg_apt_detect_auth_machine() {
    if [ -d "$PKG_APT_SOURCES_ARTIFACT_DIR" ]; then
        for auth_src_file in "$PKG_APT_SOURCES_ARTIFACT_DIR"/*.sources; do
            [ -r "$auth_src_file" ] || continue

            auth_machine="$(
                sed -n 's#.*https://\([^/[:space:]]*\).*#\1#p' "$auth_src_file" |
                    sed -n '1p'
            )"

            if [ -n "$auth_machine" ]; then
                printf '%s\n' "$auth_machine"
                return 0
            fi
        done
    fi

    printf '%s\n' "$PKG_APT_AUTH_MACHINE_FALLBACK"
    return 0
}

# Read optional apt auth login.
pkg_apt_read_auth_login() {
    pkg_read_first_line "$PKG_APT_AUTH_LOGIN_FILE"
}

# Read optional apt auth password/token.
pkg_apt_read_auth_password() {
    pkg_read_first_line "$PKG_APT_AUTH_PASSWORD_FILE"
}

# Create optional apt auth config if secret files are present.
pkg_apt_install_auth_if_secrets_present() {
    if [ ! -r "$PKG_APT_AUTH_LOGIN_FILE" ] || [ ! -r "$PKG_APT_AUTH_PASSWORD_FILE" ]; then
        pkg_log_info "APT auth secret files not present, skipping auth config creation"
        return 0
    fi

    apt_auth_login="$(pkg_apt_read_auth_login || true)"
    apt_auth_password="$(pkg_apt_read_auth_password || true)"
    apt_auth_machine="$(pkg_apt_detect_auth_machine)"

    if [ -z "$apt_auth_login" ] || [ -z "$apt_auth_password" ]; then
        pkg_log_warn "APT auth secret file is empty, skipping auth config creation"
        return 0
    fi

    apt_auth_dir="$(dirname "$PKG_APT_AUTH_CONF")"

    if [ ! -d "$apt_auth_dir" ]; then
        mkdir -p "$apt_auth_dir" || {
            pkg_log_fail "Failed to create APT auth directory, $apt_auth_dir"
            return 1
        }
    fi

    apt_tmp_auth="${PKG_APT_AUTH_CONF}.$$"

    apt_old_umask="$(umask)"
    umask 077

    {
        printf 'machine %s\n' "$apt_auth_machine"
        printf 'login %s\n' "$apt_auth_login"
        printf 'password %s\n' "$apt_auth_password"
    } > "$apt_tmp_auth" || {
        umask "$apt_old_umask"
        rm -f "$apt_tmp_auth"
        pkg_log_fail "Failed to write temporary APT auth config"
        return 1
    }

    umask "$apt_old_umask"

    chmod 600 "$apt_tmp_auth" 2>/dev/null || true

    mv "$apt_tmp_auth" "$PKG_APT_AUTH_CONF" || {
        rm -f "$apt_tmp_auth"
        pkg_log_fail "Failed to install APT auth config, $PKG_APT_AUTH_CONF"
        return 1
    }

    chmod 600 "$PKG_APT_AUTH_CONF" 2>/dev/null || true

    pkg_log_pass "Installed optional APT auth config, $PKG_APT_AUTH_CONF"
    return 0
}

# Install optional apt source artifacts when present.
pkg_apt_install_sources_if_present() {
    if [ ! -d "$PKG_APT_SOURCES_ARTIFACT_DIR" ]; then
        pkg_log_info "No APT metadata source directory found, using existing apt sources"
        return 0
    fi

    if [ ! -d /etc/apt/sources.list.d ]; then
        mkdir -p /etc/apt/sources.list.d || {
            pkg_log_fail "Failed to create /etc/apt/sources.list.d"
            return 1
        }
    fi

    apt_src_found=0

    for apt_src_file in "$PKG_APT_SOURCES_ARTIFACT_DIR"/*.sources; do
        [ -r "$apt_src_file" ] || continue
        apt_src_found=1

        apt_target_path="/etc/apt/sources.list.d/$(basename "$apt_src_file")"

        if grep -qi "password" "$apt_src_file" 2>/dev/null; then
            pkg_log_fail "APT source artifact appears to contain credentials, refusing to install, $apt_src_file"
            return 1
        fi

        cp "$apt_src_file" "$apt_target_path" || {
            pkg_log_fail "Failed to install APT source file, $apt_target_path"
            return 1
        }

        chmod 644 "$apt_target_path" 2>/dev/null || true
        pkg_log_pass "Installed APT source file, $apt_target_path"
    done

    if [ "$apt_src_found" -eq 0 ]; then
        pkg_log_info "No *.sources artifacts found, using existing apt sources"
    fi

    return 0
}

# Log metadata source-package, if present.
pkg_apt_log_metadata_source_package() {
    apt_metadata_file="$PKG_APT_SOURCES_ARTIFACT_DIR/metadata.json"

    if [ ! -r "$apt_metadata_file" ]; then
        return 0
    fi

    apt_source_package="$(
        sed -n 's/.*"source-package"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$apt_metadata_file" |
            sed -n '1p'
    )"

    if [ -n "$apt_source_package" ]; then
        pkg_log_info "APT metadata source-package, $apt_source_package"
    fi

    return 0
}

# Return the default Qualcomm Debusine suite for the detected OS.
pkg_apt_default_debusine_suite() {
    debusine_os_id="$(pkg_detect_os_id)"

    case "$debusine_os_id" in
        ubuntu)
            printf '%s\n' "resolute"
            ;;
        debian)
            printf '%s\n' "trixie"
            ;;
        *)
            printf '%s\n' "trixie"
            ;;
    esac
}

# Return success when an apt source file already has the requested URI and suite.
pkg_apt_source_file_matches() {
    source_file="$1"
    expected_uri="$2"
    expected_suite="$3"

    [ -r "$source_file" ] || return 1

    expected_uri_norm="$(printf '%s' "$expected_uri" | sed 's#/*$##')"
    actual_uri_norm="$(
        sed -n 's/^URIs:[[:space:]]*//p' "$source_file" 2>/dev/null |
            sed -n '1p' |
            sed 's#/*$##'
    )"
    actual_suite="$(
        sed -n 's/^Suites:[[:space:]]*//p' "$source_file" 2>/dev/null |
            sed -n '1p'
    )"

    [ "$actual_uri_norm" = "$expected_uri_norm" ] &&
        [ "$actual_suite" = "$expected_suite" ]
}

# Configure a built-in Qualcomm Debusine apt source when requested.
pkg_apt_install_debusine_source_if_configured() {
    debusine_source_name="$PKG_APT_DEBUSINE_SOURCE"

    case "$PKG_APT_DEBUSINE_SUITE" in
        ''|auto)
            debusine_suite="$(pkg_apt_default_debusine_suite)"
            ;;
        *)
            debusine_suite="$PKG_APT_DEBUSINE_SUITE"
            ;;
    esac

    case "$debusine_source_name" in
        ""|none|disabled)
            pkg_log_info "No built-in Qualcomm Debusine apt source requested"
            return 0
            ;;
        qli)
            debusine_target="/etc/apt/sources.list.d/qli.sources"
            debusine_uri="https://deb.debusine.qualcomm.com/qualcomm/qli"
            debusine_components="main contrib non-free-firmware non-free"
            ;;
        qli-staging)
            debusine_target="/etc/apt/sources.list.d/qli-staging.sources"
            debusine_uri="https://deb.debusine.qualcomm.com/qualcomm/qli-staging"
            debusine_components="main contrib non-free non-free-firmware"
            ;;
        *)
            pkg_log_fail "Unsupported apt_debusine_source value, $debusine_source_name"
            return 1
            ;;
    esac

    mkdir -p /etc/apt/sources.list.d || {
        pkg_log_fail "Failed to create /etc/apt/sources.list.d"
        return 1
    }

    if pkg_apt_source_file_matches "$debusine_target" "$debusine_uri" "$debusine_suite"; then
        pkg_log_pass "APT source already configured, $debusine_target"
        return 0
    fi

    if [ -r "$debusine_target" ]; then
        pkg_log_warn "APT source exists but does not match requested URI/suite, updating, $debusine_target"
    fi

    case "$debusine_source_name" in
        qli)
            cat > "$debusine_target" <<EOF
# Qualcomm Linux repository
Types: deb
URIs: $debusine_uri
Suites: $debusine_suite
Components: $debusine_components
Signed-By:
 -----BEGIN PGP PUBLIC KEY BLOCK-----
 .
 mDMEag8p/xYJKwYBBAHaRw8BAQdAdB6JSNF1OXxnsTgp4VTUekW52BM7e6ZQVRsq
 QT5QDaS0JEFyY2hpdmUgc2lnbmluZyBrZXkgZm9yIHF1YWxjb21tL3FsaYiQBBMW
 CgA4FiEEOwuFfyf8aPE5SQakb8qSvoHfw8IFAmoPKf8CGwMFCwkIBwIGFQoJCAsC
 BBYCAwECHgECF4AACgkQb8qSvoHfw8Lz1gEA9XocADbvqUgZQc0LceThn7vMI98d
 kTJoiInuulQ6rEUBANo+GOKILH71VRnZ5jWtsu7IlVk7oUMlTtC0eE5tcBwB
 =bX6V
 -----END PGP PUBLIC KEY BLOCK-----
EOF
            ;;
        qli-staging)
            cat > "$debusine_target" <<EOF
Types: deb deb-src
URIs: $debusine_uri
Suites: $debusine_suite
Components: $debusine_components
Signed-By:
 -----BEGIN PGP PUBLIC KEY BLOCK-----
 .
 mDMEajuyfxYJKwYBBAHaRw8BAQdASazjfos7KwJJ+G6xdBRzc3v7orITHEY6jKc3
 RJ9SKQ+0LEFyY2hpdmUgc2lnbmluZyBrZXkgZm9yIHF1YWxjb21tL3FsaS1zdGFn
 aW5niJAEExYKADgWIQQHaA+DhymsE9b1W++Bhz/mnjKc1AUCajuyfwIbAwULCQgH
 AgYVCgkICwIEFgIDAQIeAQIXgAAKCRCBhz/mnjKc1BFAAQCBx/l+c5fPIl1yxrHZ
 oesE1USx5864EapEurg7g8Ov6gD/ZJbguusDuXxCCPkZtyR/APq3ckIEy6zIl7/0
 9RR1JgI=
 =sKJS
 -----END PGP PUBLIC KEY BLOCK-----
EOF
            ;;
    esac

    chmod 644 "$debusine_target" 2>/dev/null || true
    pkg_log_pass "Installed Qualcomm Debusine apt source, $debusine_target"
    return 0
}

# Prepare apt sources and optional auth.
pkg_apt_prepare_sources() {
    pkg_apt_install_debusine_source_if_configured || return 1
    pkg_apt_install_sources_if_present || return 1
    pkg_apt_install_auth_if_secrets_present || return 1
    pkg_apt_log_metadata_source_package || true
    return 0
}

# Dump file with credential-like fields redacted.
pkg_dump_file_redacted() {
    dump_prefix="$1"
    dump_file_path="$2"

    if [ ! -r "$dump_file_path" ]; then
        return 0
    fi

    sed \
        -e 's/[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][[:space:]]\+.*/password REDACTED/' \
        -e 's/[Ll][Oo][Gg][Ii][Nn][[:space:]]\+.*/login REDACTED/' \
        -e 's#://[^/@][^/@]*:[^/@][^/@]*@#://REDACTED:REDACTED@#g' \
        "$dump_file_path" 2>/dev/null |
        sed "s/^/[$dump_prefix] /"
}

# Dump apt sources for CI debugging.
pkg_apt_dump_sources() {
    pkg_log_info "APT configured sources:"

    if [ -r /etc/apt/sources.list ]; then
        pkg_log_info "APT source file, /etc/apt/sources.list"
        pkg_dump_file_redacted "APT-SOURCE" /etc/apt/sources.list || true
    fi

    if [ -d /etc/apt/sources.list.d ]; then
        find /etc/apt/sources.list.d -maxdepth 1 -type f -print 2>/dev/null |
            while IFS= read -r dump_src_file; do
                pkg_log_info "APT source file, $dump_src_file"
                pkg_dump_file_redacted "APT-SOURCE" "$dump_src_file" || true
            done
    fi
}

# Verify apt-get availability.
pkg_apt_tool_check() {
    if ! command -v "$PKG_APT_GET" >/dev/null 2>&1; then
        pkg_log_fail "$PKG_APT_GET is not available"
        return 1
    fi

    return 0
}

# Run apt update once per test session.
pkg_apt_update() {
    pkg_apt_tool_check || return 1

    if [ -f "$PKG_APT_UPDATED_MARK" ]; then
        pkg_log_info "APT update already completed in this test session"
        return 0
    fi

    pkg_apt_prepare_sources || return 1
    pkg_ensure_network_ready || return 1

    pkg_log_info "APT version:"
    "$PKG_APT_GET" --version 2>&1 || true

    pkg_apt_dump_sources || true

    pkg_run_cmd_retry "apt-update" \
        env DEBIAN_FRONTEND=noninteractive \
        "$PKG_APT_GET" update -y \
        --allow-releaseinfo-change-origin \
        --allow-releaseinfo-change-label \
        -o Acquire::Retries=2 \
        -o Acquire::Languages=none \
        -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}"

    apt_update_rc=$?

    if [ "$apt_update_rc" -eq 0 ]; then
        : > "$PKG_APT_UPDATED_MARK" 2>/dev/null || true
    fi

    return "$apt_update_rc"
}

# Optionally run apt upgrade.
pkg_apt_upgrade() {
    if ! pkg_bool_true "$PKG_PACKAGE_UPGRADE"; then
        pkg_log_info "APT upgrade disabled by config"
        return 0
    fi

    if [ -f "$PKG_APT_UPGRADED_MARK" ]; then
        pkg_log_info "APT upgrade already completed in this test session"
        return 0
    fi

    pkg_apt_update || return 1

    pkg_run_cmd_retry "apt-upgrade" \
        env DEBIAN_FRONTEND=noninteractive \
        "$PKG_APT_GET" upgrade -y \
        -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}"

    apt_upgrade_rc=$?

    if [ "$apt_upgrade_rc" -eq 0 ]; then
        : > "$PKG_APT_UPGRADED_MARK" 2>/dev/null || true
    fi

    return "$apt_upgrade_rc"
}

# Best-effort apt fix-broken.
pkg_apt_fix_broken_if_enabled() {
    if ! pkg_bool_true "$PKG_APT_FIX_BROKEN"; then
        return 0
    fi

    pkg_run_cmd_retry "apt-fix-broken" \
        env DEBIAN_FRONTEND=noninteractive \
        "$PKG_APT_GET" -f install -y \
        -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" || true

    return 0
}

# List direct runtime dependencies for an apt package.
pkg_apt_package_runtime_deps() {
    apt_dep_pkg="$1"

    apt-cache depends "$apt_dep_pkg" 2>/dev/null |
        sed -n \
            -e 's/^[[:space:]]*Depends:[[:space:]]*//p' \
            -e 's/^[[:space:]]*PreDepends:[[:space:]]*//p' |
        sed 's/<[^>]*>//g' |
        awk '{print $1}' |
        sed '/^$/d' |
        sort -u
}

# Log runtime dependencies and installed versions for a package.
pkg_log_package_dependencies() {
    parent_pkg="$1"
    dep_provider="$(pkg_active_provider)"

    [ -n "$parent_pkg" ] || return 0

    case "$dep_provider" in
        apt)
            dep_list="$(pkg_apt_package_runtime_deps "$parent_pkg" || true)"
            ;;
        *)
            return 0
            ;;
    esac

    [ -n "$dep_list" ] || return 0

    dep_list_one_line="$(printf '%s\n' "$dep_list" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    pkg_log_info "Runtime dependencies for package, $parent_pkg: $dep_list_one_line"

    for dep_pkg in $dep_list; do
        [ -n "$dep_pkg" ] || continue

        if pkg_have_package "$dep_pkg"; then
            dep_version="$(pkg_installed_package_version "$dep_pkg" || true)"
            if [ -n "$dep_version" ]; then
                pkg_log_pass "Dependency installed, parent=$parent_pkg dep=$dep_pkg version=$dep_version"
            else
                pkg_log_pass "Dependency installed, parent=$parent_pkg dep=$dep_pkg"
            fi
        else
            pkg_log_warn "Dependency not installed, parent=$parent_pkg dep=$dep_pkg"
        fi
    done
}

# Install an apt package.
#
# Ordinary packages follow the global install-recommends policy.
#
# DKMS packages are handled differently:
# - do not run apt-get -f install before installing the package, because a
#   previously unpacked DKMS package may be configured before its recommended
#   compiler/build dependencies are available
# - explicitly enable APT recommendations so dkms, compiler, libc development
#   files, fakeroot and related build requirements are selected by APT
pkg_apt_install_package() {
    apt_install_pkg="$1"
    apt_install_is_dkms=0

    [ -n "$apt_install_pkg" ] || return 1

    pkg_apt_update || return 1
    pkg_apt_upgrade || return 1

    if pkg_is_dkms_package "$apt_install_pkg"; then
        apt_install_is_dkms=1
        pkg_log_info "DKMS package detected, enabling recommended build dependencies, pkg=$apt_install_pkg"
        pkg_log_info "Skipping pre-install apt fix-broken for DKMS package, pkg=$apt_install_pkg"
    else
        pkg_apt_fix_broken_if_enabled || true
    fi

    if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy "$apt_install_pkg" 2>&1 |
            sed "s/^/[APT-POLICY:$apt_install_pkg] /" ||
            true
    fi

    if [ "$apt_install_is_dkms" -eq 1 ]; then
        if pkg_bool_true "$PKG_APT_FIX_MISSING"; then
            pkg_run_cmd_retry "apt-install-$apt_install_pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --install-recommends \
                --fix-missing \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$apt_install_pkg"
        else
            pkg_run_cmd_retry "apt-install-$apt_install_pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --install-recommends \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$apt_install_pkg"
        fi

        return $?
    fi

    if pkg_bool_true "$PKG_APT_INSTALL_RECOMMENDS"; then
        if pkg_bool_true "$PKG_APT_FIX_MISSING"; then
            pkg_run_cmd_retry "apt-install-$apt_install_pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --fix-missing \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$apt_install_pkg"
        else
            pkg_run_cmd_retry "apt-install-$apt_install_pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$apt_install_pkg"
        fi
    else
        if pkg_bool_true "$PKG_APT_FIX_MISSING"; then
            pkg_run_cmd_retry "apt-install-$apt_install_pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --no-install-recommends \
                --fix-missing \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$apt_install_pkg"
        else
            pkg_run_cmd_retry "apt-install-$apt_install_pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --no-install-recommends \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$apt_install_pkg"
        fi
    fi
}

# Install multiple ordinary apt packages in one transaction.
#
# Args:
#   $1     - command-label suffix, normally the package-set name
#   $2..$N - package names
#
# DKMS packages must continue through pkg_apt_install_package() so their
# header preflight, recommended build dependencies, and cleanup behavior are
# preserved.
pkg_apt_install_package_list() {
    apt_list_label="$1"
    shift

    if [ "$#" -eq 0 ]; then
        return 0
    fi

    for apt_list_pkg in "$@"; do
        [ -n "$apt_list_pkg" ] || continue

        if pkg_is_dkms_package "$apt_list_pkg"; then
            pkg_log_fail "DKMS package cannot use batch apt installation, pkg=$apt_list_pkg"
            return 1
        fi
    done

    apt_list_packages="$*"

    pkg_apt_update || return 1
    pkg_apt_upgrade || return 1

    pkg_apt_fix_broken_if_enabled || true

    if command -v apt-cache >/dev/null 2>&1; then
        for apt_list_pkg in "$@"; do
            [ -n "$apt_list_pkg" ] || continue

            apt-cache policy "$apt_list_pkg" 2>&1 |
                sed "s/^/[APT-POLICY:$apt_list_pkg] /" ||
                true
        done
    fi

    pkg_log_info "Installing apt package list in one transaction, packages=$apt_list_packages"

    if pkg_bool_true "$PKG_APT_INSTALL_RECOMMENDS"; then
        if pkg_bool_true "$PKG_APT_FIX_MISSING"; then
            pkg_run_cmd_retry "apt-install-package-set-$apt_list_label" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --fix-missing \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$@"
        else
            pkg_run_cmd_retry "apt-install-package-set-$apt_list_label" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$@"
        fi
    else
        if pkg_bool_true "$PKG_APT_FIX_MISSING"; then
            pkg_run_cmd_retry "apt-install-package-set-$apt_list_label" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --no-install-recommends \
                --fix-missing \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$@"
        else
            pkg_run_cmd_retry "apt-install-package-set-$apt_list_label" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --no-install-recommends \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$@"
        fi
    fi
}

# Pick rpm package manager.
pkg_rpm_tool() {
    if command -v dnf >/dev/null 2>&1; then
        printf '%s\n' "dnf"
        return 0
    fi

    if command -v yum >/dev/null 2>&1; then
        printf '%s\n' "yum"
        return 0
    fi

    return 1
}

# Refresh rpm metadata.
pkg_rpm_update() {
    rpm_tool="$(pkg_rpm_tool || true)"

    if [ -z "$rpm_tool" ]; then
        pkg_log_warn "Neither dnf nor yum is available"
        return 1
    fi

    if [ -f "$PKG_RPM_UPDATED_MARK" ]; then
        pkg_log_info "$rpm_tool metadata update already completed in this test session"
        return 0
    fi

    pkg_ensure_network_ready || return 1

    "$rpm_tool" --version 2>&1 || true
    "$rpm_tool" repolist all 2>&1 | sed "s/^/[RPM-REPOLIST] /" || true

    if pkg_bool_true "$PKG_RPM_BEST_EFFORT_CLEAN"; then
        "$rpm_tool" clean all 2>&1 | sed "s/^/[RPM-CLEAN] /" || true
    fi

    pkg_run_cmd_retry "$rpm_tool-makecache" "$rpm_tool" makecache -y
    rpm_update_rc=$?

    if [ "$rpm_update_rc" -eq 0 ]; then
        : > "$PKG_RPM_UPDATED_MARK" 2>/dev/null || true
    fi

    return "$rpm_update_rc"
}

# Optionally upgrade rpm packages.
pkg_rpm_upgrade() {
    rpm_tool="$(pkg_rpm_tool || true)"

    if [ -z "$rpm_tool" ]; then
        return 1
    fi

    if ! pkg_bool_true "$PKG_PACKAGE_UPGRADE"; then
        pkg_log_info "$rpm_tool upgrade disabled by config"
        return 0
    fi

    if [ -f "$PKG_RPM_UPGRADED_MARK" ]; then
        pkg_log_info "$rpm_tool upgrade already completed in this test session"
        return 0
    fi

    pkg_rpm_update || return 1

    pkg_run_cmd_retry "$rpm_tool-upgrade" "$rpm_tool" upgrade -y
    rpm_upgrade_rc=$?

    if [ "$rpm_upgrade_rc" -eq 0 ]; then
        : > "$PKG_RPM_UPGRADED_MARK" 2>/dev/null || true
    fi

    return "$rpm_upgrade_rc"
}

# Install rpm package.
pkg_rpm_install_package() {
    rpm_install_pkg="$1"
    rpm_tool="$(pkg_rpm_tool || true)"

    if [ -z "$rpm_tool" ]; then
        return 1
    fi

    pkg_rpm_update || return 1
    pkg_rpm_upgrade || return 1

    "$rpm_tool" info "$rpm_install_pkg" 2>&1 | sed "s/^/[RPM-INFO:$rpm_install_pkg] /" || true

    pkg_run_cmd_retry "$rpm_tool-install-$rpm_install_pkg" "$rpm_tool" install -y "$rpm_install_pkg"
}

# Refresh opkg metadata.
pkg_opkg_update() {
    if [ -f "$PKG_OPKG_UPDATED_MARK" ]; then
        pkg_log_info "opkg update already completed in this test session"
        return 0
    fi

    pkg_ensure_network_ready || return 1

    pkg_run_cmd_retry "opkg-update" opkg update
    opkg_update_rc=$?

    if [ "$opkg_update_rc" -eq 0 ]; then
        : > "$PKG_OPKG_UPDATED_MARK" 2>/dev/null || true
    fi

    return "$opkg_update_rc"
}

# Install opkg package.
pkg_opkg_install_package() {
    opkg_install_pkg="$1"

    pkg_opkg_update || return 1
    pkg_run_cmd_retry "opkg-install-$opkg_install_pkg" opkg install "$opkg_install_pkg"
}

# Install package using active provider.
pkg_install_package() {
    install_pkg="$1"
    install_provider="$(pkg_active_provider)"
 
    if [ -z "$install_pkg" ]; then
        pkg_log_warn "pkg_install_package called with empty package name"
        return 1
    fi
 
    if pkg_have_package "$install_pkg"; then
        pkg_log_package_present "$install_pkg"
        pkg_log_package_dependencies "$install_pkg"
        return 0
    fi
 
    if ! pkg_can_install; then
        pkg_log_warn "Package missing and package install disabled, $install_pkg"
        return 1
    fi
 
    # DKMS packages require matching kernel headers. For mandatory overlay
    # packages, missing headers should fail before apt/rpm/opkg install begins.
    pkg_dkms_preflight "$install_pkg" "install"
    dkms_rc=$?
    case "$dkms_rc" in
        0)
            ;;
        1)
            return 1
            ;;
        2)
            return 0
            ;;
    esac
 
    pkg_provider_summary
 
    install_rc=1
 
    case "$install_provider" in
        apt)
            pkg_apt_install_package "$install_pkg"
            install_rc=$?
            ;;
        rpm)
            pkg_rpm_install_package "$install_pkg"
            install_rc=$?
            ;;
        opkg)
            pkg_opkg_install_package "$install_pkg"
            install_rc=$?
            ;;
        check)
            pkg_log_warn "Check-only provider does not support package installation"
            return 1
            ;;
        *)
            pkg_log_warn "Unsupported package provider, $install_provider"
            return 1
            ;;
    esac
 
    if [ "$install_rc" -ne 0 ]; then
        pkg_cleanup_failed_dkms_package "$install_pkg" || true
        return "$install_rc"
    fi
 
    return 0
}

# Ensure a single package is installed through the active provider.
pkg_ensure_package() {
    ensure_single_pkg="$1"

    if [ -z "$ensure_single_pkg" ]; then
        return 1
    fi

    if pkg_have_package "$ensure_single_pkg"; then
        pkg_log_package_present "$ensure_single_pkg"
        pkg_log_package_dependencies "$ensure_single_pkg"
        return 0
    fi

    pkg_install_package "$ensure_single_pkg"
}

# Upgrade an already-installed package through the active provider.
pkg_upgrade_installed_package() {
    upgrade_pkg="$1"
    upgrade_provider="$(pkg_active_provider)"
 
    [ -n "$upgrade_pkg" ] || return 1
 
    # DKMS package upgrades can also trigger postinst/autoinstall. Avoid that
    # when matching kernel headers are missing.
    pkg_dkms_preflight "$upgrade_pkg" "upgrade"
    dkms_rc=$?
    case "$dkms_rc" in
        0)
            ;;
        1)
            return 1
            ;;
        2)
            return 0
            ;;
    esac
 
    case "$upgrade_provider" in
        apt)
            pkg_apt_update || return 1
 
            if command -v apt-cache >/dev/null 2>&1; then
                apt-cache policy "$upgrade_pkg" 2>&1 |
                    sed "s/^/[APT-POLICY:$upgrade_pkg] /" || true
            fi
 
            pkg_log_info "Checking package-specific upgrade, $upgrade_pkg"
            pkg_run_cmd_retry "apt-only-upgrade-$upgrade_pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --only-upgrade \
                --no-install-recommends \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$upgrade_pkg"
            ;;
        rpm)
            pkg_log_info "Checking package-specific rpm upgrade, $upgrade_pkg"
            rpm_tool="$(pkg_rpm_tool || true)"
            [ -n "$rpm_tool" ] || return 1
            pkg_rpm_update || return 1
            pkg_run_cmd_retry "$rpm_tool-upgrade-$upgrade_pkg" "$rpm_tool" upgrade -y "$upgrade_pkg"
            ;;
        opkg)
            pkg_log_info "Checking package-specific opkg upgrade, $upgrade_pkg"
            pkg_opkg_update || return 1
            pkg_run_cmd_retry "opkg-upgrade-$upgrade_pkg" opkg upgrade "$upgrade_pkg"
            ;;
        *)
            pkg_log_info "Provider does not support package upgrade, provider=$upgrade_provider pkg=$upgrade_pkg"
            return 0
            ;;
    esac
}

# Install a missing package or upgrade it when package-set upgrade is enabled.
pkg_ensure_or_upgrade_package() {
    ensure_pkg="$1"

    [ -n "$ensure_pkg" ] || return 1

    if pkg_have_package "$ensure_pkg"; then
        pkg_log_package_present "$ensure_pkg"
        pkg_log_package_dependencies "$ensure_pkg"

        if pkg_bool_true "$PKG_PACKAGE_SET_UPGRADE"; then
            if ! pkg_upgrade_installed_package "$ensure_pkg"; then
                return 1
            fi

            if pkg_have_package "$ensure_pkg"; then
                pkg_log_package_present "$ensure_pkg"
                pkg_log_package_dependencies "$ensure_pkg"
            fi
        fi

        return 0
    fi

    pkg_log_warn "Package missing, installing, $ensure_pkg"

    if ! pkg_install_package "$ensure_pkg"; then
        return 1
    fi

    if pkg_have_package "$ensure_pkg"; then
        pkg_log_package_present "$ensure_pkg"
        pkg_log_package_dependencies "$ensure_pkg"
    fi

    return 0
}

# Ensure every package in a named package set is installed or upgraded when mapped.
#
# APT package sets batch ordinary missing packages into one transaction.
# DKMS packages retain their existing individual handling.
# RPM, opkg, and check-only providers retain their existing behavior.
pkg_ensure_package_set() {
    set_name="$1"

    if [ -z "$set_name" ]; then
        pkg_log_warn "pkg_ensure_package_set called with empty set name"
        return 1
    fi

    set_provider="$(pkg_active_provider)"
    set_os_id="$(pkg_detect_os_id)"
    set_packages="$(pkg_lookup_package_set "$set_name" || true)"

    if [ -z "$set_packages" ]; then
        pkg_log_info "Package-set recovery skipped, no mapping for set=$set_name provider=$set_provider os=$set_os_id"
        return 0
    fi

    pkg_log_info "Ensuring package set, set=$set_name packages=$set_packages"

    case "$set_provider" in
        apt)
            set_existing_packages=""
            set_missing_packages=""
            set_missing_dkms_packages=""

            for set_pkg in $set_packages; do
                [ -n "$set_pkg" ] || continue

                if pkg_have_package "$set_pkg"; then
                    set_existing_packages="${set_existing_packages}${set_existing_packages:+ }$set_pkg"
                elif pkg_is_dkms_package "$set_pkg"; then
                    set_missing_dkms_packages="${set_missing_dkms_packages}${set_missing_dkms_packages:+ }$set_pkg"
                else
                    set_missing_packages="${set_missing_packages}${set_missing_packages:+ }$set_pkg"
                fi
            done

            if [ -n "$set_missing_packages" ]; then
                if ! pkg_can_install; then
                    pkg_log_fail "Package set is incomplete and installation is unavailable, set=$set_name missing=$set_missing_packages"
                    return 1
                fi

                pkg_provider_summary

                # Package names come from the trusted repository package map.
                # shellcheck disable=SC2086
                if ! pkg_apt_install_package_list \
                    "$set_name" \
                    $set_missing_packages; then
                    pkg_log_warn "Batch package-set installation failed; falling back to individual recovery, set=$set_name"

                    for set_pkg in $set_missing_packages; do
                        [ -n "$set_pkg" ] || continue
                        pkg_log_warn "Package missing, installing individually, $set_pkg"

                        if ! pkg_ensure_package "$set_pkg"; then
                            pkg_log_fail "Failed to ensure package set, set=$set_name pkg=$set_pkg"
                            return 1
                        fi
                    done
                fi

                for set_pkg in $set_missing_packages; do
                    [ -n "$set_pkg" ] || continue

                    if ! pkg_have_package "$set_pkg"; then
                        pkg_log_fail "Package remains missing after package-set installation, set=$set_name pkg=$set_pkg"
                        return 1
                    fi

                    pkg_log_package_present "$set_pkg"
                    pkg_log_package_dependencies "$set_pkg"
                done
            fi

            for set_pkg in $set_missing_dkms_packages; do
                [ -n "$set_pkg" ] || continue
                pkg_log_warn "DKMS package missing, installing individually, $set_pkg"

                if ! pkg_ensure_or_upgrade_package "$set_pkg"; then
                    pkg_log_fail "Failed to ensure package set, set=$set_name pkg=$set_pkg"
                    return 1
                fi
            done

            for set_pkg in $set_existing_packages; do
                [ -n "$set_pkg" ] || continue

                if ! pkg_ensure_or_upgrade_package "$set_pkg"; then
                    pkg_log_fail "Failed to ensure package set, set=$set_name pkg=$set_pkg"
                    return 1
                fi
            done
            ;;
        *)
            for set_pkg in $set_packages; do
                [ -n "$set_pkg" ] || continue

                if ! pkg_ensure_or_upgrade_package "$set_pkg"; then
                    pkg_log_fail "Failed to ensure package set, set=$set_name pkg=$set_pkg"
                    return 1
                fi
            done
            ;;
    esac

    pkg_log_pass "Package set ready, set=$set_name"
    return 0
}

# Remove an explicit list of installed packages using the active provider.
pkg_remove_package_list() {
    prpl_provider="$(pkg_active_provider)"
    prpl_installed=""

    for prpl_pkg in "$@"; do
        [ -n "$prpl_pkg" ] || continue

        if pkg_have_package "$prpl_pkg"; then
            prpl_installed="$prpl_installed $prpl_pkg"
        fi
    done

    prpl_installed="$(printf '%s\n' "$prpl_installed" | sed 's/^[[:space:]]*//')"

    if [ -z "$prpl_installed" ]; then
        pkg_log_pass "Requested packages are already absent"
        return 0
    fi

    if ! pkg_can_install; then
        return 1
    fi

    pkg_log_info "Removing package list, provider=$prpl_provider packages=$prpl_installed"

    case "$prpl_provider" in
        apt)
            # Intentional splitting: package names are read from the trusted map.
            # shellcheck disable=SC2086
            pkg_run_cmd_retry "apt-purge-package-set" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" purge -y \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                $prpl_installed || return 1
            ;;
        rpm)
            prpl_rpm_tool="$(pkg_rpm_tool || true)"
            [ -n "$prpl_rpm_tool" ] || return 1

            # Intentional splitting: package names are read from the trusted map.
            # shellcheck disable=SC2086
            pkg_run_cmd_retry "$prpl_rpm_tool-remove-package-set" \
                "$prpl_rpm_tool" remove -y $prpl_installed || return 1
            ;;
        opkg)
            # Intentional splitting: package names are read from the trusted map.
            # shellcheck disable=SC2086
            pkg_run_cmd_retry "opkg-remove-package-set" \
                opkg remove $prpl_installed || return 1
            ;;
        *)
            pkg_log_fail "Provider does not support package removal, provider=$prpl_provider"
            return 1
            ;;
    esac

    for prpl_pkg in $prpl_installed; do
        if pkg_have_package "$prpl_pkg"; then
            pkg_log_fail "Package remains installed after removal, $prpl_pkg"
            return 1
        fi

        pkg_log_pass "Package removed, $prpl_pkg"
    done

    return 0
}

# Restore a named optional package set to the base image state by removing all
# currently installed packages mapped to that set.
#
# Return values:
#   0 - package set was already absent
#   1 - restore failed or package-set mapping is missing
#   2 - packages were removed successfully; reboot is required
pkg_restore_package_set() {
    prps_set_name="$1"

    if [ -z "$prps_set_name" ]; then
        pkg_log_warn "pkg_restore_package_set called with empty set name"
        return 1
    fi

    prps_provider="$(pkg_active_provider)"
    prps_os_id="$(pkg_detect_os_id)"
    prps_packages="$(pkg_lookup_package_set "$prps_set_name" || true)"

    if [ -z "$prps_packages" ]; then
        pkg_log_fail "No package-set mapping available for restore, set=$prps_set_name provider=$prps_provider os=$prps_os_id"
        return 1
    fi

    prps_installed=""

    for prps_pkg in $prps_packages; do
        [ -n "$prps_pkg" ] || continue

        if pkg_have_package "$prps_pkg"; then
            prps_installed="$prps_installed $prps_pkg"
        fi
    done

    prps_installed="$(printf '%s\n' "$prps_installed" | sed 's/^[[:space:]]*//')"

    if [ -z "$prps_installed" ]; then
        pkg_log_pass "Optional package set already restored to base state, set=$prps_set_name"
        return 0
    fi

    pkg_log_info "Restoring base package state, set=$prps_set_name installed_overlay_packages=$prps_installed"

    # Intentional splitting: package names are read from the trusted map.
    # shellcheck disable=SC2086
    if ! pkg_remove_package_list $prps_installed; then
        pkg_log_fail "Failed to remove optional package set, set=$prps_set_name"
        return 1
    fi

    pkg_log_pass "Optional package set removed, set=$prps_set_name"
    pkg_log_warn "A reboot is required before the base kernel driver can own the device"
    return 2
}

# Ensure command is available, recovering missing commands through mapped packages.
pkg_ensure_command() {
    ensure_cmd="$1"
    shift || true

    if [ -z "$ensure_cmd" ]; then
        return 1
    fi

    if pkg_have_command "$ensure_cmd"; then
        pkg_log_pass "Command present, $ensure_cmd"
        return 0
    fi

    ensure_cmd_packages="$*"

    if [ -z "$ensure_cmd_packages" ]; then
        ensure_cmd_packages="$(pkg_lookup_packages_for_command "$ensure_cmd" || true)"
    fi

    if [ -z "$ensure_cmd_packages" ]; then
        pkg_log_warn "Command missing and no package mapping is available, $ensure_cmd"
        return 1
    fi

    pkg_log_warn "Command missing, $ensure_cmd; required package set: $ensure_cmd_packages"

    for required_pkg in $ensure_cmd_packages; do
        [ -n "$required_pkg" ] || continue

        if ! pkg_ensure_package "$required_pkg"; then
            pkg_log_warn "Failed to install required package for command, cmd=$ensure_cmd pkg=$required_pkg"
            return 1
        fi
    done

    if pkg_have_command "$ensure_cmd"; then
        pkg_log_pass "Command available after package recovery, $ensure_cmd"
        return 0
    fi

    pkg_log_warn "Package set installed but command is still missing, cmd=$ensure_cmd packages=$ensure_cmd_packages"
    return 1
}

# Print provider summary.
pkg_provider_summary() {
    summary_provider="$(pkg_active_provider)"
    summary_os_id="$(pkg_detect_os_id)"
    summary_os_version="$(pkg_os_release_value VERSION_ID || echo unknown)"

    pkg_log_info "Package provider, provider=$summary_provider os=$summary_os_id version=$summary_os_version recover=$PKG_CHECK_DEPS_RECOVER auto_install=$PKG_AUTO_INSTALL upgrade=$PKG_PACKAGE_UPGRADE package_set_upgrade=$PKG_PACKAGE_SET_UPGRADE"

    case "$summary_provider" in
        apt)
            pkg_log_info "APT provider active, optional_sources_path=$PKG_APT_SOURCES_ARTIFACT_DIR auth_conf=$PKG_APT_AUTH_CONF debusine_source=$PKG_APT_DEBUSINE_SOURCE debusine_suite=$PKG_APT_DEBUSINE_SUITE"
            ;;
        rpm)
            pkg_log_info "RPM provider active"
            ;;
        opkg)
            pkg_log_info "OPKG provider active"
            ;;
        *)
            pkg_log_info "Check-only provider active"
            ;;
    esac
}

###############################################################################
# Package-set state helpers
###############################################################################
# Return success when a mapped package set contains a package name.
pkg_package_set_contains() {
    ppsc_set="$1"
    ppsc_package="$2"
    ppsc_packages=""

    [ -n "$ppsc_set" ] || return 1
    [ -n "$ppsc_package" ] || return 1

    if ! command -v pkg_lookup_package_set >/dev/null 2>&1; then
        return 1
    fi

    ppsc_packages="$(pkg_lookup_package_set "$ppsc_set" 2>/dev/null || true)"

    case " $ppsc_packages " in
        *" $ppsc_package "*)
            return 0
            ;;
    esac

    return 1
}

# Return success only when every package in a mapped set is installed.
pkg_verify_package_set_installed() {
    pvpsi_set="$1"
    pvpsi_packages=""
    pvpsi_missing=""

    [ -n "$pvpsi_set" ] || return 1

    if ! command -v pkg_lookup_package_set >/dev/null 2>&1; then
        log_error "Package-set lookup helper is unavailable"
        return 1
    fi

    pvpsi_packages="$(pkg_lookup_package_set "$pvpsi_set" 2>/dev/null || true)"

    if [ -z "$pvpsi_packages" ]; then
        log_error "Package-set mapping is unavailable: $pvpsi_set"
        return 1
    fi

    for pvpsi_package in $pvpsi_packages; do
        [ -n "$pvpsi_package" ] || continue

        if ! pkg_have_package "$pvpsi_package"; then
            pvpsi_missing="${pvpsi_missing}${pvpsi_missing:+ }$pvpsi_package"
        fi
    done

    if [ -n "$pvpsi_missing" ]; then
        log_warn "Package set is incomplete, set=$pvpsi_set missing=$pvpsi_missing"
        return 1
    fi

    log_pass "Package set is already installed, set=$pvpsi_set"
    return 0
}

# Avoid package-manager/network work when a required package set is complete.
pkg_ensure_required_package_set_present() {
    perps_set="$1"

    [ -n "$perps_set" ] || return 1

    if pkg_verify_package_set_installed "$perps_set"; then
        return 0
    fi

    if ! command -v pkg_ensure_package_set >/dev/null 2>&1; then
        log_error "Required package-set helper is unavailable"
        return 1
    fi

    if ! pkg_ensure_package_set "$perps_set"; then
        return 1
    fi

    pkg_verify_package_set_installed "$perps_set"
}

# Avoid package-manager/network work when an optional package set is complete.
pkg_ensure_optional_package_set_present() {
    peops_set="$1"
    peops_source="$2"
    peops_mode="$3"
    shift 3

    [ -n "$peops_set" ] || return 1
    [ -n "$peops_source" ] || peops_source="auto"
    [ -n "$peops_mode" ] || peops_mode="auto"

    if pkg_verify_package_set_installed "$peops_set"; then
        return 0
    fi

    if ! command -v pkg_ensure_optional_package_set >/dev/null 2>&1; then
        log_error "Optional package-set helper is unavailable"
        return 1
    fi

    if ! pkg_ensure_optional_package_set \
        "$peops_set" \
        "$peops_source" \
        "$peops_mode" \
        "$@"; then
        return 1
    fi

    pkg_verify_package_set_installed "$peops_set"
}

# Return success when an installed package owns a file matching an ERE.
pkg_package_has_file_matching() {
    pphfm_package="$1"
    pphfm_pattern="$2"

    [ -n "$pphfm_package" ] || return 1
    [ -n "$pphfm_pattern" ] || return 1

    if ! pkg_have_package "$pphfm_package"; then
        return 1
    fi

    if command -v dpkg-query >/dev/null 2>&1; then
        dpkg-query -L "$pphfm_package" 2>/dev/null |
            grep -Eq "$pphfm_pattern"
        return $?
    fi

    if command -v rpm >/dev/null 2>&1; then
        rpm -ql "$pphfm_package" 2>/dev/null |
            grep -Eq "$pphfm_pattern"
        return $?
    fi

    return 1
}

