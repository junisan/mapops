#!/usr/bin/env bash
#
# mapops.sh — MapOps operations: map download, imports and services.
#
#   ./mapops.sh fetch [--ors] <region...>  Download Geofabrik extracts
#                                   (verifying .md5) and combine them into
#                                   maps/map.osm.pbf (or maps/ors.osm.pbf with --ors)
#   ./mapops.sh import [-y]         Reimport according to the mode (see
#                                   MAPOPS_MODE): Nominatim -> Photon and/or
#                                   ORS graphs. Maintenance window: current
#                                   data is wiped and reimported from maps/
#   ./mapops.sh update [-y] [region...]  fetch + import. Without regions it
#                                   reuses the manifests of the last fetch
#   ./mapops.sh up | down | status  Start/stop/inspect the mode's services
#   ./mapops.sh pack [dir]          Package the mode's data into exports/…
#                                   (services stop briefly) as a bundle
#                                   ready to move to another node
#   ./mapops.sh restore <dir> [-y]  Restore a bundle on this node (replaces
#                                   current data). Builder node (B) imports
#                                   -> pack -> rsync -> restore on the
#                                   serving node (A): A's downtime shrinks
#                                   to the restore time
#
# Installation mode — MAPOPS_MODE in .env (or as an environment variable):
#   full       Nominatim + Photon + ORS (default)
#   geocoding  Nominatim + Photon, no ORS
#   photon     Photon only: Nominatim is used for the import and its data
#              is destroyed afterwards (asks for confirmation unless -y)
#   ors        ORS only, no geocoding
#
# Regions are Geofabrik paths (country or sub-region where available):
#   europe/spain  europe/spain/madrid  europe/spain/andalucia  africa/canary-islands
# and can be combined freely. Available aliases:
#   spain-full  = europe/spain africa/canary-islands
# IMPORTANT: combined extracts must be downloaded the same day (they overlap
# at borders); fetch downloads all of them in a single run.
#
# Rough cost: combining large countries (e.g. Spain+France) produces a
# 150-200GB Nominatim database and roughly a one-day import.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAPS_DIR="$REPO_DIR/maps"
OSMIUM_IMAGE="iboates/osmium:1.19.0"
GEOFABRIK="https://download.geofabrik.de"

# Same overrides (ports, mode) that docker compose reads
# shellcheck disable=SC1091
[ -f "$REPO_DIR/.env" ] && . "$REPO_DIR/.env"
ORS_HEALTH_URL="http://127.0.0.1:${ORS_PORT:-17072}/ors/v2/health"
MODE="${MAPOPS_MODE:-full}"

case "$MODE" in
    full|geocoding|photon|ors) ;;
    *) printf '[mapops] ERROR: invalid MAPOPS_MODE: %s (use full|geocoding|photon|ors)\n' "$MODE" >&2; exit 1 ;;
esac

log() { printf '\n[mapops] %s\n' "$*"; }
die() { printf '\n[mapops] ERROR: %s\n' "$*" >&2; exit 1; }

# Which components take part in the current mode
wants_ors()             { [ "$MODE" = full ] || [ "$MODE" = ors ]; }
wants_photon()          { [ "$MODE" != ors ]; }
wants_nominatim_serve() { [ "$MODE" = full ] || [ "$MODE" = geocoding ]; }

mode_services() {
    local s=()
    wants_nominatim_serve && s+=(nominatim)
    wants_photon && s+=(photon)
    wants_ors && s+=(ors)
    echo "${s[@]}"
}

# With explicit -f compose does not auto-load overrides: add them by hand
compose() {
    local files=(-f "$REPO_DIR/docker-compose.yml")
    [ -f "$REPO_DIR/docker-compose.override.yml" ] && files+=(-f "$REPO_DIR/docker-compose.override.yml")
    docker compose "${files[@]}" "$@"
}
compose_import() {
    local files=(-f "$REPO_DIR/importer/docker-compose.yml")
    [ -f "$REPO_DIR/importer/docker-compose.override.yml" ] && files+=(-f "$REPO_DIR/importer/docker-compose.override.yml")
    docker compose "${files[@]}" "$@"
}

ensure_network() {
    docker network inspect mapops >/dev/null 2>&1 \
        || docker network create --attachable mapops >/dev/null
}

