#!/bin/sh
set -eu

STATE_DIR="${STATE_DIR:-/var/lib/route53-ddns}"
LAST_IP_FILE="${STATE_DIR}/last_ip"
INTERVAL="${ROUTE53_UPDATE_INTERVAL:-300}"
TTL="${ROUTE53_TTL:-300}"
ZONE_ID="${ROUTE53_ZONE_ID:-}"
RECORDS="${ROUTE53_RECORDS:-}"

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

if [ -z "${ZONE_ID}" ] || [ -z "${RECORDS}" ]; then
  log_err "ROUTE53_ZONE_ID and ROUTE53_RECORDS must be set."
  exit 1
fi

get_public_ip() {
  curl -fsS https://checkip.amazonaws.com 2>/dev/null || curl -fsS https://api.ipify.org 2>/dev/null
}

# Check if a record exists in Route53 and has the expected IP
record_needs_update() {
  record_name="$1"
  expected_ip="$2"

  case "${record_name}" in
    *.) fqdn="${record_name}" ;;
    *) fqdn="${record_name}." ;;
  esac

  current_ip=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "${ZONE_ID}" \
    --query "ResourceRecordSets[?Name=='${fqdn}' && Type=='A'].ResourceRecords[0].Value" \
    --output text 2>/dev/null || echo "")

  if [ -z "${current_ip}" ] || [ "${current_ip}" = "None" ]; then
    log "  ${record_name}: not found in Route53, needs creating"
    return 0
  elif [ "${current_ip}" != "${expected_ip}" ]; then
    log "  ${record_name}: points to ${current_ip}, needs updating to ${expected_ip}"
    return 0
  fi
  return 1
}

update_record() {
  record_name="$1"
  ip="$2"

  case "${record_name}" in
    *.) fqdn="${record_name}" ;;
    *) fqdn="${record_name}." ;;
  esac

  log "  Updating ${fqdn} -> ${ip} (TTL ${TTL})"

  cat > /tmp/route53-change.json <<EOF
{ "Comment": "Route53 DDNS update", "Changes": [ { "Action": "UPSERT", "ResourceRecordSet": { "Name": "${fqdn}", "Type": "A", "TTL": ${TTL}, "ResourceRecords": [ { "Value": "${ip}" } ] } } ] }
EOF

  if output=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${ZONE_ID}" \
    --change-batch file:///tmp/route53-change.json 2>&1); then
    change_id=$(echo "${output}" | grep -o '"Id": "[^"]*"' | head -1 || true)
    log "  Success: ${record_name} ${change_id}"
  else
    log_err "  Failed to update ${record_name}: ${output}"
    return 1
  fi
}

log "Performing initial check..."

last_no_change_log=0

while true; do
  ip="$(get_public_ip || true)"
  if [ -z "${ip}" ]; then
    log_err "Failed to determine public IP (both checkip.amazonaws.com and api.ipify.org failed)"
    sleep "${INTERVAL}"
    continue
  fi

  last_ip=""
  if [ -f "${LAST_IP_FILE}" ]; then
    last_ip="$(cat "${LAST_IP_FILE}")"
  fi

  if [ "${ip}" != "${last_ip}" ]; then
    if [ -z "${last_ip}" ]; then
      log "First run — current public IP: ${ip}"
    else
      log "IP changed: ${last_ip} -> ${ip}"
    fi
    log "Updating all record(s)..."
    fail_count=0
    for record in $(echo "${RECORDS}" | tr ',' ' '); do
      record="$(echo "${record}" | tr -d ' ')"
      [ -z "${record}" ] && continue
      if ! update_record "${record}" "${ip}"; then
        fail_count=$((fail_count + 1))
      fi
    done
    if [ "${fail_count}" -eq 0 ]; then
      echo "${ip}" > "${LAST_IP_FILE}"
      log "All records updated successfully."
    else
      log_err "${fail_count} record(s) failed to update. Will retry next cycle."
    fi
    last_no_change_log=$(date +%s)
  else
    # IP hasn't changed — check if any individual records are missing or stale
    missing_records=""
    for record in $(echo "${RECORDS}" | tr ',' ' '); do
      record="$(echo "${record}" | tr -d ' ')"
      [ -z "${record}" ] && continue
      if record_needs_update "${record}" "${ip}"; then
        missing_records="${missing_records} ${record}"
      fi
    done

    if [ -n "${missing_records}" ]; then
      log "IP unchanged (${ip}) but some records need updating:${missing_records}"
      fail_count=0
      for record in ${missing_records}; do
        if ! update_record "${record}" "${ip}"; then
          fail_count=$((fail_count + 1))
        fi
      done
      if [ "${fail_count}" -eq 0 ]; then
        log "All missing/stale records updated successfully."
      else
        log_err "${fail_count} record(s) failed to update. Will retry next cycle."
      fi
      last_no_change_log=$(date +%s)
    else
      now=$(date +%s)
      elapsed=$((now - last_no_change_log))
      if [ "${elapsed}" -ge 86400 ]; then
        log "No changes needed in the last 24h (IP still ${ip}, all records correct). Next log in 24h."
        last_no_change_log=${now}
      fi
    fi
  fi

  sleep "${INTERVAL}"
done
