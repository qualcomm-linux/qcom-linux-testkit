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
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
CS_BASE="/sys/bus/coresight/devices"
LPM_SLEEP="/sys/module/lpm_levels/parameters/sleep_disabled"
ORIG_SLEEP_VAL=""
FAIL_COUNT=0

CTI_MAX_TRIGGERS=8
CTI_MAX_CHANNELS=4

cleanup() {
    if [ -f "$LPM_SLEEP" ] && [ -n "$ORIG_SLEEP_VAL" ]; then
        log_info "Restoring LPM Sleep value: $ORIG_SLEEP_VAL"
        echo "$ORIG_SLEEP_VAL" > "$LPM_SLEEP" 2>/dev/null
    fi
}
trap cleanup EXIT

setup_sleep() {
    if [ -f "$LPM_SLEEP" ]; then
        ORIG_SLEEP_VAL=$(cat "$LPM_SLEEP" 2>/dev/null)
        if [ "$ORIG_SLEEP_VAL" != "Y" ] && [ "$ORIG_SLEEP_VAL" != "1" ]; then
            log_info "Disabling LPM Sleep for test duration..."
            echo 1 > "$LPM_SLEEP" 2>/dev/null
        fi
    fi
}

map_cti_trigin() {
    trig=$1; channel=$2; ctiname=$3;
    cti_dev="$CS_BASE/$ctiname"

    [ ! -d "$cti_dev" ] && return

    log_info "Legacy: mapping trig $trig ch $channel to $ctiname"
    [ -f "$cti_dev/map_trigin" ] && echo "$trig" "$channel" > "$cti_dev/map_trigin" 2>/dev/null
    
    trigin=""
    channelin=""
    [ -f "$cti_dev/show_trigin" ] && trigin=$(cut -b 4 "$cti_dev/show_trigin" 2>/dev/null)
    [ -f "$cti_dev/show_trigin" ] && channelin=$(cut -b 8 "$cti_dev/show_trigin" 2>/dev/null)

    if [ -n "$trigin" ] && [ -n "$channelin" ] && [ "$trig" -eq "$trigin" ] && [ "$channel" -eq "$channelin" ] 2>/dev/null; then
        [ -f "$cti_dev/unmap_trigin" ] && echo "$trig" "$channel" > "$cti_dev/unmap_trigin" 2>/dev/null
        
        trigin=""
        [ -f "$cti_dev/show_trigin" ] && trigin=$(cut -b 4 "$cti_dev/show_trigin" 2>/dev/null)
        if [ -n "$trigin" ]; then
             log_warn "Failed to unmap $ctiname trigin"
             FAIL_COUNT=$((FAIL_COUNT + 1))
             [ -f "$cti_dev/reset" ] && echo 1 > "$cti_dev/reset" 2>/dev/null
        fi
    else
        log_warn "Failed to map $ctiname trigin $trig to channel $channel"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        [ -f "$cti_dev/reset" ] && echo 1 > "$cti_dev/reset" 2>/dev/null
    fi
}

set_trigin_attach() {
    trig=$1; channel=$2; ctiname=$3;
    cti_dev="$CS_BASE/$ctiname"

    [ ! -d "$cti_dev/channels" ] && return

    log_info "Attach trigin: trig $trig -> ch $channel on $ctiname"
    
    [ -f "$cti_dev/enable" ] && echo 1 > "$cti_dev/enable" 2>/dev/null
    [ -f "$cti_dev/channels/trigin_attach" ] && echo "$channel" "$trig" > "$cti_dev/channels/trigin_attach" 2>/dev/null
    [ -f "$cti_dev/channels/chan_xtrigs_sel" ] && echo "$channel" > "$cti_dev/channels/chan_xtrigs_sel" 2>/dev/null
    
    read_trig=""
    [ -f "$cti_dev/channels/chan_xtrigs_in" ] && read_trig=$(cat "$cti_dev/channels/chan_xtrigs_in" 2>/dev/null)
    
    if [ -n "$read_trig" ] && [ "$trig" -eq "$read_trig" ] 2>/dev/null; then
        [ -f "$cti_dev/channels/trigin_detach" ] && echo "$channel" "$trig" > "$cti_dev/channels/trigin_detach" 2>/dev/null
        [ -f "$cti_dev/channels/chan_xtrigs_sel" ] && echo "$channel" > "$cti_dev/channels/chan_xtrigs_sel" 2>/dev/null
        
        read_trig=""
        [ -f "$cti_dev/channels/chan_xtrigs_in" ] && read_trig=$(cat "$cti_dev/channels/chan_xtrigs_in" 2>/dev/null)
        
        if [ -n "$read_trig" ]; then
             log_warn "Failed to detach trigin on $ctiname"
             FAIL_COUNT=$((FAIL_COUNT + 1))
             [ -f "$cti_dev/reset" ] && echo 1 > "$cti_dev/reset" 2>/dev/null
        fi
    else
        log_warn "Failed to attach trigin $trig to channel $channel on $ctiname"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        [ -f "$cti_dev/channels/chan_xtrigs_reset" ] && echo 1 > "$cti_dev/channels/chan_xtrigs_reset" 2>/dev/null
    fi
    
    [ -f "$cti_dev/enable" ] && echo 0 > "$cti_dev/enable" 2>/dev/null
}

