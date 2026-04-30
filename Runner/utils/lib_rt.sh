#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# lib_rt.sh - helpers for RT-tests wrappers

: "${log_info:=:}"
: "${log_warn:=:}"
: "${log_error:=:}"
: "${log_fail:=:}"
: "${log_skip:=:}"
: "${log_pass:=:}"

# shellcheck disable=SC2034
PERF_RT_BG_PID=""
# shellcheck disable=SC2034
PERF_RT_BG_NAME=""
# shellcheck disable=SC2034
PERF_RT_BG_CMD=""
PERF_RT_BG_KILL_TIMEOUT="${PERF_RT_BG_KILL_TIMEOUT:-3}"
PERF_RT_BG_KILL_SIGNAL="${PERF_RT_BG_KILL_SIGNAL:-KILL}"
PERF_RT_BG_LOGFILE="${PERF_RT_BG_LOGFILE:-}"

INTERRUPTED=0
export INTERRUPTED

RT_STREAM_TESTNAME="rt-tests"
export RT_STREAM_TESTNAME

RT_INTERRUPTED="${RT_INTERRUPTED:-0}"
export RT_INTERRUPTED

RT_CUR_TESTNAME="${RT_CUR_TESTNAME:-RTTest}"
RT_CUR_BIN_PID="${RT_CUR_BIN_PID:-}"
RT_CUR_TEE_PID="${RT_CUR_TEE_PID:-}"
RT_CUR_FIFO="${RT_CUR_FIFO:-}"

# shellcheck disable=SC2034
RT_HEARTBEAT_PID=""
export RT_HEARTBEAT_PID

# shellcheck disable=SC2034
RT_HEARTBEAT_INLINE=0
export RT_HEARTBEAT_INLINE

# shellcheck disable=SC2034
RT_HEARTBEAT_TTY=""
export RT_HEARTBEAT_TTY

PERF_RT_RETURN_CODE=""
export PERF_RT_RETURN_CODE

# shellcheck disable=SC2034
RT_RUN_TARGET_DURATION_SECS=""
export RT_RUN_TARGET_DURATION_SECS

# shellcheck disable=SC2034
RT_RUN_RC=1
# shellcheck disable=SC2034
RT_RUN_JSON_OK=0
# shellcheck disable=SC2034
RT_RUN_STDOUTLOG=""
# shellcheck disable=SC2034
RT_RUN_JSONFILE=""
export RT_RUN_RC RT_RUN_JSON_OK RT_RUN_STDOUTLOG RT_RUN_JSONFILE

# shellcheck disable=SC2034
RT_BASELINE_VALUE=""
# shellcheck disable=SC2034
RT_BASELINE_FAIL_COUNT=""
# shellcheck disable=SC2034
RT_BASELINE_FAIL_LIMIT=""
export RT_BASELINE_VALUE RT_BASELINE_FAIL_COUNT RT_BASELINE_FAIL_LIMIT

# ---------------------------------------------------------------------------
# rt_stream_init <testname> <outdir>
# Initialize generic streaming state for a wrapper.
# ---------------------------------------------------------------------------
rt_stream_init() {
  testname=$1
  outdir=$2

  RT_STREAM_TESTNAME="${testname:-rt-tests}"
  export RT_STREAM_TESTNAME

  INTERRUPTED=0
  export INTERRUPTED

  RT_STREAM_OUTDIR="${outdir:-/tmp}"
  export RT_STREAM_OUTDIR
}

# ---------------------------------------------------------------------------
# rt_stream_on_sigint
# Mark a streaming run as interrupted and log a partial-results message.
# ---------------------------------------------------------------------------
rt_stream_on_sigint() {
  INTERRUPTED=1
  export INTERRUPTED
  log_warn "${RT_STREAM_TESTNAME:-rt-tests}: Ctrl-C received, stopping test and reporting results collected so far..."
}

# ---------------------------------------------------------------------------
# rt_run_with_progress <name> <step_sec> <outfile> <cmd> [args...]
# Run a command in the background and log progress every step_sec seconds.
# ---------------------------------------------------------------------------
rt_run_with_progress() {
  name=$1
  step=$2
  outfile=$3
  shift 3

  [ -n "$name" ] || name="rt-test"
  case "$step" in ''|*[!0-9]*|0) step=5 ;; esac
  [ -n "$outfile" ] || outfile="/tmp/rt_run_with_progress.out"

  : >"$outfile" 2>/dev/null || true

  "$@" >"$outfile" 2>&1 &
  pid=$!

  case "$pid" in
    ''|*[!0-9]*)
      log_warn "$name: failed to start command (invalid pid='$pid')"
      return 1
      ;;
  esac

  elapsed=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    sleep "$step"
    elapsed=$((elapsed + step))
    log_info "$name: running... ${elapsed}s elapsed"
  done

  wait "$pid"
  return $?
}

# ---------------------------------------------------------------------------
# rt_handle_int
# Interrupt handler for RT wrappers.
# Marks the run interrupted, clears inline heartbeat, and forwards SIGINT to
# the active child when one is known.
# ---------------------------------------------------------------------------
rt_handle_int() {
  RT_INTERRUPTED=1
  export RT_INTERRUPTED

  log_warn "${RT_CUR_TESTNAME:-RTTest}: Ctrl-C received; stopping test and reporting results collected so far..."

  rt_heartbeat_clear >/dev/null 2>&1 || true

  if [ -n "$RT_CUR_BIN_PID" ]; then
    kill -INT "$RT_CUR_BIN_PID" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# rt_cleanup_pipes
# Best-effort cleanup for FIFO/tee based streaming runs.
# ---------------------------------------------------------------------------
rt_cleanup_pipes() {
  if [ -n "$RT_CUR_TEE_PID" ]; then
    kill "$RT_CUR_TEE_PID" 2>/dev/null || true
  fi

  if [ -n "$RT_CUR_FIFO" ]; then
    rm -f "$RT_CUR_FIFO" 2>/dev/null || true
  fi

  RT_CUR_BIN_PID=""
  RT_CUR_TEE_PID=""
  RT_CUR_FIFO=""
}

# ---------------------------------------------------------------------------
# rt_stream_run_json <outfile> <cmd> [args...]
# Stream command output via FIFO into outfile while preserving return code.
# ---------------------------------------------------------------------------
rt_stream_run_json() {
  outfile=$1
  shift

  [ -n "$outfile" ] || return 1
  [ "$#" -gt 0 ] || return 1

  outdir=$(dirname "$outfile")
  mkdir -p "$outdir" 2>/dev/null || true

  fifo="${outfile}.fifo.$$"
  rm -f "$fifo" 2>/dev/null || true
  if ! mkfifo "$fifo"; then
    return 1
  fi

  RT_CUR_FIFO="$fifo"

  tee -a "$outfile" <"$fifo" &
  RT_CUR_TEE_PID=$!

  "$@" >"$fifo" 2>&1 &
  RT_CUR_BIN_PID=$!

  wait "$RT_CUR_BIN_PID"
  rc=$?

  if [ -n "${RT_CUR_TEE_PID:-}" ]; then
    wait "$RT_CUR_TEE_PID" 2>/dev/null || true
  fi

  rm -f "$fifo" 2>/dev/null || true
  RT_CUR_FIFO=""
  RT_CUR_BIN_PID=""
  RT_CUR_TEE_PID=""

  return "$rc"
}

# ---------------------------------------------------------------------------
# rt_log_kernel_rt_status
# Best-effort RT kernel detection based on uname.
# ---------------------------------------------------------------------------
rt_log_kernel_rt_status() {
  rel=$(uname -r 2>/dev/null || echo "")
  ver=$(uname -v 2>/dev/null || echo "")

  case "$rel $ver" in
    *-rt*|*PREEMPT_RT*)
      log_info "Kernel appears to be RT-enabled: uname -r='$rel'"
      return 0
      ;;
    *)
      log_warn "Kernel does NOT look RT-enabled: uname -r='$rel' (results may be worse)"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# perf_rt_bg_start <name> <command>
