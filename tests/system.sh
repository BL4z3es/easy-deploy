#!/usr/bin/env bash
# shellcheck disable=SC2016  # each `bash -c` check expands its own arguments
#
# The whole chain, as root, on a disposable machine: init.sh, install.sh for
# real (deploy root, installer.py, unit, sudoers, CI key), then deploys through
# the CI key's forced command over a real SSH connection -- what GitHub's
# runner does, minus GitHub.
#
# It changes the machine it runs on (a user, /srv, /etc/sudoers.d, a unit,
# authorized_keys), so it refuses to run unless told this machine is
# disposable: a CI runner or a container.
#
#   sudo EASY_DEPLOY_SYSTEM_TEST=1 tests/system.sh
#
# With systemd running, the unit is real. Without it (a container), a fake
# systemctl stands in, installed as /usr/local/sbin/systemctl for the run.

set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 2; }
[[ -n "${EASY_DEPLOY_SYSTEM_TEST:-}" ]] \
    || { echo "This changes the machine it runs on. On a disposable one: EASY_DEPLOY_SYSTEM_TEST=1" >&2; exit 2; }
for tool in sshd ssh ssh-keygen runuser visudo sudo git curl python3; do
    command -v "$tool" >/dev/null || { echo "$tool is not installed." >&2; exit 2; }
done

ED="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SVC_USER=edtest NAME=edtest-app PREFIX=/srv/edtest-app
T="$(mktemp -d)"
chmod 755 "$T"
# A copy the service account can read: the checkout may sit under a home it
# cannot enter (a runner's /home/runner, say).
cp -a "$ED" "$T/easy-deploy"
chmod -R a+rX "$T/easy-deploy"
ED="$T/easy-deploy"
# A machine whose HTTPS goes through a proxy may keep the proxy's CA bundle
# where only root can read it; the service account gets a copy.
for var in PIP_CERT REQUESTS_CA_BUNDLE SSL_CERT_FILE PIP_CONFIG_FILE; do
    file="${!var:-}"
    [[ -n "$file" && -r "$file" ]] || continue
    install -m 0644 "$file" "$T/$var"
    export "$var=$T/$var"
done
free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
PORT="$(free_port)" SSH_PORT="$(free_port)"

FAKE=0
if [[ ! -d /run/systemd/system ]]; then
    FAKE=1
    install -m 0755 "$ED/tests/fixture/fake-systemctl" /usr/local/sbin/systemctl
    mkdir -p /run/systemd/system
fi

cleanup() {
    [[ -f "$T/sshd.pid" ]] && kill "$(cat "$T/sshd.pid")" 2>/dev/null
    systemctl stop "$NAME" 2>/dev/null
    systemctl disable "$NAME" 2>/dev/null
    rm -f "/etc/systemd/system/$NAME.service" "/etc/sudoers.d/$NAME-deploy"
    if (( FAKE )); then rm -f /usr/local/sbin/systemctl; rmdir /run/systemd/system 2>/dev/null; else systemctl daemon-reload; fi
    userdel -r "$SVC_USER" 2>/dev/null
    rm -rf "$PREFIX" "$T" /etc/edtest-app
}
trap cleanup EXIT

PASS=0 FAIL=0 OUT=""
ok()  { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '%s\n' "$OUT" | sed 's/^/        /'; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }

# A service account like the real one: a home, a shell, no password -- but not
# locked, or sshd refuses it even a key login.
useradd -m -s /bin/bash "$SVC_USER"
usermod -p '*' "$SVC_USER"
as() { runuser -u "$SVC_USER" -- env -u XDG_CONFIG_HOME HOME="/home/$SVC_USER" "$@"; }
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# origin, and the editable checkout install.sh runs from -- both the service
# account's, as on the real server.
install -d -o "$SVC_USER" -g "$SVC_USER" "$T/origin.git" "$T/work"
as git init --quiet --bare -b main "$T/origin.git"
as git -C "$T/work" init --quiet -b main
as git -C "$T/work" remote add origin "$T/origin.git"
install -o "$SVC_USER" -m 0644 "$ED/tests/fixture/app.py" "$T/work/app.py"
as bash -c "echo v1 > '$T/work/version.txt'; : > '$T/work/requirements.txt'"
push() { as git -C "$T/work" add -A && as git -C "$T/work" commit --quiet -m "$1" && as git -C "$T/work" push --quiet origin main; }

