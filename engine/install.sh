#!/usr/bin/env bash
#
# Managed by easy-deploy @VERSION@ -- do not edit. This project's settings and
# hooks live in deploy/easy-deploy.conf; refresh this file with
# `init.sh --update` from an easy-deploy checkout.
#
# Install this project on the server: everything a deploy needs root for, and
# nothing else.
#
#   sudo deploy/install.sh                  first time, from any checkout of the project
#   sudo PREFIX/deploy/install.sh           again, whenever deploy.sh reports drift
#   sudo deploy/install.sh --ci-key         also create (or replace) the CI key and print the secrets
#        [--host ADDR]                      the address GitHub reaches this server on, for those secrets
#   deploy/install.sh --print-config        the settings it would use; needs no root
#
# Idempotent. In order:
#   1. the deploy root PREFIX, cloned as SERVICE_USER from this checkout and
#      pointed at the same origin, so it works before or after the first push
#   2. ENV_FILE, then dependencies, as SERVICE_USER: installer.py (python) or
#      npm ci (node)
#   3. WRITABLE_DIRS, owned by SERVICE_USER, then the on_install hook, as root
#   4. the before_restart hook, as SERVICE_USER -- what a deploy does before
#      its restart, so the first start finds migrations applied
#   5. deploy/<unit>.service for every unit in SERVICES, enabled and restarted,
#      the after_restart hook, then the same health check a deploy uses
#   6. one sudoers line per unit: SERVICE_USER may `systemctl restart` it, and
#      nothing else
#   7. deploy/NAME.caddy into /etc/caddy/conf.d, with the whole Caddy config
#      validated first and the previous one put back if it does not validate
#   8. the CI key's forced-command line in SERVICE_USER's authorized_keys
#
# It never edits /etc/caddy/Caddyfile beyond appending the conf.d import when
# that line is missing (with a backup), and never touches data in the deploy
# root: everything it creates there is created only if missing.

set -euo pipefail

EASY_DEPLOY_VERSION=@VERSION@

BASE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH="$BASE_PATH"
export PYTHONDONTWRITEBYTECODE=1
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONF="$SOURCE_DIR/deploy/easy-deploy.conf"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m%s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m%s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- config ----
# The same defaults as deploy.sh's load_conf: keep the two in step (the tests
# compare their --print-config output).

# shellcheck disable=SC2034  # each script uses its own share of these
load_conf() {
    NAME="" SERVICE_USER="" PREFIX="" BRANCH=main STATE_DIR=""
    STACK=none DEPS_FILES="" PYTHON=python3 PY_CHECK=""
    SERVICES="" OPTIONAL_SERVICES="" PORT="" SITE="" WRITABLE_DIRS="" ENV_FILE="" EXTRA_PATH=""
    HEALTH_URLS="" HEALTH_HOST="" HEALTH_STATUS=200 HEALTH_TRIES=15
    LOCK_WAIT=300 SYSTEMCTL="sudo -n systemctl"
    UNIT_DIR=/etc/systemd/system CADDY_DIR=/etc/caddy/conf.d CADDY_MAIN=/etc/caddy/Caddyfile
    unset -f before_restart after_restart health_check install_deps on_install

    if ! bash -n "$CONF"; then
        warn "$CONF does not parse."
        return 1
    fi
    # shellcheck source=/dev/null
    . "$CONF" || { warn "$CONF failed to load."; return 1; }

    [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
        || { warn "NAME in $CONF must be letters, digits, - and _ (it is '$NAME')."; return 1; }
    [[ -n "$SERVICE_USER" ]] || { warn "SERVICE_USER is not set in $CONF."; return 1; }
    PREFIX="${PREFIX:-/srv/$NAME}"
    SERVICES="${SERVICES:-$NAME}"
    local svc
    for svc in $SERVICES $OPTIONAL_SERVICES; do
        [[ "$svc" =~ ^[A-Za-z0-9][A-Za-z0-9@_.:-]*$ ]] || { warn "'$svc' in $CONF is not a unit name."; return 1; }
    done
    STATE_DIR="${STATE_DIR:-$PREFIX/.easy-deploy}"
    if [[ -z "$HEALTH_URLS" && -n "$PORT" ]]; then
        HEALTH_URLS="http://127.0.0.1:$PORT/"
    fi
    case "$STACK" in
        python) DEPS_FILES="${DEPS_FILES:-requirements.txt}" ;;
        node)   DEPS_FILES="${DEPS_FILES:-package.json package-lock.json}" ;;
        none)   ;;
        *) warn "STACK in $CONF must be python, node or none (it is '$STACK')."; return 1 ;;
    esac
    local n
    for n in HEALTH_TRIES HEALTH_STATUS LOCK_WAIT; do
        [[ "${!n}" =~ ^[0-9]+$ ]] || { warn "$n in $CONF must be a number (it is '${!n}')."; return 1; }
    done
    PATH="${EXTRA_PATH:+$EXTRA_PATH:}$BASE_PATH"
    read -r -a SYSTEMCTL_CMD <<<"$SYSTEMCTL"
    VENV="$PREFIX/env"
    PY="$VENV/bin/python"
}