# Start an optional background workload.
# ---------------------------------------------------------------------------
perf_rt_bg_start() {
  PERF_RT_BG_NAME="${1:-rt-tests}"
  PERF_RT_BG_CMD="${2:-}"

  [ -n "$PERF_RT_BG_CMD" ] || return 0

  perf_rt_bg_stop >/dev/null 2>&1 || true

  if [ -n "${PERF_RT_BG_LOGFILE:-}" ]; then
    bg_dir=$(dirname "$PERF_RT_BG_LOGFILE" 2>/dev/null || echo "")
    if [ -n "$bg_dir" ]; then
      mkdir -p "$bg_dir" 2>/dev/null || true
    fi
    log_info "$PERF_RT_BG_NAME: starting background cmd (logging -> $PERF_RT_BG_LOGFILE): $PERF_RT_BG_CMD"
    sh -c "$PERF_RT_BG_CMD" >>"$PERF_RT_BG_LOGFILE" 2>&1 &
  else
    log_info "$PERF_RT_BG_NAME: starting background cmd: $PERF_RT_BG_CMD"
    sh -c "$PERF_RT_BG_CMD" >/dev/null 2>&1 &
  fi

  PERF_RT_BG_PID=$!

  case "$PERF_RT_BG_PID" in
    ''|*[!0-9]*)
      log_warn "$PERF_RT_BG_NAME: background cmd started but PID invalid: '$PERF_RT_BG_PID'"
      PERF_RT_BG_PID=""
      return 0
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# perf_rt_bg_stop
# Stop an optional background workload.
# ---------------------------------------------------------------------------
perf_rt_bg_stop() {
  [ -n "$PERF_RT_BG_PID" ] || return 0

  case "$PERF_RT_BG_PID" in
    ''|*[!0-9]*)
      PERF_RT_BG_PID=""
      PERF_RT_BG_CMD=""
      PERF_RT_BG_NAME=""
      return 0
      ;;
  esac

  log_info "${PERF_RT_BG_NAME:-rt-tests}: stopping background cmd pid=$PERF_RT_BG_PID"

  kill "$PERF_RT_BG_PID" >/dev/null 2>&1 || true

  t=0
  while [ "$t" -lt "$PERF_RT_BG_KILL_TIMEOUT" ] 2>/dev/null; do
    if kill -0 "$PERF_RT_BG_PID" >/dev/null 2>&1; then
      sleep 1
      t=$((t + 1))
      continue
    fi
    break
  done

  if kill -0 "$PERF_RT_BG_PID" >/dev/null 2>&1; then
    log_warn "${PERF_RT_BG_NAME:-rt-tests}: background cmd still running; sending ${PERF_RT_BG_KILL_SIGNAL}"
    kill -"$PERF_RT_BG_KILL_SIGNAL" "$PERF_RT_BG_PID" >/dev/null 2>&1 || true
  fi

  wait "$PERF_RT_BG_PID" >/dev/null 2>&1 || true

  PERF_RT_BG_PID=""
  PERF_RT_BG_CMD=""
  PERF_RT_BG_NAME=""
  return 0
}

# ---------------------------------------------------------------------------
# rt_check_clock_sanity <testname>
# Best-effort clock sanity check.
# ---------------------------------------------------------------------------
rt_check_clock_sanity() {
  testname=$1
  [ -n "$testname" ] || testname="RTTest"

  log_info "Ensuring system clock is reasonable before $testname..."
  if command -v ensure_reasonable_clock >/dev/null 2>&1; then
    if ! ensure_reasonable_clock; then
      log_error "Clock is not reasonable; $testname results may be impacted."
      return 1
    fi
    return 0
  fi

  log_info "ensure_reasonable_clock() not available, continuing without clock sanity check."
  return 0
}

# ---------------------------------------------------------------------------
# rt_fmt_num <value>
# Normalize numeric values for KPI output.
# - Integers are emitted unchanged.
# - Floating-point values are rounded to 3 decimals.
# - Trailing zeros and trailing decimal point are removed.
# - Non-numeric input is returned as-is.
# ---------------------------------------------------------------------------
rt_fmt_num() {
  v=$1

  [ -n "$v" ] || {
    echo ""
    return 0
  }

  printf '%s\n' "$v" | awk '
    function trim(x) {
      sub(/0+$/, "", x)
      sub(/\.$/, "", x)
      return x
    }
    {
      if ($0 ~ /^-?[0-9]+$/) {
        print $0
        exit
      }
      if ($0 ~ /^-?[0-9]+(\.[0-9]+)?$/) {
        x=sprintf("%.3f", $0)
        print trim(x)
        exit
      }
      print $0
    }
  '
}

# ---------------------------------------------------------------------------
# rt_aggregate_iter_latencies <prefix> <iter_kpi_file>
# Aggregate iteration-prefixed latency KPI lines across all iterations.
# ---------------------------------------------------------------------------
rt_aggregate_iter_latencies() {
  prefix=$1
  infile=$2

  [ -n "$prefix" ] || return 1
  [ -n "$infile" ] || return 1
  [ -r "$infile" ] || return 1

  awk -v pfx="$prefix" '
    function isnum(x) { return (x ~ /^-?[0-9]+(\.[0-9]+)?$/) }

    BEGIN {
      min_min=""; min_max=""; min_sum=0; min_n=0
      avg_min=""; avg_max=""; avg_sum=0; avg_n=0
      max_min=""; max_max=""; max_sum=0; max_n=0
      worst_max=""; worst_tid=""
    }

    /^iteration-[0-9]+-t[0-9]+-(min|avg|max)-latency[[:space:]]+pass[[:space:]]+/ {
      key=$1
      sub(/^iteration-[0-9]+-/, "", key)

      tid=key
      sub(/-.*$/, "", tid)

      metric=key
      sub(/^t[0-9]+-/, "", metric)

      val=$3
      if (!isnum(val))
        next

      if (metric == "min-latency") {
        if (min_min == "" || (val + 0) < (min_min + 0))
          min_min=val
        if (min_max == "" || (val + 0) > (min_max + 0))
          min_max=val
        min_sum += (val + 0)
        min_n++
      } else if (metric == "avg-latency") {
        if (avg_min == "" || (val + 0) < (avg_min + 0))
          avg_min=val
        if (avg_max == "" || (val + 0) > (avg_max + 0))
          avg_max=val
        avg_sum += (val + 0)
        avg_n++
      } else if (metric == "max-latency") {
        if (max_min == "" || (val + 0) < (max_min + 0))
          max_min=val
        if (max_max == "" || (val + 0) > (max_max + 0))
          max_max=val
        max_sum += (val + 0)
        max_n++

        if (worst_max == "" || (val + 0) > (worst_max + 0)) {
          worst_max=val
          worst_tid=tid
        }
      }
    }

    END {
      if (min_n > 0) {
        printf "%s-all-min-latency-min pass %s us\n", pfx, min_min
        printf "%s-all-min-latency-mean pass %.6f us\n", pfx, (min_sum / min_n)
        printf "%s-all-min-latency-max pass %s us\n", pfx, min_max
      }
      if (avg_n > 0) {
        printf "%s-all-avg-latency-min pass %s us\n", pfx, avg_min
        printf "%s-all-avg-latency-mean pass %.6f us\n", pfx, (avg_sum / avg_n)
        printf "%s-all-avg-latency-max pass %s us\n", pfx, avg_max
      }
      if (max_n > 0) {
        printf "%s-all-max-latency-min pass %s us\n", pfx, max_min
        printf "%s-all-max-latency-mean pass %.6f us\n", pfx, (max_sum / max_n)
        printf "%s-all-max-latency-max pass %s us\n", pfx, max_max
      }
      if (worst_tid != "" && worst_max != "") {
        printf "%s-worst-thread-max-latency pass %s us\n", pfx, worst_max
        sub(/^t/, "", worst_tid)
        printf "%s-worst-thread-id pass %s id\n", pfx, worst_tid
      }
    }
  ' "$infile" 2>/dev/null | while IFS= read -r line; do
    kpi=$(printf '%s\n' "$line" | awk '{print $1}')
    stat=$(printf '%s\n' "$line" | awk '{print $2}')
    num=$(printf '%s\n' "$line" | awk '{print $3}')
    unit=$(printf '%s\n' "$line" | awk '{print $4}')

    if [ -n "$kpi" ] && [ "$stat" = "pass" ] && [ -n "$num" ] && [ -n "$unit" ]; then
      num2=$(rt_fmt_num "$num")
      printf '%s pass %s %s\n' "$kpi" "$num2" "$unit"
    else
      printf '%s\n' "$line"
    fi
  done
}

