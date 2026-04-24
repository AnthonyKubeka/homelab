# homelab

GitOps-managed homelab infrastructure. All services run as Docker Compose stacks on a single Ubuntu server, deployed automatically via a self-hosted Forgejo CI/CD pipeline.

Push to `main` → Forgejo Actions picks up the change → runner on the server executes `deploy-stack.sh <stack>` → Docker Compose applies the diff. No SSH required for normal operations. Config files are bind-mounted read-only from the repo, so the repo is always the source of truth.

```mermaid
flowchart LR
    dev[Dev machine] -->|git push| forgejo[Forgejo\nself-hosted]
    forgejo -->|Actions runner| deploy[deploy-stack.sh]
    deploy --> bootstrap[bootstrap-host.sh\ncreate base dirs]
    bootstrap --> compose[docker compose up]
    compose --> caddy[Caddy reload]
```

---

## Stacks

Each stack is independently deployable. `core` is the only required one — all others are optional and can be added or skipped freely.

| Stack | Services | Required? |
|-------|----------|-----------|
| `core` | Caddy (reverse proxy + TLS), AdGuard Home (DNS), Forgejo, Portainer | Yes |
| `observability` | Prometheus, Grafana, Node Exporter, cAdvisor, Homepage | No |
| `media` | Plex (optional GPU), qBittorrent, Radarr, Sonarr, Prowlarr, FlareSolverr | No |
| `apps` | Calibre, FileBrowser | No |
| `home` | Home Assistant, Matter Server | No |

```mermaid
graph TD
    subgraph core
        Caddy
        AdGuard
        Forgejo
        Portainer
    end
    subgraph media
        Plex
        qBittorrent
        Radarr
        Sonarr
        Prowlarr
    end
    subgraph apps
        Calibre
        FileBrowser
    end
    subgraph home
        HomeAssistant
        MatterServer
    end
    subgraph observability
        Prometheus
        Grafana
        NodeExporter
        cAdvisor
        Homepage
    end

    Caddy -->|reverse proxy| media
    Caddy -->|reverse proxy| apps
    Caddy -->|reverse proxy| home
    Caddy -->|reverse proxy| observability
    Prometheus -->|scrapes| NodeExporter
    Prometheus -->|scrapes| cAdvisor
    Grafana -->|queries| Prometheus
```

---

## Architecture highlights

### Reverse proxy + TLS
Caddy runs with `network_mode: host` and handles TLS for all subdomains via a **DNS challenge** (custom-built Caddy binary with a `caddy-dns/<provider>` plugin). No ports are exposed to the internet — TLS certs are issued entirely via DNS. The domain is set once as `HOMELAB_DOMAIN=yourdomain.com` in `caddy.env` and referenced everywhere in the Caddyfile as `{$HOMELAB_DOMAIN}`. The repo uses Porkbun as the DNS provider but any provider with a Caddy plugin works.

### DNS: split-horizon with AdGuard + Tailscale

```mermaid
flowchart TD
    lan[LAN device] -->|DNS query| adguard[AdGuard Home\nport 53]
    adguard -->|rewrite *.yourdomain.com| server_lan[Server LAN IP → Caddy]

    remote[Remote device\non Tailscale] -->|split DNS\nyourdomain.com queries| adguard
    adguard -->|same rewrite| server_lan

    caddy_build[Custom Caddy build\ncaddy-dns/porkbun] -->|DNS challenge| porkbun[Porkbun API\nTLS cert issuance]
```

- **LAN**: Router DHCP points to AdGuard. AdGuard rewrites `*.yourdomain.com → server LAN IP` so local devices always hit Caddy directly.
- **Remote (Tailscale)**: Tailscale split DNS routes `yourdomain.com` queries to AdGuard via the server's Tailscale IP. Same resolution, no public exposure.
- **Result**: Everything works identically on LAN and Tailscale with a single Caddyfile and real TLS certs everywhere.

### Secrets
Never committed. Live at `/opt/homelab/secrets/` on the server. Example files are in `infra/secrets/examples/`. `deploy-stack.sh` validates stack-specific secrets exist and creates that stack's data directories before deploying.

---

## Installation

### Prerequisites
- Ubuntu server (or any systemd-based Linux)
- Docker + Docker Compose plugin
- A domain with Porkbun DNS (or adapt the Caddy build for your DNS provider)
- A Forgejo instance with an Actions runner on the server — can be self-hosted via the `core` stack itself

---

### Core (required)

#### 1. Clone the repo

```bash
sudo mkdir -p /opt/homelab && sudo chown $USER:$USER /opt/homelab
git clone https://github.com/AnthonyKubeka/homelab.git /opt/homelab/repo
cd /opt/homelab/repo
```

