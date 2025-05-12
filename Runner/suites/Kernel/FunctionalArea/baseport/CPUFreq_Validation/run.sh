#!/bin/sh

. "$(pwd)/init_env"
# CPUFreq Validator: Parallel, Colorized
/var/Runner/init_env
TESTNAME="CPUFreq_Validation"
. "$TOOLS/functestlib.sh"

test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== CPUFreq Frequency Walker with Validation ==="

# Color codes
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
NC="\e[0m" # No Color

NUM_CPUS=$(nproc)
echo -e "${YELLOW}Detected $NUM_CPUS CPU cores.${NC}"

overall_pass=true
declare -A core_status

validate_cpu_core() {
    local cpu=$1
    local core_id=$2

    echo -e "${BLUE}Processing $cpu...${NC}"

    if [ ! -d "$cpu/cpufreq" ]; then
        echo -e "${BLUE}[SKIP]${NC} $cpu does not support cpufreq."
        core_status["$core_id"]="skip"
        return
    fi

    available_freqs=$(cat "$cpu/cpufreq/scaling_available_frequencies" 2>/dev/null)

    if [ -z "$available_freqs" ]; then
        echo -e "${YELLOW}[INFO]${NC} No available frequencies for $cpu. Skipping..."
        core_status["$core_id"]="skip"
        return
    fi

    # Set governor to userspace
    if echo "userspace" | tee "$cpu/cpufreq/scaling_governor" > /dev/null; then
        echo -e "${YELLOW}[INFO]${NC} Set governor to userspace."
    else
        echo -e "${RED}[ERROR]${NC} Cannot set userspace governor for $cpu."
        core_status["$core_id"]="fail"
        return
    fi

    core_status["$core_id"]="pass"  # Assume pass unless a failure happens

    for freq in $available_freqs; do
        log_info "Setting $cpu to frequency $freq kHz..."
        if echo $freq | tee "$cpu/cpufreq/scaling_setspeed" > /dev/null; then
            sleep 0.2
            actual_freq=$(cat "$cpu/cpufreq/scaling_cur_freq")
            if [ "$actual_freq" == "$freq" ]; then
                echo -e "${GREEN}[PASS]${NC} $cpu set to $freq kHz."
            else
                echo -e "${RED}[FAIL]${NC} Tried to set $cpu to $freq kHz, but current is $actual_freq kHz."
                core_status["$core_id"]="fail"
            fi
        else
            echo -e "${RED}[ERROR]${NC} Failed to set $cpu to $freq kHz."
            core_status["$core_id"]="fail"
        fi
    done

    # Restore governor
    echo "Restoring $cpu governor to 'ondemand'..."
    echo "ondemand" | sudo tee "$cpu/cpufreq/scaling_governor" > /dev/null
}

# Launch validation per CPU in parallel
cpu_index=0
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    validate_cpu_core "$cpu" "$cpu_index" &
    ((cpu_index++))
done

# Wait for all background jobs to finish
wait

# Summary
log_info ""
log_info "=== Per-Core Test Summary ==="
for idx in "${!core_status[@]}"; do
    status=${core_status[$idx]}
    case "$status" in
        pass)
            echo -e "CPU$idx: ${GREEN}[PASS]${NC}"
            ;;
        fail)
            echo -e "CPU$idx: ${RED}[FAIL]${NC}"
            overall_pass=false
            ;;
        skip)
            echo -e "CPU$idx: ${BLUE}[SKIPPED]${NC}"
            ;;
        *)
            echo -e "CPU$idx: ${RED}[UNKNOWN STATUS]${NC}"
            overall_pass=false
            ;;
    esac
done

# Overall result
log_info ""
log_info "=== Overall CPUFreq Validation Result ==="
if $overall_pass; then
    echo -e "${GREEN}[OVERALL PASS]${NC} All CPUs validated successfully."
	log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME : Test Passed" > $test_path/$TESTNAME.res
    echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
    exit 0
else
    echo -e "${RED}[OVERALL FAIL]${NC} Some CPUs failed frequency validation."
	log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME : Test Failed" > $test_path/$TESTNAME.res
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"