# Host keys before install.sh, which prints them: a fresh image may have none yet.
[[ -f /etc/ssh/ssh_host_ed25519_key ]] || ssh-keygen -A >/dev/null

printf '\n\033[1minit.sh, install.sh\033[0m\n'

OUT="$(cd "$T/work" && as "$ED/init.sh" --yes --name "$NAME" --stack python --port "$PORT" \
                       --user "$SVC_USER" --prefix "$PREFIX" --branch main 2>&1)"
check "init.sh sets the project up" test -f "$T/work/deploy/easy-deploy.conf"
as sed -i "s|^ExecStart=.*|ExecStart=$PREFIX/env/bin/python $PREFIX/app.py $PORT|" "$T/work/deploy/$NAME.service"
# A hook that needs a secret from ENV_FILE, the way Nebula's migrations do.
as tee -a "$T/work/deploy/easy-deploy.conf" > /dev/null <<'EOF'
ENV_FILE=/etc/edtest-app/edtest-app.env
before_restart() {
    echo "$GREETING $ED_PHASE" > data/before_restart
}
EOF
install -d -m 0750 -o root -g "$SVC_USER" /etc/edtest-app
echo "GREETING=hello" > /etc/edtest-app/edtest-app.env
chown "root:$SVC_USER" /etc/edtest-app/edtest-app.env
chmod 0640 /etc/edtest-app/edtest-app.env
push "v1"

OUT="$("$T/work/deploy/install.sh" --ci-key --host 127.0.0.1 2>&1)"; RC=$?
check "install.sh succeeds" test "$RC" = 0
check "  the deploy root belongs to the service account" test "$(stat -c %U "$PREFIX/.git")" = "$SVC_USER"
check "  and points at the real origin" test "$(git config --file "$PREFIX/.git/config" remote.origin.url)" = "$T/origin.git"
check "  installer.py built env/" test -x "$PREFIX/env/bin/python"
check "  the service is up" test "$(curl -s --max-time 3 "http://127.0.0.1:$PORT/")" = v1
check "  before_restart ran as the service account, with ENV_FILE loaded" \
    bash -c '[[ $(cat "$0") = "hello install" && $(stat -c %U "$0") = "$1" ]]' "$PREFIX/data/before_restart" "$SVC_USER"
check "  the sudoers file passes visudo" visudo -cqf "/etc/sudoers.d/$NAME-deploy"
check "  and allows exactly the restart" bash -c '[[ $(grep -c "" "$0") = 1 ]] && grep -q "NOPASSWD: .*systemctl restart $1$" "$0"' "/etc/sudoers.d/$NAME-deploy" "$NAME"
check "  the CI key has the forced command" grep -q "^command=\"$PREFIX/deploy/deploy.sh\",restrict ssh-ed25519 .* $NAME-github-actions$" "/home/$SVC_USER/.ssh/authorized_keys"
check "  the secrets were printed" grep -q "VPS_KNOWN_HOSTS" <<<"$OUT"
OUT="$("$T/work/deploy/install.sh" --ci-key --host 127.0.0.1 2>&1)"; RC=$?
check "re-running it (key rotation) succeeds" test "$RC" = 0
check "  and leaves one CI key, not two" test "$(grep -c "$NAME-github-actions" "/home/$SVC_USER/.ssh/authorized_keys")" = 1

