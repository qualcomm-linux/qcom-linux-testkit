# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Import test suite definitions
. $(pwd)/init_env

#import platform
. $TOOLS/platform.sh

#import test functions library
. $TOOLS/functestlib.sh

# CPU_FAST CPU_SLOW FTRACE_START_MARKER are used by the ftrace libraries

FTRACE_FILE=./trace.ftrace
LOAD_GENERATOR=$TOOLS/tasklibrary
FTRACE_ANALYZER_EXE=$TOOLS/ftrace
TRACE_CMD_EXE=$TOOLS/trace-cmd
BIG_LITTLE_SWITCH_SO=$TOOLS/libbiglittleswitch.so.1.0.0
HOG_CPU=$TOOLS/affinity_tools
TASKSET=$TOOLS/affinity_tools
CONFIG_FTRACE_EVENTS="-e sched:*"
CONFIG_FTRACE_BUFFER_SIZE=40960

CPU_FAST=
CPU_SLOW=
IMPLEMENTER=0x41
#A7
default_little_cpulist
HMPSLOWCPUS=$__RET
littlecore=`echo $HMPSLOWCPUS|busybox awk {'print $1'}`
CONFIG_TARGET_LITTLE_CPUPART=$( cpupart $littlecore )
PART_SLOW=`echo $CONFIG_TARGET_LITTLE_CPUPART`
#A15
default_big_cpulist
HMPFASTCPUS=$__RET
bigcore=`echo $HMPFASTCPUS|busybox awk {'print $1'}`
CONFIG_TARGET_BIG_CPUPART=$( cpupart $bigcore )
PART_FAST=`echo $CONFIG_TARGET_BIG_CPUPART`
commaslow=
commafast=
for cpu in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 21 22 23 24 25 26 ; do
    $TASKSET -part $cpu,$IMPLEMENTER,$PART_SLOW >/dev/null
    if [ $? == 0 ] ; then
        CPU_SLOW=$CPU_SLOW$commaslow$cpu
        commaslow=,
    fi
    $TASKSET -part $cpu,$IMPLEMENTER,$PART_FAST >/dev/null
    if [ $? == 0 ] ; then
        CPU_FAST=$CPU_FAST$commafast$cpu
        commafast=,
    fi
done
echo "Fast CPU $CPU_FAST Slow CPU $CPU_SLOW"

if [  ! -e /proc/sys/kernel/sched_upmigrate ]  ||  [ ! -e /proc/sys/kernel/sched_downmigrate  ]; then 
    echo "up-upmigrate and down-downmigrate values not exported. Precondition failure"
    #non-zero exit signals test runner to declare this test as a failure
    exit 1
fi

UP_THRESHOLD_1024=$(cat '/proc/sys/kernel/sched_upmigrate' | cut -f 1)
DOWN_THRESHOLD_1024=$(cat '/proc/sys/kernel/sched_downmigrate' | cut -f 1)
let UP_THRESHOLD=$UP_THRESHOLD_1024*100/1024
let DOWN_THRESHOLD=$DOWN_THRESHOLD_1024*100/1024
let UNDER_DOWN_THRESHOLD=$DOWN_THRESHOLD_1024*50/1024
let LITTLE_THRESHOLD=$DOWN_THRESHOLD*70/100
let NOCHANGE_THRESHOLD=\($DOWN_THRESHOLD_1024+$UP_THRESHOLD_1024\)*100/1024/2
let BIG_THRESHOLD=$UP_THRESHOLD*130/100
let THRESHOLD_TOLERANCE=15
# separate down threshold as test load is +/- 10% accurate at best
let NODOWN_THRESHOLD=$NOCHANGE_THRESHOLD
if [ "$NODOWN_THRESHOLD" -lt "$(($DOWN_THRESHOLD+$THRESHOLD_TOLERANCE))" ] ; then
  NODOWN_THRESHOLD=$(($DOWN_THRESHOLD+$THRESHOLD_TOLERANCE))
  echo "Setting NODOWN_THRESHOLD to $NODOWN_THRESHOLD"