# ---------------------------------------------------------------------------
# rt_aggregate_iter_latencies_per_thread <prefix> <iter_kpi_file>
# Aggregate iteration-prefixed latency KPI lines per thread across iterations.
# ---------------------------------------------------------------------------
rt_aggregate_iter_latencies_per_thread() {
  prefix=$1
  infile=$2

  [ -n "$prefix" ] || return 1
  [ -n "$infile" ] || return 1
  [ -r "$infile" ] || return 1

  awk -v pfx="$prefix" '
    function isnum(x) { return (x ~ /^-?[0-9]+(\.[0-9]+)?$/) }

    /^iteration-[0-9]+-t[0-9]+-(min|avg|max)-latency[[:space:]]+pass[[:space:]]+/ {
      key=$1
      sub(/^iteration-[0-9]+-/, "", key)

      tid=key
      sub(/-.*$/, "", tid)

      metric=key
      sub(/^t[0-9]+-/, "", metric)

      val=$3
      if (!isnum(val))
        next

      idx=tid "|" metric

      if (!(idx in seen)) {
        seen[idx]=1
        minv[idx]=val
        maxv[idx]=val
        sumv[idx]=(val + 0)
        cntv[idx]=1
        order[++nidx]=idx
      } else {
        if ((val + 0) < (minv[idx] + 0))
          minv[idx]=val
        if ((val + 0) > (maxv[idx] + 0))
          maxv[idx]=val
        sumv[idx]+=(val + 0)
        cntv[idx]++
      }
    }

    END {
      for (i=1; i<=nidx; i++) {
        idx=order[i]
        split(idx, parts, /\|/)
        tid=parts[1]
        metric=parts[2]

        printf "%s-%s-%s-min pass %s us\n", pfx, tid, metric, minv[idx]
        printf "%s-%s-%s-mean pass %.6f us\n", pfx, tid, metric, (sumv[idx] / cntv[idx])
        printf "%s-%s-%s-max pass %s us\n", pfx, tid, metric, maxv[idx]
      }
    }
  ' "$infile" 2>/dev/null | while IFS= read -r line; do
    kpi=$(printf '%s\n' "$line" | awk '{print $1}')
    stat=$(printf '%s\n' "$line" | awk '{print $2}')
    num=$(printf '%s\n' "$line" | awk '{print $3}')
    unit=$(printf '%s\n' "$line" | awk '{print $4}')

    if [ -n "$kpi" ] && [ "$stat" = "pass" ] && [ -n "$num" ] && [ -n "$unit" ]; then
      num2=$(rt_fmt_num "$num")
      printf '%s pass %s %s\n' "$kpi" "$num2" "$unit"
    else
      printf '%s\n' "$line"
    fi
  done
}

# ---------------------------------------------------------------------------
# rt_require_duration_seconds <testname> <duration_string>
# Convert a wrapper duration string to integer seconds.
# Logs FAIL and returns 1 for invalid values.
# ---------------------------------------------------------------------------
rt_require_duration_seconds() {
  testname=$1
  duration_str=$2

  duration_secs=$(rt_duration_to_seconds "$duration_str" 2>/dev/null)

  case "$duration_secs" in
    ''|*[!0-9]*|0)
      log_fail "$testname: invalid duration '$duration_str'"
      return 1
      ;;
  esac

  printf '%s\n' "$duration_secs"
  return 0
}

