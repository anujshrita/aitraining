#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="apache2"
HEALTH_URL="http://localhost:80"
CHECK_INTERVAL_SECONDS="30"
MONITOR_LOG="/var/log/payment-monitor.log"
THREAD_DUMP_DIR="/var/log"
PID_FILE="/tmp/payment-monitor.pid"
STATE_FILE="/tmp/payment-monitor.state"
ONCE_LOCK_FILE="/tmp/payment-monitor-once.lock"

DRY_RUN="false"
MODE=""

usage() {
  cat <<'EOF'
Usage:
  payment-monitor.sh --daemon [--dry-run]
  payment-monitor.sh --once [--dry-run]
  payment-monitor.sh --rollback [--dry-run]

Options:
  --daemon    Start monitoring loop in background (idempotent start)
  --once      Run one health check cycle
  --rollback  Stop monitor loop and restore original apache service state
  --dry-run   Print actions without changing service state
  -h, --help  Show this help
EOF
}

log_action() {
  local message="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  printf '%s %s\n' "${timestamp}" "${message}" | sudo tee -a "${MONITOR_LOG}" > /dev/null
}

init_logs() {
  sudo touch "${MONITOR_LOG}"
  sudo chmod 0644 "${MONITOR_LOG}"
}

is_monitor_running() {
  if [[ -f "${PID_FILE}" ]]; then
    local existing_pid
    existing_pid="$(cat "${PID_FILE}")"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}


get_service_state() {
  local state
  if state="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null)"; then
    printf '%s\n' "${state}"
  else
    printf '%s\n' "inactive"
  fi
}

save_state_file() {
  local original_state="$1"
  printf 'PID=%s\nORIGINAL_STATE=%s\n' "$$" "${original_state}" > "${STATE_FILE}"
}

capture_thread_dump() {
  local dump_ts
  local dump_file
  dump_ts="$(date '+%Y%m%d_%H%M%S')"
  dump_file="${THREAD_DUMP_DIR}/apache-thread-dump-${dump_ts}.log"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_action "[DRY-RUN] Would capture apache thread dump to ${dump_file}"
    return 0
  fi

  log_action "Capturing apache thread dump to ${dump_file}"
  {
    printf 'Thread dump timestamp: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'Service: %s\n' "${SERVICE_NAME}"
    printf '\n=== ps -L output (apache2 threads) ===\n'
    ps -L -C apache2 -o pid,tid,pcpu,stat,comm || true
    printf '\n=== systemctl status (truncated) ===\n'
    systemctl status "${SERVICE_NAME}" --no-pager -n 100 || true
  } | sudo tee "${dump_file}" > /dev/null
}

restart_apache() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_action "[DRY-RUN] Would restart ${SERVICE_NAME} via systemctl"
    return 0
  fi

  log_action "Restarting ${SERVICE_NAME} via systemctl"
  sudo systemctl restart "${SERVICE_NAME}"
  log_action "Restart complete for ${SERVICE_NAME}"
}

check_health_and_remediate() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${HEALTH_URL}" || true)"

  if [[ "${code}" == "200" ]]; then
    log_action "Health check OK (${HEALTH_URL} -> HTTP ${code})"
    return 0
  fi

  log_action "Health check FAILED (${HEALTH_URL} -> HTTP ${code}); preparing remediation"
  capture_thread_dump
  restart_apache
}

restore_service_state() {
  local original_state="$1"

  if [[ "${original_state}" == "active" ]]; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_action "[DRY-RUN] Would restore ${SERVICE_NAME} to active state"
    else
      log_action "Restoring ${SERVICE_NAME} to active state"
      sudo systemctl start "${SERVICE_NAME}"
    fi
  else
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_action "[DRY-RUN] Would restore ${SERVICE_NAME} to inactive state"
    else
      log_action "Restoring ${SERVICE_NAME} to inactive state"
      sudo systemctl stop "${SERVICE_NAME}"
    fi
  fi
}

rollback() {
  local rollback_state="$1"
  local rollback_pid="$2"

  log_action "Rollback requested"

  if [[ -n "${rollback_pid}" ]] && kill -0 "${rollback_pid}" 2>/dev/null; then
    if [[ "${DRY_RUN}" == "true" ]]; then
      log_action "[DRY-RUN] Would stop monitor loop process PID ${rollback_pid}"
    else
      log_action "Stopping monitor loop process PID ${rollback_pid}"
      kill "${rollback_pid}" || true
    fi
  fi

  restore_service_state "${rollback_state}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_action "[DRY-RUN] Would remove ${PID_FILE} and ${STATE_FILE}"
  else
    rm -f "${PID_FILE}" "${STATE_FILE}"
    log_action "Rollback complete"
  fi
}

