# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Decode the image-provided nine-column Arm feature table using exact hex fields.
function power2(exponent, result) {
    result = 1
    while (exponent-- > 0) result *= 2
    return result
}
function extract(hex, high, low, position, digit, result) {
    sub(/^0x/, "", hex)
    result = 0
    for (position = high; position >= low; position--) {
        digit = index("0123456789abcdef", substr(tolower(hex), 16 - int(position / 4), 1)) - 1
        if (digit < 0) return -999
        result = result * 2 + int(digit / power2(position % 4)) % 2
    }
    return result
}
function meets(value, kind, width, minimum) {
    if (kind == "s" && value >= power2(width - 1)) value -= power2(width)
    if (kind == "i" && value == 15) value = 0
    return value >= minimum
}
FNR == NR {
    if ($0 ~ /^#/ || NF == 0) next
    if (NF != 9 || $1 !~ /^FEAT_[A-Za-z0-9_]+$/ || $2 !~ /^ID_AA64[A-Za-z0-9_]+$/ ||
        $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+$/ || $3 > 63 || $4 > $3 ||
        $5 !~ /^[usi]$/ || $6 !~ /^[0-9]+$/ || $8 !~ /^[vh]$/ || $9 !~ /^[km]$/) {
        malformed = 1
        next
    }
    count++
    feature[count] = $1
    register[count] = $2
    high[count] = $3
    low[count] = $4
    kind[count] = $5
    minimum[count] = $6
    visible[count] = $8
    guest[count] = $9
    next
}
$1 == "el0" && $3 ~ /^ID_AA64/ && $4 ~ /^0x[0-9a-fA-F]+$/ {
    if (!first_cpu) first_cpu = $2
    if ($2 == first_cpu) el0[$3] = $4
}
$1 == "kvm" && $2 ~ /^ID_AA64/ && $3 ~ /^0x[0-9a-fA-F]+$/ { kvm[$2] = $3 }
END {
    if (malformed || !count) exit 2
    for (index_value = 1; index_value <= count; index_value++) {
        name = feature[index_value]
        reg = register[index_value]
        if (!seen[name]++) names[++name_count] = name
        row_known = 0
        if (visible[index_value] == "v" && reg in el0) {
            row_known = 1
            if (meets(extract(el0[reg], high[index_value], low[index_value]), kind[index_value],
                      high[index_value] - low[index_value] + 1, minimum[index_value])) present[name] = 1
        }
        if (guest[index_value] == "k" && reg in kvm) {
            row_known = 1
            if (meets(extract(kvm[reg], high[index_value], low[index_value]), kind[index_value],
                      high[index_value] - low[index_value] + 1, minimum[index_value])) present[name] = 1
        }
        if (!row_known) unknown[name] = 1
    }
    for (index_value = 1; index_value <= name_count; index_value++) {
        name = names[index_value]
        print name, present[name] ? "present" : unknown[name] ? "unknown" : "absent"
    }
}