# ---------------------------------------------------------------------------
# perf_parse_rt_tests_json <testname> <json_file>
# Parse rt-tests style JSON output and emit KPI lines.
# ---------------------------------------------------------------------------
perf_parse_rt_tests_json() {
  testname=$1
  jsonfile=$2

  [ -n "$testname" ] || return 1
  [ -n "$jsonfile" ] || return 1
  [ -r "$jsonfile" ] || return 1

  rt_json_get_top_num() {
    key=$1
    awk -v k="$key" '
      {
        s=$0
        while (match(s, "\"" k "\"[[:space:]]*:[[:space:]]*\"?-?[0-9]+(\\.[0-9]+)?\"?")) {
          m=substr(s, RSTART, RLENGTH)
          sub(/.*:[[:space:]]*\"?/, "", m)
          sub(/\"?$/, "", m)
          print m
          exit
        }
      }
    ' "$jsonfile" 2>/dev/null | head -n 1
  }

  printed=0

  thread_lines=$(
    awk '
      function brace_delta(s, t,o,c) {
        t=s; o=gsub(/\{/, "", t)
        t=s; c=gsub(/\}/, "", t)
        return (o - c)
      }

      function extract_tid(line, t) {
        t=line
        sub(/^[[:space:]]*"/, "", t)
        sub(/".*$/, "", t)
        return t
      }

      function extract_num(line, m) {
        if (match(line, /:[[:space:]]*-?[0-9]+(\.[0-9]+)?/)) {
          m=substr(line, RSTART, RLENGTH)
          sub(/^:[[:space:]]*/, "", m)
          gsub(/[[:space:]]/, "", m)
          return m
        }
        return ""
      }

      BEGIN {
        in_thread=0
        thread_depth=0
        in_tid=0
        tid=""
        tid_depth=0
        in_recv=0
        recv_depth=0
        min=""
        avg=""
        max=""
      }

      {
        line=$0
        gsub(/\r/, "", line)

        if (!in_thread) {
          if (match(line, /"thread"[[:space:]]*:[[:space:]]*\{/)) {
            in_thread=1
            s=substr(line, RSTART)
            b=index(s, "{")
            if (b > 0) {
              chunk=substr(s, b)
              thread_depth = brace_delta(chunk)
            } else {
              thread_depth = 1
            }
          }
          next
        }

        thread_depth += brace_delta(line)

        if (!in_tid && match(line, /^[[:space:]]*"[0-9][0-9]*"[[:space:]]*:[[:space:]]*\{/)) {
          tid = extract_tid(line)
          min=""; avg=""; max=""
          in_tid=1

          s3=line
          b3=index(s3, "{")
          if (b3 > 0) {
            chunk3=substr(s3, b3)
            tid_depth = brace_delta(chunk3)
          } else {
            tid_depth = 1
          }

          in_recv=0
          recv_depth=0
          next
        }

        if (in_tid) {
          tid_depth += brace_delta(line)

          if (!in_recv && match(line, /"receiver"[[:space:]]*:[[:space:]]*\{/)) {
            in_recv=1
            s2=substr(line, RSTART)
            b2=index(s2, "{")
            if (b2 > 0) {
              chunk2=substr(s2, b2)
              recv_depth = brace_delta(chunk2)
            } else {
              recv_depth = 1
            }
            next
          }

          if (in_recv) {
            if (min=="" && line ~ /"min"[[:space:]]*:/) { n=extract_num(line); if (n!="") min=n }
            else if (avg=="" && line ~ /"avg"[[:space:]]*:/) { n=extract_num(line); if (n!="") avg=n }
            else if (max=="" && line ~ /"max"[[:space:]]*:/) { n=extract_num(line); if (n!="") max=n }

            recv_depth += brace_delta(line)
            if (recv_depth <= 0) {
              in_recv=0
              recv_depth=0
            }
          } else {
            if (min=="" && line ~ /^[[:space:]]*"min"[[:space:]]*:/) { n=extract_num(line); if (n!="") min=n }
            else if (avg=="" && line ~ /^[[:space:]]*"avg"[[:space:]]*:/) { n=extract_num(line); if (n!="") avg=n }
            else if (max=="" && line ~ /^[[:space:]]*"max"[[:space:]]*:/) { n=extract_num(line); if (n!="") max=n }
          }

          if (tid_depth <= 0) {
            if (tid != "") {
              if (min != "") printf "t%s-min-latency pass %s us\n", tid, min
              if (avg != "") printf "t%s-avg-latency pass %s us\n", tid, avg
              if (max != "") printf "t%s-max-latency pass %s us\n", tid, max
            }
            in_tid=0
            tid=""
            tid_depth=0
            in_recv=0
            recv_depth=0
            min=""; avg=""; max=""
          }
        }

        if (thread_depth <= 0) {
          exit
        }
      }
    ' "$jsonfile" 2>/dev/null
  )

  if [ -n "$thread_lines" ]; then
    printf '%s\n' "$thread_lines"
    printed=1
  fi

  if [ "$printed" -ne 1 ] 2>/dev/null; then
    one=$(
      tr '\n' ' ' <"$jsonfile" 2>/dev/null | awk '
        function getnum(s, key, m) {
          if (match(s, "\"" key "\"[[:space:]]*:[[:space:]]*\"?-?[0-9]+(\\.[0-9]+)?\"?")) {
            m=substr(s, RSTART, RLENGTH)
            sub(/.*:[[:space:]]*\"?/, "", m)
            sub(/\"?$/, "", m)
            return m
          }
          return ""
        }
        {
          s=$0
          min=getnum(s, "min")
          avg=getnum(s, "avg")
          max=getnum(s, "max")
          if (min!="" || avg!="" || max!="") {
            print "0|" min "|" avg "|" max
            exit
          }
        }
      ' 2>/dev/null
    )

    if [ -n "$one" ]; then
      tid=$(printf '%s' "$one" | awk -F'|' '{print $1}')
      min=$(printf '%s' "$one" | awk -F'|' '{print $2}')
      avg=$(printf '%s' "$one" | awk -F'|' '{print $3}')
      max=$(printf '%s' "$one" | awk -F'|' '{print $4}')
      [ -n "$min" ] && echo "t${tid}-min-latency pass ${min} us"
      [ -n "$avg" ] && echo "t${tid}-avg-latency pass ${avg} us"
      [ -n "$max" ] && echo "t${tid}-max-latency pass ${max} us"
    fi
  fi

  inv=$(rt_json_get_top_num inversion)
  [ -n "$inv" ] && echo "inversion pass ${inv} count"

  rc=$(rt_json_get_top_num return_code)
  [ -n "$rc" ] || rc=$(rt_json_get_top_num return)

  PERF_RT_RETURN_CODE="${rc:-}"
  export PERF_RT_RETURN_CODE

  case "$rc" in
    0|0.0)
      echo "${testname}-ok pass 1 ok"
      echo "${testname}-rc pass 0 rc"
      echo "$testname pass"
      ;;
    *)
      echo "${testname}-ok pass 0 ok"
      if [ -n "$rc" ]; then
        echo "${testname}-rc pass ${rc} rc"
      else
        echo "${testname}-rc pass -1 rc"
      fi
      echo "$testname fail"
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# rt_require_common_tools <tool> [tool...]
# Check that all requested tools are available.
# ---------------------------------------------------------------------------
rt_require_common_tools() {
  if command -v check_dependencies >/dev/null 2>&1; then
    if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$@"; then
      return 1
    fi
    return 0
  fi

  for rt_tool in "$@"; do
    if ! command -v "$rt_tool" >/dev/null 2>&1; then
      return 1
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# rt_require_json_helpers
# Ensure the JSON parser and latency aggregate helpers exist.
# ---------------------------------------------------------------------------
rt_require_json_helpers() {
  if ! command -v perf_parse_rt_tests_json >/dev/null 2>&1; then
    log_skip "RT helper missing: perf_parse_rt_tests_json"
    return 1
  fi

  if ! command -v rt_aggregate_iter_latencies >/dev/null 2>&1; then
    log_skip "RT helper missing: rt_aggregate_iter_latencies"
    return 1
  fi

  if ! command -v rt_aggregate_iter_latencies_per_thread >/dev/null 2>&1; then
    log_skip "RT helper missing: rt_aggregate_iter_latencies_per_thread"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# rt_require_stream_helpers
# Ensure streaming helper exists.
# ---------------------------------------------------------------------------
rt_require_stream_helpers() {
  if ! command -v rt_stream_run_json >/dev/null 2>&1; then
    log_skip "RT helper missing: rt_stream_run_json"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# rt_normalize_common_params
# Normalize common wrapper environment variables to safe defaults.
# ---------------------------------------------------------------------------
rt_normalize_common_params() {
  case "${INTERVAL:-}" in ''|*[!0-9]*) INTERVAL=1000 ;; esac
  case "${STEP:-}" in ''|*[!0-9]*) STEP=500 ;; esac
  case "${THREADS:-}" in ''|*[!0-9]*) THREADS=1 ;; esac
  case "${ITERATIONS:-}" in ''|*[!0-9]*|0) ITERATIONS=1 ;; esac
  case "${PROGRESS_EVERY:-}" in ''|*[!0-9]*|0) PROGRESS_EVERY=1 ;; esac
  case "${HEARTBEAT_SEC:-}" in ''|*[!0-9]*|0) HEARTBEAT_SEC=10 ;; esac
  case "${USER_BASELINE:-}" in '' ) ;; *[!0-9.]* ) USER_BASELINE="" ;; esac

  if [ "$THREADS" -eq 0 ] 2>/dev/null; then
    if command -v nproc >/dev/null 2>&1; then
      THREADS=$(nproc 2>/dev/null || echo 0)
    else
      THREADS=0
    fi
    case "$THREADS" in ''|*[!0-9]*|0) THREADS=1 ;; esac
  fi

  export INTERVAL STEP THREADS ITERATIONS PROGRESS_EVERY HEARTBEAT_SEC USER_BASELINE
  return 0
}

# ---------------------------------------------------------------------------
# rt_resolve_binary <binary-name> <explicit-path>
# Resolve a binary path either from an explicit path or PATH lookup.
# ---------------------------------------------------------------------------
rt_resolve_binary() {
  bin_name=$1
  explicit_bin=$2

  if [ -n "$explicit_bin" ]; then
    if [ -x "$explicit_bin" ]; then
      printf '%s\n' "$explicit_bin"
      return 0
    fi
    return 1
  fi

  if command -v "$bin_name" >/dev/null 2>&1; then
    resolved_bin=$(command -v "$bin_name" 2>/dev/null || echo "")
    if [ -n "$resolved_bin" ] && [ -x "$resolved_bin" ]; then
      printf '%s\n' "$resolved_bin"
      return 0
    fi
  fi

  return 1
}

# ---------------------------------------------------------------------------
# rt_prepare_output_layout <outdir> <result_txt> [extra files...]
# Create output directories and truncate result/log files.
# ---------------------------------------------------------------------------
rt_prepare_output_layout() {
  rt_out_dir=$1
  rt_result_txt=$2
  shift 2

  if [ -n "$rt_out_dir" ]; then
    mkdir -p "$rt_out_dir" 2>/dev/null || true
  fi

  if [ -n "$rt_result_txt" ]; then
    mkdir -p "$(dirname "$rt_result_txt")" 2>/dev/null || true
    : >"$rt_result_txt" 2>/dev/null || true
  fi

  while [ "$#" -gt 0 ]; do
    rt_file=$1
    shift
    if [ -n "$rt_file" ]; then
      mkdir -p "$(dirname "$rt_file")" 2>/dev/null || true
      : >"$rt_file" 2>/dev/null || true
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# rt_log_common_runtime_env <testname> <binary-path>
# Emit common environment and runtime metadata for debugging.
# ---------------------------------------------------------------------------
rt_log_common_runtime_env() {
  testname=$1
  rt_bin=$2

  [ -n "$testname" ] || testname="RTTest"

  if command -v rt_log_kernel_rt_status >/dev/null 2>&1; then
    rt_log_kernel_rt_status || true
  fi

  log_info "$testname: uname -a: $(uname -a 2>/dev/null || echo n/a)"
  log_info "$testname: sched_rt_runtime_us=$(cat /proc/sys/kernel/sched_rt_runtime_us 2>/dev/null || echo n/a)"
  log_info "$testname: sched_rt_period_us=$(cat /proc/sys/kernel/sched_rt_period_us 2>/dev/null || echo n/a)"

  rt_memlock_line=$(awk '
    $1=="Max" && $2=="locked" && $3=="memory" {
      soft=$4; hard=$5; unit=$6
      if (soft=="" || hard=="") print "n/a"
      else printf("%s/%s %s\n", soft, hard, unit)
      exit
    }
  ' /proc/self/limits 2>/dev/null)

  [ -n "$rt_memlock_line" ] || rt_memlock_line="n/a"
  log_info "$testname: memlock(soft/hard)=$rt_memlock_line"

  if command -v nproc >/dev/null 2>&1; then
    log_info "$testname: nproc=$(nproc 2>/dev/null || echo n/a)"
  else
    log_info "$testname: nproc=n/a"
  fi

  log_info "$testname: cpu_online=$(cat /sys/devices/system/cpu/online 2>/dev/null || echo n/a)"
  rt_gov0=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo n/a)
  log_info "$testname: governor0=$rt_gov0"

  if [ -n "$rt_bin" ]; then
    log_info "$testname: BIN=$rt_bin"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# rt_start_heartbeat <testname> <heartbeat-sec>
# Start background heartbeat progress reporting.
# Prefer writing inline progress to /dev/tty when available.
# Otherwise stay silent and rely on the final completion line.
# ---------------------------------------------------------------------------
rt_start_heartbeat() {
  testname=$1
  heartbeat_sec=$2

  [ -n "$testname" ] || testname="RTTest"
  case "$heartbeat_sec" in ''|*[!0-9]*|0) heartbeat_sec=10 ;; esac

  rt_stop_heartbeat >/dev/null 2>&1 || true

  RT_HEARTBEAT_INLINE=0
  RT_HEARTBEAT_TTY=""
  if [ -c /dev/tty ] && [ -w /dev/tty ]; then
    RT_HEARTBEAT_INLINE=1
    RT_HEARTBEAT_TTY="/dev/tty"
  fi
  export RT_HEARTBEAT_INLINE RT_HEARTBEAT_TTY

  (
    elapsed=0
    while :; do
      sleep "$heartbeat_sec"
      elapsed=$((elapsed + heartbeat_sec))

      if [ "${RT_HEARTBEAT_INLINE:-0}" -eq 1 ] 2>/dev/null && [ -n "${RT_HEARTBEAT_TTY:-}" ]; then
        printf '\r[INFO] %s: elapsed %ss' "$testname" "$elapsed" >"$RT_HEARTBEAT_TTY"
      fi
    done
  ) &
  RT_HEARTBEAT_PID=$!
  export RT_HEARTBEAT_PID
  return 0
}

# ---------------------------------------------------------------------------
# rt_stop_heartbeat
# Stop heartbeat progress reporting.
# ---------------------------------------------------------------------------
rt_stop_heartbeat() {
  if [ -n "${RT_HEARTBEAT_PID:-}" ]; then
    kill "$RT_HEARTBEAT_PID" 2>/dev/null || true
    wait "$RT_HEARTBEAT_PID" 2>/dev/null || true
  fi

  if [ "${RT_HEARTBEAT_INLINE:-0}" -eq 1 ] 2>/dev/null && [ -n "${RT_HEARTBEAT_TTY:-}" ]; then
    printf '\r\033[K' >"$RT_HEARTBEAT_TTY"
  fi

  RT_HEARTBEAT_PID=""
  RT_HEARTBEAT_INLINE=0
  RT_HEARTBEAT_TTY=""
  export RT_HEARTBEAT_PID RT_HEARTBEAT_INLINE RT_HEARTBEAT_TTY
  return 0
}

# ---------------------------------------------------------------------------
# rt_heartbeat_render <testname> <elapsed-sec>
# Render a single-line elapsed timer to /dev/tty when available.
# ---------------------------------------------------------------------------
rt_heartbeat_render() {
  testname=$1
  elapsed=$2

  if [ -c /dev/tty ] && [ -w /dev/tty ]; then
    printf '\r[INFO] %s: elapsed %ss' "$testname" "$elapsed" > /dev/tty
  fi
}

# ---------------------------------------------------------------------------
# rt_heartbeat_clear
# Clear the single-line elapsed timer from /dev/tty when available.
# ---------------------------------------------------------------------------
rt_heartbeat_clear() {
  if [ -c /dev/tty ] && [ -w /dev/tty ]; then
    printf '\r\033[K' > /dev/tty
  fi
}

# ---------------------------------------------------------------------------
# rt_run_and_capture <testname> <heartbeat-sec> <stdoutlog> <cmd> [args...]
# Run a command, capture stdout/stderr to stdoutlog, and preserve exit status.
# ---------------------------------------------------------------------------
rt_run_and_capture() {
  testname=$1
  heartbeat_sec=$2
  stdoutlog=$3
  shift 3

  RT_RUN_RC=1
  RT_RUN_STDOUTLOG="$stdoutlog"
  export RT_RUN_RC RT_RUN_STDOUTLOG

  [ -n "$testname" ] || testname="RTTest"
  case "$heartbeat_sec" in
    ''|*[!0-9]*|0)
      heartbeat_sec=10
      ;;
  esac
  [ -n "$stdoutlog" ] || return 1
  [ "$#" -gt 0 ] || return 1

  mkdir -p "$(dirname "$stdoutlog")" 2>/dev/null || true
  : >"$stdoutlog" 2>/dev/null || true

  RT_CUR_TESTNAME="$testname"
  export RT_CUR_TESTNAME

  start_ts=$(date +%s 2>/dev/null || echo 0)

  "$@" >"$stdoutlog" 2>&1 &
  run_pid=$!
  RT_CUR_BIN_PID="$run_pid"
  export RT_CUR_BIN_PID

  case "$run_pid" in
    ''|*[!0-9]*)
      log_fail "$testname: failed to start test binary"
      RT_RUN_RC=1
      RT_CUR_BIN_PID=""
      export RT_RUN_RC RT_CUR_BIN_PID
      return 1
      ;;
  esac

  while kill -0 "$run_pid" 2>/dev/null; do
    sleep "$heartbeat_sec"
    if kill -0 "$run_pid" 2>/dev/null; then
      now_ts=$(date +%s 2>/dev/null || echo 0)
      if [ "$start_ts" -gt 0 ] 2>/dev/null && [ "$now_ts" -ge "$start_ts" ] 2>/dev/null; then
        elapsed=$((now_ts - start_ts))
        rt_heartbeat_render "$testname" "$elapsed"
      fi
    fi
  done

  wait "$run_pid"
  RT_RUN_RC=$?
  export RT_RUN_RC

  end_ts=$(date +%s 2>/dev/null || echo 0)
  rt_heartbeat_clear

  RT_CUR_BIN_PID=""
  export RT_CUR_BIN_PID

  if [ -n "${RT_RUN_TARGET_DURATION_SECS:-}" ]; then
    log_info "$testname: completed requested duration ${RT_RUN_TARGET_DURATION_SECS}s"

    if [ "${VERBOSE:-0}" -eq 1 ] 2>/dev/null && \
       [ "$start_ts" -gt 0 ] 2>/dev/null && \
       [ "$end_ts" -ge "$start_ts" ] 2>/dev/null; then
      elapsed=$((end_ts - start_ts))
      log_info "$testname: actual elapsed ${elapsed}s"
    fi
  else
    if [ "$start_ts" -gt 0 ] 2>/dev/null && [ "$end_ts" -ge "$start_ts" ] 2>/dev/null; then
      elapsed=$((end_ts - start_ts))
      log_info "$testname: completed after ${elapsed}s"
    fi
  fi

  if [ "$RT_RUN_RC" -ne 0 ] 2>/dev/null; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# rt_run_json_iteration <testname> <heartbeat-sec> <stdoutlog> <jsonfile> <cmd> [args...]
# Runs a single RT test iteration directly, emits heartbeat progress while the
# binary is alive, and exports:
# RT_RUN_RC
# RT_RUN_JSON_OK
# RT_RUN_STDOUTLOG
# RT_RUN_JSONFILE
# Supports Ctrl-C via rt_handle_int().
# ---------------------------------------------------------------------------
rt_run_json_iteration() {
  testname=$1
  heartbeat_sec=$2
  stdoutlog=$3
  jsonfile=$4
  shift 4

  RT_RUN_RC=1
  RT_RUN_JSON_OK=0
  RT_RUN_STDOUTLOG="$stdoutlog"
  RT_RUN_JSONFILE="$jsonfile"
  export RT_RUN_RC RT_RUN_JSON_OK RT_RUN_STDOUTLOG RT_RUN_JSONFILE

  [ -n "$testname" ] || testname="RTTest"

  case "$heartbeat_sec" in
    ''|*[!0-9]*|0)
      heartbeat_sec=10
      ;;
  esac

  [ -n "$stdoutlog" ] || return 1
  [ -n "$jsonfile" ] || return 1
  [ "$#" -gt 0 ] || return 1

  mkdir -p "$(dirname "$stdoutlog")" 2>/dev/null || true
  mkdir -p "$(dirname "$jsonfile")" 2>/dev/null || true
  : >"$stdoutlog" 2>/dev/null || true

  RT_CUR_TESTNAME="$testname"
  export RT_CUR_TESTNAME

  start_ts=$(date +%s 2>/dev/null || echo 0)

  "$@" >"$stdoutlog" 2>&1 &
  run_pid=$!
  RT_CUR_BIN_PID="$run_pid"
  export RT_CUR_BIN_PID

  case "$run_pid" in
    ''|*[!0-9]*)
      log_fail "$testname: failed to start test binary"
      RT_RUN_RC=1
      RT_CUR_BIN_PID=""
      export RT_RUN_RC RT_CUR_BIN_PID
      return 1
      ;;
  esac

  while kill -0 "$run_pid" 2>/dev/null; do
    sleep "$heartbeat_sec"
    if kill -0 "$run_pid" 2>/dev/null; then
      now_ts=$(date +%s 2>/dev/null || echo 0)
      if [ "$start_ts" -gt 0 ] 2>/dev/null && [ "$now_ts" -ge "$start_ts" ] 2>/dev/null; then
        elapsed=$((now_ts - start_ts))
        rt_heartbeat_render "$testname" "$elapsed"
      fi
    fi
  done

  wait "$run_pid"
  RT_RUN_RC=$?
  export RT_RUN_RC

  end_ts=$(date +%s 2>/dev/null || echo 0)
  rt_heartbeat_clear

  RT_CUR_BIN_PID=""
  export RT_CUR_BIN_PID

  if [ -n "${RT_RUN_TARGET_DURATION_SECS:-}" ]; then
    log_info "$testname: completed requested duration ${RT_RUN_TARGET_DURATION_SECS}s"

    if [ "${VERBOSE:-0}" -eq 1 ] 2>/dev/null && \
       [ "$start_ts" -gt 0 ] 2>/dev/null && \
       [ "$end_ts" -ge "$start_ts" ] 2>/dev/null; then
      elapsed=$((end_ts - start_ts))
      log_info "$testname: actual elapsed ${elapsed}s"
    fi
  else
    if [ "$start_ts" -gt 0 ] 2>/dev/null && [ "$end_ts" -ge "$start_ts" ] 2>/dev/null; then
      elapsed=$((end_ts - start_ts))
      log_info "$testname: completed after ${elapsed}s"
    fi
  fi

  if [ -r "$jsonfile" ]; then
    RT_RUN_JSON_OK=1
  else
    RT_RUN_JSON_OK=0
  fi
  export RT_RUN_JSON_OK

  if [ "$RT_RUN_RC" -ne 0 ] 2>/dev/null; then
    return 1
  fi

  if [ "$RT_RUN_JSON_OK" -ne 1 ] 2>/dev/null; then
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# rt_run_streaming_iteration <testname> <heartbeat-sec> <stdoutlog> <jsonfile> <cmd> [args...]
# Run a JSON-producing test iteration with live streamed output.
# ---------------------------------------------------------------------------
rt_run_streaming_iteration() {
  testname=$1
  heartbeat_sec=$2
  stdoutlog=$3
  jsonfile=$4
  shift 4

  RT_RUN_RC=1
  RT_RUN_JSON_OK=0
  RT_RUN_STDOUTLOG="$stdoutlog"
  RT_RUN_JSONFILE="$jsonfile"
  export RT_RUN_RC RT_RUN_JSON_OK RT_RUN_STDOUTLOG RT_RUN_JSONFILE

  [ -n "$testname" ] || testname="RTTest"
  case "$heartbeat_sec" in ''|*[!0-9]*|0) heartbeat_sec=10 ;; esac
  [ -n "$stdoutlog" ] || return 1
  [ -n "$jsonfile" ] || return 1
  [ "$#" -gt 0 ] || return 1

  mkdir -p "$(dirname "$stdoutlog")" 2>/dev/null || true
  mkdir -p "$(dirname "$jsonfile")" 2>/dev/null || true
  : >"$stdoutlog" 2>/dev/null || true

  RT_CUR_TESTNAME="$testname"
  export RT_CUR_TESTNAME

  rt_stream_run_json "$stdoutlog" "$@" &
  run_pid=$!

  case "$run_pid" in
    ''|*[!0-9]*)
      log_fail "$testname: failed to start streaming test helper"
      return 1
      ;;
  esac

  start_ts=$(date +%s 2>/dev/null || echo 0)

  rt_start_heartbeat "$testname" "$heartbeat_sec"
  while kill -0 "$run_pid" 2>/dev/null; do
    sleep 1
  done

  wait "$run_pid"
  RT_RUN_RC=$?
  export RT_RUN_RC
  end_ts=$(date +%s 2>/dev/null || echo 0)
  rt_stop_heartbeat

  if [ "$start_ts" -gt 0 ] 2>/dev/null && [ "$end_ts" -ge "$start_ts" ] 2>/dev/null; then
    elapsed=$((end_ts - start_ts))
    log_info "$testname: completed after ${elapsed}s"
  fi

  if [ -r "$jsonfile" ]; then
    RT_RUN_JSON_OK=1
  else
    RT_RUN_JSON_OK=0
  fi
  export RT_RUN_JSON_OK

  if [ "$RT_RUN_RC" -ne 0 ] 2>/dev/null; then
    return 1
  fi
  if [ "$RT_RUN_JSON_OK" -ne 1 ] 2>/dev/null; then
    return 1
  fi
  return 0
}

