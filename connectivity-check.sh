#!/usr/bin/env bash
set -uo pipefail

# ---------------------------------------------------------------------------
# connectivity-check.sh
# Validates network connectivity after a change window.
# Run as: labadmin (sudo required for log file creation/append)
# Usage:  ./connectivity-check.sh [--dry-run] [--critical-only]
# ---------------------------------------------------------------------------

readonly LOG_FILE="/var/log/connectivity-check.log"

# Network targets
readonly GATEWAY="10.0.0.1"
readonly SELF_IP="10.0.0.4"
readonly INTERNET="8.8.8.8"
readonly APP_SERVER="10.0.1.10"
readonly DB_SERVER="10.0.2.10"
readonly DB_PORT="5432"
readonly APP_PORT="8080"
readonly IFACE="eth0"
readonly DNS_HOST="google.com"

# Runtime flags (mutated by parse_args)
DRY_RUN="false"
CRITICAL_ONLY="false"

# Result counters
PASSED=0
FAILED=0
SKIPPED=0
CRITICAL_FAILED=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  connectivity-check.sh [OPTIONS]

Options:
  --dry-run        Print what checks would run without executing them
  --critical-only  Skip non-critical checks (app/DB pings, port checks, tc)
  -h, --help       Show this help

Critical checks  : gateway ping, self ping, internet ping, DNS, default route
Non-critical     : app server ping, DB server ping, port checks, tc qdisc
EOF
}

init_log() {
  sudo touch "${LOG_FILE}"
  sudo chmod 0644 "${LOG_FILE}"
}

log_and_print() {
  local message="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  local line="${timestamp} ${message}"
  printf '%s\n' "${line}"
  printf '%s\n' "${line}" | sudo tee -a "${LOG_FILE}" > /dev/null
}

record_result() {
  local label="$1"
  local status="$2"    # PASS | FAIL | SKIP
  local detail="$3"
  local is_critical="${4:-false}"

  case "${status}" in
    PASS)
      PASSED=$((PASSED + 1))
      log_and_print "[PASS] ${label}: ${detail}"
      ;;
    FAIL)
      FAILED=$((FAILED + 1))
      if [[ "${is_critical}" == "true" ]]; then
        CRITICAL_FAILED=$((CRITICAL_FAILED + 1))
      fi
      log_and_print "[FAIL] ${label}: ${detail}"
      ;;
    SKIP)
      SKIPPED=$((SKIPPED + 1))
      log_and_print "[SKIP] ${label}: ${detail}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Check: ICMP ping  (-c3 packets, -W 5s timeout per-ping)
# ---------------------------------------------------------------------------

check_ping() {
  local label="$1"
  local host="$2"
  local is_critical="$3"

  if [[ "${CRITICAL_ONLY}" == "true" ]] && [[ "${is_critical}" == "false" ]]; then
    record_result "${label}" "SKIP" "skipped by --critical-only" "${is_critical}"
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    record_result "${label}" "SKIP" "[DRY-RUN] would run: ping -c3 -W 5 ${host}" "${is_critical}"
    return 0
  fi

  local output
  local exit_code=0
  output="$(ping -c3 -W 5 "${host}" 2>&1)" || exit_code=$?

  if [[ "${exit_code}" -eq 0 ]]; then
    record_result "${label}" "PASS" "ping to ${host} succeeded" "${is_critical}"
  else
    record_result "${label}" "FAIL" "ping to ${host} failed (exit ${exit_code})" "${is_critical}"
  fi
}

# ---------------------------------------------------------------------------
# Check: TCP port reachability  (nc -w 5 timeout)
# ---------------------------------------------------------------------------

check_port() {
  local label="$1"
  local host="$2"
  local port="$3"
  local is_critical="$4"

  if [[ "${CRITICAL_ONLY}" == "true" ]] && [[ "${is_critical}" == "false" ]]; then
    record_result "${label}" "SKIP" "skipped by --critical-only" "${is_critical}"
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    record_result "${label}" "SKIP" "[DRY-RUN] would run: nc -zv -w 5 ${host} ${port}" "${is_critical}"
    return 0
  fi

  local output
  local exit_code=0
  output="$(nc -zv -w 5 "${host}" "${port}" 2>&1)" || exit_code=$?

  if [[ "${exit_code}" -eq 0 ]]; then
    record_result "${label}" "PASS" "port ${host}:${port} is reachable" "${is_critical}"
  else
    record_result "${label}" "FAIL" "port ${host}:${port} is unreachable (exit ${exit_code})" "${is_critical}"
  fi
}

# ---------------------------------------------------------------------------
# Check: DNS resolution  (timeout 5s wraps nslookup)
# ---------------------------------------------------------------------------