fi
# separate up threshold as test load is +/- 10% accurate at best
let NOUP_THRESHOLD=$NOCHANGE_THRESHOLD
if [ "$NOUP_THRESHOLD" -gt "$(($UP_THRESHOLD-$THRESHOLD_TOLERANCE))" ] ; then
  NOUP_THRESHOLD=$(($UP_THRESHOLD-$THRESHOLD_TOLERANCE))
  echo "Setting NOUP_THRESHOLD to $NOUP_THRESHOLD"
fi
CUTOFF_PRIORITY_GT=-5
CUTOFF_PRIORITY_LT=2
TIME_ERROR_MS=100
HOG_PID=

copy_trace_events()
{
    if [ -f $FTRACE_EVENTS/header_page ] ; then
        echo "Trace events already copied"
        TRACE_EVENTS_PATH=$FTRACE_EVENTS
        return
    fi

    echo "Copying trace events..."
    odir=`pwd`
    cd /sys/kernel/debug/tracing/events
    mkdir $FTRACE_EVENTS
    for i in * ; do
        if [ -f $i ] ; then
            cat $i > $FTRACE_EVENTS/$i
        else
            old=`pwd`
            cd $i
            mkdir $FTRACE_EVENTS/$i/
            for j in * ; do
                if [ -f $j/format ] ; then
                    mkdir $FTRACE_EVENTS/$i/$j
                    cat $j/format > $FTRACE_EVENTS/$i/$j/format
                fi
            done
            cd $old
        fi
    done
    cd $odir
    TRACE_EVENTS_PATH=$FTRACE_EVENTS
}

get_uptime()
{
    _temp="`cat /proc/uptime`"
# RESULT is the second integer of /proc/uptime
    for _temp1 in $_temp ; do
        RESULT=$_temp1
    done
}

hog_cpu_fast()
{
    $HOG_CPU $CPU_FAST,$CPU_FAST,$CPU_FAST &
    HOG_PID="$HOG_PID $!"
}

hog_cpu_slow()
{
    $HOG_CPU $CPU_SLOW,$CPU_SLOW,$CPU_SLOW &
    HOG_PID="$HOG_PID $!"
}

unhog_cpu()
{
    for i in $HOG_PID ; do
        kill -10 $i
        wait $i
    done
    HOG_PID=
}

taskset_cpuslow()
{
    $TASKSET -pc $CPU_SLOW $1
}

taskset_cpufast()
{
    $TASKSET -pc $CPU_FAST $1
}

taskset_cpuany()
{
    $TASKSET -pc $CPU_FAST,$CPU_SLOW $1
}

CALIBRATION=${CALIBRATION:-$BASEDIR/calib.txt}
calibrate_tasklib()
{
    # share between test suites if possible
    if [ ! -f $CALIBRATION ] ; then
        $LOAD_GENERATOR --calibrate
        mv calib.txt $CALIBRATION
    fi
}

# Force load_generator calibration each time this file is sourced.
# This ensures that the following load_generator function could find a valid
# calibration file once it is called by a test, even for the first time.
calibrate_tasklib

load_generator()
{
    echo "Using tasklibrary calibdation file: $CALIBRATION"
    $LOAD_GENERATOR --calibfile=$CALIBRATION --loadseq=$1 &
    RESULT=$!
    if [ "$2" == "START_SLOW" ] ; then
        taskset_cpuslow $RESULT
        for ii in 0 ; do sleep 1; taskset_cpuany $RESULT ; done &
    fi
    if [ "$2" == "START_FAST" ] ; then
        taskset_cpufast $RESULT
        for ii in 0 ; do sleep 1; taskset_cpuany $RESULT ; done &
    fi
    if [ "$2" == "STARTSTOP_SLOW" ] ; then
        taskset_cpuslow $RESULT
    fi
    if [ "$2" == "STARTSTOP_FAST" ] ; then
        taskset_cpufast $RESULT
    fi
    echo "#load_generator PID=$RESULT COMMAND=$1"
}

