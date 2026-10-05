#!/usr/bin/env bash
#
# Set a project up to deploy with easy-deploy, or refresh the engine in one
# that already is. Run it from inside the project's checkout, on your own
# machine; nothing here touches a server.
#
#   /path/to/easy-deploy/init.sh            set up the project in the current directory
#   /path/to/easy-deploy/init.sh --update   refresh deploy/deploy.sh, deploy/install.sh
#                                           and installer.py; touch nothing else
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/BL4z3es/easy-deploy/main/init.sh)
#                                           the same, without a checkout of easy-deploy
#
# Options (asked for when not given, if there is a terminal):
#   --name NAME       the systemd unit and everything named after it   (the directory's name)
#   --stack STACK     python | node | none                              (detected)
#   --port PORT       the loopback port the application listens on      (8000)
#   --site DOMAIN     its public name, for a Caddy fragment              (none)
#   --user USER       the server account that owns and runs it          (you)
#   --prefix DIR      the deploy root on the server                      (/srv/NAME)
#   --branch BRANCH   the branch that deploys                            (the default branch)
#   --force           replace existing deploy/deploy.sh, deploy/install.sh,
#                     installer.py and .github/workflows/deploy.yml
#   -y, --yes         ask nothing; take the defaults
#   [DIR]             the project, if not the current directory
#
# Files it writes in the project:
#   deploy/deploy.sh, deploy/install.sh, installer.py   the engine: managed, never edit
#   deploy/easy-deploy.conf                             settings and hooks: yours
#   deploy/NAME.service, deploy/NAME.caddy              the unit and the site: yours
#   .github/workflows/deploy.yml                        checks, then the shared deploy job: yours

set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true

UPSTREAM=https://github.com/BL4z3es/easy-deploy
ED_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P || true)"

# Run from a pipe or a process substitution, there is no checkout next to this
# script to copy the engine from: fetch one and hand over to its init.sh.
if [[ ! -f "$ED_DIR/engine/deploy.sh" ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    git clone --quiet --depth 1 --branch "${EASY_DEPLOY_REF:-main}" "$UPSTREAM" "$tmp/easy-deploy"
    bash "$tmp/easy-deploy/init.sh" "$@"
    exit $?
fi

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m%s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx \033[0m%s\n' "$*" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < "$ED_DIR/VERSION")"
MARKER="Managed by easy-deploy"

NAME="" STACK="" PORT="" SITE="" SERVICE_USER="" PREFIX="" BRANCH="" FORCE=0 YES=0 UPDATE=0 PROJECT=""
while (( $# )); do
    case "$1" in
        --name)   NAME="${2:?--name needs a value}"; shift ;;
        --stack)  STACK="${2:?--stack needs a value}"; shift ;;
        --port)   PORT="${2:?--port needs a value}"; shift ;;
        --site)   SITE="${2:?--site needs a value}"; shift ;;
        --user)   SERVICE_USER="${2:?--user needs a value}"; shift ;;
        --prefix) PREFIX="${2:?--prefix needs a value}"; shift ;;
        --branch) BRANCH="${2:?--branch needs a value}"; shift ;;
        --update) UPDATE=1 ;;
        --force)  FORCE=1 ;;
        -y|--yes) YES=1 ;;
        -h|--help) sed -n '2,/^$/p' "$ED_DIR/init.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "Unknown option: $1 (try --help)" ;;
        *)  PROJECT="$1" ;;
    esac
    shift
done

PROJECT="${PROJECT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
PROJECT="$(cd "$PROJECT" && pwd -P)" || die "No such directory: $PROJECT"
[[ "$PROJECT" != "$ED_DIR" ]] || die "Run this from inside the project to set up, not from easy-deploy itself."
cd "$PROJECT"
[[ -d .git ]] || warn "$PROJECT is not the top of a git checkout; deploys need one."

is_managed() { [[ -f "$1" ]] && head -5 "$1" | grep -qF "$MARKER"; }
version_of() { head -5 "$1" 2>/dev/null | grep -oE "$MARKER [0-9][0-9A-Za-z.+-]*" | awk '{print $NF}' || true; }

# The engine, rendered: the only placeholder in it is its version.
put_engine() {  # source-in-engine/ destination mode
    local text
    text="$(<"$ED_DIR/engine/$1")"
    printf '%s\n' "${text//@VERSION@/"$VERSION"}" > "$2"
    chmod "$3" "$2"
}

engine_files() {  # stack
    printf '%s\n' "deploy.sh deploy/deploy.sh 755" "install.sh deploy/install.sh 755"
    [[ "$1" == python ]] && printf '%s\n' "installer.py installer.py 644"
    return 0
}

# ---------------------------------------------------------------- update ----

