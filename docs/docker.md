# Docker workflow

The `make` targets in the root `Makefile` are thin wrappers around the commands below. Everything
runs MariaDB **13.0.2** (official image, pinned by digest in `docker/mariadb/Dockerfile`) with
`campus_audit` compiled against that image's own server headers.

> **Status (2026-11-03):** a team member ran `make up`, `make demo` and `make test` on the earlier
> version: both images built and the containers started, but every login failed (below, "What went
> wrong on the first Docker run"). The fixed version then ran in CI on GitHub's `ubuntu-24.04`
> runners (Docker Engine): `make up`, `make doctor`, `make demo`, `make test`, `make examples`,
> `make test-browser`, a server restart and the regression test for that failure all passed
> (`docs/evidence/linux-ci-2026-11-03/`). Those runs also found two plugin bugs that only Linux shows,
> fixed in plugin 1.1.1 (experiments 18 and 19). Windows Docker Desktop was manually validated on
> 2026-11-09; macOS remains unverified. See the [dated Windows validation summary](evidence/windows-docker-desktop-2026-11-09/README.md).

## Start

```bash
make up
```

which does:

```bash
bash scripts/make_env.sh                                  # only if .env is missing: random secrets, mode 600
docker compose up -d --build --wait mariadb               # build (unit tests run inside the build), start the server
# as root, with the password from .env:
bash scripts/post_start.sh                                # migrations for older volumes, app account, INSTALL SONAME
docker compose up -d --build --wait web                   # healthy only if the app can log in to MariaDB
bash scripts/bootstrap_admin.sh                            # one-time admin; private file, no password on screen
```

The build stage installs `libmariadbd-dev` and `libmariadb-dev` in the exact version of the server
image, runs the plugin unit tests and compiles `campus_audit.so` (and the `campus_change_user` test
helper); if a test fails, the image is not built. An **empty** data volume is initialised from
`database/` (schema, migrations, triggers, fictional seed data, application account).

The catalogue of the official booking pages (Vacuum, Study Room, …) is **not** part of that
initialisation: it is inserted by `frontend/seed.py`, which neither `make up` nor
`frantastic.cmd up` runs. After the first start on an empty volume, and again after `make reset`,
load it once as described in the README, "Load the Booking Catalogue" (`DB_ADMIN_USER` and
`MYSQL_PWD` of a maintenance account, never `campus_app`).

### Database installation order

`scripts/setup_database.sh` and the image's `/docker-entrypoint-initdb.d/` file names apply the
database files in the same, explicit order (`scripts/check_repo.py` and
`tests/shell/test_database_setup.sh` check that the two agree):

| Step | Fresh volume (initdb name) | Upgrade (`post_start.sh`, `make migrate`: `SKIP_SEED=1`) |
|---|---|---|
| 1 | `database/schema.sql` (`10-schema.sql`) | applied (`CREATE ... IF NOT EXISTS`, existing tables kept) |
| 2 | migrations 001, 002, 003 (`20-`, `21-`, `22-migration-00N.sql`) | applied |
| 3 | `database/triggers.sql` (`30-triggers.sql`) | applied |
| 4 | `database/seed.sql` (`40-seed.sql`) | **skipped** |
| 5 | migrations 004, 005, 006 (`50-`, `51-`, `52-migration-00N.sql`) | applied |
| 6 | application account `campus_app` (`60-app-account.sh`) | refreshed when `CAMPUS_APP_PASSWORD` is set |

Migrations 004 and 005 run **after** the seed on purpose. On a fresh database the team's
`database/seed.sql` inserts `dana.admin@example.edu` as an administrator, and migration 004 then
demotes that published demo identity. The seed sets a role only when it inserts a row (its
`ON DUPLICATE KEY UPDATE` changes `full_name` only), so a later seed run can neither promote Dana
again nor demote a locally assigned administrator. Migration 005 creates the one-time local administrator gate and opens it only when no administrator
exists, so it must see the state after 004. `database/triggers.sql` runs before the seed, so the seed
rows and the demotion appear in `audit_events`. A new migration has to be added to the lists in
`scripts/setup_database.sh` and to the Dockerfile; the script refuses to run while a file in
`database/migrations/` is missing from its lists.

Migration 006 adds `cancelled` to `loans.status` (default still `active`, no row changed; the
existing `chk_loans_status_returned_consistent` already requires `returned_at IS NULL` for it). The
application account has no DELETE on `loans`, so a future loan is to be cancelled with
`UPDATE loans SET status = 'cancelled'`, which the loans trigger records; the web app still deletes
the row and is changed to the status update in a later integration stage.

| Service | Address (127.0.0.1 only) | Change with |
|---|---|---|
| MariaDB | `127.0.0.1:3307` | `MARIADB_PORT` in `.env` |
| Web app | <http://127.0.0.1:5080> (guided tour: `/lab`) | `WEB_PORT` in `.env` |

## Use

```bash
make demo          # = MYSQL_PWD=<root password> MARIADB_CLIENT="docker compose exec -T -e MYSQL_PWD mariadb mariadb" bash scripts/demo.sh
make doctor        # read-only diagnosis; says what to do for every failure
make sql           # interactive SQL shell as root
make logs          # last records of the plugin's JSON Lines file
```

## Test

```bash
make test          # shared runtime runner: plugin unit/repository/plugin E2E/DB/app suites; needs make up first
make browser-setup # optional, once: isolated Playwright environment + Chromium
make test-browser  # Audit Lab in a real browser; bootstraps browser-setup automatically if needed
```

The browser tests run on the host against the Docker web app. Their dependencies are isolated in
`.venv-browser/`; the first `make test-browser` creates that environment and installs the pinned
Playwright package and Chromium. On Linux, Playwright also installs the required system libraries (and
may request `sudo`). `python3-venv` is required to create the environment. The environment is excluded
from Git and the Docker build context.

The end-to-end script installs, reconfigures and uninstalls the plugin and temporarily switches its
log file: run it only against this disposable Compose database.

## What went wrong on the first Docker run, and what changed

Reported after `make up` → `make demo` → `make test`, with healthy containers:

```text
ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: YES)   (make demo, make test-e2e)
Internal Server Error                                                                  (registering, logging in)
```

**Cause.** `make up` had just created a new `.env` with new random passwords, but a database volume
from an earlier run already existed. The MariaDB image applies `MARIADB_ROOT_PASSWORD`, and runs
`docker/mariadb/initdb/` (which creates `campus_app`), **only when it initialises an empty volume**.
Because `compose.yaml` fixes the project name (`campus-audit`), even a fresh clone in another
directory reuses the volume `campus-audit_mariadb-data`. Root and `campus_app` therefore still had
the old passwords:

- `make demo` / `make test` log in as root with the new password → ERROR 1045;
- the web app logs in as `campus_app` with the new password → PyMySQL raises
  `OperationalError (1045)`, which the app did not handle → HTTP 500;
- the containers still looked healthy: the MariaDB healthcheck logs in with its own account stored
  in the volume, and the web service had no healthcheck at all (`docker compose up --wait` reports a
  running container without a healthcheck as healthy).

We could not inspect that machine's volume. We reproduced every symptom on a native 13.0.2 server
by starting the old code with passwords that differ from the stored ones (experiment 17,
`docs/evidence/windows-2026-11-03/01-reproduction-root-1045.txt` and `02-reproduction-flask-500.txt`), and with the correct passwords the same code
passes its demo and tests (`03-baseline-original-code.txt`).

**Changes.**

| Change | Effect |
|---|---|
| `scripts/make_env.sh` warns when it creates a `.env` while the database volume already exists | the mismatch is announced before anything fails |
| `make up` runs `scripts/post_start.sh` as root before starting the web app | a wrong root password stops `make up` with an explanation instead of later 1045s; older volumes get the new migrations; `campus_app` is (re)created with the password from `.env` |
| web service healthcheck on `/healthz` (logs in as `campus_app`, reads `users`) | `up --wait` fails when the app cannot use the database, instead of serving HTTP 500 |
| the app catches connection errors | a 503 page that explains ER 1045 / 2003 / 1049 (never shows a password); the traceback stays in `docker compose logs web` |
| `make doctor` | read-only check of `.env`, volume age, both logins, the plugin and the lab objects |
| `make repair-credentials` | sets the stored passwords to `.env` **without deleting data** (one-off server with `--skip-grant-tables --skip-networking`, `ALTER USER ... IDENTIFIED BY PASSWORD '<hash>'`), then `make up` |

## Stop, clean up, start over

```bash
make down                 # = docker compose down       stop; database and audit logs are kept
make repair-credentials   # .env and the volume disagree on passwords; keeps all data
make reset-admin          # explicitly rotate the local administrator credential
make migrate              # apply new migrations to an existing volume; keeps all data (make up does this too)
make reset                # = docker compose down -v    DELETES the database and audit-log volumes
```

`make reset` is the only command here that deletes data. For an independent second copy (for
example to test a clean checkout without touching your data), set `COMPOSE_PROJECT_NAME` in that
checkout's `.env`: it gets its own containers and volumes.

## Windows Docker Desktop

For the newcomer/demo path, install and start Docker Desktop for Windows once. Open PowerShell in the
project directory and run:

```powershell
.\frantastic.cmd up
.\frantastic.cmd demo
.\frantastic.cmd test
.\frantastic.cmd down
```

If `.admin-credentials` is lost, run `frantastic.cmd reset-admin` to explicitly rotate the canonical local administrator. A fresh database with an old credential file reuses that unique password; ordinary startup never rotates an existing administrator.

The launcher needs Docker Desktop with Docker Compose V2 and an available Docker daemon. On the
default WSL 2 backend, Docker documents Windows 10/11 servicing versions, the WSL 2 feature (version
2.1.5 or later), virtualization support and at least 8 GB RAM. Docker Desktop also supports other
backends on supported editions. Docker manages its Linux VM; this project does not require installing
or managing a separate Ubuntu distribution. See [Docker Desktop's current Windows requirements](https://docs.docker.com/desktop/setup/install/windows-install/)
and [WSL 2 backend requirements](https://docs.docker.com/desktop/features/wsl/).

`up` creates `.env` only if it is absent, starts MariaDB and the web service, applies idempotent
migrations, then reconciles the local credential against the database's one-time bootstrap state. A
valid stale credential file is reused for a genuinely fresh database; an existing administrator is
never silently rotated or replaced. New credentials are staged before database changes and verified
before the final file is atomically replaced. Existing `.env` and credential files are preserved
unless the explicit rotation command is used. Windows uses `SetNamedSecurityInfoW` with only the
DACL and protected-DACL flags. It disables inheritance and verifies exactly three explicit FullControl
entries by SID: the current user, SYSTEM (`S-1-5-18`) and built-in Administrators (`S-1-5-32-544`).
It does not request or modify SACL, owner or group data. A normal, non-elevated user can protect files
they own; ACL failures abort sensitive operations and preserve an existing destination. Do not run
the launcher as Administrator to work around an ACL failure. Keep the file and check that it is a
regular file owned by the current user and that the user can change its DACL.
`down` stops project containers and keeps volumes. `test` first runs the Windows PowerShell 5.1
launcher tests (`tests/windows/`, including an end-to-end run of the launcher with a fake Docker), then the same runtime test suites as Linux `make test` in the
test-runner container (plugin unit tests, repository checks, administrator credential/diagnostic
script tests, plugin E2E, database and application/Audit Lab tests); the suites execute at command
time, not only at image build time. The host does not need GNU make, Python, a compiler, or a local
database. Native Windows plugin development remains the separate `plugin/build_windows.ps1` + MariaDB
headers + Zig workflow.

### How the launcher handles credentials and Docker Desktop

- **One source for the secrets: `.env`.** Docker Compose reads `.env` and gives the mariadb service
  `MARIADB_ROOT_PASSWORD` and `CAMPUS_APP_PASSWORD`. The scripts the launcher runs *inside* that
  container (`scripts/post_start.sh`, `scripts/demo.sh`, `scripts/provision_local_admin_db.sh`) take
  the root password from there (`scripts/mariadb_admin_auth.sh`); the launcher does not forward a
  database password from Windows. Compose would prefer a variable of the same name from the
  PowerShell session (or the user/system environment) over `.env`; the launcher removes
  `MARIADB_ROOT_PASSWORD`, `CAMPUS_APP_PASSWORD` and `SECRET_KEY` from its own process before calling
  Docker and says so (`Ignoring ... from the environment`), as the Makefile does with `unexport`.
- **`.env` is checked before anything starts**, following Compose's documented `.env` syntax: `=` or
  `:` between name and value, spaces around a value ignored, quotes optional; an unquoted value ends at
  a `#` that follows whitespace (`VAL # comment`, but `VAL#x` is a value); a quoted value keeps `#` and
  spaces and may be followed by a comment (`"VAL" # comment`). A missing file, a missing, empty or
  whitespace-only secret, a duplicate definition, an unclosed quote, text after a closing quote, or
  `export MARIADB_ROOT_PASSWORD=...` stops the launcher with the line number; values are never shown
  and never changed. Compose substitutes variable references (`${NAME}`, `$NAME`) in unquoted and
  double-quoted values, and an unset one becomes empty; the launcher does not evaluate them, so a `$`
  in an unquoted or double-quoted secret is rejected. Use single quotes for a literal `$`
  (`MARIADB_ROOT_PASSWORD='pa$$word'`). Multi-line values are not supported for the secrets.
- **Docker Desktop that is still starting** is waited for, up to 120 seconds, with a one-line
  message; each `docker info` probe is limited to 15 seconds (never more than the time left), so a
  hanging probe cannot extend the wait. If Docker is in Windows-containers mode, the account may not
  use the engine, the active context or `DOCKER_HOST` selects an engine that Docker Desktop does not
  provide, or the context is Docker Desktop's but no Docker Desktop process runs, the launcher stops
  at once and says which of these it found. It never starts or restarts Docker Desktop itself.

### Windows troubleshooting

| Message | Meaning and what to do |
|---|---|
| `no Docker Desktop process is running` / `did not respond within 120 seconds` | start Docker Desktop and wait for "Engine running" (restart it if it stays in "starting"), then rerun the command |
| `selected by the DOCKER_HOST environment variable is not reachable` / `active context '...' is not reachable` | Docker is set up to use another engine than Docker Desktop's: start that engine, or remove `DOCKER_HOST` (`Remove-Item Env:DOCKER_HOST`) / switch back with `docker context use desktop-linux` |
| `Docker Desktop is using Windows containers` | Docker Desktop tray icon → *Switch to Linux containers…* |
| `.env line N: unsupported syntax` / `is empty or contains only whitespace` / `does not define` / `not closed` / `unexpected text after the closing quote` / `contains '$'` | correct that line (for example `NAME=value`, `NAME="value" # comment`, or `NAME='value with $'` for a literal `$`), or put back the `.env` you used before; a new `.env` against an existing database volume is the case in the next row |
| `ERROR 1045 ... (using password: YES)`, "rejects the root password" | the database volume was initialised with the passwords of an earlier `.env` (or `.env` was edited later). **Keep the data:** put the earlier `.env` back. `make repair-credentials` (Linux/macOS with GNU make) can set the stored passwords to the new `.env`; the launcher has no equivalent. **Only if the data is disposable:** `docker compose down --volumes` in the project folder, then `.\frantastic.cmd up` — this deletes the database and audit logs of this project (`COMPOSE_PROJECT_NAME`). If unsure, keep the volume and ask for help |
| `ERROR 1045 ... (using password: NO)` | the client received no password; this is not a volume problem, and deleting volumes will not fix it. Check that `.env` defines `MARIADB_ROOT_PASSWORD` and that the mariadb container has it: `docker compose exec -T mariadb sh -c 'case ${MARIADB_ROOT_PASSWORD:+set} in set) echo present;; *) echo missing;; esac'` (prints only `present`/`missing`) |
| `could not connect to the MariaDB server` | not a password problem: `docker compose ps`, `docker compose logs mariadb` |
| `Ignoring MARIADB_ROOT_PASSWORD from the environment` | informational: a variable of that name exists in your session or user environment; `.env` is used. Remove it with `Remove-Item Env:MARIADB_ROOT_PASSWORD` (session) or in the Windows environment-variable settings (user) |

`make doctor` and `make repair-credentials` need bash and GNU make (Linux/macOS); they are not
part of the Windows launcher.

On 2026-11-09, the project owner manually exercised this workflow on Windows 11 Pro build
`26100.6899`, Windows PowerShell 5.1, Docker Desktop `4.99.0.245822` with its WSL2 backend and
Linux-container mode, using MariaDB `13.0.2`. The final source ZIP was extracted into a fresh path
containing spaces. `frantastic.cmd up` built both images; MariaDB and web became healthy, migrations
001–005 completed, `campus_app` was provisioned, `campus_audit` was `ACTIVE`, and local administrator
provisioning and verification completed with credentials saved locally without display. With
`MARIADB_PORT=13317` and `WEB_PORT=15081`, Compose published `127.0.0.1:15081` and the launcher printed
`http://127.0.0.1:15081/lab`. `frantastic.cmd demo` also succeeded. This was manual Windows Docker
Desktop validation, not a Windows CI run; it exercises Linux containers from Windows and does not
establish native Windows plugin-development support. See the [dated evidence summary](evidence/windows-docker-desktop-2026-11-09/README.md).

The tested host required a local Docker Desktop WSL bootstrap checksum workaround: the installed
`docker-wsl-cli.iso` digest differed from its `.sha256` sidecar. The original sidecar was preserved
in a timestamped backup, and the local sidecar was changed to match the observed ISO digest. Docker
Desktop then started. The Docker Desktop executable and downloaded installer had valid Authenticode
signatures from Docker Inc.; the ISO itself was not independently authenticated. This was specific
to that host, is not normal installation guidance, and is not required by FRANtastic.

The owner also reported eight passing Windows ACL checks, ten passing launcher URL regression checks
(all ten also passed against the freshly extracted ZIP), and a passing five-suite `frantastic.cmd test`
run. This manual validation is distinct from Windows CI and native Windows plugin-development tests.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `ERROR 1045 ... 'root'@'localhost' (using password: YES)`, `make up` stops after "rejects the root password" | the volume keeps the passwords of an earlier `.env`: `make repair-credentials` (keeps data), or put the old `.env` back, or `make reset && make up` (deletes data). Windows: see [Windows troubleshooting](#windows-troubleshooting) |
| `ERROR 1045 ... (using password: NO)` | no password reached the client — not a volume problem: check that `.env` defines `MARIADB_ROOT_PASSWORD` and that a custom `MARIADB_CLIENT` forwards `-e MYSQL_PWD`; `make doctor` |
| `MYSQL_PWD and MARIADB_ROOT_PASSWORD are both set but differ` | a stale value is exported in the shell, or the containers were created from another `.env`: unset it (or `make up` to re-create the containers), then retry |
| Web page "The web app cannot reach its database", MariaDB error 1045 | same cause, for `campus_app` only: `make up` re-creates the account from `.env`; `make doctor` tells which account fails |
| `port is already allocated` / `address already in use` | another service uses 3307 or 5080 (on macOS 12+ port 5000 belongs to the AirPlay receiver, hence 5080): set `MARIADB_PORT` / `WEB_PORT` in `.env` |
| `set MARIADB_ROOT_PASSWORD in .env` | `.env` is missing: `bash scripts/make_env.sh` |
| Build fails at `apt-get install libmariadbd-dev=...` | the apt repository of the pinned image no longer serves that version: pick the current 13.0.x image and its digest in `docker/mariadb/Dockerfile` (`ARG MARIADB_IMAGE`) |
| `ERROR 1126 ... prohibited by --plugin-maturity=gamma` | the container's `campus_audit.cnf` must set `plugin_maturity=beta`; check that `docker/mariadb/campus_audit.cnf` is copied into the image |
| `bash\r: command not found`, or values in `.env` ending in `\r` | files checked out with CRLF line endings; `.gitattributes` forces LF for scripts and `.env.example`, re-checkout; `make doctor` detects CRLF in `.env` |
| Changes to `database/*.sql` have no effect | initialisation runs only on an empty volume: `make migrate` (keeps data) |
| Windows reports a `SeSecurityPrivilege` error while protecting a sensitive file | use the current `scripts/windows_security.ps1` and run `tests/windows/test_local_file_acl.ps1` in Windows PowerShell 5.1 from a non-elevated session. The helper requests DACL information only. Preserve existing credential files, check that the file is regular and owned by the current user, and record the full error for diagnosis. Do not enable `SeSecurityPrivilege` or start the launcher elevated. |
