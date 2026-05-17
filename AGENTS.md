# docker-compose-nas

This directory contains the Docker Compose NAS stack for `duarte-pc`.
It runs the reverse proxy, media automation, download clients, media
servers, DNS, photo services, and supporting utilities.

Most media-management and download-facing services share the `vpn`
container network namespace using `network_mode: "service:vpn"`. The
`vpn` service is Gluetun with ProtonVPN over OpenVPN, and services such
as Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, qBittorrent, Jellyseerr,
Homepage, and Tdarr depend on `vpn` becoming healthy before they start.

Traefik publishes the externally reachable HTTP/HTTPS entrypoints and
routes to services by labels. Data lives primarily under `/slow/media`
and downloads under `/media/torrents`; service config is rooted in this
directory via `CONFIG_ROOT=/home/antero/docker-compose-nas`.

## Operations

- Use `docker compose` from this directory so `.env` and the compose
  file set are resolved correctly.
- Do not add external USB drives to any LVM volume group.
- Be careful with `network_mode: "service:vpn"` services: they do not
  have their own Docker network stack or published ports. Their localhost
  checks and service ports are reached through the `vpn` namespace.

## Troubleshooting

### VPN Logs `EHOSTUNREACH` After Docker/Network Updates

Observed after a Linux/Docker networking update: Gluetun started but
could not reach ProtonVPN endpoints, logging OpenVPN errors like:

```text
read UDPv4 [EHOSTUNREACH]: Host is unreachable
TLS key negotiation failed to occur within 60 seconds
```

The root cause was not ProtonVPN credentials or Gluetun configuration.
Docker bridge interfaces had lost their host-side gateway IP addresses
and some bridges were down. Containers still had routes to Docker gateway
IPs such as `172.18.0.1`, but the host bridge did not actually own that
address, so all container egress failed.

Quick checks:

```bash
ip addr show br-a715bbddccec
docker network inspect docker-compose-nas
docker compose ps vpn qbittorrent sonarr radarr prowlarr
docker logs --tail 120 vpn
```

For the NAS compose network, the bridge should be up and should have:

```text
inet 172.18.0.1/16 scope global br-a715bbddccec
```

Docker's network definition should show:

```text
Subnet: 172.18.0.0/16
Gateway: 172.18.0.1
```

Preferred manual repair, if the gateway is missing:

```bash
cd /home/antero/docker-compose-nas
sudo scripts/repair-docker-bridge-gateways.sh
docker compose up -d
```

The script is idempotent. It reads Docker's bridge network definitions,
brings each host bridge up, and restores any missing Docker gateway CIDR
such as `172.18.0.1/16`. If it is run without root privileges, it exits
without making changes and prints the `sudo` command to use.

If local Docker bridge networks need inspection, use:

```bash
docker network ls
docker network inspect <network-name>
ip addr show <bridge-name>
```

Known bridge mappings from the current host:

```text
default bridge/docker0   docker0          172.17.0.1/16
docker-compose-nas       br-a715bbddccec  172.18.0.1/16
newsfilter_app-net       br-29885f0199eb  172.19.0.1/16
ollama-net               br-488ccd2d8e03  172.20.0.1/16
ememe_default            br-f21f40177990  172.21.0.1/16
```

After repair, verify VPN routing:

```bash
docker inspect --format '{{.State.Health.Status}}' vpn
docker exec vpn wget -qO- --timeout=10 https://ifconfig.me/ip
docker exec qbittorrent wget -qO- --timeout=10 https://ifconfig.me/ip
docker exec sonarr curl --fail --max-time 10 http://127.0.0.1:8989/sonarr/ping
```

The `vpn` and qBittorrent public IPs should match, and the app pings
should return OK.
