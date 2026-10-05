#!/usr/bin/env bash
#
# Managed by easy-deploy @VERSION@ -- do not edit. This project's settings and
# hooks live in deploy/easy-deploy.conf; refresh this file with
# `init.sh --update` from an easy-deploy checkout.
#
# Deploy this project from origin/$BRANCH, and roll back if it does not come up.
#
#   deploy/deploy.sh                  deploy now
#   deploy/deploy.sh --print-config   show the settings it would use, and exit
#
# Run as the forced command on this project's own CI key in authorized_keys,
#
#   command="/srv/NAME/deploy/deploy.sh",restrict ssh-ed25519 AAAA... NAME-github-actions
#
# so any session that key opens runs this, and whatever the client asked for is
# discarded. A leaked key buys a deploy and nothing else. Running it by hand,
# as SERVICE_USER, does the same thing.
#
# The sequence:
#   1. fetch origin/$BRANCH. Nothing to do when the checkout is already there
#      and the last deploy of it finished.
#   2. git reset --hard, not pull: the deploy root mirrors origin, it is not
#      somewhere work happens, and a merge conflict here would wedge every
#      later deploy. Gitignored paths (env/, node_modules/, data/, .env) are
#      untouched by it.
#   3. dependencies, only when their manifest moved or they are missing.
#   4. the before_restart hook, a restart of every unit in SERVICES, the
#      after_restart hook.
#   5. poll HEALTH_URLS until every one answers, then the health_check hook.
#   6. on any failure, steps 2-5 for the previous commit, then exit 1 either
#      way, because what is live is not what was pushed.
#   7. report units and the Caddy fragment in deploy/ that differ from the
#      copies in /etc. Reported, never applied: writing /etc needs root, and a
#      sudoers line that allowed it would make a leaked CI key root.

set -euo pipefail

# The whole script is parsed before anything runs: step 2 replaces this file,
# and bash would otherwise read the rest of it from the new version.
main() {

EASY_DEPLOY_VERSION=@VERSION@

# A forced command inherits almost no environment, so nothing below may assume
# a login shell ran.
BASE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH="$BASE_PATH"
export GIT_TERMINAL_PROMPT=0
export PYTHONDONTWRITEBYTECODE=1
ED_ME="$(id -un)"
# The account's own home, not the deploy root: git finds its credentials there
# (a deploy key in ~/.ssh, or gh's credential helper).
HOME="$(getent passwd "$ED_ME" | cut -d: -f6)"
export HOME

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CONF="$REPO/deploy/easy-deploy.conf"

local print_only=0 arg
for arg in "$@"; do
    case "$arg" in
        --print-config) print_only=1 ;;
        -h|--help) sed -n '7,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
        *) warn "Unknown argument: $arg"; return 2 ;;
    esac
done

[[ -f "$CONF" ]] || { warn "There is no $CONF. Run easy-deploy's init.sh in this project first."; return 1; }
load_conf || return 1
if (( print_only )); then
    print_config
    return 0
fi

# NAME, PREFIX, BRANCH, SERVICE_USER and STATE_DIR are read once, from the
# checkout already here. A commit that changes one of them needs install.sh,
# not a deploy.
pin_identity

if [[ "$REPO" != "$(readlink -m "$PREFIX")" ]]; then
    warn "This is $REPO, but the deploy root is $PREFIX."
    warn "deploy.sh resets its own checkout to origin/$BRANCH, so it only runs from there:  $PREFIX/deploy/deploy.sh"
    return 1
fi

local owner
owner="$(stat -c %U "$REPO/.git")"
if [[ "$owner" != "$ED_ME" ]]; then
    warn "Run this as $owner, who owns $REPO, not as $ED_ME: everything a deploy writes has to stay $owner's."
    return 1
fi

# Checked up front rather than discovered halfway through: npm, say, is only
# needed on the deploys where the manifest moved, so a missing one would work
# for months and then fail on the deploy that mattered, after the reset.
local tool
# shellcheck disable=SC2046  # one tool per word
for tool in git curl flock tee systemctl $(stack_tools); do
    command -v "$tool" >/dev/null && continue
    warn "$tool is not on this PATH ($PATH)."
    case "$tool" in
        node|npm) warn "A node from nvm or fnm is invisible to a forced command: install it from the distro or NodeSource, or set EXTRA_PATH." ;;
    esac
    return 1
done

cd "$REPO"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# One deploy at a time, from any trigger. GitHub's concurrency group only
# covers the runs it starts; this also covers a deploy started by hand.
# fd 9 holds the lock: everything started from here that could outlive this
# script gets it closed (9>&-), or it would hold the lock after we exit.
exec 9>>"$STATE_DIR/lock"
if ! flock -w "$LOCK_WAIT" 9; then
    warn "Another deploy has held $STATE_DIR/lock for over ${LOCK_WAIT}s. Not deploying."
    return 1
