#!/bin/bash
# HDD-temperature based fan control for nct6687 (MSI PRO B760M-P)
# pwm3 = out/exhaust fan, pwm4 = HDD intake fan
# Temp source: drivetemp sensor for the target HDD device
#
# NOTE: pwmX_enable is set to manual (1) ONCE at startup, then never
# touched again. This avoids the known nct6687d bug where repeated
# enable-mode transitions break fan RPM reporting. If RPM reads 0 in
# `sensors` afterward, that's a cosmetic monitoring glitch — actual
# fan speed control should still work. Reload the module to restore
# RPM reporting: `modprobe -r nct6687 && modprobe nct6687`

set -uo pipefail

# --- Config ---
# Independent curves per fan: °C breakpoints -> matching PWM duty (0-255)
OUT_TEMPS=(30 38 41 45 50)      # out/exhaust fan curve
OUT_PWMS=(65 105 125 185 225)

IN_TEMPS=(30 38 41 45 50)       # HDD intake fan curve
IN_PWMS=(65 105 130 205 225)

POLL_INTERVAL=25            # seconds between checks
MIN_PWM=60                  # floor, avoid stalling fans
HDD_DEVICE="sdc"            # target drive to read temp from
DEBUG="${DEBUG:-0}"         # set to 1 (env var, flag, or edit here) for verbose per-poll logging

LOG_TAG="hdd-fan-control"
log() { echo "[$(date '+%F %T')] $*"; }
debug() { [[ "$DEBUG" == "1" ]] && echo "[$(date '+%F %T')] [DEBUG] $*"; return 0; }

# --- Parse -d/--debug flag (in addition to DEBUG env var) ---
for arg in "$@"; do
    case "$arg" in
        -d|--debug) DEBUG=1 ;;
    esac
done

# --- Locate the nct6687 control hwmon dir (number can shift across boots) ---
find_ctrl_hwmon() {
    for hw in /sys/class/hwmon/hwmon*; do
        [[ -f "$hw/name" ]] || continue
        [[ "$(cat "$hw/name")" == "nct6687" ]] && { echo "$hw"; return 0; }
    done
    return 1
}

# --- Locate the drivetemp hwmon dir for the target HDD (number can shift too) ---
find_hdd_hwmon() {
    for hw in /sys/class/hwmon/hwmon*; do
        [[ -f "$hw/name" ]] || continue
        [[ "$(cat "$hw/name")" == "drivetemp" ]] || continue
        dev_path="$(readlink -f "$hw/device" 2>/dev/null)"
        [[ -d "$dev_path/block" ]] || continue
        blk="$(ls "$dev_path/block" 2>/dev/null | head -n1)"
        [[ "$blk" == "$HDD_DEVICE" ]] && { echo "$hw"; return 0; }
    done
    return 1
}

CTRL_HWMON="$(find_ctrl_hwmon)" || { log "ERROR: nct6687 hwmon not found, exiting"; exit 1; }
HDD_HWMON="$(find_hdd_hwmon)"   || { log "ERROR: drivetemp hwmon for /dev/$HDD_DEVICE not found, exiting"; exit 1; }

PWM_OUT="$CTRL_HWMON/pwm3"
PWM_IN="$CTRL_HWMON/pwm4"
TEMP_FILE="$HDD_HWMON/temp1_input"

log "Control hwmon: $CTRL_HWMON (pwm3=out fan, pwm4=HDD intake fan)"
log "HDD temp source: $TEMP_FILE (/dev/$HDD_DEVICE)"
[[ "$DEBUG" == "1" ]] && log "Debug logging enabled"
debug "Out fan curve:   temps=(${OUT_TEMPS[*]}) pwms=(${OUT_PWMS[*]})"
debug "Intake fan curve: temps=(${IN_TEMPS[*]}) pwms=(${IN_PWMS[*]})"
debug "min_pwm=$MIN_PWM poll_interval=${POLL_INTERVAL}s"

