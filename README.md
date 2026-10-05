# easy-deploy

Push to `main`, and the server deploys it: health-checked, and rolled back if
it doesn't come up. This is the deploy sequence Nebula, mcbot, ai4rc-homepage
and Remote Manager each carried a hand-maintained copy of, pulled into one
place. Nebula's behaviour is the reference; `installer.py` owns the Python
environment.

- **GitHub side**: one reusable workflow. A project calls it after its own
  checks; there is nothing to copy.
- **Server side**: `deploy/deploy.sh` and `deploy/install.sh`, copied into
  each project by `init.sh` and never edited there. Everything specific to a
  project lives in `deploy/easy-deploy.conf`.

The engine is copied into each project, not installed once on the server, on
purpose. An engine upgrade then lands through each project's own CI and
deploy, and rolls back with it. One bad upgrade on the server can't break
every project's deploy at once.

## Set up a project

On your machine, from the project's checkout:

```bash
git clone https://github.com/BL4z3es/easy-deploy ~/easy-deploy
~/easy-deploy/init.sh
```

It asks for a name, the stack (python, node or none, detected), the port, an
optional public domain, the server account and the deploy root. It writes:

| File | |
|---|---|
| `deploy/deploy.sh`, `deploy/install.sh`, `installer.py` | the engine: managed, never edit |
| `deploy/easy-deploy.conf` | settings and hooks: yours |
| `deploy/NAME.service` | the systemd unit: yours. **Check its `ExecStart`.** |
| `deploy/NAME.caddy` | a Caddy fragment, if you gave a domain: yours |
| `.github/workflows/deploy.yml` | checks, then the shared deploy job: yours |

Commit and push. Then on the server, from any checkout of the project:

```bash
sudo deploy/install.sh --ci-key
```

That builds the deploy root, starts the service and checks its health. It
also installs the sudoers line and the Caddy site, creates the project's CI
key, and prints the four secrets to set on the repository:

| Secret | |
|---|---|
| `VPS_HOST` | the server's address |
| `VPS_USER` | `SERVICE_USER` |
| `VPS_KNOWN_HOSTS` | the server's host keys, read from the server itself |
| `VPS_SSH_KEY` | the CI key's private half (then delete it from the server) |

From then on every push to the branch deploys.

## What a push does

`.github/workflows/deploy.yml` runs the project's checks, then calls the
shared job:

```yaml
deploy:
  needs: check
  uses: BL4z3es/easy-deploy/.github/workflows/deploy.yml@v1
  secrets: inherit
  # with: { timeout-minutes: 20, ssh-port: 22 }
```

That job opens one SSH session with the CI key, and does nothing else. The key
carries a forced command in `authorized_keys`:

```
command="/srv/NAME/deploy/deploy.sh",restrict ssh-ed25519 AAAA... NAME-github-actions
```

so the session runs `deploy.sh`, whatever the client asked for. On the server,
`deploy.sh` then:

1. **fetches `origin/BRANCH`**. If the checkout is already there and the last
   deploy of it finished, there's nothing to do.
2. **`git reset --hard`** to it, not a pull. The deploy root mirrors origin, and
   a merge conflict there would wedge every later deploy. Gitignored paths
   (`env/`, `node_modules/`, `data/`, `.env`) are untouched.
3. **loads this commit's `easy-deploy.conf`**, so its hooks deploy (and roll
   back) with its code, then reads `ENV_FILE`.
4. **installs dependencies only if their manifest moved** since they were last
   installed: `installer.py` for python, `npm ci` for node, or your
   `install_deps` hook.
5. runs **`before_restart`**, **restarts** every unit in `SERVICES`, then runs
   **`after_restart`**.
6. **polls the health check**: every unit active, every URL in `HEALTH_URLS`
   answering 200, then the `health_check` hook.
7. on any failure, **does 2–6 again for the previous commit**. It exits 1 either
   way, because what is live is not what was pushed, and annotates the run.
8. **reports drift**: units or the Caddy fragment in `deploy/` that differ from
   what's installed in `/etc`. That's a warning on the run, never applied.

Durability details, each one a failure that happened, or nearly happened, in
one of the hand-maintained copies:

- **Hooks run in their own `bash -euo pipefail`.** Inside `if apply ...`, bash
  turns off `set -e` for every function it calls, so a failed migration would
  otherwise fall through to a restart.