rt_run_json_iteration_streaming() {
  rt_run_streaming_iteration "$@"
}

# ---------------------------------------------------------------------------
# rt_log_iteration_progress <testname> <iter-num> <total-iters> <progress-every> [label]
# Emit controlled iteration progress logs.
# ---------------------------------------------------------------------------
rt_log_iteration_progress() {
  testname=$1
  iter_num=$2
  total_iters=$3
  progress_every=$4
  label=${5:-starting}

  [ -n "$testname" ] || testname="RTTest"
  case "$iter_num" in ''|*[!0-9]*) return 0 ;; esac
  case "$total_iters" in ''|*[!0-9]*|0) total_iters=1 ;; esac
  case "$progress_every" in ''|*[!0-9]*|0) progress_every=1 ;; esac

  if [ "$iter_num" -eq 1 ] 2>/dev/null || [ "$iter_num" -eq "$total_iters" ] 2>/dev/null; then
    log_info "$testname: iteration $iter_num/$total_iters $label"
    return 0
  fi

  rem=$((iter_num % progress_every))
  if [ "$rem" -eq 0 ] 2>/dev/null; then
    log_info "$testname: iteration $iter_num/$total_iters $label"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# rt_append_iteration_kpi <iter-num> <tmp_one> <iter_kpi> <result_txt>
