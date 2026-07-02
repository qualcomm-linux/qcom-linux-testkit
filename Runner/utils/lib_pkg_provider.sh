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
PKG_APT_AUTH_MACHINE_FALLBACK="deb.stage.debusine.qualcomm.com"
PKG_APT_AUTH_LOGIN_FILE="/run/qcom-testkit/secrets/debusine_login"
PKG_APT_AUTH_PASSWORD_FILE="/run/qcom-testkit/secrets/debusine_api_token"

PKG_RPM_UPDATED_MARK="/tmp/qcom_testkit_rpm_updated"
PKG_RPM_UPGRADED_MARK="/tmp/qcom_testkit_rpm_upgraded"
PKG_RPM_BEST_EFFORT_CLEAN="1"

PKG_OPKG_UPDATED_MARK="/tmp/qcom_testkit_opkg_updated"

__PKG_PROVIDER_INITIALIZED="0"
__PKG_ACTIVE_PROVIDER=""

# Log an informational message using functestlib.sh logging when available.
# Falls back to plain stdout when the package provider is used standalone.
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

# Print provider debug messages only when debug=1 is enabled in pkg_provider.conf.
pkg_debug() {
    if [ "$PKG_DEBUG" = "1" ]; then
        pkg_log_info "[PKG] $*"
    fi
}

# Return success when a config value represents boolean true.
pkg_bool_true() {
    value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"

    case "$value" in
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
    value="$1"
    fallback="$2"

    if pkg_is_uint "$value"; then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$fallback"
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
    key="$1"
    value="$2"

    case "$key" in
        provider)
            PKG_PROVIDER="$value"
            ;;
        check_dependencies_recover)
            PKG_CHECK_DEPS_RECOVER="$value"
            ;;
        auto_install)
            PKG_AUTO_INSTALL="$value"
            ;;
        package_map)
            PKG_PACKAGE_MAP="$value"
            ;;
        package_upgrade)
            PKG_PACKAGE_UPGRADE="$value"
            ;;
        debug)
            PKG_DEBUG="$value"
            ;;
        *)
            pkg_debug "Ignoring unknown package provider config key, $key"
            ;;
    esac
}

# Load pkg_provider.conf and apply supported key=value entries.
pkg_load_config_file() {
    cfg_file="$1"

    if [ -z "$cfg_file" ] || [ ! -r "$cfg_file" ]; then
        return 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*)
                continue
                ;;
            *=*)
                key="$(printf '%s' "${line%%=*}" | tr -d '[:space:]')"
                value="$(pkg_strip_value "${line#*=}")"
                [ -n "$key" ] || continue
                pkg_apply_config_entry "$key" "$value"
                ;;
            *)
                pkg_debug "Ignoring malformed config line, $line"
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
# No arguments are used to avoid ShellCheck SC2120/SC2119.
pkg_provider_init() {
    if [ "$__PKG_PROVIDER_INITIALIZED" = "1" ]; then
        return 0
    fi

    cfg_file="$(pkg_default_config_path || true)"
    if [ -n "$cfg_file" ]; then
        pkg_load_config_file "$cfg_file" || true
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

    uid="$(id -u 2>/dev/null || echo 1)"
    if [ "$uid" -ne 0 ] 2>/dev/null; then
        pkg_log_warn "Package install requested but current user is not root"
        return 1
    fi

    return 0
}

# Read a normalized value from /etc/os-release.
pkg_os_release_value() {
    key="$1"

    if [ ! -r /etc/os-release ]; then
        return 1
    fi

    sed -n "s/^${key}=//p" /etc/os-release 2>/dev/null |
        sed -n '1p' |
        sed 's/^"//; s/"$//' |
        tr '[:upper:]' '[:lower:]'
}

# Detect OS ID for logging and package-map override lookup.
pkg_detect_os_id() {
    os_id="$(pkg_os_release_value ID || true)"

    if [ -n "$os_id" ]; then
        printf '%s\n' "$os_id"
        return 0
    fi

    printf '%s\n' "unknown"
    return 0
}

# Detect package-manager provider. This is package-manager based, not distro based.
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
    path="$1"

    case "$path" in
        /*)
            printf '%s\n' "$path"
            ;;
        *)
            if [ -n "${ROOT_DIR:-}" ] && [ -e "$ROOT_DIR/$path" ]; then
                printf '%s\n' "$ROOT_DIR/$path"
                return 0
            fi

            if [ -n "${TOOLS:-}" ] && [ -e "$TOOLS/../$path" ]; then
                printf '%s\n' "$TOOLS/../$path"
                return 0
            fi

            if [ -n "${ROOT_DIR:-}" ]; then
                printf '%s\n' "$ROOT_DIR/$path"
            else
                printf '%s\n' "$path"
            fi
            ;;
    esac
}

# Look up exact key in command-to-package map.
pkg_lookup_key_in_map() {
    map_file="$1"
    map_key="$2"

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*)
                continue
                ;;
            *=*)
                key="$(printf '%s' "${line%%=*}" | tr -d '[:space:]')"
                value="$(pkg_strip_value "${line#*=}")"

                if [ "$key" = "$map_key" ]; then
                    printf '%s\n' "$value"
                    return 0
                fi
                ;;
        esac
    done < "$map_file"

    return 1
}

# Resolve command to package names using map.
pkg_lookup_packages_for_command() {
    cmd="$1"
    provider="$(pkg_active_provider)"
    os_id="$(pkg_detect_os_id)"
    testname="${TESTNAME:-}"
    map_file="$(pkg_resolve_path "$PKG_PACKAGE_MAP")"

    if [ ! -r "$map_file" ]; then
        pkg_log_warn "Package map file is not readable, $map_file"
        return 1
    fi

    if [ -n "$testname" ]; then
        value="$(pkg_lookup_key_in_map "$map_file" "${os_id}:${testname}:${cmd}" || true)"
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi

        value="$(pkg_lookup_key_in_map "$map_file" "${provider}:${testname}:${cmd}" || true)"
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    fi

    value="$(pkg_lookup_key_in_map "$map_file" "${os_id}:${cmd}" || true)"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
        return 0
    fi

    value="$(pkg_lookup_key_in_map "$map_file" "${provider}:${cmd}" || true)"
    if [ -n "$value" ]; then
        printf '%s\n' "$value"
        return 0
    fi

    pkg_log_warn "No package mapping found for command, os=$os_id provider=$provider cmd=$cmd"
    return 1
}

# Return success when package is installed.
pkg_have_package() {
    pkg="$1"
    provider="$(pkg_active_provider)"

    case "$provider" in
        apt)
            dpkg-query -W -f='${Status}\n' "$pkg" 2>/dev/null |
                grep -q "install ok installed"
            ;;
        rpm)
            rpm -q "$pkg" >/dev/null 2>&1
            ;;
        opkg)
            opkg status "$pkg" 2>/dev/null |
                grep -q "Status:.* installed"
            ;;
        *)
            return 1
            ;;
    esac
}

# Run command and print result.
pkg_run_cmd() {
    label="$1"
    shift

    pkg_log_info "Running command [$label]: $*"

    "$@"
    rc=$?

    if [ "$rc" -eq 0 ]; then
        pkg_log_pass "Command passed [$label]"
    else
        pkg_log_warn "Command failed [$label], rc=$rc"
    fi

    return "$rc"
}

# Run command with bounded retries.
pkg_run_cmd_retry() {
    label="$1"
    shift

    retries="$(pkg_normalize_uint "$PKG_COMMAND_RETRIES" 2)"
    retry_sleep="$(pkg_normalize_uint "$PKG_COMMAND_RETRY_SLEEP" 5)"

    if [ "$retries" -lt 1 ]; then
        retries=1
    fi

    attempt=1
    while [ "$attempt" -le "$retries" ]; do
        pkg_log_info "Command attempt [$label], ${attempt}/${retries}"

        if pkg_run_cmd "$label" "$@"; then
            return 0
        fi

        if [ "$attempt" -lt "$retries" ]; then
            pkg_log_warn "Retrying command [$label] after ${retry_sleep}s"
            sleep "$retry_sleep"
        fi

        attempt=$((attempt + 1))
    done

    pkg_log_fail "Command failed after ${retries} attempt(s) [$label]"
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
        interfaces="$(get_ethernet_interfaces 2>/dev/null || true)"

        for iface in $interfaces; do
            [ -n "$iface" ] || continue
            pkg_log_info "Trying Ethernet bring-up, iface=$iface"
            bringup_interface "$iface" || true

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

    retries="$(pkg_normalize_uint "$PKG_NETWORK_RETRIES" 2)"
    retry_sleep="$(pkg_normalize_uint "$PKG_NETWORK_RETRY_SLEEP" 5)"

    if [ "$retries" -lt 1 ]; then
        retries=1
    fi

    attempt=1
    while [ "$attempt" -le "$retries" ]; do
        pkg_log_warn "Network recovery attempt ${attempt}/${retries}"

        pkg_try_network_recovery_once || true
        sleep "$retry_sleep"

        if pkg_network_status; then
            pkg_log_pass "Network recovered successfully"
            return 0
        fi

        attempt=$((attempt + 1))
    done

    pkg_log_fail "Network is still not ready after recovery attempts"
    return 1
}

# Read first line from file.
pkg_read_first_line() {
    file_path="$1"

    if [ -z "$file_path" ] || [ ! -r "$file_path" ]; then
        return 1
    fi

    sed -n '1p' "$file_path" 2>/dev/null |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# Detect apt auth machine from *.sources, fallback to current stage hostname.
pkg_apt_detect_auth_machine() {
    if [ -d "$PKG_APT_SOURCES_ARTIFACT_DIR" ]; then
        for src_file in "$PKG_APT_SOURCES_ARTIFACT_DIR"/*.sources; do
            [ -r "$src_file" ] || continue

            machine="$(
                sed -n 's#.*https://\([^/[:space:]]*\).*#\1#p' "$src_file" |
                    sed -n '1p'
            )"

            if [ -n "$machine" ]; then
                printf '%s\n' "$machine"
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

    auth_login="$(pkg_apt_read_auth_login || true)"
    auth_password="$(pkg_apt_read_auth_password || true)"
    auth_machine="$(pkg_apt_detect_auth_machine)"

    if [ -z "$auth_login" ] || [ -z "$auth_password" ]; then
        pkg_log_warn "APT auth secret file is empty, skipping auth config creation"
        return 0
    fi

    auth_dir="$(dirname "$PKG_APT_AUTH_CONF")"

    if [ ! -d "$auth_dir" ]; then
        mkdir -p "$auth_dir" || {
            pkg_log_fail "Failed to create APT auth directory, $auth_dir"
            return 1
        }
    fi

    tmp_auth="${PKG_APT_AUTH_CONF}.$$"

    old_umask="$(umask)"
    umask 077

    {
        printf 'machine %s\n' "$auth_machine"
        printf 'login %s\n' "$auth_login"
        printf 'password %s\n' "$auth_password"
    } > "$tmp_auth" || {
        umask "$old_umask"
        rm -f "$tmp_auth"
        pkg_log_fail "Failed to write temporary APT auth config"
        return 1
    }

    umask "$old_umask"

    chmod 600 "$tmp_auth" 2>/dev/null || true

    mv "$tmp_auth" "$PKG_APT_AUTH_CONF" || {
        rm -f "$tmp_auth"
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

    found=0

    for src_file in "$PKG_APT_SOURCES_ARTIFACT_DIR"/*.sources; do
        [ -r "$src_file" ] || continue
        found=1

        target_path="/etc/apt/sources.list.d/$(basename "$src_file")"

        if grep -qi "password" "$src_file" 2>/dev/null; then
            pkg_log_fail "APT source artifact appears to contain credentials, refusing to install, $src_file"
            return 1
        fi

        cp "$src_file" "$target_path" || {
            pkg_log_fail "Failed to install APT source file, $target_path"
            return 1
        }

        chmod 644 "$target_path" 2>/dev/null || true
        pkg_log_pass "Installed APT source file, $target_path"
    done

    if [ "$found" -eq 0 ]; then
        pkg_log_info "No *.sources artifacts found, using existing apt sources"
    fi

    return 0
}

# Log metadata source-package, if present.
pkg_apt_log_metadata_source_package() {
    metadata_file="$PKG_APT_SOURCES_ARTIFACT_DIR/metadata.json"

    if [ ! -r "$metadata_file" ]; then
        return 0
    fi

    source_package="$(
        sed -n 's/.*"source-package"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$metadata_file" |
            sed -n '1p'
    )"

    if [ -n "$source_package" ]; then
        pkg_log_info "APT metadata source-package, $source_package"
    fi

    return 0
}

# Prepare apt sources and optional auth.
pkg_apt_prepare_sources() {
    pkg_apt_install_sources_if_present || return 1
    pkg_apt_install_auth_if_secrets_present || return 1
    pkg_apt_log_metadata_source_package || true
    return 0
}

# Dump file with credential-like fields redacted.
pkg_dump_file_redacted() {
    prefix="$1"
    file_path="$2"

    if [ ! -r "$file_path" ]; then
        return 0
    fi

    sed \
        -e 's/[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd][[:space:]]\+.*/password REDACTED/' \
        -e 's/[Ll][Oo][Gg][Ii][Nn][[:space:]]\+.*/login REDACTED/' \
        -e 's#://[^/@][^/@]*:[^/@][^/@]*@#://REDACTED:REDACTED@#g' \
        "$file_path" 2>/dev/null |
        sed "s/^/[$prefix] /"
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
            while IFS= read -r src_file; do
                pkg_log_info "APT source file, $src_file"
                pkg_dump_file_redacted "APT-SOURCE" "$src_file" || true
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
        "$PKG_APT_GET" update \
        -o Acquire::Retries=2 \
        -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}"

    rc=$?

    if [ "$rc" -eq 0 ]; then
        : > "$PKG_APT_UPDATED_MARK" 2>/dev/null || true
    fi

    return "$rc"
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

    rc=$?

    if [ "$rc" -eq 0 ]; then
        : > "$PKG_APT_UPGRADED_MARK" 2>/dev/null || true
    fi

    return "$rc"
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