# The runner's side: its own sshd, the printed host keys, the printed key.
mkdir -p /run/sshd
cat > "$T/sshd_config" <<EOF
Port $SSH_PORT
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile $T/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
/usr/sbin/sshd -f "$T/sshd_config"
# Printed as "127.0.0.1 KEY", or "[127.0.0.1]:PORT KEY" where sshd is not on 22;
# this sshd is on a port of its own either way.
grep -oE '(127\.0\.0\.1|\[127\.0\.0\.1\]:[0-9]+) ssh-ed25519 [A-Za-z0-9+/=]+' <<<"$OUT" | head -1 \
    | sed -E "s/^[^ ]+ /[127.0.0.1]:$SSH_PORT /" > "$T/known_hosts"
install -m 0600 "/home/$SVC_USER/$NAME-ci-key" "$T/key"
check "the printed host key is this server's own" grep -qF "$(cut -d' ' -f2 /etc/ssh/ssh_host_ed25519_key.pub)" "$T/known_hosts"
runner() {  # the exact ssh the reusable workflow runs; $1 is the command the client asks for
    OUT="$(ssh -i "$T/key" -p "$SSH_PORT" -o BatchMode=yes -o StrictHostKeyChecking=yes \
               -o UserKnownHostsFile="$T/known_hosts" -o ConnectTimeout=15 -o ServerAliveInterval=30 \
               "$SVC_USER@127.0.0.1" "$1" 2>&1)"
    RC=$?
}

printf '\n\033[1mdeploys through the forced command\033[0m\n'

as bash -c "echo v2 > '$T/work/version.txt'"; push "v2"
runner "cat /etc/shadow"
check "a session on the CI key deploys, whatever it asks for" bash -c '[[ $0 = 0 ]] && grep -q "Deployed" <<<"$1" && ! grep -q "^root:" <<<"$1"' "$RC" "$OUT"
check "  and the new commit is live" test "$(curl -s --max-time 3 "http://127.0.0.1:$PORT/")" = v2
check "  its hook saw ENV_FILE too" test "$(cat "$PREFIX/data/before_restart")" = "hello deploy"
runner deploy
check "  a second session has nothing to do" bash -c '[[ $0 = 0 ]] && grep -q "nothing to do" <<<"$1"' "$RC" "$OUT"

as touch "$T/work/broken"; as bash -c "echo v3 > '$T/work/version.txt'"; push "v3: does not start"
runner deploy
check "a commit that does not start fails the run and rolls back" \
    bash -c '[[ $0 = 1 ]] && grep -q "Rolled back" <<<"$1" && [[ $2 = v2 ]]' "$RC" "$OUT" "$(curl -s --max-time 3 "http://127.0.0.1:$PORT/")"
check "  with an annotation for the run" grep -q "::error title=Deploy rolled back::" <<<"$OUT"

as rm "$T/work/broken"; as bash -c "echo 'definitely-not-a-real-package-easy-deploy==9.9' > '$T/work/requirements.txt'; echo v4 > '$T/work/version.txt'"
push "v4: a requirement that cannot install"
runner deploy
check "a requirement that cannot install rolls back too" \
    bash -c '[[ $0 = 1 ]] && [[ $1 = v2 ]]' "$RC" "$(curl -s --max-time 3 "http://127.0.0.1:$PORT/")"

as bash -c ": > '$T/work/requirements.txt'; echo v5 > '$T/work/version.txt'"
echo "# drift" | as tee -a "$T/work/deploy/$NAME.service" >/dev/null
push "v5: unit changed"
runner deploy
check "unit drift is reported to the run as a warning" \
    bash -c '[[ $0 = 0 ]] && grep -q "::warning title=Server config drift::" <<<"$1"' "$RC" "$OUT"
"$PREFIX/deploy/install.sh" > /dev/null 2>&1
runner deploy
check "  and install.sh clears it" bash -c '[[ $0 = 0 ]] && ! grep -q "differs" <<<"$1"' "$RC" "$OUT"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