if (( UPDATE )); then
    [[ -f deploy/easy-deploy.conf ]] || die "There is no deploy/easy-deploy.conf here: run init.sh without --update first."
    # shellcheck disable=SC2016  # expanded by that bash, not this one
    stack="$(bash -c 'STACK=none; . deploy/easy-deploy.conf >/dev/null 2>&1; printf "%s" "$STACK"')"
    while read -r src dest mode; do
        if [[ -f "$dest" ]] && ! is_managed "$dest" && (( ! FORCE )); then
            warn "$dest is not managed by easy-deploy; left alone (--force replaces it)."
            continue
        fi
        old="$(version_of "$dest")"
        put_engine "$src" "$dest" "$mode"
        say "$dest: ${old:-new} -> $VERSION"
    done < <(engine_files "$stack")
    echo
    say "Review with git diff, commit and push: the next deploy runs the new engine for the deploy after it."
    exit 0
fi

# ------------------------------------------------------------- questions ----

[[ ! -f deploy/easy-deploy.conf ]] \
    || die "deploy/easy-deploy.conf already exists. To refresh the engine: init.sh --update"

stack_given="$STACK"
if [[ -z "$STACK" ]]; then
    if [[ -f requirements.txt || -f installer.py || -f pyproject.toml ]]; then STACK=python
    elif [[ -f package.json ]]; then STACK=node
    else STACK=none
    fi
fi
default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
default_branch="${default_branch#origin/}"
[[ -n "$default_branch" ]] || default_branch="$(git branch --show-current 2>/dev/null || true)"

interactive=0
if (( ! YES )) && [[ -t 1 ]] && { : < /dev/tty; } 2>/dev/null; then
    interactive=1
fi
ask() {  # variable prompt default
    local answer=""
    if (( interactive )); then
        read -r -p "$2 [$3]: " answer < /dev/tty || true
    fi
    printf -v "$1" '%s' "${answer:-$3}"
}

base="$(basename "$PROJECT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9_-' '-')"
base="${base%-}"
[[ -n "$NAME" ]]         || ask NAME "Name (the systemd unit)" "$base"
[[ -n "$stack_given" ]]  || ask STACK "Stack: python, node or none" "$STACK"
[[ -n "$PORT" ]]         || ask PORT "Loopback port it listens on" 8000
[[ -n "$SITE" ]]         || ask SITE "Public domain for a Caddy site (empty for none)" ""
[[ -n "$SERVICE_USER" ]] || ask SERVICE_USER "Server account that owns and runs it" "$(id -un)"
[[ -n "$PREFIX" ]]       || ask PREFIX "Deploy root on the server" "/srv/$NAME"
[[ -n "$BRANCH" ]]       || ask BRANCH "Branch that deploys" "${default_branch:-main}"