# Prefix parsed KPI lines with iteration-N- and append them to iter_kpi/result.
# ---------------------------------------------------------------------------
rt_append_iteration_kpi() {
  iter_num=$1
  tmp_one=$2
  iter_kpi=$3
  result_txt=$4

  [ -n "$iter_num" ] || return 1
  [ -r "$tmp_one" ] || return 1
  [ -n "$iter_kpi" ] || return 1
  [ -n "$result_txt" ] || return 1

  awk -v p="iteration-${iter_num}-" 'NF { print p $0 }' "$tmp_one" >>"$iter_kpi" 2>/dev/null || return 1
  awk -v p="iteration-${iter_num}-" 'NF { print p $0 }' "$tmp_one" >>"$result_txt" 2>/dev/null || return 1
  return 0
}

# ---------------------------------------------------------------------------
# rt_parse_and_append_iteration_kpi <prefix> <jsonfile> <tmp_one> <iter_kpi> <result_txt> <iter-num>
# Parse a JSON file using perf_parse_rt_tests_json() and store iteration-tagged KPI lines.
# ---------------------------------------------------------------------------
rt_parse_and_append_iteration_kpi() {
  prefix=$1
  jsonfile=$2
  tmp_one=$3
  iter_kpi=$4
  result_txt=$5
  iter_num=$6

  [ -n "$prefix" ] || return 1
  [ -r "$jsonfile" ] || return 1
  [ -n "$tmp_one" ] || return 1
  [ -n "$iter_kpi" ] || return 1
  [ -n "$result_txt" ] || return 1
  [ -n "$iter_num" ] || return 1

  : >"$tmp_one" 2>/dev/null || true
  if ! perf_parse_rt_tests_json "$prefix" "$jsonfile" >"$tmp_one" 2>/dev/null; then
    return 1
  fi

  rt_append_iteration_kpi "$iter_num" "$tmp_one" "$iter_kpi" "$result_txt"
}