fi

# A runner that goes away -- a timeout, a cancelled job -- must not stop a
# deploy halfway, between the reset and the restart. Output keeps going to the
# log file once the connection is gone, and the hangup is ignored.
trap '' HUP PIPE

local head
head="$(git rev-parse HEAD)"
if [[ ! -s "$STATE_DIR/deployed" ]]; then
    # The first run here: what is checked out is what is running.
    record deployed "$head"
    record deps "$head"
fi
DEPLOYED="$(<"$STATE_DIR/deployed")"
git cat-file -e "$DEPLOYED^{commit}" 2>/dev/null || DEPLOYED="$head"

log "Fetching origin/$BRANCH"
if ! git fetch --quiet origin "$BRANCH" 9>&-; then
    warn "git fetch origin $BRANCH failed, as $ED_ME with HOME=$HOME."
    return 1
fi
TARGET="$(git rev-parse "origin/$BRANCH")"

if [[ "$DEPLOYED" == "$TARGET" && "$head" == "$TARGET" ]]; then
    log "Already at ${TARGET:0:8} -- nothing to do"
    report_drift
    return 0
fi
PREVIOUS="$DEPLOYED"

# From here on this run deploys, and its output is the deploy log.
[[ -f "$STATE_DIR/deploy.log" ]] && mv -f "$STATE_DIR/deploy.log" "$STATE_DIR/deploy.log.1"
exec > >(tee -a -p "$STATE_DIR/deploy.log" 9>&-) 2>&1

if [[ "$head" == "$TARGET" ]]; then
    # An earlier deploy moved the checkout and never finished: the job was
    # killed, the connection dropped before the trap above existed, the server
    # rebooted. The checkout looks deployed; what runs may not be.
    log "The checkout is at ${TARGET:0:8}, but the last deploy that finished was ${PREVIOUS:0:8} -- finishing it"
else
    log "Deploying ${PREVIOUS:0:8} -> ${TARGET:0:8}  (easy-deploy $EASY_DEPLOY_VERSION)"
    git --no-pager log --oneline "$PREVIOUS..$TARGET" 2>/dev/null | sed 's/^/    /' || true
fi

if apply "$TARGET" deploy && healthy; then
    record deployed "$TARGET"
    log "Deployed ${TARGET:0:8}"
    report_drift
    return 0
fi

log "ROLLING BACK to ${PREVIOUS:0:8}"
if apply "$PREVIOUS" rollback && healthy; then
    record deployed "$PREVIOUS"
    log "Rolled back to ${PREVIOUS:0:8}; $NAME is serving the previous commit"
    annotate error "Deploy rolled back" "${TARGET:0:8} did not come up; ${PREVIOUS:0:8} is live again. Log: $STATE_DIR/deploy.log"
else
    log "ROLLBACK FAILED -- $NAME is down and needs a human"
    local svc
    for svc in $SERVICES; do
        log "    journalctl -u $svc -n 100 --no-pager"
    done
    annotate error "Rollback failed" "Neither ${TARGET:0:8} nor ${PREVIOUS:0:8} came up: $NAME is down."
fi
report_drift

# Fail either way: what is live is not what was pushed.
return 1
}

# ---------------------------------------------------------------- output ----

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*" || true; }
warn() { printf '\033[1;33m!! \033[0m%s\n' "$*" >&2 || true; }

# A line the GitHub runner turns into an annotation on the run. Only under the
# forced command, where that is who is reading.
annotate() {  # warning|error title message
    if [[ -n "${SSH_ORIGINAL_COMMAND:-}" ]]; then
        printf '::%s title=%s::%s\n' "$1" "$2" "$3" || true
    fi
}

record() {  # name commit -- written whole, so a crash never leaves half a line
    printf '%s\n' "$2" > "$STATE_DIR/$1.tmp" && mv -f "$STATE_DIR/$1.tmp" "$STATE_DIR/$1"
}

# ---------------------------------------------------------------- config ----
# The same defaults as install.sh's load_conf: keep the two in step (the tests
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

pin_identity() {
    ID_NAME="$NAME" ID_PREFIX="$PREFIX" ID_BRANCH="$BRANCH" ID_USER="$SERVICE_USER" ID_STATE="$STATE_DIR"
}