- **The reset and the restart are made safe to interrupt.** A runner that goes
  away (timeout, cancelled job) no longer stops a deploy halfway: hangups are
  ignored and output goes on to `.easy-deploy/deploy.log`. And if a deploy
  dies anyway, the next run sees that the checkout moved without finishing,
  and finishes it.
- **The rollback reinstalls the old dependencies.** Each install is recorded
  per commit, so the rollback pass diffs against what is actually installed,
  not against the commit it is returning to.
- **One deploy at a time from any trigger.** GitHub's concurrency group covers
  CI runs; a lock on the server also covers a deploy started by hand.
- **It refuses to run from anywhere but the deploy root**, so it can't
  `reset --hard` an editable checkout. It also refuses to run as anyone but the
  checkout's owner, so files can't end up root-owned.

## Security model

- **One key per project, with a forced command and `restrict`.** No pty, no
  forwarding, no other command. A leaked `VPS_SSH_KEY` triggers that project's
  deploy and nothing else. Keys are never shared between projects.
- **One sudoers line per unit**: `SERVICE_USER ALL=(root) NOPASSWD:
  /usr/bin/systemctl restart NAME`. That is all a deploy can do as root.
- **Drift is reported, never applied.** Writing `/etc` unattended would need a
  sudoers line for `install` or `cp`, which amounts to root, and then a
  leaked CI key would be root. Re-run `sudo deploy/install.sh` to apply.
- **The host key is pinned.** `StrictHostKeyChecking=yes` against
  `VPS_KNOWN_HOSTS`, which `install.sh --ci-key` reads from the server's own
  host keys rather than from a scan over the network.
- **Secrets are read, never sourced.** `ENV_FILE` is parsed as `NAME=VALUE`
  lines only. A malformed line is skipped and reported by line number, never
  executed or echoed into the CI log.

## Configuration: `deploy/easy-deploy.conf`

Plain bash, sourced: assignments and hook functions only.
`deploy/deploy.sh --print-config` shows what it resolves to.

| Setting | Default | |
|---|---|---|
| `NAME` | (required) | the unit, sudoers file and Caddy fragment are named after it |
| `SERVICE_USER` | (required) | owns `PREFIX`, runs deploys; never root |
| `PREFIX` | `/srv/NAME` | the deploy root |
| `BRANCH` | `main` | |
| `STACK` | `none` | `python`, `node` or `none` |
| `DEPS_FILES` | by stack | the manifests whose change triggers an install |
| `PYTHON` | `python3` | the interpreter `installer.py` builds `env/` with |
| `PY_CHECK` | found | `installer.py`'s validation step, as arguments for `env/`'s python; `none` for none |
| `SERVICES` | `NAME` | units restarted and health-checked |
| `OPTIONAL_SERVICES` | | restarted when enabled; a failure only warns |
| `PORT` | | the loopback port; gives the default `HEALTH_URLS` |
| `SITE` | | the public name `deploy/NAME.caddy` serves |
| `WRITABLE_DIRS` | | created by `install.sh`, owned by `SERVICE_USER` |
| `ENV_FILE` | | read before hooks run; a leading `-` makes it optional |
| `HEALTH_URLS` | `http://127.0.0.1:PORT/` | all must answer `HEALTH_STATUS` |
| `HEALTH_HOST` | | sent as the Host header |
| `HEALTH_STATUS` | `200` | |
| `HEALTH_TRIES` | `15` | seconds; with no URLs, units must stay active 5 in a row |
| `EXTRA_PATH` | | prepended to the bare `PATH` a forced command gets |
| `STATE_DIR` | `PREFIX/.easy-deploy` | deploy log, lock, what's deployed |
| `LOCK_WAIT` | `300` | seconds to wait for another deploy |

`NAME`, `PREFIX`, `BRANCH`, `SERVICE_USER` and `STATE_DIR` are read once, from
the checkout already on the server. Changing one is an install, not a deploy.

**Hooks** each run from the deploy root in their own `bash -euo pipefail`,
with `$REPO $PREFIX $NAME $PY $VENV $ED_REF $ED_PHASE`, the `ENV_FILE`
variables, `log` and `warn`:

| Hook | When | As |
|---|---|---|
| `before_restart` | after dependencies, before the restart (deploy, rollback, install) | `SERVICE_USER` |
| `after_restart` | after the restart, before the health check | `SERVICE_USER` |
| `health_check` | once the URLs answer; fail it to roll back | `SERVICE_USER` |
| `install_deps` | replaces the stack's own dependency step | `SERVICE_USER` |
| `on_install` | `install.sh` only, before the units start (has `asuser`) | root |

