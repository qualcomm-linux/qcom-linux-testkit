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
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/coresight_helper.sh"

TESTNAME="Coresight-Sink-Source-Test"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
log_info "---------------------------$TESTNAME Starting---------------------------"
no_remote_etm=0
if [ "$#" -eq 1 ]; then
    no_remote_etm=1
fi
cs_base="/sys/bus/coresight/devices"
fail=0

if [ ! -d "$cs_base" ]; then
    log_warn "Coresight directory $cs_base not found. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

cleanup() {
    reset_coresight
}
trap cleanup EXIT HUP INT TERM

reset_coresight
sinks=""
sources=""
for node in "$cs_base"/*; do
    [ ! -d "$node" ] && continue
    node_name=$(basename "$node")
    
    if [ -f "$node/enable_sink" ]; then
        [ "$node_name" = "tmc_etf1" ] && continue
        sinks="$sinks $node"
        
        if [ -f "$node/out_mode" ]; then
            echo mem > "$node/out_mode" 2>/dev/null || true
        fi
    fi
    
    if [ -f "$node/enable_source" ]; then
        sources="$sources $node"
    fi
done

sinks=${sinks# }
sources=${sources# }
if [ -z "$sinks" ]; then
    log_warn "No Coresight sinks found. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

if [ -z "$sources" ]; then
    log_warn "No Coresight sources found. Skipping test."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

i=0
while [ "$i" -le 2 ]; do
    log_info "Starting iteration: $((i+1))" 
    for sink_node in $sinks; do
        sink_dev=$(basename "$sink_node")
        log_info "Sink Active:- $sink_dev"
        
        for source_node in $sources; do
            dev_name=$(basename "$source_node")
            
            case "$dev_name" in
                *etm*)
                    if [ "$no_remote_etm" -eq 1 ]; then
                        continue
                    fi
                    ;;
                *tpdm-vsense* | *tpdm-qm*)
                    continue
                    ;;
            esac      
            reset_coresight
            
            [ -f "$sink_node/enable_sink" ] && echo 1 > "$sink_node/enable_sink" 2>/dev/null
            if [ -f "$source_node/enable_source" ]; then
                echo 1 > "$source_node/enable_source" 2>/dev/null
                ret=$(tr -d ' ' < "$source_node/enable_source")
                if [ "$ret" = "0" ]; then
                    log_fail "FAIL: enable source in $dev_name"
                    fail=1
                    continue
                fi
            fi          
            sleep 1
            reset_coresight
            
            rm -f "/tmp/$sink_dev.bin"
            if [ -c "/dev/$sink_dev" ]; then
                cat "/dev/$sink_dev" > "/tmp/$sink_dev.bin" 2>/dev/null
                outfilesize=$(wc -c < "/tmp/$sink_dev.bin" 2>/dev/null | tr -d ' ')
            else
                log_warn "Character device /dev/$sink_dev not found! Skipping read."
                outfilesize=0
            fi
            
            if [ -n "$outfilesize" ] && [ "$outfilesize" -ge 64 ]; then
                log_info "Source: $dev_name with trace captured of size $outfilesize bytes"
            else
                log_fail "Source: $dev_name with no traces captured of size ${outfilesize:-0}"
                fail=1
            fi
        done
    done
    i=$((i + 1))
done
reset_coresight

for source_node in $sources; do
    dev_name=$(basename "$source_node")
    if [ -f "$source_node/enable_source" ]; then
        ret=$(tr -d ' ' < "$source_node/enable_source")
        if [ "$ret" = "1" ]; then
            log_fail "fail to disable source in $dev_name during final verification"
            fail=1
        fi
    fi
done

if [ "$fail" -eq 0 ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "---------------------------$TESTNAME Finished---------------------------"
