# truenas-apps

GitOps source of truth for the Docker apps running on the **cr-storage** TrueNAS box,
managed by [doco-cd](https://doco.cd) (Flux-style: this repo is the single source of truth;
doco-cd polls it and reconciles). Secrets are injected from **1Password** at deploy time — no
secrets in git. Modelled on [mirceanton/truenas-apps](https://github.com/mirceanton/truenas-apps).

> Replaces the GUI-managed TrueNAS catalog apps (`ix-*`) with declarative compose stacks.

## Layout

| Path                     | What                                                                                                           |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `.doco-cd.yaml`          | doco-cd config — auto-discovers `apps/*`, maps `op://` → env                                                   |
| `bootstrap/compose.yaml` | the doco-cd controller (deployed once; polls this repo)                                                        |
| `apps/traefik/`          | reverse proxy on `10.32.8.34`, wildcard TLS for `*.codelooks.com` + `*.core.codelooks.com` (Cloudflare DNS-01) |
| `apps/garage/`           | Garage S3 (`s3-nas.…`) + WebUI (`garage-nas.…`) — backup target, data at `/mnt/pool/apps/garage`               |
| `apps/dozzle/`           | read-only container/log UI (`dozzle.…`)                                                                        |
| `apps/monitoring/`       | node-exporter + smartctl-exporter (host network, scraped by cluster Prometheus)                                |
| `apps/syncthing/`        | Syncthing — GUI via Traefik (`syncthing.…`), sync ports direct on host                                         |

## Hostnames (resolve to `10.32.8.34` via OPNsense Unbound)

`traefik` · `garage-nas` · `s3-nas` · `dozzle` · `syncthing` — each under both
`codelooks.com` and `core.codelooks.com`.

## Prerequisites (one-time, before bootstrap)

1. **Alias IP `10.32.8.34/24` on `bond0`** (TrueNAS → Network → the bond interface → add alias;
   has a 60 s test/confirm). Traefik binds it because the UI owns `.33:80/443`.
2. **1Password service account** with read on the **Home Operations** vault →
   token at `/root/.doco-cd/1pw_token` on the NAS (`chmod 600`).
3. **DNS** — add Unbound host-overrides in `network-ops/ansible/vars/dns.yml`
   (`traefik`, `garage-nas`, `s3-nas`, `dozzle`, `syncthing` for both domains → `10.32.8.34`),
   apply the `opnsense-dns` playbook.
4. **Docker network**: `docker network create traefik_network` (referenced `external: true`).
5. **1Password items** referenced by `.doco-cd.yaml` (Home Operations vault):
   - `garage-nas`: `rpc_secret`, `admin_token` ✅ exist; **create** `WEBUI_AUTH_USER_PASS`
     (`htpasswd -nbB admin <pw>`), `DOZZLE_USERNAME`, `DOZZLE_AUTH`.
   - `Cloudflare`: `dns-api-token` (Cloudflare API token, Zone:DNS:Edit) + `acme-email` — **confirm/create**.

## Bootstrap

```bash
# on the NAS, after the prerequisites above:
git clone https://github.com/LukeEvansTech/truenas-apps.git /root/truenas-apps
cd /root/truenas-apps/bootstrap && docker compose up -d   # starts doco-cd
# doco-cd then polls this repo and deploys everything in apps/
```

Add a TrueNAS cron job to keep the **bootstrap** itself current (apps update via doco-cd polling):
`/root/truenas-apps/scripts/cron.sh /root/truenas-apps` _(see mirceanton reference)_.

## Adoption notes (these apps have existing data — preserve it)

- **garage** — adopt **only after the MinIO→Garage migration completes**. doco-cd recreates the
  container on the same `/mnt/pool/apps/garage` data, so buckets/layout persist. S3 moves behind
  Traefik (`https://s3-nas.codelooks.com`), so update the k8s cluster→NAS sync CronJob endpoint and
  Veeam/Arq to the HTTPS hostname.
- **syncthing** — copy config from the ix path first:
  `cp -a /mnt/.ix-apps/app_mounts/syncthing/config /mnt/pool/apps/syncthing/config`; data dataset
  `/mnt/pool/syncthing` is unchanged. Stop `ix-syncthing` before starting this stack (same sync ports).
- **monitoring** — stop the `ix-monitoring` exporters before starting (same host ports 9100/9633).
- **minio** — NOT migrated; decommissioned after the data migration + producer repoint.

## Status (2026-06-14)

Garage in-cluster (RF=3) + CNPG cutover live; MinIO→Garage 5 TB migration in progress; this repo is the
IaC layer to bring the NAS apps under doco-cd once the migration finishes.