# --- Enable manual mode once ---
for f in "$CTRL_HWMON/pwm3_enable" "$CTRL_HWMON/pwm4_enable"; do
    if [[ -f "$f" ]]; then
        echo 1 > "$f" 2>/dev/null && log "Set $f -> manual (1)" \
            || log "WARNING: could not write $f (check permissions/run as root)"
    fi
done

# --- Restore to automatic mode + full speed on exit (Ctrl+C, service stop) ---
cleanup() {
    log "Stopping — restoring automatic fan control"
    [[ -f "$CTRL_HWMON/pwm3_enable" ]] && echo 2 > "$CTRL_HWMON/pwm3_enable" 2>/dev/null
    [[ -f "$CTRL_HWMON/pwm4_enable" ]] && echo 2 > "$CTRL_HWMON/pwm4_enable" 2>/dev/null
    exit 0
}
trap cleanup SIGTERM SIGINT

# --- Linear interpolation between breakpoints ---
# Usage: temp_to_pwm <temp_c> <temps_array_name> <pwms_array_name>
temp_to_pwm() {
    local t=$1
    local -n _temps=$2
    local -n _pwms=$3
    local n=${#_temps[@]}
    if (( t <= _temps[0] )); then echo "$MIN_PWM"; return; fi
    if (( t >= _temps[n-1] )); then echo "${_pwms[n-1]}"; return; fi
    for ((i=0; i<n-1; i++)); do
        if (( t >= _temps[i] && t <= _temps[i+1] )); then
            local t0=${_temps[i]} t1=${_temps[i+1]} p0=${_pwms[i]} p1=${_pwms[i+1]}
            local pwm=$(( p0 + (p1 - p0) * (t - t0) / (t1 - t0) ))
            (( pwm < MIN_PWM )) && pwm=$MIN_PWM
            echo "$pwm"; return
        fi
    done
    echo "$MIN_PWM"
}

last_pwm_out=-1
last_pwm_in=-1

while true; do
    if [[ ! -r "$TEMP_FILE" ]]; then
        log "WARNING: cannot read $TEMP_FILE, forcing fans to full speed as failsafe"
        echo 255 > "$PWM_OUT" 2>/dev/null
        echo 255 > "$PWM_IN" 2>/dev/null
        sleep "$POLL_INTERVAL"
        continue
    fi

    raw_temp=$(cat "$TEMP_FILE")
    temp_c=$(( raw_temp / 1000 ))
    pwm_val_out=$(temp_to_pwm "$temp_c" OUT_TEMPS OUT_PWMS)
    pwm_val_in=$(temp_to_pwm "$temp_c" IN_TEMPS IN_PWMS)

    debug "poll: raw_temp=${raw_temp} temp_c=${temp_c}°C out_pwm=${pwm_val_out} in_pwm=${pwm_val_in} last_out=${last_pwm_out} last_in=${last_pwm_in} pwm3_readback=$(cat "$PWM_OUT" 2>/dev/null) pwm4_readback=$(cat "$PWM_IN" 2>/dev/null)"

    if (( pwm_val_out != last_pwm_out )); then
        log "HDD temp: ${temp_c}°C -> OUT fan PWM ${pwm_val_out} ($(( pwm_val_out * 100 / 255 ))%)"
        echo "$pwm_val_out" > "$PWM_OUT" 2>/dev/null || log "WARNING: failed to write $PWM_OUT"
        last_pwm_out=$pwm_val_out
    else
        debug "out fan: no change, skipping write"
    fi

    if (( pwm_val_in != last_pwm_in )); then
        log "HDD temp: ${temp_c}°C -> IN fan PWM ${pwm_val_in} ($(( pwm_val_in * 100 / 255 ))%)"
        echo "$pwm_val_in" > "$PWM_IN" 2>/dev/null || log "WARNING: failed to write $PWM_IN"
        last_pwm_in=$pwm_val_in
    else
        debug "in fan: no change, skipping write"
    fi

    sleep "$POLL_INTERVAL"
done