ftrace_start()
{
    BOOST_GOVERNOR=${1:-1}

    if [ $ANDROID -eq 1 ]; then
        echo "Stop all android services"
        stop
    fi

    if [ $BOOST_GOVERNOR -eq 1 ]; then
        echo "Save current CPUFreq governors configuration"
        i=0
        FTRACE_OLD_GOV=""
        while [ $i != 9999 ] ; do
            temp="` cat /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor 2>/dev/null`"
            if [ "$temp" == "" ] ; then
                i=9999
            else
                let i=$i+1
                FTRACE_OLD_GOV="$FTRACE_OLD_GOV $temp"
            fi
        done

        echo "Set CPUFreq governor to [performance]"
        i=0
        while [ $i != 9999 ] ; do
            temp="` cat /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor 2>/dev/null`"
            if [ "$temp" == "" ] ; then
                i=9999
            else
                echo performance > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor
                let i=$i+1
            fi
        done
    fi

    mount -t debugfs none /sys/kernel/debug/ 2>/dev/null
    get_uptime
    FTRACE_START_MARKER=$RESULT

    echo "Start FTrace..."
    $TRACE_CMD_EXE reset
    $TRACE_CMD_EXE start -b $CONFIG_FTRACE_BUFFER_SIZE $CONFIG_FTRACE_EVENTS
    echo $FTRACE_START_MARKER > /sys/kernel/debug/tracing/trace_marker
    echo "Tracing started @ $FTRACE_START_MARKER"
}

ftrace_stop()
{
    RESTORE_GOVERNOR=${1:-1}

    $TRACE_CMD_EXE stop

    get_uptime
    ftrace_stop_start=$RESULT
    echo "Tracing stopped"

    rm $FTRACE_FILE 2>/dev/null
    if [ "$CONFIG_FTRACE_BINARY" == "n" ] ; then
        echo "Extracting ASCII trace buffer..."
        $TRACE_CMD_EXE show > $FTRACE_FILE 2>/dev/null
    else
        echo "Extracting BINARY trace buffer..."
        $TRACE_CMD_EXE extract -o $FTRACE_FILE 2>/dev/null
    fi
    get_uptime
    ftrace_extract_done=$RESULT
    echo "Trace analysis from $ftrace_stop_start to $ftrace_extract_done"

    if [ $RESTORE_GOVERNOR -eq 1 ]; then
        echo "Restore CPUFreq governors..."
        i=0
        for value  in $FTRACE_OLD_GOV ; do
            echo $value > /sys/devices/system/cpu/cpu$i/cpufreq/scaling_governor
            let i=$i+1
        done
    fi

    copy_trace_events
}


