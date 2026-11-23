#!/bin/sh
# Start or wait for incusd at boot, restarting a crashed daemon a bounded
# number of times per boot. Alpine's incusd service and its stop() are left
# unchanged; this never supervises incusd after boot.
#
# Usage: tama-incus-guard.sh ensure [readiness command...]
set -u
umask 077

boot=${TAMA_BOOT_ROOT:-}
console=${TAMA_CONSOLE:-/dev/hvc0}
max_restarts=${TAMA_INCUS_MAX_RESTARTS:-2}
ready_timeout=${TAMA_INCUS_READY_TIMEOUT:-120}
log_lines=${TAMA_INCUS_LOG_LINES:-40}
err_lines=${TAMA_INCUS_ERR_LINES:-40}
head_lines=${TAMA_INCUS_HEAD_LINES:-30}
state_dir=$boot/run/tama-incus-guard
guard_log=$boot/var/log/tama-incus-guard.log
incus_log=$boot/var/log/incus/incusd.log
incus_err=$boot/var/log/incus/incusd.err

# The host reads only the serial console. Write there directly so output is
# not lost or duplicated by whichever service runner invoked the guard.
say() {
    printf '%s\n' "$*" >> "$guard_log" 2>/dev/null || true
    if [ -w "$console" ]; then
        printf '%s\n' "$*" >> "$console" 2>/dev/null || printf '%s\n' "$*" >&2
    else
        printf '%s\n' "$*" >&2
    fi
}

# OpenRC status: 0 started, 32 crashed, 3 stopped, 16 inactive,
# 4 stopping, 8 starting.
service_state() {
    rc-service incusd status >/dev/null 2>&1
    case $? in
        0) echo running ;;
        32) echo crashed ;;
        3 | 16) echo stopped ;;
        *) echo transitional ;;
    esac
}

restarts() {
    value=$(cat "$state_dir/restarts" 2>/dev/null || true)
    case $value in
        '' | *[!0-9]*) echo 0 ;;
        *) echo "$value" ;;
    esac
}

tail_file() {
    # $1 path, $2 lines. Prefix every copied line so log text can never be
    # parsed by the host as a provisioning observation.
    if [ -s "$1" ]; then
        say "incusd| --- ${1#"$boot"} (last $2 lines) ---"
        tail -n "$2" "$1" 2>/dev/null | cut -c 1-400 | sed 's/^/incusd| /' | while IFS= read -r line; do
            say "$line"
        done
    else
        say "incusd| --- ${1#"$boot"} is empty or missing ---"
    fi
}

crash_head() {
    # A Go crash dump starts with its reason and the crashing goroutine, which
    # a plain tail of a long dump cuts off. Copy the start of the last one.
    start=$(grep -n -E '^(panic: |fatal error: |SIG[A-Z]+: |unexpected fault address)' "$incus_err" 2>/dev/null |
        tail -n 1 | cut -d: -f1)
    [ -n "$start" ] || return 0
    say "incusd| --- ${incus_err#"$boot"} (last crash, first $head_lines lines) ---"
    sed -n "${start},$((start + head_lines - 1))p" "$incus_err" 2>/dev/null | cut -c 1-400 |
        sed 's/^/incusd| /' | while IFS= read -r line; do
            say "$line"
        done
}

evidence() {
    # $1 observed state, $2 restart label
    say "TAMA_INCUSD_CRASHED state=$1 restart=$2"
    crash_head
    tail_file "$incus_log" "$log_lines"
    tail_file "$incus_err" "$err_lines"
    say 'TAMA_INCUSD_EVIDENCE_END'
}

fail() {
    # Record the code so a later step on this boot reports the same failure.
    printf '%s\n' "$1" > "$state_dir/failed"
    say "MACUS_OBSERVATION v1 stage=failed code=$1"
    say "TAMA_INCUSD_FAILED code=$1: $2; Incus data was kept"
    exit 1
}

now() { date +%s; }

ensure() {
    mkdir -p "$state_dir" "$boot/var/log"
    say 'MACUS_OBSERVATION v1 stage=incus'
    if [ -e "$state_dir/failed" ]; then
        code=$(cat "$state_dir/failed" 2>/dev/null || true)
        case $code in
            incus_crashed | incus_not_ready) ;;
            *) code=incus_crashed ;;
        esac
        fail "$code" 'incusd already failed earlier on this boot'
    fi
    launched=false
    started_at=$(now)
    while :; do
        state=$(service_state)
        if [ "$state" = stopped ] && [ "$launched" = false ]; then
            launched=true
            started_at=$(now)
            rc-service incusd start >/dev/null 2>&1 || true
            continue
        fi
        if [ "$state" = running ] || [ "$state" = transitional ]; then
            if [ "$state" = running ] && incusd waitready --timeout 5 >/dev/null 2>&1; then
                if [ "$#" -eq 0 ] || "$@"; then
                    count=$(restarts)
                    [ "$count" -eq 0 ] || say "TAMA_INCUSD_RECOVERED restarts=$count"
                    exit 0
                else
                    check=$?
                fi
                state=$(service_state)
                if [ "$state" = running ]; then
                    say "TAMA_INCUSD_READINESS_CHECK_FAILED status=$check"
                    exit "$check"
                fi
            elif [ $(($(now) - started_at)) -lt "$ready_timeout" ]; then
                [ "$state" = running ] || sleep 1
                continue
            else
                state=$(service_state)
                if [ "$state" = running ] || [ "$state" = transitional ]; then
                    evidence "$state" "none"
                    fail incus_not_ready "incusd did not become ready within ${ready_timeout}s"
                fi
            fi
        fi
        # Crashed, or stopped after a launch.
        count=$(restarts)
        if [ "$count" -ge "$max_restarts" ]; then
            evidence "$state" "exhausted/$max_restarts"
            # A crashed incusd makes OpenRC's shutdown fail to stop incusd, so
            # tama-storage is never asked to stop. Its process is gone; mark it
            # stopped so shutdown reaches the storage stop. (The export can still
            # find /var/lib/incus busy after a crash; the next boot imports it.)
            [ "$state" != crashed ] || rc-service incusd zap >/dev/null 2>&1 || true
            fail incus_crashed "incusd exited during boot after $count restarts"
        fi
        count=$((count + 1))
        printf '%s\n' "$count" > "$state_dir/restarts"
        evidence "$state" "$count/$max_restarts"
        say 'MACUS_OBSERVATION v1 stage=incus state=restarting'
        [ "$state" != crashed ] || rc-service incusd zap >/dev/null 2>&1 || true
        launched=true
        rc-service incusd start >/dev/null 2>&1 || true
        sleep 1
        started_at=$(now)
    done
}

case ${1:-} in
    ensure)
        shift
        ensure "$@"
        ;;
    *)
        echo 'usage: tama-incus-guard.sh ensure [readiness command...]' >&2
        exit 2
        ;;
esac
