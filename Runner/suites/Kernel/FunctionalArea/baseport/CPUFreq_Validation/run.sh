#!/bin/sh

. "$(pwd)/init_env"
TESTNAME="CPUFreq_Validation"
. "$TOOLS/functestlib.sh"

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== CPUFreq Frequency Walker with Validation ==="

# Color codes (ANSI escape sequences)
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

NUM_CPUS=$(nproc)
printf "${YELLOW}Detected %s CPU cores.${NC}\n" "$NUM_CPUS"

overall_pass=0
status_dir="/tmp/cpufreq_status.$$"
mkdir -p "$status_dir"

validate_cpu_core() {
    cpu=$1
    core_id=$2
    status_file="$status_dir/core_$core_id"

    printf "${BLUE}Processing %s...${NC}\n" "$cpu"

    if [ ! -d "$cpu/cpufreq" ]; then
        printf "${BLUE}[SKIP]${NC} %s does not support cpufreq.\n" "$cpu"
        echo "skip" > "$status_file"
        return
    fi

    available_freqs=$(cat "$cpu/cpufreq/scaling_available_frequencies" 2>/dev/null)

    if [ -z "$available_freqs" ]; then
        printf "${YELLOW}[INFO]${NC} No available frequencies for %s. Skipping...\n" "$cpu"
        echo "skip" > "$status_file"
        return
    fi

    if echo "userspace" | tee "$cpu/cpufreq/scaling_governor" > /dev/null; then
        printf "${YELLOW}[INFO]${NC} Set governor to userspace.\n"
    else
        printf "${RED}[ERROR]${NC} Cannot set userspace governor for %s.\n" "$cpu"
        echo "fail" > "$status_file"
        return
    fi

    echo "pass" > "$status_file"

    for freq in $available_freqs; do
        log_info "Setting $cpu to frequency $freq kHz..."
        if echo "$freq" | tee "$cpu/cpufreq/scaling_setspeed" > /dev/null; then
            sleep 0.2
            actual_freq=$(cat "$cpu/cpufreq/scaling_cur_freq")
            if [ "$actual_freq" = "$freq" ]; then
                printf "${GREEN}[PASS]${NC} %s set to %s kHz.\n" "$cpu" "$freq"
            else
                printf "${RED}[FAIL]${NC} Tried to set %s to %s kHz, but current is %s kHz.\n" "$cpu" "$freq" "$actual_freq"
                echo "fail" > "$status_file"
            fi
        else
            printf "${RED}[ERROR]${NC} Failed to set %s to %s kHz.\n" "$cpu" "$freq"
            echo "fail" > "$status_file"
        fi
    done

    echo "Restoring $cpu governor to 'ondemand'..."
    echo "ondemand" | sudo tee "$cpu/cpufreq/scaling_governor" > /dev/null
}

cpu_index=0
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    validate_cpu_core "$cpu" "$cpu_index" &
    cpu_index=$((cpu_index + 1))
done

wait

log_info ""
log_info "=== Per-Core Test Summary ==="
for status_file in "$status_dir"/core_*; do
    idx=$(basename "$status_file" | cut -d_ -f2)
    status=$(cat "$status_file")
    case "$status" in
        pass)
            printf "CPU%s: ${GREEN}[PASS]${NC}\n" "$idx"
            ;;
        fail)
            printf "CPU%s: ${RED}[FAIL]${NC}\n" "$idx"
            overall_pass=1
            ;;
        skip)
            printf "CPU%s: ${BLUE}[SKIPPED]${NC}\n" "$idx"
            ;;
        *)
            printf "CPU%s: ${RED}[UNKNOWN STATUS]${NC}\n" "$idx"
            overall_pass=1
            ;;
    esac
done

log_info ""
log_info "=== Overall CPUFreq Validation Result ==="
if [ "$overall_pass" -eq 0 ]; then
    printf "${GREEN}[OVERALL PASS]${NC} All CPUs validated successfully.\n"
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
    rm -r "$status_dir"
    exit 0
else
    printf "${RED}[OVERALL FAIL]${NC} Some CPUs failed frequency validation.\n"
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    rm -r "$status_dir"
    exit 1
fi