# After loading another commit's config: keep the installed identity, and say
# so if the commit wanted a different one.
restore_identity() {  # [quiet]
    if [[ -z "${1:-}" && "$NAME|$PREFIX|$BRANCH|$SERVICE_USER|$STATE_DIR" != "$ID_NAME|$ID_PREFIX|$ID_BRANCH|$ID_USER|$ID_STATE" ]]; then
        warn "This commit changes NAME, PREFIX, BRANCH, SERVICE_USER or STATE_DIR. That is an install, not a deploy:"
        warn "this deploy keeps the ones in place. Apply them with install.sh."
    fi
    NAME="$ID_NAME" PREFIX="$ID_PREFIX" BRANCH="$ID_BRANCH" SERVICE_USER="$ID_USER" STATE_DIR="$ID_STATE"
}

stack_tools() {
    case "$STACK" in
        python) printf '%s\n' "$PYTHON" ;;
        node)   printf '%s\n' node npm ;;
    esac
}

# The env file holds secrets, so it is read rather than sourced. `.` executes
# whatever the file contains: a stray space in `KEY= value` turns the value
# into a command, and the "command not found" that follows prints the secret
# straight into the CI log. Only NAME=VALUE lines are honoured here; anything
# else is reported by line number and skipped, never run.
load_env() {
    local file="$1" line name value lineno=0

    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line=${line%$'\r'}                        # tolerate a CRLF file
        line=${line#"${line%%[![:space:]]*}"}     # and leading indentation

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
            # The offending text is deliberately not echoed back -- it is most
            # likely a secret that was merely mistyped.
            warn "$file line $lineno is not NAME=VALUE -- skipped"
        fi
    done < "$file"
}

load_env_file() {
    [[ -n "$ENV_FILE" ]] || return 0
    # A leading '-' means "optional", the way systemd's EnvironmentFile=-/path does.
    local file="${ENV_FILE#-}"
    if [[ ! -e "$file" ]]; then
        [[ "$ENV_FILE" == -* ]] && return 0
        warn "ENV_FILE $file does not exist."
        return 1
    fi
    [[ -r "$file" ]] || { warn "ENV_FILE $file is not readable by $ED_ME."; return 1; }
    load_env "$file"
}

# ----------------------------------------------------------------- apply ----
# Every step returns explicitly on failure, because this runs inside `if`,
# where bash suspends set -e for every function it calls: a failed install must
# not fall through to a restart.

apply() {  # commit deploy|rollback -- check it out, install what changed, restart
    local ref="$1" from=""
    [[ -s "$ID_STATE/deps" ]] && from="$(<"$ID_STATE/deps")"

    git reset --quiet --hard "$ref" || return 1

    # This commit's own settings and hooks, so they deploy -- and roll back --
    # together with its code. A config that does not load fails the commit,
    # and the identity stays what it was for the rollback that follows.
    if ! load_conf; then
        restore_identity quiet
        return 1
    fi
    restore_identity
    export REPO NAME PREFIX BRANCH SERVICE_USER SERVICES VENV PY PREVIOUS TARGET
    export ED_REF="$ref" ED_PHASE="$2"

    # Before dependencies: installer.py's validation step imports the
    # application, which should see the environment it runs with.
    load_env_file || return 1
    deps "$from" "$ref" || return 1
    run_hook before_restart || return 1
    restart || return 1
    run_hook after_restart || return 1
}

# Dependencies only when the manifest moved between the commit they were last
# installed for and this one; an install on every deploy is a minute of
# nothing. "Last installed for" rather than "the commit before": on the
# rollback pass those differ, and diffing against the wrong one would leave
# the old code running against the new commit's packages.
deps() {  # from ref
    local from="$1" ref="$2" files=()
    read -r -a files <<<"$DEPS_FILES"
    if (( ${#files[@]} == 0 )) && ! declare -F install_deps >/dev/null; then
        record deps "$ref"
        return 0
    fi
    if [[ -n "$from" ]] && (( ${#files[@]} > 0 )) && ! deps_missing \
       && git diff --quiet "$from" "$ref" -- "${files[@]}" 2>/dev/null; then
        record deps "$ref"
        return 0
    fi

    # Until this finishes, nothing is known to be installed: a failure here
    # makes the next pass (the rollback included) install again.
    rm -f "$STATE_DIR/deps"
    if deps_missing; then
        log "No dependencies installed yet -- installing"
    else
        log "Dependencies changed (${DEPS_FILES:-every deploy}) -- installing"
    fi
    if declare -F install_deps >/dev/null; then
        run_hook install_deps || return 1
    else
        case "$STACK" in
            python) python_deps || return 1 ;;
            node)   node_deps || return 1 ;;
        esac
    fi
    record deps "$ref"
}

deps_missing() {
    case "$STACK" in
        python) [[ ! -x "$PY" ]] ;;
        node)   [[ ! -d "$REPO/node_modules" ]] ;;
        *)      return 1 ;;
    esac
}

# installer.py owns the Python environment: env/ at the top of the checkout,
# requirements.txt into it, then the project's validation step.
python_deps() {
    if [[ ! -f "$REPO/installer.py" ]]; then
        warn "STACK=python, but there is no installer.py at the top of the repository (init.sh puts it there)."
        return 1
    fi
    local args=(--non-interactive)
    [[ -n "$PY_CHECK" ]] && args+=(--check "$PY_CHECK")
    (cd "$REPO" && "$PYTHON" installer.py "${args[@]}" 9>&-)
}

node_deps() {
    if [[ -f "$REPO/package-lock.json" ]]; then
        (cd "$REPO" && npm ci --omit=dev --no-audit --no-fund 9>&-)
    else
        (cd "$REPO" && npm install --omit=dev --no-audit --no-fund 9>&-)
    fi
}

# A hook is a function in easy-deploy.conf. It runs in a bash of its own with
# errexit on: called from here it would run inside `if`, where set -e is
# suspended, and carry on past a failed migration to report success.
run_hook() {  # name
    declare -F "$1" >/dev/null || return 0
    log "$1"
    (cd "$REPO" && bash -c 'set -euo pipefail; . "$1"; "$2"' easy-deploy-hook "$CONF" "$1" 9>&-)
}
export -f log warn load_env

# SERVICES must restart. OPTIONAL_SERVICES -- a worker beside the site, say --
# restart when they are enabled here, and one that will not is reported, never
# rolled back over: the health check is about SERVICES.
restart() {
    local svc
    for svc in $SERVICES; do
        log "Restarting $svc"
        if ! "${SYSTEMCTL_CMD[@]}" restart "$svc" 9>&-; then
            warn "Could not restart $svc. Is install.sh's sudoers line for it in place?  sudo $PREFIX/deploy/install.sh"
            return 1
        fi
    done
    for svc in $OPTIONAL_SERVICES; do
        systemctl is-enabled --quiet "$svc" 2>/dev/null || continue
        log "Restarting $svc"
        "${SYSTEMCTL_CMD[@]}" restart "$svc" 9>&- || warn "$svc did not restart (not fatal: it is in OPTIONAL_SERVICES)"
    done
    return 0
}

# ---------------------------------------------------------------- health ----
# A unit is up before it is ready, so this polls rather than checking once
# after a fixed sleep: a fast deploy stays fast and a slow one stays correct.
# Healthy means every unit in SERVICES is active and every URL in HEALTH_URLS
# answers HEALTH_STATUS -- then the health_check hook, if there is one. With no
# URLs, the units have to stay active for five checks in a row, which is what
# tells a service that is up from one that is crash-looping.

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
                if declare -F health_check >/dev/null && ! run_hook health_check; then
                    log "Up after ${i}s, but the health_check hook failed"
                    return 1
                fi
                log "Healthy after ${i}s"
                return 0
            fi
        else
            streak=0
        fi
        sleep 1
    done
    log "Unhealthy after ${HEALTH_TRIES}s -- not up:${down}${codes:+  (last:$codes)}"
    return 1
}

# ----------------------------------------------------------------- drift ----
# The units and the Caddy fragment live in the repository, so a commit can
# change them, but installing them needs root. So: compared after every deploy,
# reported loudly, and applied by a person re-running install.sh. Every file
# compared here is world-readable, so this needs no privilege.

report_drift() {
    local drifted=0 svc
    for svc in $SERVICES $OPTIONAL_SERVICES; do
        [[ -f "$REPO/deploy/$svc.service" ]] || continue
        if ! cmp -s "$REPO/deploy/$svc.service" "$UNIT_DIR/$svc.service"; then
            warn "deploy/$svc.service differs from $UNIT_DIR/$svc.service."
            drifted=1
        fi
    done
    if [[ -f "$REPO/deploy/$NAME.caddy" ]]; then
        if ! cmp -s "$REPO/deploy/$NAME.caddy" "$CADDY_DIR/$NAME.caddy"; then
            warn "deploy/$NAME.caddy differs from $CADDY_DIR/$NAME.caddy."
            drifted=1
        fi
        # Another project re-installing a whole Caddyfile drops the import, and
        # with it this site.
        if [[ -r "$CADDY_MAIN" ]] && ! grep -qF "$(basename "$CADDY_DIR")/*.caddy" "$CADDY_MAIN"; then
            warn "$CADDY_MAIN no longer imports $CADDY_DIR/*.caddy -- ${SITE:-this site} is not being served."
            drifted=1
        fi
    fi
    if (( drifted )); then
        warn "Apply with:  sudo $PREFIX/deploy/install.sh"
        annotate warning "Server config drift" "deploy/ differs from what is installed in /etc. Run: sudo $PREFIX/deploy/install.sh"
    fi
    return 0
}

main "$@"; exit $?