# Expand region aliases into Geofabrik paths
expand_regions() {
    local expanded=()
    for r in "$@"; do
        case "$r" in
            spain-full) expanded+=("europe/spain" "africa/canary-islands") ;;
            *)          expanded+=("$r") ;;
        esac
    done
    printf '%s\n' "${expanded[@]}"
}

md5_of() {
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | awk '{print $1}'
    else
        md5 -q "$1"
    fi
}

confirm() {
    read -r -p "$1 [y/N] " answer
    case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *) die "operation cancelled" ;;
    esac
}

cmd_fetch() {
    local target=map manifest_file=manifest.txt
    if [ "${1:-}" = "--ors" ]; then
        target=ors; manifest_file=manifest-ors.txt; shift
    fi
    [ "$#" -ge 1 ] || die "fetch needs at least one region (e.g. europe/spain, europe/spain/madrid or the spain-full alias)"
    local regions=()
    while IFS= read -r r; do regions+=("$r"); done < <(expand_regions "$@")
    set -- "${regions[@]}"
    mkdir -p "$MAPS_DIR/src"

    local files=()
    local manifest_lines=()
    local fetch_date
    fetch_date="$(date -u +%Y-%m-%d)"

    for region in "$@"; do
        local name url file
        name="$(echo "$region" | tr '/' '_')"
        url="$GEOFABRIK/${region}-latest.osm.pbf"
        file="$MAPS_DIR/src/${name}-latest.osm.pbf"

        log "Downloading $url"
        curl -fL --retry 3 -o "$file" "$url" || die "could not download $url"
        curl -fsL --retry 3 -o "$file.md5" "$url.md5" || die "could not download $url.md5"

        local expected actual
        expected="$(awk '{print $1}' "$file.md5")"
        actual="$(md5_of "$file")"
        [ "$expected" = "$actual" ] || die "md5 mismatch for $region (expected $expected, got $actual)"
        log "md5 OK for $region ($actual)"

        files+=("$file")
        manifest_lines+=("$region $actual")
    done

    if [ "${#files[@]}" -eq 1 ]; then
        log "Single region: copying to maps/${target}.osm.pbf"
        cp "${files[0]}" "$MAPS_DIR/${target}.osm.pbf"
    else
        log "Merging ${#files[@]} extracts with osmium ($OSMIUM_IMAGE)"
        local args=()
        for f in "${files[@]}"; do
            args+=("/maps/src/$(basename "$f")")
        done
        docker run --rm -u "$(id -u):$(id -g)" \
            -v "$MAPS_DIR:/maps" \
            --entrypoint osmium "$OSMIUM_IMAGE" \
            merge "${args[@]}" -o "/maps/${target}.osm.pbf" --overwrite \
            || die "osmium merge failed"
    fi

    {
        echo "date: $fetch_date"
        echo "regions:"
        for line in "${manifest_lines[@]}"; do echo "  $line"; done
    } > "$MAPS_DIR/$manifest_file"

    rm -rf "$MAPS_DIR/src"
    log "Done: maps/${target}.osm.pbf ($(du -h "$MAPS_DIR/${target}.osm.pbf" | awk '{print $1}')). Manifest at maps/$manifest_file"
}

confirm_import() {
    local affected=""
    wants_photon && affected="   - The contents of nominatim-data/ and photon-data/ are WIPED
   - nominatim and photon stay down for the whole import
     (hours or days depending on the map size)"
    wants_ors && affected="$affected
   - ORS will rebuild its graphs (it keeps serving the old ones until the end)"
    cat <<EOF

  WARNING [mode: $MODE]: the import is destructive and runs as a maintenance window:
$affected

EOF
    confirm "Continue?"
}

wipe_data_dir() {
    # Deletion runs inside a container: the files belong to container users.
    # $2 (optional) = file to preserve. nominatim-data must end up completely
    # empty: Postgres initdb refuses to initialise a non-empty directory.
    local keep="${2:-}"
    log "Wiping $1"
    mkdir -p "$REPO_DIR/$1"
    if [ -n "$keep" ]; then
        docker run --rm -v "$REPO_DIR/$1:/d" alpine \
            sh -c "find /d -mindepth 1 -name '$keep' -prune -o -exec rm -rf {} + 2>/dev/null; true"
    else
        docker run --rm -v "$REPO_DIR/$1:/d" alpine \
            sh -c 'find /d -mindepth 1 -exec rm -rf {} + 2>/dev/null; true'
    fi
}