## Python: `installer.py`

`installer.py` owns the Python environment, the same way on a workstation, in
CI and on the server. It builds `env/` next to itself, writes `VIRTUAL_ENV`,
`ACTIVATE_SCRIPT` and `PYTHON_EXECUTABLE` to `.env`, and installs
`python-dotenv` and `requirements.txt`, retrying a package that fails to
build. Then it runs the project's validation step.

It is your `installer.py`, with five changes:

1. **The validation step is a setting**, not a copy-paste edit. That was the
   only difference between the copies. Without one it finds `manage.py`
   (`manage.py check`) or imports `main.py`. Importing rather than running it
   means a server's entry point can't hang the installer, and the step times
   out after 300s anyway.
2. **`--non-interactive`** (used by deploys, `install.sh` and CI) never
   prompts, and **never installs a guessed package name**. A missing module
   fails the run with the name to add to `requirements.txt`. On a server, no
   one can confirm that `import jwt` meant PyJWT and not the unrelated `jwt`
   on PyPI.
3. **`.env` keys are replaced, not appended.** The old one added three lines
   on every run.
4. **`python-dotenv` is checked in `env/`**, where the project imports it from,
   not in the interpreter running the installer.
5. **Failures exit non-zero.** The old one printed "Setup finished
   successfully" whatever happened, and a deploy has to know. It also no
   longer loops forever on a module that's still missing after install.

## Moving an existing project over

`examples/` maps four of them, setting by setting: `nebula.conf`,
`mcbot.conf`, `ai4rc-homepage.conf` and `rm.conf`, each with the changes
needed in that repository. For each project:

1. `~/easy-deploy/init.sh --force` in its checkout. `--force` replaces the old
   `deploy.sh`, `install.sh` and `installer.py`; git keeps the old ones.
   Existing units, Caddy fragments and workflows are kept.
2. Replace `deploy/easy-deploy.conf` with the example and read it against the
   old `deploy.sh` once.
3. In `.github/workflows/deploy.yml`, keep the `check` job and replace the
   `deploy` job with the shared one (`init.sh` prints the snippet).
4. Push. The push that lands this is deployed by the *old* `deploy.sh`, and
   every deploy after it runs the new one. The forced command path
   (`/srv/NAME/deploy/deploy.sh`) and the secrets don't change.
5. On the server, `sudo /srv/NAME/deploy/install.sh` once, to bring
   `/etc` in line.

**Not everything should use this.** claude-tasks drains running jobs before a
restart, only fast-forwards because people work in its checkout, and updates
itself from timers. That's a different deploy model, and forcing it into this
one would lose what makes it work. Nmail has no CI deploy at all.

## Operating

- **Deploy by hand**: Actions → *Run workflow*, or `/srv/NAME/deploy/deploy.sh` as `SERVICE_USER`.
- **What happened**: `/srv/NAME/.easy-deploy/deploy.log` (and `deploy.log.1`).
- **Rotate the CI key**: `sudo deploy/install.sh --ci-key` replaces it, then update `VPS_SSH_KEY`.
- **Apply drift**: `sudo /srv/NAME/deploy/install.sh`.
- **Upgrade the engine in a project**: `~/easy-deploy/init.sh --update`, review, commit, push.
- **Pin the workflow**: tag a release here (`v1`) and point `uses:` at it, so
  a change to this repository's `main` never reaches a deploy unannounced.

## Testing

```bash
tests/run.sh                                  # init.sh, deploy.sh, installer.py, end to end; no root
sudo EASY_DEPLOY_SYSTEM_TEST=1 tests/system.sh # install.sh for real, then deploys over SSH
```

`tests/run.sh` deploys a throwaway project from a local origin with a stub
`systemctl`. It covers deploy, no-op, rollback on a failed start, on a failed
hook, a failed `health_check` and a broken config, dependency reinstalls on
rollback, finishing an interrupted deploy, drift, the lock, and a hangup
mid-deploy.

`tests/system.sh` changes the machine it runs on, so use a disposable one. It
runs `install.sh --ci-key` for real (sudoers checked by `visudo`), then
deploys through the CI key's forced command over a real SSH connection. CI
runs both on every push, the second on a GitHub runner with real systemd.
