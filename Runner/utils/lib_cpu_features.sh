#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# cpu_features_views <register-log> <online-cpu-list>
# Require a complete, identical system-wide EL0 view on every selected CPU.
cpu_features_views() {
    awk -v cpus="$2" '
        BEGIN { total = split(cpus, list, /[[:space:]]+/); for (i = 1; i <= total; i++) if (list[i] != "") expected["cpu" list[i]] = 1 }
        $1 == "el0" && $2 in expected && $3 ~ /^ID_AA64/ && $4 ~ /^0x[0-9a-fA-F]+$/ {
            if (length($4) != 18) bad = 1
            key = $2 SUBSEP $3
            if (key in observed) bad = 1
            observed[key] = tolower($4)
            registers[$3] = 1
            if ($3 in value && value[$3] != tolower($4)) bad = 1
            value[$3] = tolower($4)
            count++
        }
        END {
            for (cpu in expected) for (reg in registers) if (!(cpu SUBSEP reg in observed)) bad = 1
            exit bad || !count
        }
    ' "$1"
}

# cpu_features_validate_pac <log> <online-cpu-list>
# Require all per-CPU keys, corrupt-modifier faults and key-reset evidence.
cpu_features_validate_pac() {
    awk -v cpus="$2" '
        BEGIN { n = split(cpus, list, /[[:space:]]+/); for (i = 1; i <= n; i++) if (list[i] != "") expected["cpu" list[i]] = 1 }
        $2 in expected && $4 == "sign" {
            if ($8 !~ /^(ok|unsigned)$/) bad = 1
            if ($8 == "ok") signed_keys++
            keys[$2, $3]++
        }
        $2 in expected && $3 == "APGA" { if ($6 != "ok") bad = 1; keys[$2, $3]++ }
        $2 in expected && $4 == "corrupt" {
            if ($5 != "signal" || ($6 != 4 && $6 != 11)) bad = 1
            faults[$2, $3]++
        }
        $2 == "reset" && $3 ~ /^AP/ { if ($4 != "changed") bad = 1; resets[$3]++ }
        END {
            split("APIA APIB APDA APDB APGA", names, " ")
            for (key_index in names) {
                key = names[key_index]
                if (resets[key] != 1) bad = 1
                for (cpu in expected) {
                    if (keys[cpu, key] != 1) bad = 1
                    if (key != "APGA" && faults[cpu, key] != 1) bad = 1
                }
            }
            exit bad || !signed_keys
        }
    ' "$1"
}

# cpu_features_vector <vector-log> <feature> <instruction> <online-cpu-list>
# Compare instruction availability, HWCAP, decoded registers and CPU flags.
cpu_features_vector() {
    local log="$1" feature="$2" instruction="$3" cpus="$4" hw register_value flags
    hw=$(awk -v feature="$feature" '
        $1 == "vec" && $2 == "hwcap" { for (i = 3; i < NF; i += 2) if ($i == feature) print $(i + 1) }
    ' "$log")
    case "$hw" in
        0|1)
            ;;
        *)
            return 1
            ;;
    esac
    flags=$(awk -v feature="$feature" '
        /^Features[[:space:]]*:/ { count++; have = 0; for (i = 3; i <= NF; i++) if ($i == feature) have = 1; if (!have) absent++ }
        END { if (!count) print "unknown"; else if (absent == count) print 0; else if (!absent) print 1; else print "mixed" }
    ' /proc/cpuinfo)
    [ "$flags" = "$hw" ] || return 1
    if [ -s "$SCENARIO_DIR/features.tsv" ]; then
        register_value=$(awk -v feature="FEAT_$(printf '%s' "$feature" | tr '[:lower:]' '[:upper:]')" '$1 == feature {print $2}' "$SCENARIO_DIR/features.tsv")
        case "$register_value:$hw" in
            present:1|absent:0)
                ;;
            unknown:*|'':*)
                return 2
                ;;
            *)
                return 1
                ;;
        esac
    else
        return 2
    fi
    [ -n "$instruction" ] || return 0
    awk -v cpus="$cpus" -v instruction="$instruction" -v present="$hw" '
        BEGIN { n = split(cpus, list, /[[:space:]]+/); for (i = 1; i <= n; i++) if (list[i] != "") expected["cpu" list[i]] = 1 }
        $2 in expected && $3 == instruction {
            seen[$2]++
            if (present && ($4 != "exit" || $5 != 0)) bad = 1
            if (!present && ($4 != "signal" || $5 != 4)) bad = 1
        }
        END { for (cpu in expected) if (seen[cpu] != 1) bad = 1; exit bad }
    ' "$log"
}