wait_for_ors_ready() {
    log "Waiting for ORS to rebuild its graphs (this can take hours)..."
    while true; do
        local status
        status="$(curl -fs "$ORS_HEALTH_URL" 2>/dev/null | grep -o '"status" *: *"[^"]*"' | cut -d'"' -f4 || true)"
        if [ "$status" = "ready" ]; then
            break
        fi
        if [ -z "$(docker ps -q -f name=^ors$)" ]; then
            die "the ors container stopped while rebuilding graphs; check 'docker logs ors'"
        fi
        sleep 30
    done
    log "ORS ready"
}

# Rough disk estimate derived from the PBF size (Nominatim ~35x, Photon ~3x,
# ORS graphs ~10x) BEFORE wiping anything. Skip with MAPOPS_SKIP_DISK_CHECK=1
# (e.g. when the data lives on another filesystem).
check_disk_space() {
    [ "${MAPOPS_SKIP_DISK_CHECK:-0}" = "1" ] && return 0
    local pbf="$MAPS_DIR/map.osm.pbf"
    [ -f "$pbf" ] || return 0
    local pbf_kb free_kb mult=0
    pbf_kb="$(du -k "$pbf" | awk '{print $1}')"
    if wants_photon; then mult=$((mult + 40)); fi
    if wants_ors; then mult=$((mult + 10)); fi
    local need_kb=$((pbf_kb * mult))
    free_kb="$(df -Pk "$REPO_DIR" | awk 'NR==2{print $4}')"
    if [ "$free_kb" -lt "$need_kb" ]; then
        die "not enough disk: $((free_kb / 1048576))GB free, ~$((need_kb / 1048576))GB estimated (~${mult}x the PBF). Set MAPOPS_SKIP_DISK_CHECK=1 to force"
    fi
    log "Disk OK: $((free_kb / 1048576))GB free, ~$((need_kb / 1048576))GB estimated"
}

import_geocoding() {
    local yes="$1"

    log "Stopping previous importers (if any)"
    compose_import down --remove-orphans

    log "Stopping nominatim and photon (maintenance window)"
    compose stop nominatim photon || true

    wipe_data_dir nominatim-data
    wipe_data_dir photon-data .gitkeep

    log "Importing: Nominatim, then Photon (unattended, may take hours)"
    compose_import up --build --exit-code-from photon-importer photon-importer \
        || die "the import failed; nominatim and photon remain stopped. Check the importer logs"

    log "Import finished; removing importers"
    compose_import down

    if wants_nominatim_serve; then
        log "Starting nominatim and photon"
        compose up -d nominatim photon
    else
        # Photon mode: the Nominatim data is no longer needed
        if [ "$yes" -ne 1 ]; then
            confirm "Photon mode: destroy nominatim-data/ (it is regenerated on the next import)?"
        fi
        wipe_data_dir nominatim-data
        log "Starting photon"
        compose up -d photon
    fi
}

import_ors() {
    log "Rebuilding ORS graphs"
    REBUILD_GRAPHS=True compose up -d --force-recreate ors
    wait_for_ors_ready
    # Recreate with REBUILD_GRAPHS=False so a restart does not rebuild again
    compose up -d --force-recreate ors
}

# Prevent overlapping data operations (e.g. a cron update while another runs)
acquire_lock() {
    local lock="$REPO_DIR/.mapops-import.lock"
    mkdir "$lock" 2>/dev/null \
        || die "another data operation is in progress ($lock exists; remove it if it was left behind by an aborted run)"
    trap 'rmdir "'"$lock"'" 2>/dev/null' EXIT
}

cmd_import() {
    local yes=0
    [ "${1:-}" = "-y" ] && yes=1
    acquire_lock

    if wants_photon; then
        [ -f "$MAPS_DIR/map.osm.pbf" ] || die "maps/map.osm.pbf does not exist; run first: ./mapops.sh fetch <region...>"
        [ -f "$REPO_DIR/importer/vars.env" ] || die "importer/vars.env does not exist; copy it from importer/vars.env.example"
    fi
    if wants_ors; then
        [ -f "$REPO_DIR/ors/config/ors-config.yml" ] || die "ors/config/ors-config.yml does not exist (see the examples in ors/config/)"
        [ -f "$MAPS_DIR/map.osm.pbf" ] || [ -f "$MAPS_DIR/ors.osm.pbf" ] \
            || die "no map found in maps/; run first: ./mapops.sh fetch [--ors] <region...>"
    fi
    check_disk_space
    [ "$yes" -eq 1 ] || confirm_import

    ensure_network
    wants_photon && import_geocoding "$yes"
    wants_ors && import_ors

    log "Done [mode: $MODE]. Verify the services:"
    if wants_nominatim_serve; then log "  curl 'http://localhost:${NOMINATIM_PORT:-17070}/search?q=Madrid&format=json'"; fi
    if wants_photon; then log "  curl 'http://localhost:${PHOTON_PORT:-17071}/api?q=Gran+Via'"; fi
    if wants_ors; then log "  curl '$ORS_HEALTH_URL'"; fi
}

cmd_update() {
    local yes_flag=()
    if [ "${1:-}" = "-y" ]; then yes_flag=(-y); shift; fi

    local regions=("$@")
    if [ "${#regions[@]}" -gt 0 ]; then
        cmd_fetch "${regions[@]}"
    else
        local found=0
        if [ -f "$MAPS_DIR/manifest.txt" ] && wants_photon; then
            local main_regions=()
            while IFS= read -r line; do
                main_regions+=("$(echo "$line" | awk '{print $1}')")
            done < <(grep '^  ' "$MAPS_DIR/manifest.txt")
            [ "${#main_regions[@]}" -gt 0 ] && found=1 && \
                log "Regions from the manifest: ${main_regions[*]}" && cmd_fetch "${main_regions[@]}"
        fi
        if [ -f "$MAPS_DIR/manifest-ors.txt" ] && wants_ors; then
            local ors_regions=()
            while IFS= read -r line; do
                ors_regions+=("$(echo "$line" | awk '{print $1}')")
            done < <(grep '^  ' "$MAPS_DIR/manifest-ors.txt")
            [ "${#ors_regions[@]}" -gt 0 ] && found=1 && \
                log "Regions from the ORS manifest: ${ors_regions[*]}" && cmd_fetch --ors "${ors_regions[@]}"
        fi
        [ "$found" -eq 1 ] || die "no regions given and no previous manifests in maps/"
    fi

    cmd_import "${yes_flag[@]:-}"
}

# The mode's components as "container:inner-path:tar-name" triplets
mode_components() {
    wants_nominatim_serve && echo "nominatim:/var/lib/postgresql/16/main:nominatim-data"
    wants_photon && echo "photon:/photon:photon-data"
    wants_ors && echo "ors:/home/ors/graphs:ors-graphs"
    true
}

docker_arch() { docker version --format '{{.Server.Arch}}'; }

pack_one() {
    local container="$1" path="$2" name="$3" outdir="$4"
    log "Packing $name (from $container:$path)"
    docker run --rm --volumes-from "$container" -v "$outdir:/out" alpine \
        tar czf "/out/$name.tar.gz" -C "$path" . \
        || die "failed packing $name"
}

restore_one() {
    local container="$1" path="$2" name="$3" in="$4"
    log "Restoring $name (into $container:$path)"
    docker run --rm --volumes-from "$container" -v "$in:/in:ro" alpine \
        sh -c "find '$path' -mindepth 1 -name .gitkeep -prune -o -exec rm -rf {} + 2>/dev/null; tar xzf '/in/$name.tar.gz' -C '$path'" \
        || die "failed restoring $name"
    # Reset the owner the service expects (photon runs as the host UID, which
    # differs between nodes; nominatim runs as root and must not be touched:
    # its files already ship as postgres, the same uid on both nodes)
    local user
    user="$(docker inspect -f '{{.Config.User}}' "$container")"
    if [ -n "$user" ]; then
        docker run --rm --volumes-from "$container" alpine chown -R "$user" "$path"
    fi
}

cmd_pack() {
    acquire_lock
    local outdir="${1:-$REPO_DIR/exports/mapops-$(date +%Y%m%d-%H%M)}"
    mkdir -p "$outdir"
    outdir="$(cd "$outdir" && pwd)"

    # Make sure the containers exist (created, not necessarily running)
    ensure_network
    # shellcheck disable=SC2046,SC2086
    compose up --no-start $(mode_services) >/dev/null 2>&1 || true

    log "Stopping services for a consistent snapshot"
    compose stop nominatim photon ors 2>/dev/null || true

    local comps=()
    while IFS= read -r c; do [ -n "$c" ] && comps+=("$c"); done < <(mode_components)
    for c in "${comps[@]}"; do
        pack_one "${c%%:*}" "$(echo "$c" | cut -d: -f2)" "${c##*:}" "$outdir"
    done

    {
        echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "mode: $MODE"
        echo "arch: $(docker_arch)"
        echo "images:"
        compose config --images 2>/dev/null | sed 's/^/  /'
        echo "components:"
        for c in "${comps[@]}"; do echo "  ${c##*:}"; done
    } > "$outdir/bundle.txt"
    cp "$MAPS_DIR"/manifest*.txt "$outdir/" 2>/dev/null || true

    log "Restarting services"
    cmd_up

    log "Bundle ready at $outdir ($(du -sh "$outdir" | awk '{print $1}')):"
    sed 's/^/  /' "$outdir/bundle.txt"
}

cmd_restore() {
    local dir="${1:-}" yes=0
    [ "${2:-}" = "-y" ] && yes=1
    [ -n "$dir" ] || die "usage: restore <bundle-directory> [-y]"
    [ -d "$dir" ] || die "directory $dir does not exist"
    dir="$(cd "$dir" && pwd)"
    [ -f "$dir/bundle.txt" ] || die "not a mapops bundle (bundle.txt missing in $dir)"

    local bundle_arch here_arch
    bundle_arch="$(awk '/^arch:/{print $2}' "$dir/bundle.txt")"
    here_arch="$(docker_arch)"

    local comps=() skipped=()
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        local name="${c##*:}"
        if [ ! -f "$dir/$name.tar.gz" ]; then
            skipped+=("$name (not in the bundle)")
            continue
        fi
        if [ "$name" = "nominatim-data" ] && [ "$bundle_arch" != "$here_arch" ]; then
            die "the bundle is $bundle_arch and this node is $here_arch: nominatim-data (binary Postgres files) is not portable across architectures. Pack without nominatim (MAPOPS_MODE=photon) or reimport here"
        fi
        comps+=("$c")
    done < <(mode_components)
    [ "${#comps[@]}" -gt 0 ] || die "the bundle contains no component of the current mode ($MODE)"

    log "Bundle: $dir"
    sed 's/^/  /' "$dir/bundle.txt"
    [ "${#skipped[@]}" -gt 0 ] && log "Skipping: ${skipped[*]}"
    if [ "$yes" -ne 1 ]; then
        confirm "The current data of $(for c in "${comps[@]}"; do printf '%s ' "${c##*:}"; done)will be REPLACED. Continue?"
    fi

    acquire_lock
    ensure_network
    # shellcheck disable=SC2046,SC2086
    compose up --no-start $(mode_services) >/dev/null 2>&1 || true
    log "Stopping services"
    compose stop nominatim photon ors 2>/dev/null || true

    for c in "${comps[@]}"; do
        restore_one "${c%%:*}" "$(echo "$c" | cut -d: -f2)" "${c##*:}" "$dir"
    done
    cp "$dir"/manifest*.txt "$MAPS_DIR/" 2>/dev/null || true

    cmd_up
    log "Restore finished [mode: $MODE]"
}

cmd_up() {
    ensure_network
    local services
    services="$(mode_services)"
    log "Starting [$MODE]: $services"
    # shellcheck disable=SC2086
    compose up -d $services
}

cmd_down() {
    log "Stopping services"
    compose stop nominatim photon ors 2>/dev/null || true
}

cmd_status() {
    echo "mode: $MODE  (services: $(mode_services))"
    echo
    docker ps -a --filter name='^(nominatim|photon|ors|nominatim-importer|photon-importer)$' \
        --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
    echo
    for d in nominatim-data photon-data ors/graphs maps; do
        [ -d "$REPO_DIR/$d" ] && printf '%-16s %s\n' "$d:" "$(du -sh "$REPO_DIR/$d" 2>/dev/null | awk '{print $1}')"
    done
    for m in manifest.txt manifest-ors.txt; do
        if [ -f "$MAPS_DIR/$m" ]; then
            echo; echo "maps/$m:"; sed 's/^/  /' "$MAPS_DIR/$m"
        fi
    done
}

case "${1:-}" in
    fetch)  shift; cmd_fetch "$@" ;;
    import) shift; cmd_import "$@" ;;
    update) shift; cmd_update "$@" ;;
    up)      cmd_up ;;
    down)    cmd_down ;;
    status)  cmd_status ;;
    pack)    shift; cmd_pack "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    *)
        sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac
