#!/usr/bin/env bash
# shellcheck disable=SC2016  # each `bash -c` check expands its own arguments
#
# End-to-end tests: init.sh sets up a throwaway project, and the real
# deploy/deploy.sh deploys it from a local origin into a local deploy root,
# with a stub systemctl running a small HTTP app. Nothing here needs root.
#
#   tests/run.sh                  everything
#   SKIP_NETWORK=1 tests/run.sh   without the installer.py tests, which pip-install python-dotenv

set -uo pipefail

ED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(mktemp -d)"
cleanup() {
    for pid in "$T"/run/*.pid; do [[ -f "$pid" ]] && kill "$(cat "$pid")" 2>/dev/null; done
    rm -rf "$T"
}
trap cleanup EXIT

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/        /'; }
check() {  # description command...
    local what="$1"; shift
    if "$@"; then ok "$what"; else bad "$what" "$OUT"; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ME="$(id -un)"
PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
ORIGIN="$T/origin.git" WORK="$T/work" PREFIX="$T/srv/testapp" RUN="$T/run" STUB="$T/stub"
mkdir -p "$RUN" "$STUB" "$T/etc/systemd" "$T/etc/caddy/conf.d" "$T/srv"
cp "$ED/tests/fixture/systemctl" "$STUB/systemctl"
printf 'PREFIX=%q\nPORT=%q\nRUN=%q\n' "$PREFIX" "$PORT" "$RUN" > "$STUB/stub.env"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
git init --quiet --bare -b main "$ORIGIN"
git init --quiet -b main "$WORK"
git -C "$WORK" remote add origin "$ORIGIN"

OUT="" RC=0
deploy() {  # [env...] -- run the deploy root's deploy.sh, keep its output and status
    OUT="$(env "$@" "$PREFIX/deploy/deploy.sh" 2>&1)"
    RC=$?
}
push() {  # message -- commit everything in the work tree and push it
    git -C "$WORK" add -A
    git -C "$WORK" commit --quiet -m "$1"
    git -C "$WORK" -c push.negotiate=false push --quiet origin main
}
served()   { curl -s --max-time 3 "http://127.0.0.1:$PORT/"; }
sha()      { git -C "$WORK" rev-parse HEAD; }
deployed() { cat "$PREFIX/.easy-deploy/deployed"; }
has()      { grep -qF -- "$1" <<<"$OUT"; }
lacks()    { ! grep -qF -- "$1" <<<"$OUT"; }

write_conf() {  # [python]
    cat > "$WORK/deploy/easy-deploy.conf" <<EOF
NAME=testapp
SERVICE_USER=$ME
PREFIX=$PREFIX
BRANCH=main
STACK=none
DEPS_FILES="deps.txt"
PORT=$PORT
SYSTEMCTL=systemctl
EXTRA_PATH=$STUB
UNIT_DIR=$T/etc/systemd
CADDY_DIR=$T/etc/caddy/conf.d
CADDY_MAIN=$T/etc/caddy/Caddyfile
HEALTH_TRIES=6
LOCK_WAIT=1

install_deps() {
    echo "\$ED_REF \$ED_PHASE" >> "$RUN/deps.log"
}
before_restart() {
    test ! -f fail-hook
    echo "\$ED_REF" >> "$RUN/hooks.log"
    if [[ -f slow-hook ]]; then sleep 3; fi
}
health_check() {
    test ! -f fail-health
}
EOF
    if [[ "${1:-}" == python ]]; then
        sed -i 's/^STACK=.*/STACK=python\nPY_CHECK=none/; /^DEPS_FILES=/d; /^install_deps()/,/^}/d' "$WORK/deploy/easy-deploy.conf"
    fi
}

# ------------------------------------------------------------------ init ----
section "init.sh"

cp "$ED/tests/fixture/app.py" "$WORK/app.py"
echo v1 > "$WORK/version.txt"
echo "dep-a" > "$WORK/deps.txt"
# init.sh refuses a service that runs as root, and the tests may be running as root.
init_user="$ME"; [[ "$ME" != root ]] || init_user=deploy
OUT="$(cd "$WORK" && "$ED/init.sh" --yes --name testapp --stack none --port "$PORT" --user "$init_user" \
                    --prefix "$PREFIX" --branch main --site testapp.example.com 2>&1)"; RC=$?