# cpu_features_run
# Exercise the installed idregs v1 helper without compiling on the DUT.
cpu_features_run() {
    local binary table cpus token expected actual paca pacg feature instruction status
    case "$(uname -m)" in
        aarch64|arm64)
            ;;
        *)
            test_result_record SKIP "Arm64 feature validation is not applicable to $(uname -m)"
            return
            ;;
    esac
    binary=$(command -v "$SCENARIO_IDREGS" 2>/dev/null)
    if [ -z "$binary" ]; then
        test_result_record SKIP "Image-provided idregs-arm64 helper is missing, supply --idregs"
        return
    fi
    cpus=$(get_online_cpus)
    if ! scenario_command idregs "$binary" || ! grep -qx 'idregs 1' "$SCENARIO_DIR/idregs.log"; then
        test_result_record FAIL "Installed idregs helper failed or lacks the supported v1 output contract"
        return 1
    fi
    if cpu_features_views "$SCENARIO_DIR/idregs.log" "$cpus"; then
        # shellcheck disable=SC2034 # Required by scenario_finish.
        SCENARIO_VALIDATED=1
        test_result_record PASS "Complete identical EL0 register view on runtime-online CPUs"
    else
        test_result_record FAIL "EL0 register views differ or omit an online CPU/register"
    fi
    if [ -e /dev/kvm ]; then
        kvm_check_device_node
        status=$?
        if [ "$status" = 0 ] && grep -Eq '^kvm ID_AA64[A-Za-z0-9_]+ 0x[0-9a-fA-F]{16}$' "$SCENARIO_DIR/idregs.log"; then
            test_result_record PASS "Installed helper exercised KVM ID-register view"
        else
            test_result_record FAIL "Present KVM device could not supply a vCPU ID-register view"
        fi
    else
        test_result_record SKIP "KVM ID-register view is unavailable without /dev/kvm"
    fi
    table="$SCENARIO_FEATURE_TABLE"
    if [ -z "$table" ]; then
        for table in "${binary%/*}/features.txt" /usr/share/cpu-features/features.txt; do
            [ -s "$table" ] && break
        done
    fi
    if [ -s "$table" ]; then
        if ! awk -f "$TOOLS/cpu_feature_decode.awk" "$table" "$SCENARIO_DIR/idregs.log" \
            >"$SCENARIO_DIR/features.tsv"; then
            test_result_record FAIL "Feature table is malformed or could not be decoded: $table"
            return 1
        fi
        for token in $(printf '%s\n' "$SCENARIO_EXPECTED" | tr ',' ' '); do
            expected=${token%%:*}
            feature=${token#*:}
            actual=$(awk -v feature="$feature" '$1 == feature {print $2}' "$SCENARIO_DIR/features.tsv")
            if [ "$actual" = "$expected" ]; then
                test_result_record PASS "Expected $feature=$expected"
            else
                test_result_record FAIL "Expected $feature=$expected, observed=${actual:-not-in-table}"
            fi
        done
    elif [ -n "$SCENARIO_EXPECTED" ] || [ -n "$SCENARIO_FEATURE_TABLE" ]; then
        test_result_record FAIL "Requested feature validation lacks its readable image-provided feature table"
    else
        test_result_record SKIP "Full feature decoding requires an image-provided Arm feature table, supply --feature-table"
    fi
    if scenario_command pac "$binary" pac; then
        paca=$(awk '$2 == "hwcap" {print $4}' "$SCENARIO_DIR/pac.log")
        pacg=$(awk '$2 == "hwcap" {print $6}' "$SCENARIO_DIR/pac.log")
        if [ "$paca:$pacg" = 1:1 ]; then
            if cpu_features_validate_pac "$SCENARIO_DIR/pac.log" "$cpus"; then
                test_result_record PASS "Per-CPU PAC key roundtrips, wrong-modifier faults and key reset passed"
            else
                test_result_record FAIL "PAC output is incomplete or functional key validation failed"
            fi
            if [ -e /dev/kvm ]; then
                if awk '
                    $2 == "kvm-ptrauth" && $4 == "auth" { if ($5 != "0x0000000080000000") bad = 1; auth++ }
                    $2 == "kvm-ptrauth" && $4 == "wrong" { if ($5 == "0x0000000080000000") bad = 1; wrong++ }
                    $2 == "kvm-ptrauth" && $3 == "done" { positive = $4 == 1 }
                    $2 == "kvm-noptrauth" && $4 == "sign" { if ($5 != "0x0000000080000000") bad = 1; negative_keys++ }
                    $2 == "kvm-noptrauth" && $3 == "done" { negative = $4 == 1 && $6 > 0 && $8 ~ /^0x2000000/ }
                    END {exit bad || !positive || !negative || auth != 4 || wrong != 4 || negative_keys != 4}
                ' "$SCENARIO_DIR/pac.log"; then
                    test_result_record PASS "PAC-enabled guest and PAC-disabled guest negative control passed"
                else
                    test_result_record FAIL "PAC guest controls failed or lack complete evidence"
                fi
            else
                test_result_record SKIP "PAC guest controls require /dev/kvm"
            fi
        elif [ "$paca:$pacg" = 0:0 ]; then
            if grep -Eq '^pac cpu[0-9]+ AP[A-Z]+ sign .* ok$' "$SCENARIO_DIR/pac.log"; then
                test_result_record FAIL "A CPU signs despite absent PAC HWCAPs"
            else
                test_result_record SKIP "PAC is not exposed by this system"
            fi
        elif [ "$paca:$pacg" = 1:0 ] || [ "$paca:$pacg" = 0:1 ]; then
            test_result_record SKIP "Installed all-key PAC helper cannot prove partial PAC feature support, paca=$paca pacg=$pacg"
        else
            test_result_record FAIL "PAC helper omitted valid HWCAP evidence"
        fi
    else
        test_result_record FAIL "PAC helper invocation failed"
    fi
    if scenario_command vectors "$binary" vec; then
        for feature in sve sve2 sme sme2; do
            instruction=""
            case "$feature" in
                sve)
                    instruction=rdvl
                    ;;
                sme)
                    instruction=rdsvl
                    ;;
            esac
            cpu_features_vector "$SCENARIO_DIR/vectors.log" "$feature" "$instruction" "$cpus"
            status=$?
            case "$status" in
                0)
                    test_result_record PASS "$feature register, HWCAP and instruction exposure agrees"
                    ;;
                2)
                    test_result_record SKIP "$feature lacks a visible decoded ID-register field or feature table"
                    ;;
                *)
                    test_result_record FAIL "$feature register, HWCAP or per-CPU instruction exposure differs"
                    ;;
            esac
        done
    else
        test_result_record FAIL "Vector instruction helper failed"
    fi
    if [ "$(get_online_cpus)" != "$cpus" ]; then
        test_result_record FAIL "Online CPU population changed during feature validation, rerun on a stable system"
    fi
}
