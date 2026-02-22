#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env" >&2
    exit 1
fi

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="CTI-Test"
if command -v find_test_case_by_name >/dev/null 2>&1; then
    test_path=$(find_test_case_by_name "$TESTNAME")
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

res_file="./$TESTNAME.res"
rm -f "$res_file"
touch "$res_file"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

CS_BASE="/sys/bus/coresight/devices"
LPM_SLEEP="/sys/module/lpm_levels/parameters/sleep_disabled"
ORIG_SLEEP_VAL=""
FAIL_COUNT=0

CTI_MAX_TRIGGERS=8
CTI_MAX_CHANNELS=4
CTI_TRIGGERS_TO_TEST=1


setup_sleep() {
    if [ -f "$LPM_SLEEP" ]; then
        ORIG_SLEEP_VAL=$(cat "$LPM_SLEEP")
        if [ "$ORIG_SLEEP_VAL" != "Y" ] && [ "$ORIG_SLEEP_VAL" != "1" ]; then
            log_info "Disabling LPM Sleep for test duration..."
            echo 1 > "$LPM_SLEEP"
        fi
    fi
}

restore_sleep() {
    if [ -f "$LPM_SLEEP" ] && [ -n "$ORIG_SLEEP_VAL" ]; then
        log_info "Restoring LPM Sleep value: $ORIG_SLEEP_VAL"
        echo "$ORIG_SLEEP_VAL" > "$LPM_SLEEP"
    fi
}

map_cti_trigin() {
    trig=$1; channel=$2; ctiname=$3;
    cti_dev="$CS_BASE/$ctiname"

    log_info "Legacy: mapping trig $trig ch $channel to $ctiname"
    echo "$trig" "$channel" > "$cti_dev/map_trigin"
    
    trigin=$(cut -b 4 "$cti_dev/show_trigin")
    channelin=$(cut -b 8 "$cti_dev/show_trigin")

    if [ "$trig" -eq "$trigin" ] && [ "$channel" -eq "$channelin" ]; then
        echo "$trig" "$channel" > "$cti_dev/unmap_trigin"
        trigin=$(cut -b 4 "$cti_dev/show_trigin")
        if [ -n "$trigin" ]; then
             log_warn "Failed to unmap $ctiname trigin"
             FAIL_COUNT=$((FAIL_COUNT + 1))
             echo 1 > "$cti_dev/reset"
        fi
    else
        log_warn "Failed to map $ctiname trigin $trig to channel $channel"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo 1 > "$cti_dev/reset"
    fi
}

set_trigin_attach() {
    trig=$1; channel=$2; ctiname=$3;
    cti_dev="$CS_BASE/$ctiname"

    log_info "Attach trigin: trig $trig -> ch $channel on $ctiname"
    
    echo 1 > "$cti_dev/enable"
    
    echo "$channel" "$trig" > "$cti_dev/channels/trigin_attach"
    
    echo "$channel" > "$cti_dev/channels/chan_xtrigs_sel"
    read_trig=$(cat "$cti_dev/channels/chan_xtrigs_in")
    
    if [ "$trig" -eq "$read_trig" ]; then
        echo "$channel" "$trig" > "$cti_dev/channels/trigin_detach"
        
        echo "$channel" > "$cti_dev/channels/chan_xtrigs_sel"
        read_trig=$(cat "$cti_dev/channels/chan_xtrigs_in")
        
        if [ -n "$read_trig" ]; then
             log_warn "Failed to detach trigin on $ctiname"
             FAIL_COUNT=$((FAIL_COUNT + 1))
             echo 1 > "$cti_dev/reset"
        fi
    else
        log_warn "Failed to attach trigin $trig to channel $channel on $ctiname"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo 1 > "$cti_dev/channels/chan_xtrigs_reset"
    fi
    
    echo 0 > "$cti_dev/enable"
}