ftrace_check()
{
    get_uptime
    ftrace_check_start=$RESULT
    export TRACE_EVENTS_PATH
    commandline="TRACE_EVENTS_PATH=$FTRACE_EVENTS"
    export EXPECTED_TIME_IN_END_STATE_MS
    commandline="$commandline EXPECTED_TIME_IN_END_STATE_MS=$EXPECTED_TIME_IN_END_STATE_MS"
    export EXPECTED_CHANGE_TIME_MS_MIN
    commandline="$commandline EXPECTED_CHANGE_TIME_MS_MIN=$EXPECTED_CHANGE_TIME_MS_MIN"
    export EXPECTED_CHANGE_TIME_MS_MAX
    commandline="$commandline EXPECTED_CHANGE_TIME_MS_MAX=$EXPECTED_CHANGE_TIME_MS_MAX"
    export START_LITTLE
    commandline="$commandline START_LITTLE=$START_LITTLE"
    export START_LITTLE_PRIORITY
    commandline="$commandline START_LITTLE_PRIORITY=$START_LITTLE_PRIORITY"
    export START_BIG
    commandline="$commandline START_BIG=$START_BIG"
    export START_BIG_PRIORITY
    commandline="$commandline START_BIG_PRIORITY=$START_BIG_PRIORITY"
    export END_LITTLE
    commandline="$commandline END_LITTLE=$END_LITTLE"
    export END_LITTLE_PRIORITY
    commandline="$commandline END_LITTLE_PRIORITY=$END_LITTLE_PRIORITY"
    export END_BIG
    commandline="$commandline END_BIG=$END_BIG"
    export END_BIG_PRIORITY
    commandline="$commandline END_BIG_PRIORITY=$END_BIG_PRIORITY"
    export FTRACE_START_MARKER
    commandline="$commandline FTRACE_START_MARKER=$FTRACE_START_MARKER"
    export DISCARD_TIME_MS
    commandline="$commandline DISCARD_TIME_MS=$DISCARD_TIME_MS"
    export CPU_FAST
    commandline="$commandline CPU_FAST=$CPU_FAST"
    export CPU_SLOW
    commandline="$commandline CPU_SLOW=$CPU_SLOW"
    commandline="$commandline $FTRACE_ANALYZER_EXE -l $1 -t $FTRACE_FILE"
    echo "# $commandline"
    if [ "$CONFIG_FTRACE_BINARY" == "y" ] ; then
        $TRACE_CMD_EXE report -i $FTRACE_FILE > trace.txt 2>/dev/null
        $FTRACE_ANALYZER_EXE -l $1 -t trace.txt
        RESULT0=$?
        rm trace.txt
    else
        $FTRACE_ANALYZER_EXE -l $1 -t $FTRACE_FILE
        RESULT0=$?
    fi
    get_uptime
    ftrace_check_done=$RESULT
    echo "Trace analysis run from $ftrace_check_start to $ftrace_check_done"

    # remove ftrace files if it was a success to limit
    # space used on sdcard.
    if [ "x$CONFIG_FTRACE_CLEANUP" == "xy" -a "$RESULT0" == "0" ] ; then
        rm $FTRACE_FILE
    else
        gzip $FTRACE_FILE
    fi
    RESULT=$RESULT0
}

get_task_pid() {
    TRACE=$1
    TASK_NAME=$2

    TASK=`awk -v PATTERN="$TASK_NAME-([0-9]+)" '$1 ~ PATTERN {print $1; exit 0;}' $TRACE`
    TASK_PID=${TASK/${TASK_NAME}-/}

    echo "Found task [$TASK_NAME] PID: $TASK_PID"
    RESULT=$TASK_PID
}

ftrace_check_tasks()
{
    get_uptime
    export TRACE_TASKS

    # Generate TXT file required for analysis
    if [ "$CONFIG_FTRACE_BINARY" == "y" ] ; then
        $TRACE_CMD_EXE report -i $FTRACE_FILE > trace.txt 2>/dev/null
        mv $FTRACE_FILE $FTRACE_FILE.bin
        mv trace.txt $FTRACE_FILE
    fi

    echo "Extracting tasks PIDs..."
    for TASK in $TRACE_TASKS; do
      get_task_pid $FTRACE_FILE $TASK
      TASK_PID=$RESULT
      PIDS+="$TASK_PID,"
    done

    echo "Computing CPUs usages for PIDs: $PIDS"
    export PID=$PIDS
    commandline="PID=$PID"
    export CPUS_MASK
    commandline="$commandline CPUS_MASK=$CPUS_MASK"
    export USAGE_MIN
    commandline="$commandline USAGE_MIN=$USAGE_MIN"
    export USAGE_MAX
    commandline="$commandline USAGE_MAX=$USAGE_MAX"
    export TIME_MIN
    commandline="$commandline TIME_MIN=$TIME_MIN"
    export TIME_MAX
    commandline="$commandline TIME_MAX=$TIME_MAX"
    echo "# $commandline"
    $FTRACE_ANALYZER_EXE -l libprocess_matrix.so.1.0.0 -t $FTRACE_FILE
    RESULT0=$?

    # Recover original binary file
    if [ "$CONFIG_FTRACE_BINARY" == "y" ] ; then
        rm $FTRACE_FILE
        mv $FTRACE_FILE.bin $FTRACE_FILE
    fi

    # remove ftrace files if it was a success to limit
    # space used on sdcard.
    if [ "x$CONFIG_FTRACE_CLEANUP" == "xy" -a "$RESULT0" == "0" ] ; then
        rm $FTRACE_FILE
    else
        gzip $FTRACE_FILE
    fi

    # Return test result to testrunner
    RESULT=$RESULT0

}
