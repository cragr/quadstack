#!/usr/bin/env bash
set -euo pipefail

# --- Defaults ---------------------------------------------------------------
DEFAULT_INSTALL_DIR="/opt/containers"
DEFAULT_MANIFEST_URL="https://raw.githubusercontent.com/cragr/quadstack/refs/heads/n8n/container-manifest.txt"

# Podman network to ensure at the beginning of the run
APPNET_NAME="${APPNET_NAME:-appnet}"

# PostgreSQL container name (matches ContainerName= in your postgresql.container)
PG_CONTAINER_NAME="${PG_CONTAINER_NAME:-postgresql}"

# Default Guacamole init SQL (override with env GUAC_INIT_SQL_URL if desired)
GUAC_INIT_SQL_URL="${GUAC_INIT_SQL_URL:-https://raw.githubusercontent.com/cragr/quadstack/refs/heads/n8n/initdb.sql}"

# --- UI helpers -------------------------------------------------------------
BOLD="$(tput bold 2>/dev/null || true)"
RESET="$(tput sgr0 2>/dev/null || true)"

die() { echo "Error: $*" >&2; exit 1; }
require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root (e.g., sudo $0)"; }
check_systemd() { command -v systemctl >/dev/null 2>&1 || die "systemctl not found."; }
check_podman() { command -v podman >/dev/null 2>&1 || die "podman not found."; }

usage() {
  cat <<'EOF'
Quadlet Installer

Usage:
  install-quadlets.sh [--manifest <URL_or_path>] [--install-dir <path>] [--non-interactive]
                      [--select "<pat1,pat2,...>"] [--var KEY=VALUE ...]

Options:
  --manifest        URL (raw) or local path to a manifest listing .container sources.
                    Entries may be separated by newlines OR spaces.
                    Optional label per entry:  URL|install-name.container
  --install-dir     Path injected into templates (default: /opt/containers).
  --non-interactive Run without prompts. Requires --select and any needed --var KEY=VALUE.
  --select          Comma-separated numbers/ranges/filenames (or "all") to install.
  --var KEY=VALUE   Provide template variable(s) (repeatable). Examples:
                      --var PWP__OVERRIDE_BASE_URL=https://pwpush.example.com
                      --var GATEWAY_HOST_PORT=8080
                      --var APP_HOST_PORT=5100

Env vars:
  APPNET_NAME         Podman network ensured at start (default: "appnet")
  PG_CONTAINER_NAME   PostgreSQL container name (default: "postgresql")
  GUAC_INIT_SQL_URL   URL for Guacamole init SQL (default: dev/initdb.sql)

Quadlet metadata (for Postgres prompting):
  # RequiresPostgres: db=<name> user=<name>
EOF
}

# --- CLI parsing ------------------------------------------------------------
MANIFEST=""
INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
NON_INTERACTIVE=0
SELECT_SPEC=""
VARS=()  # KEY=VALUE pairs for token injection

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --install-dir) INSTALL_DIR="${2:-}"; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=1; shift ;;
    --select) SELECT_SPEC="${2:-}"; shift 2 ;;
    --var) [[ -n "${2:-}" ]] || die "--var requires KEY=VALUE"; VARS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_root
check_systemd
check_podman

# --- Ensure appnet exists (beginning of the script) -------------------------
ensure_appnet_network() {
  local net="${APPNET_NAME}"
  [[ -z "$net" ]] && return 0

  if podman network inspect "$net" >/dev/null 2>&1; then
    echo "Network '$net' exists."
    return 0
  fi

  echo "Creating network '$net' ..."
  if ! out="$(podman network create "$net" 2>&1)"; then
    echo "Warning: failed to create network '$net':"; echo "$out" | sed 's/^/  /'
    # Common cause: subnet overlap — try a safe fallback
    if echo "$out" | grep -Eqi 'subnet|overlap|already.*exists|already.*defined'; then
      if out2="$(podman network create --subnet 10.92.0.0/24 "$net" 2>&1)"; then
        echo "  created '$net' with subnet 10.92.0.0/24."
        return 0
      else
        echo "Warning: fallback also failed:"; echo "$out2" | sed 's/^/  /'
      fi
    fi
    # Continue; unit starts will surface any issues.
  else
    echo "  created."
  fi
}
ensure_appnet_network