# Install apt package.
pkg_apt_install_package() {
    pkg="$1"

    pkg_apt_update || return 1
    pkg_apt_upgrade || return 1
    pkg_apt_fix_broken_if_enabled || true

    if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy "$pkg" 2>&1 | sed "s/^/[APT-POLICY:$pkg] /" || true
    fi

    if pkg_bool_true "$PKG_APT_INSTALL_RECOMMENDS"; then
        if pkg_bool_true "$PKG_APT_FIX_MISSING"; then
            pkg_run_cmd_retry "apt-install-$pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --fix-missing \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$pkg"
        else
            pkg_run_cmd_retry "apt-install-$pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$pkg"
        fi
    else
        if pkg_bool_true "$PKG_APT_FIX_MISSING"; then
            pkg_run_cmd_retry "apt-install-$pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --no-install-recommends \
                --fix-missing \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$pkg"
        else
            pkg_run_cmd_retry "apt-install-$pkg" \
                env DEBIAN_FRONTEND=noninteractive \
                "$PKG_APT_GET" install -y \
                --no-install-recommends \
                -o "DPkg::Lock::Timeout=${PKG_APT_LOCK_TIMEOUT}" \
                "$pkg"
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
    tool="$(pkg_rpm_tool || true)"

    if [ -z "$tool" ]; then
        pkg_log_warn "Neither dnf nor yum is available"
        return 1
    fi

    if [ -f "$PKG_RPM_UPDATED_MARK" ]; then
        pkg_log_info "$tool metadata update already completed in this test session"
        return 0
    fi

    pkg_ensure_network_ready || return 1

    "$tool" --version 2>&1 || true
    "$tool" repolist all 2>&1 | sed "s/^/[RPM-REPOLIST] /" || true

    if pkg_bool_true "$PKG_RPM_BEST_EFFORT_CLEAN"; then
        "$tool" clean all 2>&1 | sed "s/^/[RPM-CLEAN] /" || true
    fi

    pkg_run_cmd_retry "$tool-makecache" "$tool" makecache -y
    rc=$?

    if [ "$rc" -eq 0 ]; then
        : > "$PKG_RPM_UPDATED_MARK" 2>/dev/null || true
    fi

    return "$rc"
}

