#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Logging / journald helpers
# Assumes functestlib.sh provides log_info, log_warn, log_fail, log_pass.

# Detect a readable system log file under /var/log for validation.
# Logs candidate file presence to help CI debug missing or misrouted logs.
logging_detect_log_file() {
    LOGGING_ACTIVE_LOG_FILE=""

    log_info "----- /var/log candidate files -----"
    for log_file in \
        /var/log/messages \
        /var/log/syslog \
        /var/log/user.log \
        /var/log/daemon.log \
        /var/log/kern.log
    do
        if [ -f "$log_file" ]; then
            if [ -r "$log_file" ]; then
                log_info "[log-file] present: $log_file"
                if [ -z "$LOGGING_ACTIVE_LOG_FILE" ]; then
                    LOGGING_ACTIVE_LOG_FILE="$log_file"
                fi
            else
                log_warn "[log-file] present but not readable: $log_file"
            fi
        else
            log_info "[log-file] missing: $log_file"
        fi
    done
    log_info "----- End /var/log candidate files -----"

    if [ -n "$LOGGING_ACTIVE_LOG_FILE" ]; then
        export LOGGING_ACTIVE_LOG_FILE
        log_pass "Detected log file: $LOGGING_ACTIVE_LOG_FILE"
        return 0
    fi

    log_fail "No readable log file found under /var/log"
    return 1
}

# Emit a unique test message through logger for journald and file-log verification.
# Sets and exports LOGGING_TEST_TAG and LOGGING_TEST_TOKEN for later match checks.
logging_emit_test_message() {
    tag_arg="$1"
    token_arg="$2"
    token_ts="0"

    if [ -z "$tag_arg" ]; then
        tag_arg="QLI_LOGGING_TEST"
    fi

    if [ -z "$token_arg" ]; then
        token_ts="$(date +%s 2>/dev/null || echo 0)"
        token_arg="qli-logging-test-$token_ts-$$"
    fi

    LOGGING_TEST_TAG="$tag_arg"
    LOGGING_TEST_TOKEN="$token_arg"

    export LOGGING_TEST_TAG LOGGING_TEST_TOKEN

    log_info "Emitting test log message: tag=$LOGGING_TEST_TAG token=$LOGGING_TEST_TOKEN"

    if logger -t "$LOGGING_TEST_TAG" "$LOGGING_TEST_TOKEN"; then
        log_pass "Custom log message emitted successfully"
        return 0
    fi

    log_fail "Failed to emit custom log message"
    return 1
}

# Verify that the emitted test token is visible through journalctl for the current boot.
# Logs the exact matched journal line to improve CI-side debugging and traceability.
logging_verify_test_message_in_journalctl() {
    retry_count="$1"
    sleep_secs="$2"
    attempt=1
    matched_line=""

    if [ -z "$retry_count" ]; then
        retry_count=5
    fi
    if [ -z "$sleep_secs" ]; then
        sleep_secs=1
    fi

    if [ -z "${LOGGING_TEST_TAG:-}" ] || [ -z "${LOGGING_TEST_TOKEN:-}" ]; then
        log_fail "logging_verify_test_message_in_journalctl: test message is not initialized"
        return 1
    fi

    while [ "$attempt" -le "$retry_count" ]; do
        matched_line="$(journalctl -b -t "$LOGGING_TEST_TAG" --no-pager 2>/dev/null | grep -F "$LOGGING_TEST_TOKEN" | tail -n 1)"

        if [ -n "$matched_line" ]; then
            log_info "[journalctl-match] $matched_line"
            log_pass "Custom log message found in journalctl"
            return 0
        fi

        sleep "$sleep_secs"
        attempt=$((attempt + 1))
    done

    log_fail "Custom log message not found in journalctl"
    return 1
}

# Verify that the emitted test token is present in the selected /var/log file sink.
# Logs the exact matched file-log line to make CI triage easier on logging failures.
logging_verify_test_message_in_log_file() {
    retry_count="$1"
    sleep_secs="$2"
    attempt=1
    matched_line=""

    if [ -z "$retry_count" ]; then
        retry_count=5
    fi
    if [ -z "$sleep_secs" ]; then
        sleep_secs=1
    fi

    if [ -z "${LOGGING_ACTIVE_LOG_FILE:-}" ]; then
        log_fail "logging_verify_test_message_in_log_file: active log file is not initialized"
        return 1
    fi

    if [ -z "${LOGGING_TEST_TOKEN:-}" ]; then
        log_fail "logging_verify_test_message_in_log_file: test message is not initialized"
        return 1
    fi

    while [ "$attempt" -le "$retry_count" ]; do
        matched_line="$(grep -F "$LOGGING_TEST_TOKEN" "$LOGGING_ACTIVE_LOG_FILE" 2>/dev/null | tail -n 1)"

        if [ -n "$matched_line" ]; then
            log_info "[log-file-match] $matched_line"
            log_pass "Custom log message found in $LOGGING_ACTIVE_LOG_FILE"
            return 0
        fi

        sleep "$sleep_secs"
        attempt=$((attempt + 1))
    done

    log_fail "Custom log message not found in $LOGGING_ACTIVE_LOG_FILE"
    return 1
}