check "sets up a project" test "$RC" = 0
version="$(tr -d '[:space:]' < "$ED/VERSION")"
check "engine files carry the version" grep -q "Managed by easy-deploy $version" "$WORK/deploy/deploy.sh"
check "no placeholder is left in any file" bash -c '! grep -rnE "@[A-Z][A-Z_]*@" "$1/deploy" "$1/.github"' _ "$WORK"
check "the unit's ExecStart is filled in" grep -q "^ExecStart=$PREFIX/start$" "$WORK/deploy/testapp.service"
check "a Caddy fragment for the site" grep -q "^testapp.example.com {" "$WORK/deploy/testapp.caddy"
check "the workflow calls the shared deploy job" grep -q "uses: .*/easy-deploy/.github/workflows/deploy.yml@" "$WORK/.github/workflows/deploy.yml"
check "the state dir is gitignored" grep -qx ".easy-deploy/" "$WORK/.gitignore"
check "the generated config parses" bash -n "$WORK/deploy/easy-deploy.conf"
OUT="$(cd "$WORK" && "$ED/init.sh" --yes 2>&1)"; RC=$?
check "refuses to run twice" test "$RC" != 0
echo "# hand edit" >> "$WORK/deploy/deploy.sh"
OUT="$(cd "$WORK" && "$ED/init.sh" --update 2>&1)"; RC=$?
check "--update refreshes the engine" bash -c '[[ $0 = 0 ]] && ! grep -q "hand edit" "$1"' "$RC" "$WORK/deploy/deploy.sh"
OUT="$("$WORK/deploy/deploy.sh" --print-config 2>&1)"
check "deploy.sh and install.sh resolve the config the same way" \
    test "$OUT" = "$("$WORK/deploy/install.sh" --print-config 2>&1)"

# --------------------------------------------------------- first install ----
# What install.sh does, minus root: a deploy root cloned from origin, started.

write_conf
cp "$WORK/deploy/testapp.service" "$T/etc/systemd/testapp.service"
cp "$WORK/deploy/testapp.caddy" "$T/etc/caddy/conf.d/testapp.caddy"
echo "import $T/etc/caddy/conf.d/*.caddy" > "$T/etc/caddy/Caddyfile"
push "v1"
git clone --quiet "$ORIGIN" "$PREFIX"
"$STUB/systemctl" restart testapp
sleep 1

section "deploy.sh"

deploy
check "first run: nothing to do" bash -c '[[ $0 = 0 ]] && grep -q "nothing to do" <<<"$1"' "$RC" "$OUT"
check "first run: records what is deployed" test "$(deployed)" = "$(sha)"

OUT="$(cd "$T" && "$WORK/deploy/deploy.sh" 2>&1)"; RC=$?
check "refuses to run outside the deploy root" bash -c '[[ $0 = 1 ]] && grep -q "deploy root is" <<<"$1"' "$RC" "$OUT"

echo v2 > "$WORK/version.txt"; push "v2"
deploy
check "deploys a new commit" test "$RC" = 0
check "  and serves it" test "$(served)" = v2
check "  and records it" test "$(deployed)" = "$(sha)"
check "  without reinstalling unchanged dependencies" test ! -s "$RUN/deps.log"
check "  and reports no drift" lacks "differs"

V2="$(sha)"
touch "$WORK/broken"; echo v3 > "$WORK/version.txt"; push "v3: does not start"
deploy
check "a commit that does not come up fails the deploy" test "$RC" = 1
check "  and rolls back" has "ROLLING BACK"
check "  to the previous commit, still serving" test "$(served)" = v2
check "  with the checkout back where it was" test "$(git -C "$PREFIX" rev-parse HEAD)" = "$V2"
check "  and the record unchanged" test "$(deployed)" = "$V2"

