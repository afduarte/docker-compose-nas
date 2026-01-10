#!/bin/sh
set -eu

STATE_DIR="${STATE_DIR:-/var/lib/route53-ddns}"
LAST_IP_FILE="${STATE_DIR}/last_ip"
INTERVAL="${ROUTE53_UPDATE_INTERVAL:-300}"
TTL="${ROUTE53_TTL:-300}"
ZONE_ID="${ROUTE53_ZONE_ID:-}"
RECORDS="${ROUTE53_RECORDS:-}"

mkdir -p "${STATE_DIR}"

if [ -z "${ZONE_ID}" ] || [ -z "${RECORDS}" ]; then
  echo "ROUTE53_ZONE_ID and ROUTE53_RECORDS must be set."
  exit 1
fi

get_public_ip() {
  curl -fsS https://checkip.amazonaws.com || curl -fsS https://api.ipify.org
}

update_record() {
  record_name="$1"
  ip="$2"

  case "${record_name}" in
    *.) fqdn="${record_name}" ;;
    *) fqdn="${record_name}." ;;
  esac

  cat > /tmp/route53-change.json <<EOF
{ "Comment": "Route53 DDNS update", "Changes": [ { "Action": "UPSERT", "ResourceRecordSet": { "Name": "${fqdn}", "Type": "A", "TTL": ${TTL}, "ResourceRecords": [ { "Value": "${ip}" } ] } } ] }
EOF

  aws route53 change-resource-record-sets \
    --hosted-zone-id "${ZONE_ID}" \
    --change-batch file:///tmp/route53-change.json \
    >/dev/null
}

while true; do
  ip="$(get_public_ip || true)"
  if [ -z "${ip}" ]; then
    echo "Failed to determine public IP."
    sleep "${INTERVAL}"
    continue
  fi

  last_ip=""
  if [ -f "${LAST_IP_FILE}" ]; then
    last_ip="$(cat "${LAST_IP_FILE}")"
  fi

  if [ "${ip}" != "${last_ip}" ]; then
    for record in $(echo "${RECORDS}" | tr ',' ' '); do
      record="$(echo "${record}" | tr -d ' ')"
      [ -z "${record}" ] && continue
      update_record "${record}" "${ip}"
    done
    echo "${ip}" > "${LAST_IP_FILE}"
    echo "$(date -Iseconds) IP changed to ${ip}, updated Route53 records."
  fi

  sleep "${INTERVAL}"
done