set_trigout_attach() {
    trig=$1; channel=$2; ctiname=$3;
    cti_dev="$CS_BASE/$ctiname"

    log_info "Attach trigout: trig $trig -> ch $channel on $ctiname"
    
    echo 1 > "$cti_dev/enable"
    
    echo "$channel" "$trig" > "$cti_dev/channels/trigout_attach"
    
    echo "$channel" > "$cti_dev/channels/chan_xtrigs_sel"
    read_trig=$(cat "$cti_dev/channels/chan_xtrigs_out")
    
    if [ "$trig" -eq "$read_trig" ]; then
        echo "$channel" "$trig" > "$cti_dev/channels/trigout_detach"
        
        echo "$channel" > "$cti_dev/channels/chan_xtrigs_sel"
        read_trig=$(cat "$cti_dev/channels/chan_xtrigs_out")
        
        if [ -n "$read_trig" ]; then
             log_warn "Failed to detach trigout on $ctiname"
             FAIL_COUNT=$((FAIL_COUNT + 1))
             echo 1 > "$cti_dev/reset"
        fi
    else
        log_warn "Failed to attach trigout $trig to channel $channel on $ctiname"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo 1 > "$cti_dev/channels/chan_xtrigs_reset"
    fi
    
    echo 0 > "$cti_dev/enable"
}


setup_sleep

# shellcheck disable=SC2010
CTI_DEVICES=$(ls "$CS_BASE" | grep 'cti')

if [ -z "$CTI_DEVICES" ]; then
    log_fail "No CTI devices found in $CS_BASE"
    echo "CTI_Discovery: Fail" >> "$res_file"
    restore_sleep
    exit 1
fi

NEW_VER=0
for cti in $CTI_DEVICES; do
    if [ -f "$CS_BASE/$cti/enable" ]; then
        NEW_VER=1
        break
    fi
done

log_info "CTI Driver Version: $( [ $NEW_VER -eq 1 ] && echo "Modern" || echo "Legacy" )"

for cti in $CTI_DEVICES; do
    if [ $NEW_VER -eq 1 ]; then
        if [ -f "$CS_BASE/$cti/channels/chan_xtrigs_reset" ]; then
             echo 1 > "$CS_BASE/$cti/channels/chan_xtrigs_reset"
        fi
    else
        if [ -f "$CS_BASE/$cti/reset" ]; then
             echo 1 > "$CS_BASE/$cti/reset"
        fi
    fi
done

for cti in $CTI_DEVICES; do
    cti_path="$CS_BASE/$cti"
    
    if [ $NEW_VER -eq 1 ]; then
        if [ -f "$cti_path/mgmt/devid" ]; then
            devid=$(cat "$cti_path/mgmt/devid")
            chmax=$(( (devid & 2064384) >> 16 ))
            trigmax=$(( (devid & 32640) >> 8 ))
        else
            chmax=4
            trigmax=8
        fi
    else
        if [ -f "$cti_path/show_info" ]; then
            trigmax=$(cut -f1 -d ' ' "$cti_path/show_info")
            chmax=$(cut -f2 -d ' ' "$cti_path/show_info")
        else
            chmax=4
            trigmax=8
        fi
    fi

    log_info "Device: $cti (MaxTrig: $trigmax, MaxCh: $chmax)"

    # Shellcheck disable=SC2034
    for i in $(seq 0 $CTI_TRIGGERS_TO_TEST); do
        rand_val=$(awk 'BEGIN{srand(); print int(rand()*32768)}')
        
        if [ "$trigmax" -gt 0 ]; then
            if [ "$trigmax" -lt "$CTI_MAX_TRIGGERS" ]; then
                trig=$(( rand_val % trigmax ))
            else
                trig=$(( rand_val % CTI_MAX_TRIGGERS ))
            fi
        else
             trig=0
        fi

        limit_ch=$((CTI_MAX_CHANNELS - 1))
        
        for channel in $(seq 0 $limit_ch); do
            if [ "$channel" -gt "$chmax" ]; then
                continue
            fi

            if [ $NEW_VER -eq 1 ]; then
                set_trigin_attach "$trig" "$channel" "$cti"
                set_trigout_attach "$trig" "$channel" "$cti"
            else
                map_cti_trigin "$trig" "$channel" "$cti"
            fi
        done
    done
done

restore_sleep

if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "CTI map/unmap Test PASS"
    echo "$TESTNAME: PASS" >> "$res_file"
else
    log_fail "CTI map/unmap Test FAIL ($FAIL_COUNT errors)"
    echo "$TESTNAME: FAIL" >> "$res_file"
fi

# log_info "-------------------$TESTNAME Testcase Finished----------------------------"