run_loop() {
  local original_state="$1"
  printf '%s\n' "$$" > "${PID_FILE}"
  save_state_file "${original_state}"

  trap 'rollback "${original_state}" ""; exit 0' INT TERM
  trap 'log_action "Unexpected error in monitor loop; triggering rollback"; rollback "${original_state}" ""; exit 1' ERR

  log_action "Monitor loop started (pid=$$, interval=${CHECK_INTERVAL_SECONDS}s, url=${HEALTH_URL})"

  while true; do
    check_health_and_remediate
    sleep "${CHECK_INTERVAL_SECONDS}"
  done
}

start_daemon() {
  init_logs

  if is_monitor_running; then
    local existing_pid
    existing_pid="$(cat "${PID_FILE}")"
    log_action "Monitor already running with PID ${existing_pid}; refusing duplicate start"
    printf 'Monitor already running with PID %s\n' "${existing_pid}"
    return 0
  fi

  local original_state
  original_state="$(get_service_state)"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_action "[DRY-RUN] Would start monitor daemon (original ${SERVICE_NAME} state=${original_state})"
    printf '[DRY-RUN] Would start monitor daemon\n'
    return 0
  fi

  log_action "Starting monitor daemon (original ${SERVICE_NAME} state=${original_state})"
  nohup "$0" --run-loop --original-state "${original_state}" > /dev/null 2>&1 &
  sleep 1

  if is_monitor_running; then
    local new_pid
    new_pid="$(cat "${PID_FILE}")"
    log_action "Monitor daemon started with PID ${new_pid}"
    printf 'Monitor daemon started with PID %s\n' "${new_pid}"
  else
    log_action "Failed to start monitor daemon"
    printf 'Failed to start monitor daemon\n' >&2
    exit 1
  fi
}

run_once() {
  init_logs

  # Open lock file on fd 9 and attempt a non-blocking exclusive lock.
  # flock releases automatically when this process exits (no stale locks).
  exec 9>"${ONCE_LOCK_FILE}"
  if ! flock --nonblock 9; then
    log_action "Another --once instance is already running; skipping duplicate"
    printf 'Another health check is already in progress\n' >&2
    exit 0
  fi

  local original_state
  original_state="$(get_service_state)"
  log_action "Single-run mode started (original ${SERVICE_NAME} state=${original_state})"

  trap 'rollback "${original_state}" ""; exit 0' INT TERM
  trap 'log_action "Unexpected error in single-run mode; triggering rollback"; rollback "${original_state}" ""; exit 1' ERR

  check_health_and_remediate
  log_action "Single-run mode completed"
}

run_rollback() {
  init_logs

  if [[ ! -f "${STATE_FILE}" ]]; then
    log_action "Rollback requested but no state file found at ${STATE_FILE}"
    printf 'No state file found; nothing to rollback\n'
    return 0
  fi

  # shellcheck disable=SC1090
  source "${STATE_FILE}"

  local rollback_pid
  local rollback_state
  rollback_pid="${PID:-}"
  rollback_state="${ORIGINAL_STATE:-inactive}"

  rollback "${rollback_state}" "${rollback_pid}"
}

parse_args() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 1
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --daemon)
        MODE="daemon"
        shift
        ;;
      --once)
        MODE="once"
        shift
        ;;
      --rollback)
        MODE="rollback"
        shift
        ;;
      --run-loop)
        MODE="run-loop"
        shift
        ;;
      --original-state)
        shift
        if [[ "$#" -eq 0 ]]; then
          printf 'Missing value for --original-state\n' >&2
          exit 1
        fi
        ORIGINAL_STATE_ARG="$1"
        shift
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown argument: %s\n' "$1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  local original_state_for_loop
  original_state_for_loop=""

  parse_args "$@"

  case "${MODE}" in
    daemon)
      start_daemon
      ;;
    once)
      run_once
      ;;
    rollback)
      run_rollback
      ;;
    run-loop)
      original_state_for_loop="${ORIGINAL_STATE_ARG:-inactive}"
      run_loop "${original_state_for_loop}"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