rm "$WORK/broken"; touch "$WORK/fail-hook"; echo v4 > "$WORK/version.txt"; push "v4: hook fails halfway"
deploy
check "a hook's first failing command fails it (errexit in hooks)" test "$RC" = 1
check "  the rest of the hook never ran" bash -c '! grep -q "$0" "$1"' "$(sha)" "$RUN/hooks.log"
check "  and the service was rolled back" test "$(served)" = v2

rm "$WORK/fail-hook"; touch "$WORK/fail-health"; echo v5 > "$WORK/version.txt"; push "v5: health_check fails"
deploy
check "a failing health_check hook rolls back" bash -c '[[ $0 = 1 ]] && [[ $1 = v2 ]]' "$RC" "$(served)"

rm "$WORK/fail-health"; echo v6 > "$WORK/version.txt"; echo 'NAME=testapp; broken(' >> "$WORK/deploy/easy-deploy.conf"; push "v6: config does not parse"
deploy
check "a commit whose config does not parse rolls back" bash -c '[[ $0 = 1 ]] && [[ $1 = v2 ]]' "$RC" "$(served)"

write_conf; echo v7 > "$WORK/version.txt"; push "v7: fixed"
deploy
check "the next good commit deploys" bash -c '[[ $0 = 0 ]] && [[ $1 = v7 ]]' "$RC" "$(served)"
deploy
check "a second run is a no-op" bash -c '[[ $0 = 0 ]] && grep -q "nothing to do" <<<"$1"' "$RC" "$OUT"

# Dependencies: installed only when DEPS_FILES moved, and again on the rollback.
echo "dep-b" > "$WORK/deps.txt"; touch "$WORK/broken"; push "v8: new deps, does not start"
deploy
check "changed dependencies install, then roll back with the old ones" \
    bash -c '[[ $0 = 1 ]] && [[ $(grep -c "" "$1") = 2 ]] && grep -q "deploy$" "$1" && grep -q "rollback$" "$1"' "$RC" "$RUN/deps.log"
rm "$WORK/broken"; echo dep-a > "$WORK/deps.txt"; echo v9 > "$WORK/version.txt"; push "v9"
: > "$RUN/deps.log"
deploy
check "  a commit with the deployed commit's dependencies installs nothing" \
    bash -c '[[ $0 = 0 ]] && [[ ! -s $1 ]]' "$RC" "$RUN/deps.log"

# An earlier deploy that moved the checkout and died before the restart.
echo v10 > "$WORK/version.txt"; push "v10"
git -C "$PREFIX" fetch --quiet origin main && git -C "$PREFIX" reset --quiet --hard origin/main
deploy
check "a deploy that died after the reset is finished by the next run" \
    bash -c '[[ $0 = 0 ]] && grep -q "finishing it" <<<"$1" && [[ $2 = v10 ]]' "$RC" "$OUT" "$(served)"

# Drift: the unit in deploy/ is not the one installed.
echo "# changed" >> "$WORK/deploy/testapp.service"; push "unit changed"
deploy SSH_ORIGINAL_COMMAND=deploy
check "unit drift is reported" has "deploy/testapp.service differs"
check "  as an annotation under the forced command" has "::warning title=Server config drift::"
check "  and does not fail the deploy" test "$RC" = 0
grep -v import "$T/etc/caddy/Caddyfile" > "$T/caddy.tmp"; mv "$T/caddy.tmp" "$T/etc/caddy/Caddyfile"
deploy
check "a Caddyfile that lost the conf.d import is reported" has "no longer imports"

# One deploy at a time.
echo v11 > "$WORK/version.txt"; push "v11"
flock "$PREFIX/.easy-deploy/lock" sleep 4 &
locker=$!
sleep 0.5
deploy
check "a held lock stops a second deploy" bash -c '[[ $0 = 1 ]] && grep -q "held" <<<"$1"' "$RC" "$OUT"
wait "$locker"

# A runner that goes away mid-deploy.
touch "$WORK/slow-hook"; echo v12 > "$WORK/version.txt"; push "v12: slow hook"
"$PREFIX/deploy/deploy.sh" > "$T/hup.out" 2>&1 &
deployer=$!
sleep 1.5
kill -HUP "$deployer" 2>/dev/null
wait "$deployer"; RC=$?
OUT="$(cat "$T/hup.out")"
check "a hangup mid-deploy does not stop it" bash -c '[[ $0 = 0 ]] && [[ $1 = v12 ]]' "$RC" "$(served)"
check "  and the log on the server has all of it" grep -q "Deployed" "$PREFIX/.easy-deploy/deploy.log"
rm "$WORK/slow-hook"; push "fast again"; deploy