print_config() {
    local key hook
    for key in NAME SERVICE_USER PREFIX BRANCH STATE_DIR STACK DEPS_FILES PYTHON PY_CHECK \
               SERVICES OPTIONAL_SERVICES PORT SITE WRITABLE_DIRS ENV_FILE EXTRA_PATH HEALTH_URLS HEALTH_HOST \
               HEALTH_STATUS HEALTH_TRIES LOCK_WAIT SYSTEMCTL UNIT_DIR CADDY_DIR CADDY_MAIN; do
        printf '%s=%q\n' "$key" "${!key}"
    done
    for hook in before_restart after_restart health_check install_deps on_install; do
        declare -F "$hook" >/dev/null && printf 'hook %s\n' "$hook"
    done
    return 0
}

# --------------------------------------------------------------- helpers ----

# runuser keeps root's HOME, and git's credentials, pip's cache and npm's
# cache all belong in the service user's.
asuser() { runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" PATH="$PATH" "$@"; }

# A hook from easy-deploy.conf, in a bash of its own with errexit on -- the
# same way deploy.sh runs them. $1 is the hook, $2 "user" to run it as
# SERVICE_USER rather than root.
run_hook() {
    declare -F "$1" >/dev/null || return 0
    log "$1"
    local runner=()
    [[ "${2:-}" == user ]] && runner=(runuser -u "$SERVICE_USER" -- env HOME="$SERVICE_HOME" PATH="$PATH")
    # shellcheck disable=SC2016  # expanded by the hook's bash
    (cd "$PREFIX" && "${runner[@]}" bash -c 'set -euo pipefail; . "$1"; "$2"' easy-deploy-hook "$CONF" "$1")
}

healthy() {
    local i url code svc down codes streak=0 need=1 host=()
    [[ -n "$HEALTH_URLS" ]] || need=5
    [[ -n "$HEALTH_HOST" ]] && host=(-H "Host: $HEALTH_HOST")
    for i in $(seq 1 "$HEALTH_TRIES"); do
        down="" codes=""
        for svc in $SERVICES; do
            systemctl is-active --quiet "$svc" 2>/dev/null || down+=" $svc"
        done
        for url in $HEALTH_URLS; do
            code="$(curl -s -o /dev/null -w '%{http_code}' "${host[@]}" --max-time 5 "$url" || true)"
            codes+=" $url=$code"
            [[ "$code" == "$HEALTH_STATUS" ]] || down+=" $url"
        done
        if [[ -z "$down" ]]; then
            streak=$((streak + 1))
            if (( streak >= need )); then
                run_hook health_check user || { warn "Up after ${i}s, but the health_check hook failed."; return 1; }
                log "Healthy after ${i}s"
                return 0
            fi
        else
            streak=0
        fi
        sleep 1
    done
    warn "Unhealthy after ${HEALTH_TRIES}s -- not up:${down}${codes:+  (last:$codes)}"
    return 1
}

github_slug() {  # owner/repo from origin's URL, or nothing
    local url
    url="$(git config --file "$PREFIX/.git/config" remote.origin.url 2>/dev/null || true)"
    [[ "$url" =~ github\.com[:/]+([^/]+/[^/]+)$ ]] || return 0
    printf '%s\n' "${BASH_REMATCH[1]%.git}"
}

# The env file holds secrets, so it is read rather than sourced -- the same
# way deploy.sh reads it. Only NAME=VALUE lines are honoured; anything else is
# reported by line number and skipped, never run, and never echoed.
load_env() {
    local file="$1" line name value lineno=0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}
        case "$line" in ''|'#'*) continue ;; esac
        if [[ $line =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            name=${BASH_REMATCH[2]}
            value=${BASH_REMATCH[3]}
            value=${value#"${value%%[![:space:]]*}"}
            value=${value%"${value##*[![:space:]]}"}
            case "$value" in
                \"*\") value=${value#\"}; value=${value%\"} ;;
                \'*\') value=${value#\'}; value=${value%\'} ;;
            esac
            case "$name" in
                PATH|HOME|IFS) warn "$file line $lineno sets $name -- skipped"; continue ;;
            esac
            export "$name=$value"
        else
            warn "$file line $lineno is not NAME=VALUE -- skipped"
        fi
    done < "$file"
}

load_env_file() {
    [[ -n "$ENV_FILE" ]] || return 0
    local file="${ENV_FILE#-}"
    if [[ ! -e "$file" ]]; then
        [[ "$ENV_FILE" == -* ]] && return 0
        warn "ENV_FILE $file does not exist."
        return 1
    fi
    # Readable by root is not enough: deploy.sh reads it as SERVICE_USER.
    runuser -u "$SERVICE_USER" -- test -r "$file" \
        || { warn "ENV_FILE $file is not readable by $SERVICE_USER, so deploy.sh could not read it."; return 1; }
    load_env "$file"
}

# ------------------------------------------------------------- arguments ----

CI_KEY=0 HOST_ARG="" PRINT_ONLY=0
while (( $# )); do
    case "$1" in
        --ci-key) CI_KEY=1 ;;
        --host) HOST_ARG="${2:?--host needs an address}"; shift ;;
        --print-config) PRINT_ONLY=1 ;;
        -h|--help) sed -n '7,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