check_dns() {
  local label="$1"
  local hostname="$2"
  local is_critical="$3"

  if [[ "${CRITICAL_ONLY}" == "true" ]] && [[ "${is_critical}" == "false" ]]; then
    record_result "${label}" "SKIP" "skipped by --critical-only" "${is_critical}"
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    record_result "${label}" "SKIP" "[DRY-RUN] would run: timeout 5 nslookup ${hostname}" "${is_critical}"
    return 0
  fi

  local output
  local exit_code=0
  output="$(timeout 5 nslookup "${hostname}" 2>&1)" || exit_code=$?

  if [[ "${exit_code}" -eq 0 ]]; then
    record_result "${label}" "PASS" "DNS resolved ${hostname} successfully" "${is_critical}"
  elif [[ "${exit_code}" -eq 124 ]]; then
    record_result "${label}" "FAIL" "DNS resolution of ${hostname} timed out after 5s" "${is_critical}"
  else
    record_result "${label}" "FAIL" "DNS resolution of ${hostname} failed (exit ${exit_code})" "${is_critical}"
  fi
}

# ---------------------------------------------------------------------------
# Check: Default route present
# ---------------------------------------------------------------------------

check_default_route() {
  local label="$1"
  local is_critical="$2"

  if [[ "${DRY_RUN}" == "true" ]]; then
    record_result "${label}" "SKIP" "[DRY-RUN] would run: ip route show | grep '^default'" "${is_critical}"
    return 0
  fi

  local output
  local exit_code=0
  output="$(ip route show 2>&1 | grep '^default')" || exit_code=$?

  if [[ "${exit_code}" -eq 0 ]] && [[ -n "${output}" ]]; then
    record_result "${label}" "PASS" "default route present: ${output}" "${is_critical}"
  else
    record_result "${label}" "FAIL" "no default route found in routing table" "${is_critical}"
  fi
}

# ---------------------------------------------------------------------------
# Check: No artificial latency (netem) on interface via tc qdisc
# ---------------------------------------------------------------------------

check_tc_qdisc() {
  local label="$1"
  local iface="$2"
  local is_critical="$3"

  if [[ "${CRITICAL_ONLY}" == "true" ]] && [[ "${is_critical}" == "false" ]]; then
    record_result "${label}" "SKIP" "skipped by --critical-only" "${is_critical}"
    return 0
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    record_result "${label}" "SKIP" "[DRY-RUN] would run: tc qdisc show dev ${iface} (check for netem)" "${is_critical}"
    return 0
  fi

  local output
  local exit_code=0
  output="$(tc qdisc show dev "${iface}" 2>&1)" || exit_code=$?

  if [[ "${exit_code}" -ne 0 ]]; then
    record_result "${label}" "FAIL" "tc qdisc command failed on ${iface} (exit ${exit_code}): ${output}" "${is_critical}"
    return 0
  fi

  local netem_found=0
  grep -q "netem" <<< "${output}" || netem_found=$?

  if [[ "${netem_found}" -eq 0 ]]; then
    local netem_line
    netem_line="$(grep 'netem' <<< "${output}")"
    record_result "${label}" "FAIL" "artificial latency (netem) detected on ${iface}: ${netem_line}" "${is_critical}"
  else
    record_result "${label}" "PASS" "no artificial latency (netem) on ${iface}" "${is_critical}"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  local total=$((PASSED + FAILED + SKIPPED))
  log_and_print "========================================="
  log_and_print "Connectivity Check Summary"
  log_and_print "  Total checks : ${total}"
  log_and_print "  Passed       : ${PASSED}"
  log_and_print "  Failed       : ${FAILED}"
  log_and_print "  Skipped      : ${SKIPPED}"
  if [[ "${CRITICAL_FAILED}" -gt 0 ]]; then
    log_and_print "  Critical failures: ${CRITICAL_FAILED}  <-- exit code 1"
  fi
  log_and_print "========================================="
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --critical-only)
        CRITICAL_ONLY="true"
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  init_log

  log_and_print "=== connectivity-check started (dry_run=${DRY_RUN}, critical_only=${CRITICAL_ONLY}) ==="

  # --- Group 1: Critical infrastructure pings ---
  check_ping "ping-gateway"      "${GATEWAY}"    "true"
  check_ping "ping-self"         "${SELF_IP}"    "true"
  check_ping "ping-internet"     "${INTERNET}"   "true"

  # --- Group 2: Non-critical server pings (may not be provisioned yet) ---
  check_ping "ping-app-server"   "${APP_SERVER}" "false"
  check_ping "ping-db-server"    "${DB_SERVER}"  "false"

  # --- Group 3: Non-critical port checks (may not be provisioned yet) ---
  check_port "port-postgresql"   "${DB_SERVER}"  "${DB_PORT}"  "false"
  check_port "port-app-health"   "${APP_SERVER}" "${APP_PORT}" "false"

  # --- Group 4: Critical DNS resolution ---
  check_dns "dns-resolution" "${DNS_HOST}" "true"

  # --- Group 5: Critical default route ---
  check_default_route "default-route" "true"

  # --- Group 6: Non-critical tc qdisc latency check ---
  check_tc_qdisc "tc-qdisc-${IFACE}" "${IFACE}" "false"

  print_summary
  log_and_print "=== connectivity-check completed ==="

  if [[ "${CRITICAL_FAILED}" -gt 0 ]]; then
    exit 1
  fi

  exit 0
}

main "$@"
