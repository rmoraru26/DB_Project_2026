A project for area 11, "Write a server plugin" for the [MariaDB student database projects, 2026-09](https://mariadb.org/bachelor_hackathon_2026-09/).

# Smart Campus — University Resource Management

A university database project for managing room reservations, equipment loans, and database activity monitoring.

Developed by a team of four students for the Databases course at Constructor University.

**Status:** In development. Database scripts and audit-support modules are currently maintained on separate branches.

## Overview

The project aims to provide a central system where students can reserve campus rooms and borrow equipment, while administrators manage resources and review activity.

MariaDB is the database used by the project. A custom audit plugin is planned to support database monitoring.

## Repository Branches

| Branch | Contents |
|---|---|
| `main` | Initial project structure and README |
| `website` | Website to navigate bookings, loans, cancellations, and returns |
| `database-schema` | Initial database schema and demonstration data |
| `error-handling` | C++ audit-support modules, tests, and technical documentation |

The components described below are not yet integrated into a complete application.

## Database Schema

The `database-schema` branch contains six tables:

| Table | Purpose |
|---|---|
| `users` | Student and administrator records |
| `rooms` | Bookable rooms, locations, capacities, and status |
| `items` | Individual equipment items and asset tags |
| `bookings` | Room reservations and their time intervals |
| `loans` | Equipment borrowing and return records |
| `audit_events` | Proposed storage for change-history records |

The schema includes:

- Primary and foreign keys
- Unique email addresses and equipment asset tags
- Validation of room capacities and reservation times
- Loan timestamp and return-status checks
- Indexes supporting reservation, loan, and audit queries
- JSON validation for proposed audit change data

The `audit_events` table is a proposed interface. Automatic population through a plugin has not yet been implemented.

## Sample Data

`database/seed.sql` provides fictional demonstration records, including:

- Students and an administrator (the shared demo administrator is demoted to student by
  migration 004 during setup; see "Set Up the Database")
- Campus rooms
- Equipment items
- A room reservation
- A returned equipment loan

The rooms and items offered by the website's booking pages are a separate catalogue, loaded by
`frontend/seed.py`; see "Load the Booking Catalogue".

## Audit Error Handling

The `error-handling` branch contains supporting C++ modules for:

- Representing operation results and error categories
- Checking audit-log output paths
- Detecting file-opening failures
- Reporting errors through a separate reporting component

Tests cover file-path validation and error-reporting behavior.

These modules currently run independently of MariaDB. They do not yet constitute a loadable audit plugin.

## Technology Stack

- **Database:** MariaDB
- **Audit-support modules:** C++11
- **Planned application layer:** Python
- **Version control:** Git and GitHub
- **Development environment:** Windows and Visual Studio Code
- **Locally verified MariaDB version:** 13.0.2

## Getting Started

### Clone the Repository

```bash
git clone https://github.com/rmoraru26/DB_Project_2026.git
cd DB_Project_2026
```

### Set Up the Database

The integrated project needs more than `schema.sql` and `seed.sql`. The migrations and triggers
create the row history (`audit_events` triggers), the `campus_audit` schema for the server plugin's
records, the Audit Lab objects, the local administrator bootstrap and the `cancelled` loan status;
the application account `campus_app` is what the web app logs in with. Loading only the schema and
the seed leaves out all of these.

The files must be applied in this order:

1. `database/schema.sql`
2. migrations 001–003 in `database/migrations/`
3. `database/triggers.sql`
4. `database/seed.sql` (fictional demonstration data; skip it for an existing database)
5. migrations 004–006 (004 demotes the shared demo administrator created by the seed; 005 then
   opens the one-time local administrator gate; 006 adds the `cancelled` loan status)
6. the application account, created by `database/app_account.sh` from `CAMPUS_APP_PASSWORD`

Use the setup script rather than running these files by hand; it applies exactly this order, and
every step is safe to re-run. With an account permitted to create databases, triggers and users,
run from the repository root (Git Bash on Windows):

```bash
MARIADB_CLIENT="mariadb -h127.0.0.1 -P3306" DB_ADMIN_USER=root MYSQL_PWD='<admin password>' \
  CAMPUS_APP_PASSWORD='<12+ characters of A-Z a-z 0-9 . _ ->' bash scripts/setup_database.sh
```

For an existing database, add `SKIP_SEED=1`: the seed is skipped and existing data is kept. With
Docker, `make up` (Windows: `frantastic.cmd up`) initialises an empty database volume in the same
order, upgrades an existing one and also installs the `campus_audit` plugin, which the Audit Lab
needs; see `docs/docker.md`. `make migrate` upgrades an existing Docker volume.

Verify the database:

```sql
USE university_resources;
SHOW TABLES;
SELECT * FROM rooms;
SELECT * FROM items;
```

### Load the Booking Catalogue (once per new database)

The booking pages offer a fixed catalogue: 18 items (Vacuum, Mop, Chess, Basketball, Speaker, …,
three copies A–C of each) and five rooms (Study Room, Meeting Room, Studio Room, Practice Room,
Cinema Room). `database/seed.sql` does **not** contain them; it only has the demonstration rows
(Room 201, Project Room 12, Electronics Lab and three `DEMO-…` items). The catalogue rows are
inserted by `frontend/seed.py`, and **no setup path runs that script**: not
`scripts/setup_database.sh`, not `make up` / `frantastic.cmd up`, not the Docker initialisation and
not `scripts/post_start.sh`. Until it has been run, the pages are shown but every booking attempt
answers "This item does not exist." or "This room does not exist."

**When.** Once, after the database setup above has finished (the script needs the `items` and
`rooms` tables): after `scripts/setup_database.sh` on a new database, after the first `make up` /
`frantastic.cmd up` on an empty Docker volume, and again after `make reset`, which deletes the
volume. Not after a restart, `make migrate` or an upgrade of an existing database.

**Account.** The script reads two variables and has no default for either:

| Variable | Meaning |
|---|---|
| `DB_ADMIN_USER` | a MariaDB account with INSERT on `items` and `rooms`, for example the account used for `scripts/setup_database.sh` (in Docker: `root`) |
| `MYSQL_PWD` | that account's password (in Docker: the value of `MARIADB_ROOT_PASSWORD` in `.env`) |

If either is missing the script stops before connecting (exit code 2); it never falls back to root.
Do **not** use `campus_app`: the web application account has no INSERT privilege on `items` or
`rooms` by design, the script refuses that name, and the privilege must not be granted to make
this work. `DB_HOST`, `DB_PORT` and `DB_NAME` are taken from the environment or from the
repository's `.env` (defaults `127.0.0.1`, `3306`, `university_resources`); variables that are
already set win over `.env`.

**Supplying the password on Windows.** Type it at a hidden prompt into the current PowerShell
session only. Do not write it into a script, a `.cmd` file or the command line, and do not `echo`
it. Docker (the web container already has the script, its dependencies and the right `DB_HOST` /
`DB_PORT`):

```powershell
$env:DB_ADMIN_USER = 'root'
$secure = Read-Host 'Password of the maintenance account' -AsSecureString
$env:MYSQL_PWD = [System.Net.NetworkCredential]::new('', $secure).Password
try {
    docker compose exec -T -e DB_ADMIN_USER -e MYSQL_PWD web python seed.py
} finally {
    Remove-Item Env:MYSQL_PWD, Env:DB_ADMIN_USER -ErrorAction SilentlyContinue
    Remove-Variable secure
}
```

`-e NAME` without a value forwards the variable from the session, so the password appears neither
in the command nor in the output. Without Docker, replace the `docker compose` line by
`Push-Location frontend; try { python seed.py } finally { Pop-Location }` (Python with
`frontend/requirements.txt` installed; set `DB_PORT` if the server does not listen on 3306). In Git
Bash the same is:

```bash
read -r -s -p 'Password of the maintenance account: ' MYSQL_PWD; echo
export MYSQL_PWD DB_ADMIN_USER=root
(cd frontend && python seed.py); unset MYSQL_PWD DB_ADMIN_USER
```

**Running it again.** The script is not idempotent, but a second run is harmless: both INSERTs are
one transaction, the first one fails on the unique `items.asset_tag` (MariaDB error 1062), the
transaction is rolled back, and the script reports "Seeding failed (MariaDB error 1062); nothing was
changed. The catalogue seems to be loaded already." with exit code 1. It never duplicates the
catalogue and never changes existing rows; do not treat that exit code as a broken installation.
Exit codes: 0 loaded, 1 database error (nothing changed), 2 configuration refused.

The inserted rows pass through the `items` and `rooms` triggers like any other change: the history
shows them with the maintenance account as `database_user`, no application user and
`event_source = direct_sql`.

### Run the Audit File Checks

Switch to the error-handling branch:

```bash
git switch error-handling
```

From the repository root, compile with a C++11-compatible compiler:

```bash
g++ -std=c++11 puglin1/audit_file_check.cpp puglin1/tests/test_automatic_errors.cpp -o puglin1/tests/test_automatic_errors.exe
```

Run in Windows PowerShell:

```powershell
.\puglin1\tests\test_automatic_errors.exe
```

Expected output:

```text
PASS: Empty path
PASS: Missing directory
PASS: Valid path
Failures: 0
```

The test requires `audit_test_missing_directory` to be absent. It creates and removes `audit_open_test.tmp` in the working directory.

Further details are available in `puglin1/docs/error_handling.md`.

## Current Limitations

- The application backend and frontend are not implemented.
- The audit plugin is not yet integrated with MariaDB.
- Runtime audit-write failures still require implementation and testing.
- Overlapping room bookings require additional transactional logic.
- Preventing simultaneous active loans for the same item requires additional transactional logic.
- The proposed change-history table and connection-event audit design still need to be reconciled.

## Next Steps

- Integrate the database and audit-support work.
- Build and load a minimal MariaDB audit plugin.
- Implement and test audit-event recording.
- Develop the Python backend.
- Implement reservation and equipment-loan workflows.
- Add concurrency checks and integration tests.
- Complete installation and usage documentation.
