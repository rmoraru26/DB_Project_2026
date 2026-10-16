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

- Students and an administrator
- Campus rooms
- Equipment items
- A room reservation
- A returned equipment loan

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

Switch to the database branch:

```bash
git switch database-schema
```

Open the MariaDB client with an account permitted to create databases, then execute:

```sql
SOURCE database/schema.sql;
SOURCE database/seed.sql;
```

Start the MariaDB client from the repository root, or provide absolute file paths to the SQL scripts.

Verify the database:

```sql
USE university_resources;
SHOW TABLES;
SELECT * FROM rooms;
SELECT * FROM items;
```

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