done

[[ -f "$CONF" ]] || die "There is no $CONF. Run easy-deploy's init.sh in this project first."
load_conf || die "Fix $CONF and re-run."
if (( PRINT_ONLY )); then
    print_config
    exit 0
fi

# ------------------------------------------------------------- preflight ----

[[ $EUID -eq 0 ]] || die "Run this with sudo. It installs units, a sudoers file and the Caddy site."
[[ -d /run/systemd/system ]] || die "systemd is not running here."

# sudo keeps the caller's directory, and git run as the service user refuses
# to start in one it cannot read (sudo from /root, say).
cd /

[[ "$SERVICE_USER" != root ]] || die "The service must not run as root: set SERVICE_USER in $CONF."
SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)" || true
[[ -n "$SERVICE_HOME" ]] || die "There is no account named $SERVICE_USER."
SERVICE_GROUP="$(id -gn "$SERVICE_USER")"

for tool in git curl flock runuser visudo; do
    command -v "$tool" >/dev/null || die "$tool is not installed."
done
# The path sudo will resolve `systemctl` to (its secure_path is BASE_PATH).
SYSTEMCTL_BIN="$(PATH="$BASE_PATH" command -v systemctl)"

CLEANUP=()
trap 'rm -rf "${CLEANUP[@]}"' EXIT
case "$STACK" in
    python)
        "$PYTHON" -c 'import venv, ensurepip' 2>/dev/null \
            || die "$PYTHON cannot build a virtualenv:  sudo apt-get install -y python3-venv" ;;
    node)
        command -v node >/dev/null || die "node is not installed (or not on $PATH: set EXTRA_PATH)."
        command -v npm  >/dev/null || die "npm is not installed (or not on $PATH: set EXTRA_PATH)." ;;
esac

log "easy-deploy $EASY_DEPLOY_VERSION: installing $NAME"

# ------------------------------------------------------------ deploy root ----

if [[ "$SOURCE_DIR" == "$(readlink -m "$PREFIX")" ]]; then
    log "Running from the deploy root $PREFIX"