# ---------------------------------------------------- python and installer ----

if [[ -z "${SKIP_NETWORK:-}" ]]; then
    section "installer.py"

    P="$T/py"
    mkdir -p "$P"
    sed "s/@VERSION@/$version/" "$ED/engine/installer.py" > "$P/installer.py"
    : > "$P/requirements.txt"
    echo "import json" > "$P/main.py"
    printf 'SECRET=keep-me\nVIRTUAL_ENV=/old/path\nVIRTUAL_ENV=/older/path\n' > "$P/.env"
    OUT="$(cd "$P" && python3 installer.py --non-interactive 2>&1)"; RC=$?
    check "builds env/ and validates" bash -c '[[ $0 = 0 ]] && [[ -x $1/env/bin/python ]]' "$RC" "$P"
    check "  importing main.py rather than running it" has "python -c 'import main'"
    OUT="$(cd "$P" && python3 installer.py --non-interactive 2>&1)"
    check ".env: one line per key, however often it runs" \
        bash -c '[[ $(grep -c "^VIRTUAL_ENV=" "$0") = 1 && $(grep -c "^PYTHON_EXECUTABLE=" "$0") = 1 ]]' "$P/.env"
    check ".env: other lines kept" grep -qx "SECRET=keep-me" "$P/.env"
    check ".env: the stale VIRTUAL_ENV replaced" grep -qx "VIRTUAL_ENV=$P/env" "$P/.env"

    echo "import definitely_not_a_module_xyz" > "$P/main.py"
    OUT="$(cd "$P" && python3 installer.py --non-interactive 2>&1)"; RC=$?
    check "non-interactive: a missing module fails, and installs no guess" \
        bash -c '[[ $0 = 1 ]] && grep -q "Add it to requirements.txt" <<<"$1" && ! grep -q "Installing package" <<<"$1"' "$RC" "$OUT"
    OUT="$(cd "$P" && python3 installer.py --non-interactive --check none 2>&1)"; RC=$?
    check "--check none skips validation" test "$RC" = 0
    echo "import time; time.sleep(60)" > "$P/main.py"
    printf 'import sys\nsys.argv = ["installer.py", "--non-interactive", "--check", "main.py"]\nimport installer\ninstaller.CHECK_TIMEOUT = 2\nsys.exit(installer.main(sys.argv[1:]))\n' > "$P/run_short.py"
    OUT="$(cd "$P" && python3 run_short.py 2>&1)"; RC=$?
    check "a validation step that never finishes is stopped" bash -c '[[ $0 = 1 ]] && grep -q "still running" <<<"$1"' "$RC" "$OUT"

    section "deploy.sh with STACK=python"

    cp "$P/installer.py" "$WORK/installer.py"
    : > "$WORK/requirements.txt"
    printf 'env/\n.env\n' >> "$WORK/.gitignore"
    write_conf python
    echo v20 > "$WORK/version.txt"; push "python stack"
    deploy
    check "builds env/ with installer.py on the first deploy" \
        bash -c '[[ $0 = 0 ]] && grep -q "Installer" <<<"$1" && [[ -x $2/env/bin/python ]]' "$RC" "$OUT" "$PREFIX"
    echo v21 > "$WORK/version.txt"; push "v21"
    deploy
    check "  and skips it when requirements.txt did not move" bash -c '[[ $0 = 0 ]] && ! grep -q "Installer" <<<"$1"' "$RC" "$OUT"
    echo "definitely-not-a-real-package-easy-deploy==9.9" > "$WORK/requirements.txt"; echo v22 > "$WORK/version.txt"; push "v22: bad requirement"
    deploy
    check "  a requirement that cannot install rolls back" bash -c '[[ $0 = 1 ]] && [[ $1 = v21 ]]' "$RC" "$(served)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