[[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "--name must be letters, digits, - and _ (sudoers ignores a file with a dot in its name)."
[[ "$STACK" =~ ^(python|node|none)$ ]]       || die "--stack must be python, node or none."
if [[ ! "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then die "--port must be a port number."; fi
[[ "$SERVICE_USER" != root ]]                || die "The service must not run as root."
[[ "$PREFIX" == /* ]]                        || die "--prefix must be an absolute path."

# ---------------------------------------------------------------- engine ----

conflicts=()
while read -r src dest mode; do
    if [[ -f "$dest" ]] && ! is_managed "$dest"; then conflicts+=("$dest"); fi
done < <(engine_files "$STACK")
if (( ${#conflicts[@]} )) && (( ! FORCE )); then
    warn "These exist and are not easy-deploy's: ${conflicts[*]}"
    warn "Move what they do that easy-deploy does not into deploy/easy-deploy.conf's hooks,"
    die "then re-run with --force to replace them (git keeps the old versions)."
fi

mkdir -p deploy .github/workflows
while read -r src dest mode; do
    put_engine "$src" "$dest" "$mode"
    say "Wrote $dest (easy-deploy $VERSION)"
done < <(engine_files "$STACK")

# ------------------------------------------------------------- templates ----

declare -A VARS=(
    [NAME]="$NAME" [STACK]="$STACK" [PORT]="$PORT" [SITE]="$SITE" [USER]="$SERVICE_USER"
    [PREFIX]="$PREFIX" [BRANCH]="$BRANCH" [VERSION]="$VERSION" [SITE_OR_EXAMPLE]="${SITE:-example.com}"
)

case "$STACK" in
    python)
        manage=""
        for candidate in manage.py */manage.py; do
            [[ -f "$candidate" ]] && { manage="$candidate"; break; }
        done
        if [[ -n "$manage" ]]; then
            VARS[PY_CHECK_LINE]=$'# installer.py\'s validation step: arguments for env/\'s python.\n'"PY_CHECK=\"$manage check\""
        else
            VARS[PY_CHECK_LINE]=$'# installer.py\'s validation step: arguments for env/\'s python, or none.\n# Default: manage.py check if there is one, otherwise import main.\n# PY_CHECK="-c \'import main\'"'
        fi
        VARS[ENVIRONMENT]=$'Environment=PYTHONDONTWRITEBYTECODE=1\nEnvironment=PYTHONUNBUFFERED=1'
        VARS[EXECSTART]="$PREFIX/env/bin/python -m uvicorn main:app --host 127.0.0.1 --port $PORT --proxy-headers"
        VARS[CHECK_STEPS]="
      - uses: actions/setup-python@v6
        with:
          python-version: '3.12'

      # The environment the server builds, built the same way: installer.py
      # creates env/, installs requirements.txt and runs the validation step.
      - name: installer.py
        run: python installer.py --non-interactive
" ;;
    node)
        main="$(sed -n 's/^[[:space:]]*"main"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' package.json 2>/dev/null | head -1 || true)"
        VARS[PY_CHECK_LINE]=""
        VARS[ENVIRONMENT]="Environment=NODE_ENV=production"
        VARS[EXECSTART]="/usr/bin/node $PREFIX/${main:-index.js}"
        VARS[CHECK_STEPS]="
      - uses: actions/setup-node@v5
        with:
          node-version: '22'

      - name: Install
        run: if [ -f package-lock.json ]; then npm ci; else npm install; fi

      - name: Every script parses
        run: find . -path ./node_modules -prune -o -name '*.js' -print0 | xargs -0 -r -n1 node --check
" ;;
    none)
        VARS[PY_CHECK_LINE]=""
        VARS[ENVIRONMENT]=""
        VARS[EXECSTART]="$PREFIX/start"
        VARS[CHECK_STEPS]="
      - name: Checks
        run: echo \"Add this project's tests here.\"
" ;;
esac

if [[ -n "$SITE" ]]; then
    VARS[SITE_LINE]=$'# The public name: deploy/'"$NAME"$'.caddy serves it.\n'"SITE=$SITE"
else
    VARS[SITE_LINE]=$'# The public name, if Caddy fronts it.\n# SITE=example.com'
fi

# Read without `git -C`, and allowed with -c: git refuses to look inside a
# checkout someone else owns, and easy-deploy's may well be.
upstream_url="$(git config --file "$ED_DIR/.git/config" remote.origin.url 2>/dev/null || true)"
upstream_slug="$(sed -nE 's#.*github\.com[:/]+([^/]+/[^/]+)$#\1#p' <<<"$upstream_url")"
VARS[WORKFLOW_REPO]="${upstream_slug%.git}"
VARS[WORKFLOW_REPO]="${VARS[WORKFLOW_REPO]:-BL4z3es/easy-deploy}"
VARS[WORKFLOW_REF]="$(git -c safe.directory="$ED_DIR" -C "$ED_DIR" describe --tags --exact-match HEAD 2>/dev/null || echo main)"

render() {  # template destination
    local text key
    text="$(<"$ED_DIR/templates/$1")"
    for key in "${!VARS[@]}"; do
        text="${text//"@$key@"/"${VARS[$key]}"}"
    done
    printf '%s\n' "$text" > "$2"
}

render easy-deploy.conf deploy/easy-deploy.conf
say "Wrote deploy/easy-deploy.conf"

if [[ -f "deploy/$NAME.service" ]]; then
    say "Kept deploy/$NAME.service"
else
    render app.service "deploy/$NAME.service"
    say "Wrote deploy/$NAME.service -- check its ExecStart"
fi

if [[ -n "$SITE" ]]; then
    if [[ -f "deploy/$NAME.caddy" ]]; then
        say "Kept deploy/$NAME.caddy"
    else
        render site.caddy "deploy/$NAME.caddy"
        say "Wrote deploy/$NAME.caddy"
    fi
fi

workflow=.github/workflows/deploy.yml
if [[ -f "$workflow" ]] && (( ! FORCE )); then
    warn "Kept $workflow. To use the shared deploy job, replace its deploy job with:"
    printf '\n  deploy:\n    needs: check\n    uses: %s/.github/workflows/deploy.yml@%s\n    secrets: inherit\n\n' \
        "${VARS[WORKFLOW_REPO]}" "${VARS[WORKFLOW_REF]}"
    warn "and drop any workflow-level concurrency group named easy-deploy."
else
    render workflow.yml "$workflow"
    say "Wrote $workflow"
fi
[[ "${VARS[WORKFLOW_REF]}" != main ]] \
    || warn "The workflow follows easy-deploy@main. Once easy-deploy has a release tag, pin it (@v1)."

# ------------------------------------------------------------- gitignore ----
# A reset leaves untracked and ignored paths alone; these must be among them.

ignores=(.easy-deploy/)
[[ "$STACK" == python ]] && ignores+=(env/ .env)
[[ "$STACK" == node ]] && ignores+=(node_modules/)
for entry in "${ignores[@]}"; do
    probe="${entry%/}"
    [[ "$entry" == */ ]] && probe="$probe/x"
    if git check-ignore -q --no-index "$probe" 2>/dev/null; then continue; fi
    printf '%s\n' "$entry" >> .gitignore
    say "Added $entry to .gitignore"
done

# ------------------------------------------------------------------ next ----

cat <<EOF

Next:

  1. Read deploy/easy-deploy.conf and deploy/$NAME.service (its ExecStart above all).
  2. Commit and push.
  3. On the server, from any checkout of the project:
       sudo deploy/install.sh --ci-key
     It builds $PREFIX, starts the service, and prints the four secrets.
  4. Set them on the repository. From then on every push to $BRANCH deploys,
     and rolls back if it does not come up.

EOF
