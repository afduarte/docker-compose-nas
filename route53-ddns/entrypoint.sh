#!/bin/sh
set -eu

STATE_DIR="${STATE_DIR:-/var/lib/route53-ddns}"
LAST_IP_FILE="${STATE_DIR}/last_ip"
LAST_IP6_FILE="${STATE_DIR}/last_ip6"
INTERVAL="${ROUTE53_UPDATE_INTERVAL:-300}"
TTL="${ROUTE53_TTL:-300}"
ZONE_ID="${ROUTE53_ZONE_ID:-}"
RECORDS="${ROUTE53_RECORDS:-}"
ENABLE_IPV6="${ROUTE53_ENABLE_IPV6:-true}"

log() {
  echo "$(date -Iseconds) [route53-ddns] $*"
}

log_err() {
  echo "$(date -Iseconds) [route53-ddns] ERROR: $*" >&2
}

mkdir -p "${STATE_DIR}"

log "Starting Route53 DDNS updater"
log "  Zone ID: ${ZONE_ID:-<not set>}"
log "  Records: ${RECORDS:-<not set>}"
log "  TTL: ${TTL}s"
log "  Interval: ${INTERVAL}s"
log "  IPv6: ${ENABLE_IPV6}"

if [ -z "${ZONE_ID}" ] || [ -z "${RECORDS}" ]; then
  log_err "ROUTE53_ZONE_ID and ROUTE53_RECORDS must be set."
  exit 1
fi

get_public_ip4() {
  curl -4 -fsS --max-time 10 https://checkip.amazonaws.com 2>/dev/null || \
    curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null
}

get_public_ip6() {
  curl -6 -fsS --max-time 10 https://ipv6.icanhazip.com 2>/dev/null || \
    curl -6 -fsS --max-time 10 https://api64.ipify.org 2>/dev/null
}

fqdn_of() {
  case "$1" in
    *.) echo "$1" ;;
    *) echo "$1." ;;
  esac
}

# record_needs_update <name> <type> <expected-value>
record_needs_update() {
  name="$1"; type="$2"; expected="$3"
  fqdn="$(fqdn_of "${name}")"

  current=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "${ZONE_ID}" \
    --query "ResourceRecordSets[?Name=='${fqdn}' && Type=='${type}'].ResourceRecords[0].Value" \
    --output text 2>/dev/null || echo "")

  if [ -z "${current}" ] || [ "${current}" = "None" ]; then
    log "  ${fqdn} ${type}: not found in Route53, needs creating"
    return 0
  elif [ "${current}" != "${expected}" ]; then
    log "  ${fqdn} ${type}: points to ${current}, needs updating to ${expected}"
    return 0
  fi
  return 1
}

# update_record <name> <type> <value>
update_record() {
  name="$1"; type="$2"; value="$3"
  fqdn="$(fqdn_of "${name}")"

  log "  Updating ${fqdn} ${type} -> ${value} (TTL ${TTL})"

  cat > /tmp/route53-change.json <<EOF
{ "Comment": "Route53 DDNS update", "Changes": [ { "Action": "UPSERT", "ResourceRecordSet": { "Name": "${fqdn}", "Type": "${type}", "TTL": ${TTL}, "ResourceRecords": [ { "Value": "${value}" } ] } } ] }
EOF

  if output=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${ZONE_ID}" \
    --change-batch file:///tmp/route53-change.json 2>&1); then
    change_id=$(echo "${output}" | grep -o '"Id": "[^"]*"' | head -1 || true)
    log "  Success: ${fqdn} ${type} ${change_id}"
  else
    log_err "  Failed to update ${fqdn} ${type}: ${output}"
    return 1
  fi
}

# sync_family <type> <ip> <state-file>
sync_family() {
  type="$1"; ip="$2"; state="$3"

  last=""
  if [ -f "${state}" ]; then
    last="$(cat "${state}")"
  fi

  if [ "${ip}" != "${last}" ]; then
    if [ -z "${last}" ]; then
      log "First run - current ${type} address: ${ip}"
    else
      log "${type} address changed: ${last} -> ${ip}"
    fi
    fail_count=0
    for record in $(echo "${RECORDS}" | tr ',' ' '); do
      record="$(echo "${record}" | tr -d ' ')"
      [ -z "${record}" ] && continue
      if ! update_record "${record}" "${type}" "${ip}"; then
        fail_count=$((fail_count + 1))
      fi
    done
    if [ "${fail_count}" -eq 0 ]; then
      echo "${ip}" > "${state}"
      log "All ${type} records updated successfully."
    else
      log_err "${fail_count} ${type} record(s) failed. Will retry next cycle."
    fi
    return 0
  fi

  # address unchanged - check for individual missing/stale records
  missing_records=""
  for record in $(echo "${RECORDS}" | tr ',' ' '); do
    record="$(echo "${record}" | tr -d ' ')"
    [ -z "${record}" ] && continue
    if record_needs_update "${record}" "${type}" "${ip}"; then
      missing_records="${missing_records} ${record}"
    fi
  done

  if [ -n "${missing_records}" ]; then
    log "${type} unchanged (${ip}) but some records need updating:${missing_records}"
    fail_count=0
    for record in ${missing_records}; do
      if ! update_record "${record}" "${type}" "${ip}"; then
        fail_count=$((fail_count + 1))
      fi
    done
    if [ "${fail_count}" -eq 0 ]; then
      log "All missing/stale ${type} records updated successfully."
    else
      log_err "${fail_count} ${type} record(s) failed. Will retry next cycle."
    fi
  fi
}

log "Performing initial check..."

last_no_change_log=0

while true; do
  ip4="$(get_public_ip4 || true)"
  if [ -n "${ip4}" ]; then
    sync_family "A" "${ip4}" "${LAST_IP_FILE}"
  else
    log_err "Failed to determine public IPv4 (both checkip.amazonaws.com and api.ipify.org failed)"
  fi

  if [ "${ENABLE_IPV6}" = "true" ]; then
    ip6="$(get_public_ip6 || true)"
    if [ -n "${ip6}" ]; then
      sync_family "AAAA" "${ip6}" "${LAST_IP6_FILE}"
    else
      log_err "Failed to determine public IPv6 (no global IPv6 address / no IPv6 egress)"
    fi
  fi

  now=$(date +%s)
  if [ "${now}" -ge $((last_no_change_log + 86400)) ]; then
    log "No changes needed (IPv4 ${ip4:-?}, IPv6 ${ip6:-n/a}). Next log in 24h."
    last_no_change_log=${now}
  fi

  sleep "${INTERVAL}"
done