#### 2. Run setup

```bash
bash infra/scripts/setup.sh
```

Creates the base directory structure and copies example secrets into place.

#### 3. Fill in secrets

```bash
nano /opt/homelab/secrets/core/caddy.env    # PORKBUN_API_KEY, PORKBUN_API_SECRET, HOMELAB_DOMAIN
nano /opt/homelab/secrets/core/forgejo.env  # update domain references
```

#### 4. Build the custom Caddy binary

Caddy needs a DNS provider plugin compiled in for the DNS challenge. This repo uses Porkbun — replace `caddy-dns/porkbun` with your provider if different. Full list: https://caddyserver.com/docs/modules/dns.providers

```bash
sudo apt install golang -y
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest

# Replace caddy-dns/porkbun with your DNS provider's plugin
xcaddy build \
  --with github.com/caddy-dns/porkbun \
  --output /opt/homelab/caddy/caddy

# Dockerfile so Docker Compose can build the image
cat > /opt/homelab/caddy/Dockerfile <<'EOF'
FROM ubuntu:22.04
COPY caddy /usr/bin/caddy
ENTRYPOINT ["/usr/bin/caddy"]
EOF
```

If you switch providers, also update the `(dns_tls)` snippet in `infra/docker/config/caddy/Caddyfile` and the corresponding env vars in `caddy.env`.

#### 5. Trim the Caddyfile

Remove entries for stacks you won't be deploying. Caddy issues TLS certs for every subdomain in the file, so only keep what you'll actually use:

```bash
nano infra/docker/config/caddy/Caddyfile
```

#### 6. Deploy core

```bash
REPO_ROOT=/opt/homelab/repo /opt/homelab/repo/infra/scripts/deploy-stack.sh core
```

#### 7. Configure AdGuard

In the AdGuard UI (`http://server-lan-ip:3002`):
- **Filters → DNS rewrites**: `*.yourdomain.com` → server LAN IP
- **Settings → DNS settings**: upstream DNS set to `https://dns.cloudflare.com/dns-query`

Point your router's DHCP DNS server at the server's LAN IP.

---

### Observability (optional)

```bash
nano /opt/homelab/secrets/observability/grafana.env  # set admin password
REPO_ROOT=/opt/homelab/repo /opt/homelab/repo/infra/scripts/deploy-stack.sh observability
```

Grafana available at `https://grafana.yourdomain.com`. Prometheus scrapes Node Exporter and cAdvisor automatically.

---

### Media (optional)

Update volume mounts to point at your drives:

```bash
nano /opt/homelab/repo/infra/docker/compose/media/docker-compose.yml
# Set /mnt/media and /mnt/torrents to your actual mount points
```

If you have an NVIDIA GPU for Plex transcoding, ensure the NVIDIA Container Toolkit is installed. Otherwise remove the `runtime: nvidia` and `deploy.resources` block from the Plex service.

```bash
REPO_ROOT=/opt/homelab/repo /opt/homelab/repo/infra/scripts/deploy-stack.sh media
```

---

### Apps (optional)

```bash
# Optionally update the Calibre books path in docker-compose.yml
nano /opt/homelab/repo/infra/docker/compose/apps/docker-compose.yml

REPO_ROOT=/opt/homelab/repo /opt/homelab/repo/infra/scripts/deploy-stack.sh apps
```

---

### Home (optional)

Update the Zigbee dongle device path and HA external URL:

```bash
nano /opt/homelab/repo/infra/docker/compose/home/docker-compose.yml     # update device path
nano /opt/homelab/repo/infra/docker/config/homeassistant/configuration.yaml  # update external_url
```

```bash
REPO_ROOT=/opt/homelab/repo /opt/homelab/repo/infra/scripts/deploy-stack.sh home
```

---

### Remote access via Tailscale (optional)

Install Tailscale on the server, then configure split DNS in the Tailscale admin console:
- **DNS → Nameservers**: add the server's Tailscale IP, restricted to `yourdomain.com`

Point your Porkbun A records to the server's Tailscale IP. Remote clients on Tailscale will resolve `*.yourdomain.com` via AdGuard and route through Tailscale — no port forwarding needed.

---

## Repo layout

```
infra/
├── docker/
│   ├── compose/          # one directory per stack
│   └── config/           # bind-mounted config files (Caddyfile, prometheus.yml, etc.)
├── scripts/
│   ├── setup.sh          # run once on a fresh host
│   ├── bootstrap-host.sh # run on every deploy — ensures base dirs exist
│   └── deploy-stack.sh   # called by CI; creates stack dirs, validates secrets, deploys
├── secrets/
│   └── examples/         # .env.example files copied by setup.sh
└── .forgejo/workflows/   # one workflow file per stack
```
