#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found"
  exit 1
fi

if ! command -v ip >/dev/null 2>&1; then
  echo "ip command not found"
  exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This repair changes host bridge addresses. Run it with sudo:"
  echo "  sudo $0"
  exit 1
fi

network_names="$(docker network ls --filter driver=bridge --format '{{.Name}}')"

while IFS= read -r network_name; do
  [ -n "$network_name" ] || continue

  network_id="$(docker network inspect --format '{{.Id}}' "$network_name")"
  bridge_name="$(docker network inspect --format '{{index .Options "com.docker.network.bridge.name"}}' "$network_name")"

  if [ -z "$bridge_name" ] || [ "$bridge_name" = "<no value>" ]; then
    if [ "$network_name" = "bridge" ]; then
      bridge_name="docker0"
    else
      bridge_name="br-${network_id:0:12}"
    fi
  fi

  if ! ip link show "$bridge_name" >/dev/null 2>&1; then
    echo "skip $network_name: bridge $bridge_name does not exist"
    continue
  fi

  ip link set "$bridge_name" up

  docker network inspect --format '{{range .IPAM.Config}}{{if .Gateway}}{{println .Gateway .Subnet}}{{end}}{{end}}' "$network_name" |
    while read -r gateway subnet; do
      [ -n "${gateway:-}" ] || continue
      [ -n "${subnet:-}" ] || continue

      prefix="${subnet#*/}"
      gateway_cidr="${gateway}/${prefix}"

      if ip -o -4 addr show dev "$bridge_name" | awk '{print $4}' | grep -Fxq "$gateway_cidr"; then
        echo "ok $network_name: $bridge_name has $gateway_cidr"
      else
        ip addr add "$gateway_cidr" dev "$bridge_name"
        echo "repaired $network_name: added $gateway_cidr to $bridge_name"
      fi
    done
done <<< "$network_names"
