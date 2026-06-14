# truenas-apps

GitOps source of truth for the Docker apps running on the **cr-storage** TrueNAS box,
managed by [doco-cd](https://doco.cd) (Flux-style: this repo is the single source of truth;
doco-cd polls it and reconciles). Secrets are injected from **1Password** at deploy time — no
secrets in git. Modelled on [mirceanton/truenas-apps](https://github.com/mirceanton/truenas-apps).

> Replaces the GUI-managed TrueNAS catalog apps (`ix-*`) with declarative compose stacks.
> **All app data is consolidated under `/mnt/pool/apps/<app>/…`** (on the pool, snapshotted) —
> not in anonymous docker volumes on the boot area.

## Layout

| Path                     | What                                                                                                           |
| ------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `.doco-cd.yaml`          | doco-cd config — auto-discovers `apps/*`, maps `op://` → env                                                   |
| `bootstrap/compose.yaml` | the doco-cd controller (deployed once; polls this repo). State at `/mnt/pool/apps/doco-cd/data`                |
| `apps/traefik/`          | reverse proxy on `10.32.8.34`, wildcard TLS for `*.codelooks.com` + `*.core.codelooks.com` (Cloudflare DNS-01). acme/state at `/mnt/pool/apps/traefik` |
| `apps/dozzle/`           | read-only container/log UI (`dozzle.…`)                                                                        |
| `apps/monitoring/`       | node-exporter + smartctl-exporter (host network, scraped by cluster Prometheus)                                |
| `apps/syncthing/`        | Syncthing — GUI via Traefik (`syncthing.…`), sync ports direct on host. config+data at `/mnt/pool/apps/syncthing/{config,data}` |
| `staged/garage/`         | **Garage S3 — staged OUT of `apps/`** until the MinIO→Garage migration finishes (see below). Move back into `apps/garage/` to deploy. Data at `/mnt/pool/apps/garage` |

## Hostnames (resolve to `10.32.8.34` via OPNsense Unbound)

`traefik` · `garage-nas` · `s3-nas` · `dozzle` · `syncthing` — each under both
`codelooks.com` and `core.codelooks.com`.

## Prerequisites (one-time, before bootstrap)

| # | Prereq | State |
| - | ------ | ----- |
| 1 | Alias IP `10.32.8.34/24` on `bond0` (Traefik binds it; UI owns `.33`) | ✅ done (network-ops PR #61, via `midclt`) |
| 2 | UI rebound `ui_address` `0.0.0.0`→`10.32.8.33` so `.34:443` is free | ✅ done (verified `.34:443` refuses) |
| 3 | `docker network create traefik_network` | ✅ done |
| 4 | Datasets `pool/apps/{traefik,doco-cd,syncthing}` | ✅ done |
| 5 | `op` items: `Cloudflare/acme-email`, `garage-nas/DOZZLE_USERNAME`, `garage-nas/DOZZLE_AUTH` (bcrypt) | ✅ done (login user `admin`; plaintext at `garage-nas/DOZZLE_PASSWORD`) |
| 6 | **`op://Home Operations/Cloudflare/dns-api-token`** — Cloudflare API token, Zone:DNS:Edit on both zones | ❌ **YOU create** |
| 7 | **1Password service account** (read on Home Operations) → `/root/.doco-cd/1pw_token` (`chmod 600`) | ❌ **YOU create** |
| 8 | DNS host-overrides applied (`network-ops` `opnsense-dns` playbook) | ⏳ apply **at cutover** (flips syncthing `.33`→`.34` in lockstep with its migration) |

Only **#6 and #7** are left, and both require your 1Password / Cloudflare access.

## Bootstrap (after #6 + #7 are in place)

```bash
# on the NAS:
git clone https://github.com/LukeEvansTech/truenas-apps.git /root/truenas-apps
cd /root/truenas-apps/bootstrap && docker compose up -d   # starts doco-cd
# doco-cd polls this repo and deploys everything in apps/ (traefik, dozzle, monitoring, syncthing).
# garage stays in staged/ → NOT deployed until adopted (below).
```

Keep the **bootstrap** itself current with a TrueNAS cron job (apps update via doco-cd polling):
`/root/truenas-apps/scripts/cron.sh /root/truenas-apps`.

## Cutover notes (existing instances — preserve their data)

These apps already run (as `ix-*` apps or standalone containers). doco-cd will collide on
container names / host ports, so retire the old instance as each stack comes up.

### syncthing — config + data both move under `/mnt/pool/apps/syncthing`

Carries the **device ID/keys** (so the Mac↔box pairing survives — no re-add). Data dataset is
relocated with an instant `zfs rename` (no copy). Run with `ix-syncthing` **stopped**:

```bash
# 1. stop the old app (frees sync ports 22000/21027 + the config)
docker stop ix-syncthing-syncthing-1     # or disable the app in the TrueNAS UI

# 2. relocate the 21 GB data dataset pool/syncthing -> pool/apps/syncthing/data (instant)
zfs rename pool/syncthing pool/apps/syncthing/data

# 3. copy the syncthing config (note the doubled path: .../config/config is /var/syncthing/config)
cp -a /mnt/.ix-apps/app_mounts/syncthing/config/config/. /mnt/pool/apps/syncthing/config/

# 4. ownership — compose runs as PUID/PGID 568; make config+data writable by it
chown -R 568:568 /mnt/pool/apps/syncthing/config /mnt/pool/apps/syncthing/data
# (verify the UID ix-syncthing ran as first; 568 = TrueNAS 'apps' user / house standard)
```

Container folder paths stay `/syncthing/scratch` + `/syncthing/sideload` (the `data` bind maps to
`/syncthing`), so `config.xml` needs no path edits. After doco-cd starts syncthing, confirm the
device ID matches and folders re-sync, then **apply the DNS playbook** (flips `syncthing.*` → `.34`).

### monitoring — replace the standalone exporters

```bash
docker rm -f node-exporter smartctl-exporter truenas-graphite-exporter  # same names + host ports
# doco-cd then brings up apps/monitoring on the same ports (stateless; brief scrape gap)
```

The **TrueNAS-side** graphite feed is host/DB state (survives the container swap), already created
via the REST API and only needs doing once:

```bash
midclt call reporting.exporters.create '{"enabled": true, "name": "prometheus-graphite",
  "attributes": {"exporter_type": "GRAPHITE", "destination_ip": "127.0.0.1",
  "destination_port": 9109, "prefix": "truenas", "namespace": "truenas",
  "update_every": 10, "send_names_instead_of_ids": true, "matching_charts": "*"}}'
```

> **Metric-naming caveat:** TrueNAS 25.10 netdata emits *custom* charts (`truenas_arcstats`,
> `truenas_disk_stats`, `truenas_pool.usage`, `truenas_disk_temp`) — not the vanilla netdata
> charts (`zfs.arcstats`, `disk.io`) the bridge's baked mapping + the 5 upstream Grafana
> dashboards expect. So the exporter is **up and serving ARC / disk I/O / temps / pool-usage**,
> but the upstream dashboards need retuning to the `truenas_*` names (or deploy the upstream
> `netdata.conf` to switch netdata to vanilla charts — risks the TrueNAS Reporting UI + is
> middleware-overwritten on update, so prefer retuning the dashboards). No pool *state*/scrub
> chart exists on this box. `prefix` MUST be `truenas` (the mapping hardcodes it).

### garage — adopt only AFTER the MinIO→Garage migration completes

1. Restore the three `GARAGE_*` refs in `.doco-cd.yaml` (commented there).
2. `git mv staged/garage apps/garage` (move it back so auto-discover deploys it).
3. doco-cd recreates the container on the **same `/mnt/pool/apps/garage` data** — buckets/layout
   persist. S3 then fronts at `https://s3-nas.codelooks.com`; repoint the k8s cluster→NAS sync
   CronJob endpoint + Veeam/Arq to that HTTPS host.

### minio — NOT migrated; decommission after the data migration + producer repoint.

## Status (2026-06-14)

Garage in-cluster (RF=3) + CNPG cutover live; MinIO→Garage 5 TB migration in progress
(arq done, veeam ~60%). Prereqs 1–5 done; bootstrap waits on the Cloudflare token (#6) + the
1Password service account (#7). garage staged out until the migration finishes.
