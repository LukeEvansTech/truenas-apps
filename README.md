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
| `apps/monitoring/`       | node-exporter `:9100` + smartctl-exporter `:9633` + truenas-graphite bridge `:9108` (ingest `:9109`) + docker-state-exporter `:9419` (host network, scraped by cluster Prometheus) |
| `apps/syncthing/`        | Syncthing (`syncthing.…`); carries the device ID/keys so the Mac↔box pairing survives. config+data at `/mnt/pool/apps/syncthing/{config,data}` |
| `apps/garage/`           | Garage S3 (`s3-nas.…`) + webui (`garage-nas.…`), fronted by Traefik. Data at `/mnt/pool/apps/garage` |

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
| 6 | **`op://Home Operations/Cloudflare/truenas-traefik-dns01`** — Cloudflare API token (Zone:DNS:Edit). `codelooks.com` is the only real CF zone; `*.core.codelooks.com` resolves under it (internal Unbound), so a single-zone token covers DNS-01 for both wildcards | ✅ done (2026-06-15) |
| 7 | **1Password service account** `doco-cd - TrueNAS Apps` (read on Home Operations) → `/root/.doco-cd/1pw_token` (`chmod 600`) | ✅ done (2026-06-15; token also backed up to `op://Home Operations/doco-cd - TrueNAS Apps/credential`) |
| 8 | DNS host-overrides applied (`network-ops` `opnsense-dns` playbook) | ✅ done (all hosts → `10.32.8.34`; applied at the syncthing cutover) |

All prereqs done — doco-cd is bootstrapped and reconciling.

## Bootstrap (after #6 + #7 are in place)

```bash
# on the NAS:
git clone https://github.com/LukeEvansTech/truenas-apps.git /root/truenas-apps
cd /root/truenas-apps/bootstrap && docker compose up -d   # starts doco-cd
# doco-cd polls this repo and deploys every stack in apps/ (traefik, dozzle, monitoring, syncthing, garage).
```

Keep the **bootstrap** itself current with a TrueNAS cron job (apps update via doco-cd polling):
`/root/truenas-apps/scripts/cron.sh /root/truenas-apps`.

## Cutover notes (how the pre-existing instances were migrated — kept for reference)

Each of these previously ran as an `ix-*` app or standalone container. doco-cd collides on
container names / host ports, so the old instance was retired as each stack came up. All are
now live under `apps/`; the procedures below are retained as the record of how the data moved.

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

### garage — adopted ✅ (2026-06-15, after the MinIO→Garage migration completed)

The MinIO→Garage data migration is **done and verified** (veeam + arq object counts exact-match,
0 errors). Garage was then adopted into doco-cd by:

1. Restoring the three `GARAGE_*` refs in `.doco-cd.yaml`.
2. `git mv staged/garage apps/garage` so auto-discover deploys it.
3. doco-cd recreated the container on the **same `/mnt/pool/apps/garage` data** — buckets/layout
   persisted. S3 now fronts at `https://s3-nas.codelooks.com` (webui `https://garage-nas.codelooks.com`);
   the k8s cluster→NAS sync CronJob is repointed to that HTTPS host.

### minio — suspended (data retained), pending producer repoint → then decommission

MinIO is **stopped** (`midclt call app.stop minio`; data still on disk, not destroyed). Remaining:
repoint the **Veeam/Arq** producers to `s3-nas`, verify writes, then decommission MinIO and disable
the deprecated `s3` service.

## Status (2026-06-21)

All five stacks (**traefik · dozzle · monitoring · syncthing · garage**) are live under `apps/` and
reconciling via doco-cd; `staged/` is empty. The MinIO→Garage migration is complete and verified
(veeam + arq object counts exact-match, 0 errors); Garage S3 fronts at `https://s3-nas.codelooks.com`.
Remaining: repoint the **Veeam/Arq** producers to `s3-nas`, then decommission the suspended MinIO and
disable the deprecated `s3` service.