set_trigout_attach() {
    trig=$1; channel=$2; ctiname=$3;
    cti_dev="$CS_BASE/$ctiname"

    [ ! -d "$cti_dev/channels" ] && return

    log_info "Attach trigout: trig $trig -> ch $channel on $ctiname"
    
    [ -f "$cti_dev/enable" ] && echo 1 > "$cti_dev/enable" 2>/dev/null
    [ -f "$cti_dev/channels/trigout_attach" ] && echo "$channel" "$trig" > "$cti_dev/channels/trigout_attach" 2>/dev/null
    [ -f "$cti_dev/channels/chan_xtrigs_sel" ] && echo "$channel" > "$cti_dev/channels/chan_xtrigs_sel" 2>/dev/null
    
    read_trig=""
    [ -f "$cti_dev/channels/chan_xtrigs_out" ] && read_trig=$(cat "$cti_dev/channels/chan_xtrigs_out" 2>/dev/null)
    
    if [ -n "$read_trig" ] && [ "$trig" -eq "$read_trig" ] 2>/dev/null; then
        [ -f "$cti_dev/channels/trigout_detach" ] && echo "$channel" "$trig" > "$cti_dev/channels/trigout_detach" 2>/dev/null
        [ -f "$cti_dev/channels/chan_xtrigs_sel" ] && echo "$channel" > "$cti_dev/channels/chan_xtrigs_sel" 2>/dev/null
        
        read_trig=""
        [ -f "$cti_dev/channels/chan_xtrigs_out" ] && read_trig=$(cat "$cti_dev/channels/chan_xtrigs_out" 2>/dev/null)
        
        if [ -n "$read_trig" ]; then
             log_warn "Failed to detach trigout on $ctiname"
             FAIL_COUNT=$((FAIL_COUNT + 1))
             [ -f "$cti_dev/reset" ] && echo 1 > "$cti_dev/reset" 2>/dev/null
        fi
    else
        log_warn "Failed to attach trigout $trig to channel $channel on $ctiname"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        [ -f "$cti_dev/channels/chan_xtrigs_reset" ] && echo 1 > "$cti_dev/channels/chan_xtrigs_reset" 2>/dev/null
    fi
    
    [ -f "$cti_dev/enable" ] && echo 0 > "$cti_dev/enable" 2>/dev/null
}

setup_sleep

CTI_DEVICES=""
if [ -d "$CS_BASE" ]; then
    for _dev in "$CS_BASE"/cti*; do
        [ -e "$_dev" ] || continue
        CTI_DEVICES="$CTI_DEVICES $(basename "$_dev")"
    done
    CTI_DEVICES="${CTI_DEVICES# }"
fi

if [ -z "$CTI_DEVICES" ]; then
    log_fail "No CTI devices found in $CS_BASE"
    echo "$TESTNAME FAIL" > "$res_file"
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
             echo 1 > "$CS_BASE/$cti/channels/chan_xtrigs_reset" 2>/dev/null
        fi
    else
        if [ -f "$CS_BASE/$cti/reset" ]; then
             echo 1 > "$CS_BASE/$cti/reset" 2>/dev/null
        fi
    fi
done

for cti in $CTI_DEVICES; do
    cti_path="$CS_BASE/$cti"
    
    if [ $NEW_VER -eq 1 ]; then
        if [ -f "$cti_path/mgmt/devid" ]; then
            devid=$(cat "$cti_path/mgmt/devid" 2>/dev/null)
            chmax=$(( (devid & 2064384) >> 16 )) 2>/dev/null || chmax=4
            trigmax=$(( (devid & 32640) >> 8 )) 2>/dev/null || trigmax=8
        else
            chmax=4
            trigmax=8
        fi
    else
        if [ -f "$cti_path/show_info" ]; then
            trigmax=$(cut -f1 -d ' ' "$cti_path/show_info" 2>/dev/null)
            chmax=$(cut -f2 -d ' ' "$cti_path/show_info" 2>/dev/null)
        else
            chmax=4
            trigmax=8
        fi
    fi

    [ -z "$trigmax" ] && trigmax=8
    [ -z "$chmax" ] && chmax=4

    log_info "Device: $cti (MaxTrig: $trigmax, MaxCh: $chmax)"

    _trig=0
    while [ "$_trig" -lt "$trigmax" ]; do
        if [ "$_trig" -lt "$CTI_MAX_TRIGGERS" ]; then
            trig="$_trig"
        else
            trig=$(( _trig % CTI_MAX_TRIGGERS ))
        fi

        limit_ch=$(( CTI_MAX_CHANNELS - 1 ))

        _ch=0
        while [ "$_ch" -le "$limit_ch" ]; do
            if [ "$_ch" -le "$chmax" ]; then
                if [ "$NEW_VER" -eq 1 ]; then
                    set_trigin_attach  "$trig" "$_ch" "$cti"
                    set_trigout_attach "$trig" "$_ch" "$cti"
                else
                    map_cti_trigin "$trig" "$_ch" "$cti"
                fi
            fi
            _ch=$(( _ch + 1 ))
        done

        _trig=$(( _trig + 1 ))
    done
done

if [ "$FAIL_COUNT" -eq 0 ]; then
    log_pass "CTI map/unmap Test PASS"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "CTI map/unmap Test FAIL ($FAIL_COUNT errors)"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------$TESTNAME Testcase Finished----------------------------"