# --- Defaults if not provided ----------------------------------------------
if [[ -z "$MANIFEST" ]]; then
  MANIFEST="$DEFAULT_MANIFEST_URL"
  echo "No --manifest provided; using default: $MANIFEST"
fi

# Pick/install dir (prompt once)
if [[ $NON_INTERACTIVE -eq 0 ]]; then
  read -rp "Install/data path [${INSTALL_DIR}]: " ans
  [[ -n "${ans}" ]] && INSTALL_DIR="${ans}"
fi
mkdir -p "$INSTALL_DIR"; chmod 755 "$INSTALL_DIR"

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- Load manifest once -----------------------------------------------------
SRC_DESC=()    # human descriptions
SRC_PATH=()    # local temp paths
SRC_INSTALL=() # basenames to install

trim_crlf() { printf '%s' "$1" | tr -d '\r' | xargs; }

echo "Using manifest: $MANIFEST"
MF="${WORKDIR}/manifest.txt"
if [[ "$MANIFEST" =~ ^https?:// ]]; then
  command -v curl >/dev/null 2>&1 || die "curl required for remote manifest."
  curl -fsSL "$MANIFEST" -o "$MF" || die "Failed to download manifest."
else
  [[ -f "$MANIFEST" ]] || die "Manifest not found: $MANIFEST"
  awk '{ sub(/\r$/,""); print }' "$MANIFEST" > "$MF"
fi

idx=0
while IFS= read -r raw; do
  line="$(trim_crlf "${raw%%#*}")"
  [[ -z "$line" ]] && continue
  for token in $line; do
    entry="$token"
    url="${entry}"; label=""
    if [[ "$entry" == *"|"* ]]; then
      url="${entry%%|*}"
      label="$(trim_crlf "${entry#*|}")"
    fi
    [[ -z "$url" ]] && continue

    if [[ "$url" =~ ^https?:// ]]; then
      base="$(basename "$(trim_crlf "$url")")"
      [[ -z "$label" ]] && label="$base"
      [[ "$label" != *.container ]] && label="${label}.container"
      idx=$((idx+1))
      dest="${WORKDIR}/$(printf '%02d' "$idx")_${base}"
      echo "Fetching ${base} ..."
      curl -fsSL "$url" -o "$dest" || die "Failed to download $url"
      SRC_PATH+=("$dest"); SRC_INSTALL+=("$label"); SRC_DESC+=("${label}  (from URL: ${base})")
    else
      [[ -f "$url" || -f "./$url" ]] || { echo "Warning: missing local file in manifest: $url"; continue; }
      full="$(readlink -f "${url#./}")"
      base="$(basename "$full")"
      [[ -z "$label" ]] && label="$base"
      [[ "$label" != *.container ]] && label="${label}.container"
      SRC_PATH+=("$full"); SRC_INSTALL+=("$label"); SRC_DESC+=("${label}  (from local: ${base})")
    fi
  done
done < "$MF"

[[ ${#SRC_PATH[@]} -gt 0 ]] || die "No valid .container entries found (check manifest formatting)."

# --- Token storage (persist across loops) -----------------------------------
declare -A TOKVAL; TOKVAL["INSTALL_DIR"]="$INSTALL_DIR"
seed_vars_from_cli() {
  for kv in "${VARS[@]}"; do
    key="${kv%%=*}"; val="${kv#*=}"
    [[ -z "$key" || "$key" == "$val" ]] && die "Bad --var format (KEY=VALUE): $kv"
    TOKVAL["$key"]="$val"
  done
}
seed_vars_from_cli

extract_tokens() { grep -Eoh '{{[A-Z0-9_]+}}' "$@" 2>/dev/null | sed -E 's/[{}]//g' | sort -u; }

prompt_for_missing_tokens() {
  local tokens=("$@"); [[ ${#tokens[@]} -eq 0 ]] && return
  for t in "${tokens[@]}"; do
    [[ -n "${TOKVAL[$t]:-}" ]] && continue
    [[ "$t" == "INSTALL_DIR" ]] && continue
    if [[ $NON_INTERACTIVE -eq 1 ]]; then
      die "Missing value for {{$t}} while --non-interactive. Provide --var $t=VALUE"
    fi
    local default=""
    case "$t" in
      PWP__OVERRIDE_BASE_URL) default="https://pwpush.example.com" ;;
      GATEWAY_HOST_PORT)      default="8080" ;;
      APP_HOST_PORT)          default="5100" ;;
      HOST_PORT)              default="8080" ;;
    esac
    if [[ -n "$default" ]]; then
      read -rp "Value for {{$t}} [${default}]: " ans; TOKVAL["$t"]="${ans:-$default}"
    else
      read -rp "Value for {{$t}}: " ans; [[ -z "$ans" ]] && die "No value entered for {{$t}}"; TOKVAL["$t"]="$ans"
    fi
  done
}

# --- Helpers used inside each loop ------------------------------------------
create_host_dirs_from_unit() {
  local unit_file="$1"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"; [[ -z "$line" ]] && continue
    local val="${line#*=}"
    for item in $val; do
      local host="${item%%:*}"
      [[ "$host" != /* ]] && continue
      host="${host/#\~/$HOME}"
      [[ -e "$host" ]] && continue
      local base
      base="$(basename -- "$host")"
      if [[ "$base" == *.* ]]; then
        mkdir -p -- "$(dirname -- "$host")"
      else
        mkdir -p -- "$host"
      fi
    done
  done < <(grep -E '^[[:space:]]*(Volume|Bind(ReadOnly)?)=' "$unit_file" || true)
}

choose_files() {
  local -n _out_idx_ref=$1
  local input=""
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    input="$SELECT_SPEC"
  else
    echo
    read -rp "Select by number/comma, ranges (e.g. 1,3-4), filenames, or 'all': " input
  fi
  [[ -z "$input" ]] && die "Nothing selected."

  if [[ "$input" == "all" ]]; then
    for ((i=0;i<${#SRC_PATH[@]};i++)); do _out_idx_ref+=("$i"); done
    return
  fi

  local picked=()
  IFS=',' read -r -a parts <<< "$input"
  for part in "${parts[@]}"; do
    part="$(echo "$part" | xargs)"; [[ -z "$part" ]] && continue
    if [[ "$part" =~ ^[0-9]+-[0-9]+$ ]]; then
      local start="${part%-*}" end="${part#*-}"
      for ((n=start;n<=end;n++)); do idx=$((n-1)); [[ $idx -ge 0 && $idx -lt ${#SRC_PATH[@]} ]] && picked+=("$idx"); done
    elif [[ "$part" =~ ^[0-9]+$ ]]; then
      idx=$((part-1)); [[ $idx -ge 0 && $idx -lt ${#SRC_PATH[@]} ]] && picked+=("$idx")
    else
      for ((i=0;i<${#SRC_INSTALL[@]};i++)); do
        if [[ "${SRC_INSTALL[$i]}" == "$part" ]]; then picked+=("$i"); fi
      done
    fi
  done
  [[ ${#picked[@]} -gt 0 ]] || die "Selection matched nothing."
  local seen=""; local uniq=()
  for idx in "${picked[@]}"; do [[ ":$seen:" == *":$idx:"* ]] && continue; uniq+=("$idx"); seen="${seen}:$idx"; done
  _out_idx_ref=("${uniq[@]}")
}

# PG helpers
sql_q_ident()   { local s="$1"; s="${s//\"/\"\"}"; printf '"%s"' "$s"; }
sql_q_literal() { local s="$1"; s="${s//\'/\'\'}"; printf "'%s'" "$s"; }
pg_container_running() { podman inspect -f '{{.State.Running}}' "$PG_CONTAINER_NAME" 2>/dev/null | grep -qi true; }
pg_wait_ready() { local tries=30; while (( tries-- > 0 )); do podman exec "$PG_CONTAINER_NAME" bash -lc 'pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1' && return 0; sleep 2; done; return 1; }
pg_role_exists() { local user_lit; user_lit="$(sql_q_literal "$1")"; podman exec "$PG_CONTAINER_NAME" bash -lc "psql -U postgres -d postgres -Atqc \"SELECT 1 FROM pg_roles WHERE rolname = ${user_lit}\"" | grep -q 1; }
pg_db_exists() { local db_lit; db_lit="$(sql_q_literal "$1")"; podman exec "$PG_CONTAINER_NAME" bash -lc "psql -U postgres -d postgres -Atqc \"SELECT 1 FROM pg_database WHERE datname = ${db_lit}\"" | grep -q 1; }
pg_create_user_db() {
  local db="$1" user="$2" pass="$3"
  local user_ident db_ident pass_lit
  user_ident="$(sql_q_ident "$user")"; db_ident="$(sql_q_ident "$db")"; pass_lit="$(sql_q_literal "$pass")"
  if ! pg_role_exists "$user"; then
    podman exec "$PG_CONTAINER_NAME" bash -lc \
      "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \"CREATE ROLE ${user_ident} WITH LOGIN PASSWORD ${pass_lit};\""
    echo "  created role ${user}"
  else
    echo "  role ${user} already exists; skipping create"
  fi
  if ! pg_db_exists "$db"; then
    podman exec "$PG_CONTAINER_NAME" bash -lc \
      "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \"CREATE DATABASE ${db_ident} OWNER ${user_ident};\""
    echo "  created database ${db} owned by ${user}"
  else
    echo "  database ${db} already exists; ensuring owner=${user}"
    podman exec "$PG_CONTAINER_NAME" bash -lc \
      "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \"ALTER DATABASE ${db_ident} OWNER TO ${user_ident};\""
  fi
  podman exec "$PG_CONTAINER_NAME" bash -lc \
    "psql -U postgres -d postgres -v ON_ERROR_STOP=1 -c \
     \"REVOKE ALL ON DATABASE ${db_ident} FROM PUBLIC; \
       GRANT CONNECT, CREATE, TEMP ON DATABASE ${db_ident} TO ${user_ident}; \
       GRANT ALL PRIVILEGES ON DATABASE ${db_ident} TO ${user_ident};\""
  podman exec "$PG_CONTAINER_NAME" bash -lc \
    "psql -U postgres -d ${db} -v ON_ERROR_STOP=1 -c \"ALTER SCHEMA public OWNER TO ${user_ident};\""
  podman exec "$PG_CONTAINER_NAME" bash -lc \
    "psql -U postgres -d ${db} -v ON_ERROR_STOP=1 -c \"GRANT ALL PRIVILEGES ON SCHEMA public TO ${user_ident};\""
  podman exec "$PG_CONTAINER_NAME" bash -lc \
    "psql -U postgres -d ${db} -v ON_ERROR_STOP=1 -c \
     \"ALTER DEFAULT PRIVILEGES FOR ROLE ${user_ident} IN SCHEMA public GRANT ALL ON TABLES TO ${user_ident};\""
  podman exec "$PG_CONTAINER_NAME" bash -lc \
    "psql -U postgres -d ${db} -v ON_ERROR_STOP=1 -c \
     \"ALTER DEFAULT PRIVILEGES FOR ROLE ${user_ident} IN SCHEMA public GRANT ALL ON SEQUENCES TO ${user_ident};\""
  podman exec "$PG_CONTAINER_NAME" bash -lc \
    "psql -U postgres -d ${db} -v ON_ERROR_STOP=1 -c \
     \"ALTER DEFAULT PRIVILEGES FOR ROLE ${user_ident} IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${user_ident};\""
  echo "  done."
}

# Guacamole one-shot hook
add_guac_db_init_hook() {
  local db="$1" user="$2" pass="$3"

  mkdir -p /etc/containers/init-sql \
           /etc/containers/systemd \
           /etc/systemd/system/guacamole.service.d \
           "${INSTALL_DIR}/guacamole"

  local sql="/etc/containers/init-sql/guacamole-init.sql"
  echo "Fetching Guacamole init SQL from: $GUAC_INIT_SQL_URL"
  if ! curl -fsSL "$GUAC_INIT_SQL_URL" -o "$sql"; then
    echo "Warning: could not fetch $GUAC_INIT_SQL_URL; skipping Guacamole schema load hook."
    return 0
  fi

  cat > /etc/containers/systemd/guacamole-db.env <<EOF
GUAC_DB=${db}
GUAC_USER=${user}
GUAC_PASSWORD=${pass}
EOF
  chmod 0600 /etc/containers/systemd/guacamole-db.env

  cat > /etc/systemd/system/guacamole-db-init.service <<'EOF'
[Unit]
Description=Initialize Guacamole database schema (run once)
Requires=postgresql.service
After=postgresql.service
ConditionPathExists=/etc/containers/init-sql/guacamole-init.sql
ConditionPathExists=!%%INSTALL_DIR%%/guacamole/.schema_loaded

[Service]
Type=oneshot
TimeoutSec=300
EnvironmentFile=/etc/containers/systemd/guacamole-db.env
# Wait for PG ready (up to ~120s)
ExecStartPre=/bin/bash -lc 'for i in {1..60}; do podman exec postgresql pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1'
# Ensure the app user can create in schema; safe if repeated
ExecStart=/bin/bash -lc 'podman exec postgresql psql -U postgres -d "$GUAC_DB" -v ON_ERROR_STOP=1 -c "GRANT CONNECT ON DATABASE \"$GUAC_DB\" TO \"$GUAC_USER\"; GRANT USAGE, CREATE ON SCHEMA public TO \"$GUAC_USER\";"'
# Load schema AS the app user so objects are owned by that user (pass PGPASSWORD into the container)
ExecStart=/bin/bash -lc 'PGPASSWORD="$GUAC_PASSWORD" exec /usr/bin/podman exec -e PGPASSWORD="$GUAC_PASSWORD" -i postgresql psql -h 127.0.0.1 -U "$GUAC_USER" -d "$GUAC_DB" -v ON_ERROR_STOP=1 -f - < /etc/containers/init-sql/guacamole-init.sql'
ExecStart=/usr/bin/touch %%INSTALL_DIR%%/guacamole/.schema_loaded

[Install]
WantedBy=multi-user.target
EOF
  sed -i "s#%%INSTALL_DIR%%#${INSTALL_DIR//\//\\/}#g" /etc/systemd/system/guacamole-db-init.service

  # Make Guacamole wait for the DB init to complete
  cat > /etc/systemd/system/guacamole.service.d/10-dbinit.conf <<'EOF'
[Unit]
Wants=guacamole-db-init.service
After=guacamole-db-init.service
EOF
}

# --- One "round" of installing selected items -------------------------------
run_one_round() {
  local SELECTED_IDX=()

  echo
  echo "${BOLD}Discovered Quadlet entries:${RESET}"
  for ((i=0; i<${#SRC_PATH[@]}; i++)); do
    printf "  [%d] %s\n" "$((i+1))" "${SRC_DESC[$i]}"
  done

  choose_files SELECTED_IDX

  # ---- PG prompts (metadata-driven) ----
  local PG_LABEL=() PG_DB=() PG_USER=() PG_PASS=()
  echo
  echo "${BOLD}Checking if any selected services need a PostgreSQL database...${RESET}"
  for sel in "${SELECTED_IDX[@]}"; do
    local src="${SRC_PATH[$sel]}"
    local name="${SRC_INSTALL[$sel]}"
    local short="${name%.container}"

    local raw_pg pg_line
    raw_pg="$(grep -iE '^[[:space:]]*#[[:space:]]*RequiresPostgres:' "$src" || true)"
    [[ -z "$raw_pg" ]] && continue

    pg_line="${raw_pg#*:}"
    pg_line="$(echo "$pg_line" | xargs)"
    # parse "db=foo user=bar"
    local defdb="" defuser=""
    for kv in $pg_line; do
      local k="${kv%%=*}" v="${kv#*=}"
      case "$k" in
        db|DB) defdb="$v" ;;
        user|USER) defuser="$v" ;;
      esac
    done
    [[ -z "$defdb"  ]] && defdb="${short}_db"
    [[ -z "$defuser" ]] && defuser="${short}_user"

    echo
    echo "→ ${BOLD}${short}${RESET} indicates it needs PostgreSQL."
    read -rp "  Create DB for ${short}? [Y/n]: " yn; yn="${yn:-Y}"
    case "${yn,,}" in n|no) continue ;; esac

    read -rp "  Database name [${defdb}]: " db;   db="${db:-$defdb}"
    read -rp "  Username      [${defuser}]: " usr; usr="${usr:-$defuser}"
    read -srp "  Password (leave blank to autogenerate): " pw; echo
    if [[ -z "$pw" ]]; then pw="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"; echo "  Generated password: ${pw}"; fi

    PG_LABEL+=("$short"); PG_DB+=("$db"); PG_USER+=("$usr"); PG_PASS+=("$pw")
  done
  [[ ${#PG_DB[@]} -eq 0 ]] && echo "No PG requirements detected in selected Quadlets."

  # ---- Build temp copies and collect tokens ----
  echo
  echo "Injecting variables, ensuring host paths exist, and installing to /etc/containers/systemd ..."
  local TMP_FILES_FOR_TOKEN_SCAN=()
  local DEST_BASENAMES=()
  local WORK_TMP=""
  for idx in "${SELECTED_IDX[@]}"; do
    local src="${SRC_PATH[$idx]}"; local install_bn="${SRC_INSTALL[$idx]}"
    WORK_TMP="${WORKDIR}/${install_bn}.tmp.$RANDOM"
    cp "$src" "$WORK_TMP"
    TMP_FILES_FOR_TOKEN_SCAN+=("$WORK_TMP"); DEST_BASENAMES+=("$install_bn")
  done

  mapfile -t FOUND_TOKENS < <(extract_tokens "${TMP_FILES_FOR_TOKEN_SCAN[@]}")
  prompt_for_missing_tokens "${FOUND_TOKENS[@]}"

  local TARGET_DIR="/etc/containers/systemd"; mkdir -p "$TARGET_DIR"
  local STAMP="$(date +%Y%m%d-%H%M%S)"; local BACKUP_DIR="${TARGET_DIR}.bak-${STAMP}"; mkdir -p "$BACKUP_DIR"

  local TMP_UNITS=()
  for i in "${!TMP_FILES_FOR_TOKEN_SCAN[@]}"; do
    local tmp="${TMP_FILES_FOR_TOKEN_SCAN[$i]}"; local install_bn="${DEST_BASENAMES[$i]}"
    sed -i -e "s#{{INSTALL_DIR}}#${INSTALL_DIR//\//\\/}#g" -e "s#%%INSTALL_DIR%%#${INSTALL_DIR//\//\\/}#g" "$tmp"
    for key in "${!TOKVAL[@]}"; do val="${TOKVAL[$key]}"; esc_val="${val//\//\\/}"; sed -i -e "s#{{$key}}#${esc_val}#g" "$tmp"; done
    create_host_dirs_from_unit "$tmp"
    local dest="${TARGET_DIR}/${install_bn}"
    if [[ -f "$dest" ]]; then echo "  Backing up existing ${install_bn} -> ${BACKUP_DIR}/${install_bn}"; mv -f "$dest" "${BACKUP_DIR}/${install_bn}"; fi
    install -m 0644 "$tmp" "$dest"; TMP_UNITS+=("$dest")
  done

  # ---- Reload (phase 1) ----
  echo
  echo "Reloading systemd daemon (phase 1) ..."
  systemctl daemon-reload

  # ---- Start PostgreSQL (if present) and provision DBs BEFORE app services ----
  if systemctl list-unit-files | grep -q '^postgresql\.service'; then
    echo "Starting ${PG_CONTAINER_NAME}.service (PostgreSQL) ..."
    systemctl start "${PG_CONTAINER_NAME}.service" || true
  fi

  if pg_container_running && pg_wait_ready; then
    if [[ ${#PG_DB[@]} -gt 0 ]]; then
      echo
      echo "${BOLD}Provisioning PostgreSQL database(s) before starting app services...${RESET}"
      for i in "${!PG_DB[@]}"; do
        local db="${PG_DB[$i]}"; local usr="${PG_USER[$i]}"; local pw="${PG_PASS[$i]}"; local label="${PG_LABEL[$i]}"
        echo "  -> ${label}: ${db} / ${usr}"
        pg_create_user_db "$db" "$usr" "$pw" || echo "  Warning: provisioning failed for ${db}."
      done
    fi
  else
    echo "PostgreSQL not running/ready; skipping DB provisioning (app units may fail until PG is up)."
  fi

  # ---- If Guacamole selected, add one-shot DB init hook ----
  for i in "${!PG_DB[@]}"; do
    local label="${PG_LABEL[$i]}"
    case "${label,,}" in
      guacamole*)
        add_guac_db_init_hook "${PG_DB[$i]}" "${PG_USER[$i]}" "${PG_PASS[$i]}"
        ;;
    esac
  done

  # ---- Reload (phase 2) to pick up oneshot (if added) ----
  echo "Reloading systemd daemon (phase 2) ..."
  systemctl daemon-reload

  # ---- Start then enable selected services ----
  echo
  echo "Starting, then enabling services ..."
  local STARTED=()
  for bn in "${DEST_BASENAMES[@]}"; do
    local svc="${bn%.container}.service"

    if systemctl start "$svc"; then
      STARTED+=("$svc")
    else
      echo "Warning: failed to start $svc (check logs: journalctl -u $svc). Continuing..."
    fi

    local state
    state="$(systemctl is-enabled "$svc" 2>/dev/null || true)"
    case "$state" in
      enabled|static|indirect|generated|enabled-runtime)
        echo "Info: $svc already enabled/state=$state; skipping enable."
        ;;
      *)
        local errfile; errfile="$(mktemp)"; trap 'rm -f "$errfile"' RETURN
        if ! systemctl enable "$svc" 2>"$errfile"; then
          if grep -qi 'transient or generated' "$errfile"; then
            echo "Info: $svc is a generated unit; enable not applicable. Continuing."
          else
            echo "Warning: failed to enable $svc:"; sed 's/^/  /' "$errfile"
          fi
        fi
        rm -f "$errfile"; trap - RETURN
        ;;
    esac
  done

  # ---- Summary for this round ----
  echo
  echo "${BOLD}Round complete.${RESET}"
  echo "Services started (attempted) and enabled/skipped as appropriate:"
  for s in "${STARTED[@]}"; do echo "  - $s"; done
  echo
  echo "Manage with:"
  for s in "${STARTED[@]}"; do echo "  systemctl status $s"; done
  echo
}

# --- Main loop --------------------------------------------------------------
while true; do
  run_one_round
  if [[ $NON_INTERACTIVE -eq 1 ]]; then
    break
  fi
  echo
  read -rp "Do you want to install/configure more items from this manifest? [y/N]: " again
  case "${again,,}" in
    y|yes) continue ;;
    *)     echo "All done."; break ;;
  esac
done