# ---------------------------------------------------------------------------
# rt_kpi_file_has_fail <prefix> <kpi-file>
# Return success if the KPI file contains a fail line for the prefix.
# ---------------------------------------------------------------------------
rt_kpi_file_has_fail() {
  prefix=$1
  kpi_file=$2
  [ -n "$prefix" ] || return 1
  [ -r "$kpi_file" ] || return 1
  grep -Eq "^iteration-[0-9]+-${prefix}[[:space:]]+fail$|^${prefix}[[:space:]]+fail$" "$kpi_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# rt_emit_kpi_block <testname> <title> <file>
# Print a KPI block through rt_print_kpi_block() if available, otherwise via log_info.
# ---------------------------------------------------------------------------
rt_emit_kpi_block() {
  testname=$1
  title=$2
  file=$3

  [ -n "$file" ] || return 0
  [ -s "$file" ] || return 0

  if command -v rt_print_kpi_block >/dev/null 2>&1; then
    rt_print_kpi_block "$testname" "$title" "$file"
    return 0
  fi

  log_info "$testname: ---------------- ${title} ----------------"
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      log_info "$testname: $line"
    fi
  done <"$file"
  log_info "$testname: ------------------------------------------------------"
  return 0
}

# ---------------------------------------------------------------------------
# rt_emit_aggregate_kpi <testname> <prefix> <iter_kpi> <agg_kpi> <result_txt>
# Aggregate per-iteration latencies across all threads and iterations.
# ---------------------------------------------------------------------------
rt_emit_aggregate_kpi() {
  testname=$1
  prefix=$2
  iter_kpi=$3
  agg_kpi=$4
  result_txt=$5

  : >"$agg_kpi" 2>/dev/null || true

  if rt_aggregate_iter_latencies "$prefix" "$iter_kpi" >"$agg_kpi" 2>/dev/null; then
    if [ -s "$agg_kpi" ]; then
      cat "$agg_kpi" >>"$result_txt" 2>/dev/null || true
      rt_emit_kpi_block "$testname" "aggregate results" "$agg_kpi"
    fi
    return 0
  fi

  log_warn "$testname: aggregate KPI generation failed (rt_aggregate_iter_latencies)"
  return 1
}

# ---------------------------------------------------------------------------
# rt_emit_thread_aggregate_kpi <testname> <prefix> <iter_kpi> <thread_agg_kpi> <result_txt>
# Aggregate per-thread latencies across iterations.
# ---------------------------------------------------------------------------
rt_emit_thread_aggregate_kpi() {
  testname=$1
  prefix=$2
  iter_kpi=$3
  thread_agg_kpi=$4
  result_txt=$5

  : >"$thread_agg_kpi" 2>/dev/null || true

  if rt_aggregate_iter_latencies_per_thread "$prefix" "$iter_kpi" >"$thread_agg_kpi" 2>/dev/null; then
    if [ -s "$thread_agg_kpi" ]; then
      cat "$thread_agg_kpi" >>"$result_txt" 2>/dev/null || true
      rt_emit_kpi_block "$testname" "per-thread aggregate results" "$thread_agg_kpi"
    fi
    return 0
  fi

  log_warn "$testname: per-thread aggregate KPI generation failed (rt_aggregate_iter_latencies_per_thread)"
  return 1
}

# ---------------------------------------------------------------------------
# rt_append_named_metric <name> <value> <unit> <out_file>
# Append a single KPI line to a file.
# ---------------------------------------------------------------------------
rt_append_named_metric() {
  name=$1
  value=$2
  unit=$3
  out_file=$4

  [ -n "$name" ] || return 1
  [ -n "$value" ] || return 1
  [ -n "$out_file" ] || return 1

  if [ -n "$unit" ]; then
    echo "$name pass $value $unit" >>"$out_file" 2>/dev/null || return 1
  else
    echo "$name pass $value" >>"$out_file" 2>/dev/null || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# rt_emit_pass_fail_result <testname> <res_file> <result_txt> <out_dir> <overall_fail>
# Emit final PASS/FAIL result and update the .res file.
# ---------------------------------------------------------------------------
rt_emit_pass_fail_result() {
  testname=$1
  res_file=$2
  result_txt=$3
  out_dir=$4
  overall_fail=$5

  [ -n "$testname" ] || testname="RTTest"
  [ -n "$res_file" ] || return 1

  if [ "$overall_fail" -eq 0 ] 2>/dev/null; then
    log_pass "$testname: PASS"
    echo "$testname PASS" >"$res_file"
  else
    if [ -n "$out_dir" ]; then
      log_fail "$testname: FAIL (see $result_txt and $out_dir)"
    else
      log_fail "$testname: FAIL (see $result_txt)"
    fi
    echo "$testname FAIL" >"$res_file"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# rt_emit_interrupt_aware_result <testname> <res_file> <result_txt> <out_dir> <interrupted> <overall_fail>
# Emit SKIP for user interrupt, otherwise defer to normal PASS/FAIL emission.
# ---------------------------------------------------------------------------
rt_emit_interrupt_aware_result() {
  testname=$1
  res_file=$2
  result_txt=$3
  out_dir=$4
  interrupted=$5
  overall_fail=$6

  [ -n "$testname" ] || testname="RTTest"
  [ -n "$res_file" ] || return 1

  if [ "$interrupted" -eq 1 ] 2>/dev/null; then
    log_skip "$testname: SKIP (interrupted by user; partial results kept in $result_txt)"
    echo "$testname SKIP" >"$res_file"
    return 0
  fi

  rt_emit_pass_fail_result "$testname" "$res_file" "$result_txt" "$out_dir" "$overall_fail"
}

# ---------------------------------------------------------------------------
# rt_extract_numeric_samples_from_log <logfile> <token> <out_file>
# Extract numeric samples from a logfile where the numeric value follows token.
# ---------------------------------------------------------------------------
rt_extract_numeric_samples_from_log() {
  logfile=$1
  token=$2
  out_file=$3

  [ -r "$logfile" ] || return 1
  [ -n "$token" ] || return 1
  [ -n "$out_file" ] || return 1

  : >"$out_file" 2>/dev/null || true

  awk -v tok="$token" '
    function isnum(x) { return (x ~ /^-?[0-9]+(\.[0-9]+)?$/) }
    {
      for (i=1; i<=NF; i++) {
        if ($i == tok) {
          v=$(i+1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if (isnum(v)) print v
        } else if ($i ~ ("^" tok "[0-9]")) {
          v=$i
          sub("^" tok, "", v)
          if (isnum(v)) print v
        }
      }
    }
  ' "$logfile" >"$out_file" 2>/dev/null

  [ -s "$out_file" ]
}

# ---------------------------------------------------------------------------
# rt_emit_numeric_summary <metric_prefix> <values_file> <unit> <result_txt> [testname] [parsed_file]
# Compute min/mean/max from a file of numeric values and append KPI lines.
# ---------------------------------------------------------------------------
rt_emit_numeric_summary() {
  metric_prefix=$1
  values_file=$2
  unit=$3
  result_txt=$4
  testname=$5
  parsed_file=$6

  [ -n "$metric_prefix" ] || return 1
  [ -r "$values_file" ] || return 1
  [ -n "$result_txt" ] || return 1

  summary=$(awk '
    BEGIN { min=""; max=""; sum=0; n=0 }
    /^[0-9]+(\.[0-9]+)?$/ {
      v=$1+0
      if (min=="" || v<min) min=v
      if (max=="" || v>max) max=v
      sum+=v
      n++
    }
    END {
      if (n>0) printf("%s|%.6f|%s|%d\n", min, sum/n, max, n)
    }
  ' "$values_file" 2>/dev/null)

  [ -n "$summary" ] || return 1

  s_min=$(printf '%s' "$summary" | awk -F'|' '{print $1}')
  s_mean=$(printf '%s' "$summary" | awk -F'|' '{print $2}')
  s_max=$(printf '%s' "$summary" | awk -F'|' '{print $3}')

  rt_append_named_metric "${metric_prefix}-min" "$(rt_fmt_num "$s_min")" "$unit" "$result_txt" || return 1
  rt_append_named_metric "${metric_prefix}-mean" "$(rt_fmt_num "$s_mean")" "$unit" "$result_txt" || return 1
  rt_append_named_metric "${metric_prefix}-max" "$(rt_fmt_num "$s_max")" "$unit" "$result_txt" || return 1

  if [ -n "$parsed_file" ]; then
    rt_append_named_metric "${metric_prefix}-min" "$(rt_fmt_num "$s_min")" "$unit" "$parsed_file" || true
    rt_append_named_metric "${metric_prefix}-mean" "$(rt_fmt_num "$s_mean")" "$unit" "$parsed_file" || true
    rt_append_named_metric "${metric_prefix}-max" "$(rt_fmt_num "$s_max")" "$unit" "$parsed_file" || true
  fi

  if [ -n "$testname" ]; then
    log_info "$testname: ${metric_prefix}-min pass $(rt_fmt_num "$s_min") $unit"
    log_info "$testname: ${metric_prefix}-mean pass $(rt_fmt_num "$s_mean") $unit"
    log_info "$testname: ${metric_prefix}-max pass $(rt_fmt_num "$s_max") $unit"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# rt_emit_numeric_summary_from_log <metric_prefix> <logfile> <token> <unit> <result_txt> [testname] [parsed_file]
# Extract numeric samples from a log and emit min/mean/max KPI lines.
# ---------------------------------------------------------------------------
rt_emit_numeric_summary_from_log() {
  metric_prefix=$1
  logfile=$2
  token=$3
  unit=$4
  result_txt=$5
  testname=$6
  parsed_file=$7

  values_file="${result_txt}.values.$$"
  if ! rt_extract_numeric_samples_from_log "$logfile" "$token" "$values_file"; then
    rm -f "$values_file" 2>/dev/null || true
    return 1
  fi

  rc=0
  rt_emit_numeric_summary "$metric_prefix" "$values_file" "$unit" "$result_txt" "$testname" "$parsed_file" || rc=1
  rm -f "$values_file" 2>/dev/null || true
  return "$rc"
}

# ---------------------------------------------------------------------------
# rt_emit_worst_sample_from_log <metric_name> <logfile> <token> <unit> <parsed_file> <result_txt> [testname]
# Find the worst sample from a tokenized numeric log stream and emit it as KPI.
# ---------------------------------------------------------------------------
rt_emit_worst_sample_from_log() {
  metric_name=$1
  logfile=$2
  token=$3
  unit=$4
  parsed_file=$5
  result_txt=$6
  testname=$7

  [ -n "$metric_name" ] || return 1
  [ -r "$logfile" ] || return 1
  [ -n "$token" ] || return 1
  [ -n "$result_txt" ] || return 1

  worst_line=$(
    awk -v tok="$token" '
      function isnum(x) { return (x ~ /^-?[0-9]+(\.[0-9]+)?$/) }
      {
        for (i=1; i<=NF; i++) {
          if ($i == tok) {
            v=$(i+1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (isnum(v)) {
              if (max=="" || (v+0) > (max+0)) { max=v; line=$0 }
            }
          } else if ($i ~ ("^" tok "[0-9]")) {
            v=$i
            sub("^" tok, "", v)
            if (isnum(v)) {
              if (max=="" || (v+0) > (max+0)) { max=v; line=$0 }
            }
          }
        }
      }
      END { if (line!="") print line }
    ' "$logfile" 2>/dev/null
  )

  [ -n "$worst_line" ] || return 1

  worst_value=$(printf '%s\n' "$worst_line" | awk -v tok="$token" '
    function isnum(x) { return (x ~ /^-?[0-9]+(\.[0-9]+)?$/) }
    {
      for (i=1; i<=NF; i++) {
        if ($i == tok) {
          v=$(i+1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          if (isnum(v)) { print v; exit }
        } else if ($i ~ ("^" tok "[0-9]")) {
          v=$i
          sub("^" tok, "", v)
          if (isnum(v)) { print v; exit }
        }
      }
    }
  ' 2>/dev/null)

  [ -n "$worst_value" ] || return 1

  rt_append_named_metric "$metric_name" "$worst_value" "$unit" "$result_txt" || return 1
  if [ -n "$parsed_file" ]; then
    rt_append_named_metric "$metric_name" "$worst_value" "$unit" "$parsed_file" || true
  fi

  if [ -n "$testname" ]; then
    log_info "$testname: worst-sample $worst_line"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# rt_parse_token_numeric_samples <metric_prefix> <logfile> <token> <unit>
# Parse tokenized numeric samples from a plain text log and emit KPI lines.
# ---------------------------------------------------------------------------
rt_parse_token_numeric_samples() {
  metric_prefix=$1
  logfile=$2
  token=$3
  unit=$4

  [ -n "$metric_prefix" ] || return 1
  [ -r "$logfile" ] || return 1
  [ -n "$token" ] || return 1

  values_file="${TMPDIR:-/tmp}/rt_samples.$$"
  if ! rt_extract_numeric_samples_from_log "$logfile" "$token" "$values_file"; then
    rm -f "$values_file" 2>/dev/null || true
    return 1
  fi

  summary=$(awk '
    BEGIN { min=""; max=""; sum=0; n=0 }
    /^[0-9]+(\.[0-9]+)?$/ {
      v=$1+0
      if (min=="" || v<min) min=v
      if (max=="" || v>max) max=v
      sum+=v
      n++
    }
    END {
      if (n>0) printf("%s|%.6f|%s\n", min, sum/n, max)
    }
  ' "$values_file" 2>/dev/null)

  rm -f "$values_file" 2>/dev/null || true
  [ -n "$summary" ] || return 1

  s_min=$(printf '%s' "$summary" | awk -F'|' '{print $1}')
  s_mean=$(printf '%s' "$summary" | awk -F'|' '{print $2}')
  s_max=$(printf '%s' "$summary" | awk -F'|' '{print $3}')

  printf '%s-min pass %s %s\n' "$metric_prefix" "$(rt_fmt_num "$s_min")" "$unit"
  printf '%s-mean pass %s %s\n' "$metric_prefix" "$(rt_fmt_num "$s_mean")" "$unit"
  printf '%s-max pass %s %s\n' "$metric_prefix" "$(rt_fmt_num "$s_max")" "$unit"
  return 0
}

# ---------------------------------------------------------------------------
# rt_majority_fail_limit <iterations>
# Return majority fail threshold for N iterations.
# ---------------------------------------------------------------------------
rt_majority_fail_limit() {
  iterations=$1
  case "$iterations" in ''|*[!0-9]*|0) iterations=1 ;; esac
  printf '%s\n' $(((iterations + 1) / 2))
  return 0
}

# ---------------------------------------------------------------------------
# rt_collect_named_metric_values <result_txt> <metric_name> <output_file>
# Extract numeric values for iteration-tagged KPI lines containing metric_name.
# ---------------------------------------------------------------------------
rt_collect_named_metric_values() {
  result_txt=$1
  metric_name=$2
  output_file=$3

  [ -r "$result_txt" ] || return 1
  [ -n "$metric_name" ] || return 1
  [ -n "$output_file" ] || return 1

  mkdir -p "$(dirname "$output_file")" 2>/dev/null || true
  : >"$output_file" 2>/dev/null || true

  awk -v metric="$metric_name" '
    /^iteration-/ {
      if (index($1, metric) > 0 && NF >= 3) {
        print $(NF - 1)
      }
    }
  ' "$result_txt" >"$output_file" 2>/dev/null

  [ -s "$output_file" ]
}

rt_collect_max_latency_values() {
  rt_collect_named_metric_values "$1" "max-latency" "$2"
}

# ---------------------------------------------------------------------------
# rt_evaluate_majority_threshold_gate <testname> <iterations> <values_file> <gate_kpi> <result_txt> <user_baseline> <metric_label> <unit>
# Evaluate a majority-based threshold gate against a set of numeric values.
# ---------------------------------------------------------------------------
rt_evaluate_majority_threshold_gate() {
  testname=$1
  iterations=$2
  values_file=$3
  gate_kpi=$4
  result_txt=$5
  user_baseline=$6
  metric_label=$7
  unit=$8

  RT_BASELINE_VALUE=""
  RT_BASELINE_FAIL_COUNT=""
  RT_BASELINE_FAIL_LIMIT=""
  export RT_BASELINE_VALUE RT_BASELINE_FAIL_COUNT RT_BASELINE_FAIL_LIMIT

  [ -n "$testname" ] || testname="RTTest"
  [ -r "$values_file" ] || return 1
  [ -n "$gate_kpi" ] || return 1
  [ -n "$result_txt" ] || return 1
  [ -n "$metric_label" ] || metric_label="baseline"

  if [ ! -s "$values_file" ]; then
    log_warn "$testname: no metric values found for threshold comparison"
    return 1
  fi

  if [ -n "$user_baseline" ]; then
    baseline_value="$user_baseline"
    log_info "$testname: using user-provided baseline: $baseline_value"
  else
    baseline_value=$(sort -n "$values_file" | head -n 1)
    log_info "$testname: using derived baseline (minimum observed value): $baseline_value"
  fi

  fail_count=$(awk -v b="$baseline_value" '
    BEGIN { c=0 }
    {
      if (($1 + 0) > (b + 0)) c++
    }
    END { print c }
  ' "$values_file")

  fail_limit=$(rt_majority_fail_limit "$iterations")

  RT_BASELINE_VALUE="$baseline_value"
  RT_BASELINE_FAIL_COUNT="$fail_count"
  RT_BASELINE_FAIL_LIMIT="$fail_limit"
  export RT_BASELINE_VALUE RT_BASELINE_FAIL_COUNT RT_BASELINE_FAIL_LIMIT

  : >"$gate_kpi" 2>/dev/null || true
  rt_append_named_metric "${metric_label}-baseline" "$baseline_value" "$unit" "$gate_kpi" || true
  rt_append_named_metric "${metric_label}-fail-limit" "$fail_limit" "count" "$gate_kpi" || true
  rt_append_named_metric "${metric_label}-fail-count" "$fail_count" "count" "$gate_kpi" || true

  cat "$gate_kpi" >>"$result_txt" 2>/dev/null || true
  rt_emit_kpi_block "$testname" "baseline comparison results" "$gate_kpi"

  if [ "$fail_count" -ge "$fail_limit" ] 2>/dev/null; then
    return 1
  fi
  return 0
}

rt_evaluate_baseline_gate() {
  rt_evaluate_majority_threshold_gate "$1" "$2" "$3" "$4" "$5" "$6" "baseline" "us"
}

# ---------------------------------------------------------------------------
# rt_duration_to_seconds <duration>
# Convert compact duration strings like 90, 5m, 1h, 1m30s to integer seconds.
# ---------------------------------------------------------------------------
rt_duration_to_seconds() {
  dur=$1
  dur=$(printf '%s' "$dur" | tr -d '[:space:]' 2>/dev/null)

  [ -n "$dur" ] || {
    echo 0
    return 0
  }

  case "$dur" in
    *[!0-9]*) ;;
    *) echo "$dur"; return 0 ;;
  esac

  printf '%s' "$dur" | awk '
    function add(v,u) {
      if (u=="s") t += v
      else if (u=="m") t += v*60
      else if (u=="h") t += v*3600
      else if (u=="d") t += v*86400
      else ok = 0
    }
    BEGIN { t=0; ok=1 }
    {
      s=$0
      while (match(s, /^[0-9]+[smhd]/)) {
        v = substr(s, 1, RLENGTH-1) + 0
        u = substr(s, RLENGTH, 1)
        add(v,u)
        s = substr(s, RLENGTH+1)
      }
      if (s != "") ok = 0
      if (ok && t >= 0) print int(t)
      else print 0
    }
  ' 2>/dev/null
}