# Optionally upgrade rpm packages.
pkg_rpm_upgrade() {
    tool="$(pkg_rpm_tool || true)"

    if [ -z "$tool" ]; then
        return 1
    fi

    if ! pkg_bool_true "$PKG_PACKAGE_UPGRADE"; then
        pkg_log_info "$tool upgrade disabled by config"
        return 0
    fi

    if [ -f "$PKG_RPM_UPGRADED_MARK" ]; then
        pkg_log_info "$tool upgrade already completed in this test session"
        return 0
    fi

    pkg_rpm_update || return 1

    pkg_run_cmd_retry "$tool-upgrade" "$tool" upgrade -y
    rc=$?

    if [ "$rc" -eq 0 ]; then
        : > "$PKG_RPM_UPGRADED_MARK" 2>/dev/null || true
    fi

    return "$rc"
}

# Install rpm package.
pkg_rpm_install_package() {
    pkg="$1"
    tool="$(pkg_rpm_tool || true)"

    if [ -z "$tool" ]; then
        return 1
    fi

    pkg_rpm_update || return 1
    pkg_rpm_upgrade || return 1

    "$tool" info "$pkg" 2>&1 | sed "s/^/[RPM-INFO:$pkg] /" || true

    pkg_run_cmd_retry "$tool-install-$pkg" "$tool" install -y "$pkg"
}