elif [[ ! -d "$PREFIX/.git" ]]; then
    # Read from the file rather than with `git -C`: as root, git refuses to
    # look inside a checkout someone else owns.
    ORIGIN="$(git config --file "$SOURCE_DIR/.git/config" remote.origin.url || true)"
    [[ -n "$ORIGIN" ]] || die "$SOURCE_DIR has no origin remote to deploy from."
    log "Creating $PREFIX from $SOURCE_DIR"
    install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0755 "$PREFIX"
    asuser git clone --quiet "$SOURCE_DIR" "$PREFIX"
    asuser git -C "$PREFIX" remote set-url origin "$ORIGIN"
    # Deploys follow origin, so the deploy root starts there too.
    if asuser git -C "$PREFIX" fetch --quiet origin "$BRANCH"; then
        asuser git -C "$PREFIX" checkout --quiet -B "$BRANCH" "origin/$BRANCH"
    else
        warn "Could not fetch $ORIGIN as $SERVICE_USER: deploy.sh will fail until it can."
        warn "Give $SERVICE_USER a read credential (a GitHub deploy key in ~/.ssh, or gh auth login), then re-run."
    fi
else
    log "Deploy root $PREFIX already exists"
fi

owner="$(stat -c %U "$PREFIX/.git")"
[[ "$owner" == "$SERVICE_USER" ]] \
    || die "$PREFIX belongs to $owner, not $SERVICE_USER:  sudo chown -R $SERVICE_USER:$SERVICE_GROUP $PREFIX"

# From here on, the deploy root's own copy: that is what deploy.sh will use.
CONF="$PREFIX/deploy/easy-deploy.conf"
[[ -f "$CONF" ]] || die "origin/$BRANCH has no deploy/easy-deploy.conf yet. Commit and push what init.sh wrote, then re-run."
load_conf || die "Fix $CONF and re-run."
export REPO="$PREFIX" NAME PREFIX BRANCH SERVICE_USER SERVICE_HOME SERVICES OPTIONAL_SERVICES VENV PY
export -f log warn asuser
log "Installing from $PREFIX at $(asuser git -C "$PREFIX" rev-parse --short HEAD)"

# The environment the application runs with, before anything imports it --
# installer.py's validation step included, the same order as a deploy.
load_env_file || die "Fix ENV_FILE and re-run."
export ED_REF ED_PHASE=install
ED_REF="$(asuser git -C "$PREFIX" rev-parse HEAD)"

# ---------------------------------------------------------- dependencies ----
# Built on the server and as the service user, never copied: a venv bakes in
# absolute paths, and one built as root leaves files the deploy cannot replace.

if declare -F install_deps >/dev/null; then
    run_hook install_deps user || die "install_deps failed; nothing was started."
else
    case "$STACK" in
        python)
            [[ -f "$PREFIX/installer.py" ]] || die "STACK=python, but there is no installer.py at the top of the repository."
            log "Python environment (installer.py)"
            args=(--non-interactive)
            [[ -n "$PY_CHECK" ]] && args+=(--check "$PY_CHECK")
            (cd "$PREFIX" && asuser "$PYTHON" installer.py "${args[@]}") \
                || die "installer.py failed; nothing was started." ;;
        node)
            log "Node dependencies"
            if [[ -f "$PREFIX/package-lock.json" ]]; then
                (cd "$PREFIX" && asuser npm ci --omit=dev --no-audit --no-fund) || die "npm ci failed; nothing was started."
            else
                (cd "$PREFIX" && asuser npm install --omit=dev --no-audit --no-fund) || die "npm install failed; nothing was started."
            fi ;;
    esac
fi

# ---------------------------------------------------------- writable dirs ----
# The paths the service writes. Gitignored, so `git reset --hard` leaves them
# alone; made here so their ownership is right before anything can create one
# as root by accident. 0750: they hold the application's data.

