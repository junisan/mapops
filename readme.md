# 📍 MapOps

[![CI](https://github.com/junisan/mapops/actions/workflows/ci.yml/badge.svg)](https://github.com/junisan/mapops/actions/workflows/ci.yml)

**MapOps** is a production-ready, self-hosted geospatial services stack. It includes the following components:

-   **Nominatim** – Forward and reverse geocoding service.
-   **Photon** – Search-as-you-type geocoder built on top of Nominatim data.
-   **OpenRouteService (ORS)** – Routing and navigation service.

This repository contains everything needed to import, initialise and run these services from `.osm.pbf` files. All three services share the same map (`maps/map.osm.pbf`) to keep them spatially consistent.

The only requirements are docker and docker compose.

---
## ⚙️ 0. Initial setup

Create the importer variables file from the example and set your own password for the Nominatim database:

```sh
cp importer/vars.env.example importer/vars.env
openssl rand -hex 16   # generate a password and use it for NOMINATIM_PASSWORD and DB_PASSWORD
```

> **Important:** `importer/vars.env` holds credentials and is gitignored: never commit it. The `mapops` docker network is *attachable*: any container joined to it can reach Nominatim's Postgres, so treat that password as a secret.

Create the shared docker network (other applications join it to consume the services; `mapops.sh` also creates it automatically when missing):

```sh
docker network create --attachable mapops
```

Prepare the ORS directories with the right owner:

```sh
mkdir -p ors/config ors/elevation_cache ors/graphs ors/logs
sudo chown -R 1000:1000 ors
```

Host ports are published on `127.0.0.1` only, in an uncommon range so they never clash with other applications: **17070** (Nominatim), **17071** (Photon), **17072** (ORS) and **17073** (ORS monitoring). Override them by creating a `.env` file next to `docker-compose.yml`:

```sh
# .env (optional)
MAPOPS_MODE=full
NOMINATIM_PORT=17070
PHOTON_PORT=17071
ORS_PORT=17072
ORS_MONITOR_PORT=17073
```

> Other applications normally do not use these ports: they reach the containers through the `mapops` docker network (`http://nominatim:8080`, `http://photon:2322`, `http://ors:8082`) or through the nginx proxy (`nginx.example.conf`). The host ports are for nginx and local troubleshooting.

### Installation modes

Not every installation needs all three services. `MAPOPS_MODE` (in `.env`) selects which components `mapops.sh` manages in `import`, `up`, `down` and `status`:

| Mode | Services | Typical use |
|---|---|---|
| `full` (default) | Nominatim + Photon + ORS | The whole stack |
| `geocoding` | Nominatim + Photon | Full geocoding, no routing |
| `photon` | Photon only | Autocomplete/lightweight geocoding: Nominatim acts as an ephemeral importer and its data (~30-50 GB for Spain) **is destroyed after each import** (asks for confirmation unless `-y`) |
| `ors` | ORS only | Routing only |

## 🗺️ 1. Load a map

Every service needs a map: ORS to route between coordinates, Nominatim/Photon for the labels. The map lives at `maps/map.osm.pbf` and is shared by ORS (mounted at `/home/ors/files`) and the Nominatim importer.

The most convenient way is `mapops.sh`, which downloads [Geofabrik](https://download.geofabrik.de/) extracts verifying their md5 and, when you name several regions, merges them with osmium into a single map:

```sh
./mapops.sh fetch europe/spain                            # one country
./mapops.sh fetch spain-full                              # alias: Spain + Canary Islands
./mapops.sh fetch europe/spain/madrid europe/spain/castilla-la-mancha   # individual regions
./mapops.sh fetch europe/spain africa/canary-islands europe/andorra     # any combination
```

Any Geofabrik extract path works (continent, country or sub-region; Spain's autonomous communities live under `europe/spain/…` and the Canary Islands separately at `africa/canary-islands`).

> Combined extracts must be from the same day (they overlap at borders); `fetch` downloads them all in a single run and stores a manifest with regions and date at `maps/manifest.txt`.

ORS is not forced to use the same map as Nominatim/Photon: `./mapops.sh fetch --ors <region...>` builds an independent `maps/ors.osm.pbf` (with its own manifest). To use it, point `source_file` in `ors-config.yml` at `/home/ors/files/ors.osm.pbf`. Useful when you want, say, mainland-only routing but geocoding with islands.

You can also place any `.osm.pbf` by hand (for example a [BBBike](https://extract.bbbike.org/) custom extract) at `maps/map.osm.pbf`.

> **Important:** the file name must be exactly `maps/map.osm.pbf`.

## 🚀 2. ORS. Route calculation service

Head to `ors/config/`. You will find example ORS configuration files there: the most exhaustive one, the minimum viable one, etc. We recommend starting from the minimal file and building your own configuration from it. Either way you must define an `ors-config.yml` file and reference the map in it as `files/map.osm.pbf`.

Once done, start the container in detached mode and follow the process with `docker logs`:

```sh
docker compose up -d ors
docker logs -f ors
```

On first start ORS builds its graphs. This may take several minutes for a regional map and hours for a large country or a continent. To rebuild the graphs after changing the map, start once with `REBUILD_GRAPHS=True docker compose up -d --force-recreate ors` (the `mapops.sh import` script does this automatically).

When the process finishes (`curl http://localhost:17072/ors/v2/health` returns `"status":"ready"`), it is ready to serve:

```sh
curl -X POST "http://localhost:17072/ors/v2/directions/driving-car" \
  -H "Content-Type: application/json" \
  -d '{
    "coordinates": [
      [-5.512451, 40.352344],
      [-4.683147, 40.647345]
    ],
    "instructions": true,
    "language": "es",
    "units": "km"
  }'
```

## 🌍 3. Geocoding: Nominatim and Photon

These services resolve a name or address into coordinates (geocoding) and, the other way around, find the name and address of given coordinates (reverse geocoding).

Nominatim is the de-facto standard, maintained by the OpenStreetMap team. It is very precise and well structured, but it needs more compute and does not support search-as-you-type autocompletion.

Photon fills that gap: it is less precise than Nominatim but, being built on OpenSearch, it is extremely fast and supports autocompletion. To run, Photon imports its data from the Postgres database that Nominatim keeps already structured.

A complete system can autocomplete with Photon and fall back to Nominatim once the user finishes typing. This project ships both; you can later keep either one or both.

### Unattended import (recommended)

```sh
./mapops.sh import
```

The script chains the whole process: stops the production services, wipes the previous data, imports Nominatim, waits for it to finish (healthcheck on `/status`), imports Photon, rebuilds the ORS graphs and brings production back up. It is a **maintenance window**: Nominatim and Photon stay down during the import (hours or days depending on the map); ORS keeps serving the old graphs until the final phase.

To refresh the data later, `./mapops.sh update` repeats `fetch` (reusing the manifest regions) + `import`. An update is always a full reimport: OSM replication diffs do not work with merged maps.

### Manual import (step by step)

<details>
<summary>Expand the manual procedure</summary>

The import compose lives at `importer/docker-compose.yml` (ephemeral containers, separate from the production compose). It uses the `mapops` network as external: if production has never started on this machine, create it first with `docker network create --attachable mapops`.

#### 3.1 Import data into Nominatim

Make sure the map exists at `maps/map.osm.pbf` and start the importer:

```sh
docker compose -f importer/docker-compose.yml up -d nominatim-importer
docker logs -f nominatim-importer
```

> Start nominatim-importer detached (background) so that when the import finishes the server keeps running and lets Photon connect.

Wait until the logs show:
```
[INFO] Starting gunicorn ...
[INFO] Listening at: http://0.0.0.0:8080 ...
```
This means the database build finished correctly (the container healthcheck turns `healthy` at that point).

#### 3.2 Import data into Photon

Photon has no official docker image, so this project publishes its own: [`ghcr.io/junisan/photon`](https://github.com/junisan/mapops/pkgs/container/photon) (multi-arch amd64/arm64, built by CI from `importer/`; it downloads the official jar verifying its sha256 and ships a static `wget` for healthchecks). It is pulled from GHCR by default; if you prefer building it yourself, `importer/docker-compose.yml` keeps the `build:` context — add `--build` to the command. Import the Nominatim data:

```sh
docker compose -f importer/docker-compose.yml up --build photon-importer
```
> Do not use `-d` here. The container exits by itself when the import completes. Thanks to the healthcheck, this command alone waits for Nominatim to finish its import first.

The import starts when you see `Start importing documents...`. When it finishes, the container exits automatically.

#### 3.3 Nominatim and Photon in production

With both imports completed, start the production containers:

```sh
docker compose up -d nominatim photon
```

#### 3.4 Importer cleanup

```sh
docker compose -f importer/docker-compose.yml down
rm maps/map.osm.pbf   # optional; needed again for the next import
```

</details>

### Verification

```sh
curl "http://localhost:17070/search?q=Madrid&format=json"  # Nominatim 
curl "http://localhost:17071/api?q=Gran+Vía"  # Photon
```
> Mind your map's coverage and query addresses or coordinates included in it. Also mind any port overrides.

**(Optional)**: you can drop the Nominatim data if you will not use the service (you only loaded it for Photon). In that case, and only then:

```sh
docker compose stop nominatim
docker compose rm nominatim
docker rmi mediagis/nominatim:5.3
rm -rf nominatim-data
```

## 🔁 Builder node and serving node (pack / restore)

A full reimport can take a day for a large country. To avoid that much downtime, a second node (another machine, or another directory on the same host, with this same repo) can act as the **builder**:

```sh
# Node B (builder): imports and packages
./mapops.sh update -y
./mapops.sh pack                 # → exports/mapops-<date>/ with the mode's data

# Move the bundle to node A (rsync resumes)
rsync -avP exports/mapops-<date>/ nodeA:/path/mapops/exports/mapops-<date>/

# Node A (serving): restore — its downtime shrinks to the restore time
./mapops.sh restore exports/mapops-<date> -y
```

`pack` stops the services briefly for a consistent snapshot and records the mode, architecture and image versions in `bundle.txt`; `restore` validates all of that before touching anything and replaces the data of the current mode's components.

> **Architectures**: Photon data and ORS graphs are portable across architectures (Java indexes). `nominatim-data` is a binary Postgres directory and **only moves between nodes of the same architecture** (e.g. arm64→x86_64 is not supported); `restore` rejects it automatically on mismatch. Both nodes must run the same image versions (same commit of this repo).

## 🩺 Operations

- `./mapops.sh up`, `down` and `status` start, stop and inspect the services of the configured mode (`status` shows health, data sizes and manifests).
- Every production service has `restart: unless-stopped` and a healthcheck (`/status` on Nominatim and Photon, `/ors/v2/health` on ORS); `docker ps` shows their state.
- Ports are published on `127.0.0.1` only, range 17070-17073 (configurable via `.env`); other applications go through the `mapops` docker network or a proxy (see `nginx.example.conf`, which includes example rate limiting).
- Nominatim data stays frozen at the imported map's date. Schedule `./mapops.sh update -y` if you need fresh data (the internal lock prevents overlapping runs):
  ```cron
  # Monthly update, 1st day at 03:00
  0 3 1 * * cd /path/to/mapops && ./mapops.sh update -y >> /var/log/mapops-update.log 2>&1
  ```
- `import` checks upfront that there is enough disk (estimated from the PBF; `MAPOPS_SKIP_DISK_CHECK=1` skips it).
- Cheap rollback: a `./mapops.sh pack` before an `update`/`restore` leaves a bundle of the current data you can return to with `restore`.
- Container logs rotate on their own (json-file, 10MB × 5).

## 🤝 Contributing

If you want to help, open a *pull request* or create an *issue* with suggestions, improvements or bug reports.

## 📄 License

MapOps — Geospatial Services Platform. Copyright (C) 2025 Juan Nicolás.

This project is distributed under the terms of the **GNU General Public License v3.0 (GPLv3)**.

This means:

- You may use, modify and redistribute this software freely.
- Any modification or redistribution must remain under GPLv3.
- You must always include the original license text.

MapOps includes GPLv3-licensed components (such as Nominatim and OpenRouteService), so this license applies to the project as a whole.

For details, see the [LICENSE](./LICENSE) file or visit [gnu.org/licenses/gpl-3.0](https://www.gnu.org/licenses/gpl-3.0.html).