# Refresh opkg metadata.
pkg_opkg_update() {
    if [ -f "$PKG_OPKG_UPDATED_MARK" ]; then
        pkg_log_info "opkg update already completed in this test session"
        return 0
    fi

    pkg_ensure_network_ready || return 1

    pkg_run_cmd_retry "opkg-update" opkg update
    rc=$?

    if [ "$rc" -eq 0 ]; then
        : > "$PKG_OPKG_UPDATED_MARK" 2>/dev/null || true
    fi

    return "$rc"
}

# Install opkg package.
pkg_opkg_install_package() {
    pkg="$1"

    pkg_opkg_update || return 1
    pkg_run_cmd_retry "opkg-install-$pkg" opkg install "$pkg"
}

# Install package using active provider.
pkg_install_package() {
    pkg="$1"
    provider="$(pkg_active_provider)"

    if [ -z "$pkg" ]; then
        pkg_log_warn "pkg_install_package called with empty package name"
        return 1
    fi

    if pkg_have_package "$pkg"; then
        pkg_log_pass "Package already installed, $pkg"
        return 0
    fi

    if ! pkg_can_install; then
        pkg_log_warn "Package missing and package install disabled, $pkg"
        return 1
    fi

    pkg_provider_summary

    case "$provider" in
        apt)
            pkg_apt_install_package "$pkg"
            ;;
        rpm)
            pkg_rpm_install_package "$pkg"
            ;;
        opkg)
            pkg_opkg_install_package "$pkg"
            ;;
        check)
            pkg_log_warn "Check-only provider does not support package installation"
            return 1
            ;;
        *)
            pkg_log_warn "Unsupported package provider, $provider"
            return 1
            ;;
    esac
}

# Ensure package is installed.
pkg_ensure_package() {
    pkg="$1"

    if [ -z "$pkg" ]; then
        return 1
    fi

    if pkg_have_package "$pkg"; then
        pkg_log_pass "Package present, $pkg"
        return 0
    fi

    pkg_install_package "$pkg"
}

# Ensure command is available.
# If missing, resolves command to package(s), installs the full mapped package set,
# and rechecks PATH.
#
# Important:
# A mapping value such as:
#   apt:Sensors_Validation:sns_test=qcom-sensors-api qcom-sensors-core qcom-sensors-test-apps
# is treated as a required package set, not as alternatives.
pkg_ensure_command() {
    cmd="$1"
    shift || true
 
    if [ -z "$cmd" ]; then
        return 1
    fi
 
    if pkg_have_command "$cmd"; then
        pkg_log_pass "Command present, $cmd"
        return 0
    fi
 
    packages="$*"
 
    if [ -z "$packages" ]; then
        packages="$(pkg_lookup_packages_for_command "$cmd" || true)"
    fi
 
    if [ -z "$packages" ]; then
        pkg_log_warn "Command missing and no package mapping is available, $cmd"
        return 1
    fi
 
    pkg_log_warn "Command missing, $cmd; required package set: $packages"
 
    for pkg in $packages; do
        [ -n "$pkg" ] || continue
 
        if ! pkg_ensure_package "$pkg"; then
            pkg_log_warn "Failed to install required package for command, cmd=$cmd pkg=$pkg"
            return 1
        fi
    done
 
    if pkg_have_command "$cmd"; then
        pkg_log_pass "Command available after package recovery, $cmd"
        return 0
    fi
 
    pkg_log_warn "Package set installed but command is still missing, cmd=$cmd packages=$packages"
    return 1
}

# Print provider summary.
pkg_provider_summary() {
    provider="$(pkg_active_provider)"
    os_id="$(pkg_detect_os_id)"
    os_version="$(pkg_os_release_value VERSION_ID || echo unknown)"

    pkg_log_info "Package provider, provider=$provider os=$os_id version=$os_version recover=$PKG_CHECK_DEPS_RECOVER auto_install=$PKG_AUTO_INSTALL upgrade=$PKG_PACKAGE_UPGRADE"

    case "$provider" in
        apt)
            pkg_log_info "APT provider active, optional_sources_path=$PKG_APT_SOURCES_ARTIFACT_DIR auth_conf=$PKG_APT_AUTH_CONF"
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