for dir in $WRITABLE_DIRS; do
    [[ "$dir" == /* ]] || dir="$PREFIX/$dir"
    if [[ ! -d "$dir" ]]; then
        log "Creating $dir"
        install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$dir"
    fi
done

run_hook on_install || die "on_install failed; nothing was started."

# What a deploy does before its restart, so the first start finds what every
# later one will: migrations applied, static files collected.
run_hook before_restart user || die "before_restart failed; nothing was started."

# ----------------------------------------------------------------- units ----

for svc in $SERVICES; do
    if [[ -f "$PREFIX/deploy/$svc.service" ]]; then
        log "Installing $UNIT_DIR/$svc.service"
        install -m 0644 -o root -g root "$PREFIX/deploy/$svc.service" "$UNIT_DIR/$svc.service"
    elif systemctl cat "$svc" >/dev/null 2>&1; then
        log "$svc has no deploy/$svc.service: keeping the unit already installed"
    else
        die "There is no deploy/$svc.service, and no unit named $svc installed."
    fi
done
# OPTIONAL_SERVICES: their units are installed when deploy/ has them, so a
# deploy reports no drift, but never enabled here. Whether one runs on this
# server -- a worker that needs a database set up first, say -- is a person's
# call:  sudo systemctl enable --now NAME
for svc in $OPTIONAL_SERVICES; do
    [[ -f "$PREFIX/deploy/$svc.service" ]] || continue
    log "Installing $UNIT_DIR/$svc.service"
    install -m 0644 -o root -g root "$PREFIX/deploy/$svc.service" "$UNIT_DIR/$svc.service"
done
systemctl daemon-reload
for svc in $SERVICES; do
    systemctl enable --quiet "$svc"
done

# A port taken by something else is a deploy that never comes up, with an
# error message about something else entirely.
if [[ -n "$PORT" ]] && command -v ss >/dev/null && ! systemctl is-active --quiet "$NAME"; then
    if [[ -n "$(ss -Hltn "sport = :$PORT" 2>/dev/null)" ]]; then
        warn "Something other than $NAME already listens on port $PORT:"
        ss -Hltnp "sport = :$PORT" 2>/dev/null | sed 's/^/    /' >&2 || true
    fi
fi

for svc in $SERVICES; do
    log "Restarting $svc"
    systemctl restart "$svc"
done
for svc in $OPTIONAL_SERVICES; do
    if ! systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        log "$svc is not enabled here, so deploys leave it alone. To run it:  sudo systemctl enable --now $svc"
        continue
    fi
    log "Restarting $svc"
    systemctl restart "$svc" || warn "$svc did not restart (not fatal: it is in OPTIONAL_SERVICES)"
done
run_hook after_restart user || die "after_restart failed."
if ! healthy; then
    for svc in $SERVICES; do warn "    journalctl -u $svc -n 50 --no-pager"; done
    die "$NAME did not come up."
fi

# --------------------------------------------------------------- sudoers ----
# Exactly one command per unit: deploy.sh restarts them, and that is all the
# CI key's forced command can do as root.

SUDOERS="/etc/sudoers.d/$NAME-deploy"
TMP_SUDOERS="$(mktemp)"
CLEANUP+=("$TMP_SUDOERS")
for svc in $SERVICES $OPTIONAL_SERVICES; do
    printf '%s ALL=(root) NOPASSWD: %s restart %s\n' "$SERVICE_USER" "$SYSTEMCTL_BIN" "$svc"
done > "$TMP_SUDOERS"
visudo -cqf "$TMP_SUDOERS" || die "The sudoers lines did not pass visudo; nothing was installed."
log "Installing $SUDOERS"
install -m 0440 -o root -g root "$TMP_SUDOERS" "$SUDOERS"

# ----------------------------------------------------------------- caddy ----
# A fragment, never a whole Caddyfile: the Caddyfile on a shared box is
# another site's production config, and replacing it would take that site down
# to bring this one up.

FRAGMENT="$PREFIX/deploy/$NAME.caddy"
if [[ -f "$FRAGMENT" ]] && ! command -v caddy >/dev/null; then
    warn "deploy/$NAME.caddy is here but caddy is not installed: skipping the site."
elif [[ -f "$FRAGMENT" ]]; then
    SITE_FILE="$CADDY_DIR/$NAME.caddy"
    IMPORT_LINE="import $CADDY_DIR/*.caddy"
    SITE_BACKUP="$(mktemp)" TMP_OUT="$(mktemp)"
    CLEANUP+=("$SITE_BACKUP" "$TMP_OUT")

    log "Installing the Caddy site ($SITE_FILE)"
    install -d -m 0755 -o root -g root "$CADDY_DIR"
    HAD_SITE=0
    if [[ -f "$SITE_FILE" ]]; then
        cp -a "$SITE_FILE" "$SITE_BACKUP"
        HAD_SITE=1
    fi
    install -m 0644 -o root -g root "$FRAGMENT" "$SITE_FILE"

    # `caddy validate` opens the log writers, and as root it would create each
    # log root-owned and 0600 -- which caddy, running as caddy, cannot open.
    if id caddy >/dev/null 2>&1; then
        while read -r logfile; do
            [[ -n "$logfile" ]] || continue
            install -d -m 0755 -o caddy -g caddy "$(dirname "$logfile")"
            [[ -e "$logfile" ]] || install -m 0644 -o caddy -g caddy /dev/null "$logfile"
        done < <(grep -oE 'output[[:space:]]+file[[:space:]]+[^[:space:]{}]+' "$FRAGMENT" | awk '{print $3}')
    fi

    APPENDED=0
    if ! grep -qF "$(basename "$CADDY_DIR")/*.caddy" "$CADDY_MAIN"; then
        cp -a "$CADDY_MAIN" "$CADDY_MAIN.pre-$NAME"
        log "Appending the conf.d import to $CADDY_MAIN (backup at $CADDY_MAIN.pre-$NAME)"
        printf '\n# Site fragments, one file per deployment.\n%s\n' "$IMPORT_LINE" >> "$CADDY_MAIN"
        APPENDED=1
    fi

    log "Validating the whole Caddy config"
    if ! caddy validate --config "$CADDY_MAIN" --adapter caddyfile >"$TMP_OUT" 2>&1; then
        sed 's/^/    /' "$TMP_OUT" >&2
        if (( HAD_SITE )); then cp -a "$SITE_BACKUP" "$SITE_FILE"; else rm -f "$SITE_FILE"; fi
        (( APPENDED )) && cp -a "$CADDY_MAIN.pre-$NAME" "$CADDY_MAIN"
        die "The Caddy config is invalid. The previous one is back in place and Caddy was not reloaded."
    fi
    log "Reloading caddy"
    systemctl reload caddy

    if [[ -n "$SITE" ]]; then
        log "Checking https://$SITE/ (the first certificate can take a minute)"
        code=000
        for _ in $(seq 1 30); do
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://$SITE/" || true)"
            [[ "$code" =~ ^[23] ]] && break
            sleep 2
        done
        if [[ "$code" =~ ^[23] ]]; then
            log "https://$SITE/ answers $code"
        else
            warn "https://$SITE/ answers $code. Does DNS point here, with any proxy off?  journalctl -u caddy --since '5 min ago' --no-pager | tail -40"
        fi
    fi
fi

# Reported, never changed: firewall rules on a box that already serves
# something else are not this script's to rewrite.
if [[ -n "$SITE" ]] && command -v ufw >/dev/null && UFW="$(ufw status 2>/dev/null)" && grep -q "Status: active" <<<"$UFW"; then
    grep -qE '^80(/tcp)?[[:space:]]+ALLOW'  <<<"$UFW" || warn "80/tcp is not allowed: the ACME HTTP challenge needs it.  sudo ufw allow 80/tcp"
    grep -qE '^443(/tcp)?[[:space:]]+ALLOW' <<<"$UFW" || warn "443/tcp is not allowed: nothing will reach $SITE.  sudo ufw allow 443/tcp"
    if [[ -n "$PORT" ]] && grep -qE "^$PORT(/tcp)?[[:space:]]+ALLOW" <<<"$UFW"; then
        warn "$PORT is open in ufw, but the application should only answer on the loopback:  sudo ufw delete allow $PORT"
    fi
fi

# ------------------------------------------------------------ deploy state ----
# What is checked out is what is running now, dependencies included.

install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$STATE_DIR"
HEAD_SHA="$(asuser git -C "$PREFIX" rev-parse HEAD)"
for record in deployed deps; do
    printf '%s\n' "$HEAD_SHA" > "$STATE_DIR/$record"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$STATE_DIR/$record"
done

# ---------------------------------------------------------------- CI key ----
# Its own key per project, never shared: the forced command is per key, so a
# shared key would be one whose leak reaches several services.

AUTH="$SERVICE_HOME/.ssh/authorized_keys"
KEY_COMMAND="command=\"$PREFIX/deploy/deploy.sh\""
KEY_COMMENT="$NAME-github-actions"

if (( CI_KEY )); then
    KEY_FILE="$SERVICE_HOME/$NAME-ci-key"
    TMP_KEY="$(mktemp -d)"
    CLEANUP+=("$TMP_KEY")
    ssh-keygen -q -t ed25519 -N "" -C "$KEY_COMMENT" -f "$TMP_KEY/key"

    install -d -m 0700 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$SERVICE_HOME/.ssh"
    [[ -f "$AUTH" ]] || install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_GROUP" /dev/null "$AUTH"
    # Replaces the key this script made before (rotation); every other line stays.
    { awk -v c="$KEY_COMMENT" -v p="$KEY_COMMAND" '!(index($0, p) == 1 && $NF == c)' "$AUTH"
      printf '%s,restrict %s\n' "$KEY_COMMAND" "$(cat "$TMP_KEY/key.pub")"
    } > "$TMP_KEY/authorized_keys"
    cat "$TMP_KEY/authorized_keys" > "$AUTH"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$AUTH"
    chmod 0600 "$AUTH"
    install -m 0600 -o "$SERVICE_USER" -g "$SERVICE_GROUP" "$TMP_KEY/key" "$KEY_FILE"

    # The address this server sends from, which on a VPS is the one GitHub
    # reaches it on. Behind NAT it is not: pass --host.
    HOST="${HOST_ARG:-$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p')}"
    HOST="${HOST:-SERVER-ADDRESS}"
    SSH_PORT="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }')"
    SSH_PORT="${SSH_PORT:-22}"
    HOST_SPEC="$HOST"
    [[ "$SSH_PORT" == 22 ]] || HOST_SPEC="[$HOST]:$SSH_PORT"
    SLUG="$(github_slug)"
    SLUG="${SLUG:-OWNER/REPO}"

    echo
    log "CI key installed in $AUTH as $KEY_COMMENT"
    echo
    echo "  Set these four secrets on $SLUG (Settings -> Secrets and variables -> Actions):"
    echo
    echo "    VPS_HOST         $HOST"
    echo "    VPS_USER         $SERVICE_USER"
    KNOWN_HOSTS="$(for pub in /etc/ssh/ssh_host_*_key.pub; do
        [[ -f "$pub" ]] && printf '%s %s\n' "$HOST_SPEC" "$(cut -d' ' -f1,2 "$pub")"
    done; true)"
    echo "    VPS_KNOWN_HOSTS  these lines, read from this server's own host keys:"
    # shellcheck disable=SC2001
    sed 's/^/                       /' <<<"$KNOWN_HOSTS"
    echo "    VPS_SSH_KEY      the private key in $KEY_FILE"
    echo
    echo "  With gh, on a machine that has a copy of the key file:"
    echo
    echo "    gh secret set VPS_HOST --repo $SLUG --body '$HOST'"
    echo "    gh secret set VPS_USER --repo $SLUG --body '$SERVICE_USER'"
    echo "    gh secret set VPS_KNOWN_HOSTS --repo $SLUG --body '$KNOWN_HOSTS'"
    echo "    gh secret set VPS_SSH_KEY --repo $SLUG < $NAME-ci-key"
    echo
    echo "  The host keys come from this server, not from a scan over the network, so"
    echo "  the deploy trusts this machine and nothing that answers in its place."
    [[ "$SSH_PORT" == 22 ]] || echo "  sshd listens on $SSH_PORT: pass  with: { ssh-port: $SSH_PORT }  to the deploy workflow."
    echo
    warn "Then delete $KEY_FILE. Nothing on this server needs the private half."
elif grep -qF "$KEY_COMMAND" "$AUTH" 2>/dev/null; then
    log "CI key with $KEY_COMMAND is in $AUTH"
else
    warn "No CI key with $KEY_COMMAND in $AUTH: pushes will not deploy."
    warn "Re-run with --ci-key to create one and print the GitHub secrets."
fi

echo
log "Done. Pushes to $BRANCH deploy themselves; drift is reported by every deploy."