# Check whether journal storage is persistent or volatile and print useful details.
# Passes if either journal directory exists or journalctl reports disk usage successfully.
logging_check_journal_storage_mode() {
    persistent_dir="/var/log/journal"
    volatile_dir="/run/log/journal"
    found_mode=""
    usage_line=""

    log_info "----- Journal storage mode check -----"

    if [ -d "$persistent_dir" ]; then
        log_info "[journal-storage] persistent directory present: $persistent_dir"
        found_mode="persistent"
    fi

    if [ -d "$volatile_dir" ]; then
        log_info "[journal-storage] volatile directory present: $volatile_dir"
        if [ -z "$found_mode" ]; then
            found_mode="volatile"
        fi
    fi

    usage_line="$(journalctl --disk-usage 2>/dev/null | tail -n 1)"
    if [ -n "$usage_line" ]; then
        log_info "[journal-disk-usage] $usage_line"
    fi

    if [ -n "$found_mode" ]; then
        log_pass "Journal storage mode sanity passed: $found_mode"
        log_info "----- End journal storage mode check -----"
        return 0
    fi

    if [ -n "$usage_line" ]; then
        log_warn "Journal storage directories not found, but journalctl reports disk usage"
        log_pass "Journal storage mode sanity passed"
        log_info "----- End journal storage mode check -----"
        return 0
    fi

    log_fail "Unable to determine journal storage mode"
    log_info "----- End journal storage mode check -----"
    return 1
}

# Verify that journal boot indexing is available for the current system.
# Prints the first few entries from journalctl --list-boots for CI debug visibility.
logging_check_boot_list_sanity() {
    boot_lines=""
    boot_count="0"

    log_info "----- journalctl --list-boots snapshot -----"
    boot_lines="$(journalctl --list-boots 2>/dev/null | sed -n '1,5p')"

    if [ -n "$boot_lines" ]; then
        printf '%s\n' "$boot_lines" | while IFS= read -r line; do
            [ -n "$line" ] && log_info "[boot-list] $line"
        done
        boot_count="$(printf '%s\n' "$boot_lines" | grep -c . 2>/dev/null || echo 0)"
    fi

    if [ "$boot_count" -ge 1 ]; then
        log_pass "journalctl boot list sanity passed"
        log_info "----- End journalctl --list-boots snapshot -----"
        return 0
    fi

    log_fail "journalctl boot list is empty"
    log_info "----- End journalctl --list-boots snapshot -----"
    return 1
}

# Verify that unit-scoped journal queries return data for systemd-journald.service.
# Prints a small sample of the unit logs to help debug missing unit metadata indexing.
logging_check_unit_scoped_query() {
    unit_name="$1"
    unit_lines=""

    if [ -z "$unit_name" ]; then
        unit_name="systemd-journald.service"
    fi

    log_info "----- journalctl unit query snapshot: $unit_name -----"
    unit_lines="$(journalctl -u "$unit_name" --no-pager 2>/dev/null | sed -n '1,5p')"

    if [ -n "$unit_lines" ]; then
        printf '%s\n' "$unit_lines" | while IFS= read -r line; do
            [ -n "$line" ] && log_info "[unit-log] $line"
        done
        log_pass "Unit-scoped journal query passed for $unit_name"
        log_info "----- End journalctl unit query snapshot: $unit_name -----"
        return 0
    fi

    log_fail "Unit-scoped journal query returned no data for $unit_name"
    log_info "----- End journalctl unit query snapshot: $unit_name -----"
    return 1
}

# Emit a priority-tagged error message through logger for priority filter validation.
# Sets and exports LOGGING_PRIO_TEST_TAG and LOGGING_PRIO_TEST_TOKEN for later checks.
logging_emit_priority_test_message() {
    tag_arg="$1"
    token_arg="$2"
    token_ts="0"

    if [ -z "$tag_arg" ]; then
        tag_arg="QLI_LOGGING_PRIO_TEST"
    fi

    if [ -z "$token_arg" ]; then
        token_ts="$(date +%s 2>/dev/null || echo 0)"
        token_arg="qli-logging-prio-test-$token_ts-$$"
    fi

    LOGGING_PRIO_TEST_TAG="$tag_arg"
    LOGGING_PRIO_TEST_TOKEN="$token_arg"

    export LOGGING_PRIO_TEST_TAG LOGGING_PRIO_TEST_TOKEN

    log_info "Emitting priority test log message: priority=user.err tag=$LOGGING_PRIO_TEST_TAG token=$LOGGING_PRIO_TEST_TOKEN"

    if logger -p user.err -t "$LOGGING_PRIO_TEST_TAG" "$LOGGING_PRIO_TEST_TOKEN"; then
        log_pass "Priority test log message emitted successfully"
        return 0
    fi

    log_fail "Failed to emit priority test log message"
    return 1
}

# Verify that a priority-tagged error message is visible using journalctl priority filtering.
# Prints the matched line so CI can confirm both message content and retrieval path.
logging_verify_priority_message_in_journalctl() {
    retry_count="$1"
    sleep_secs="$2"
    attempt=1
    matched_line=""

    if [ -z "$retry_count" ]; then
        retry_count=5
    fi
    if [ -z "$sleep_secs" ]; then
        sleep_secs=1
    fi

    if [ -z "${LOGGING_PRIO_TEST_TOKEN:-}" ]; then
        log_fail "logging_verify_priority_message_in_journalctl: priority test message is not initialized"
        return 1
    fi

    while [ "$attempt" -le "$retry_count" ]; do
        matched_line="$(journalctl -p err --no-pager 2>/dev/null | grep -F "$LOGGING_PRIO_TEST_TOKEN" | tail -n 1)"

        if [ -n "$matched_line" ]; then
            log_info "[priority-match] $matched_line"
            log_pass "Priority-based journal query passed"
            return 0
        fi

        sleep "$sleep_secs"
        attempt=$((attempt + 1))
    done

    log_fail "Priority-based journal query did not find the emitted error message"
    return 1
}
