# Quick start for the campus_audit project (MariaDB server plugin, Area 11).
#
#   make up       build the plugin against MariaDB 13.0.2, start database + web app
#   make demo     install the plugin, cause events, show what it recorded
#   make test          unit tests + end-to-end plugin tests + web app tests
#   make test-browser  browser tests (bootstraps a local Playwright venv on first use)
#   make doctor        explain what is wrong (passwords vs. volume, plugin, web app)
#   make help          all targets
#
# Needs Docker with the Compose plugin and GNU make.  Without make, the same
# commands are listed in docs/docker.md.  The portable targets (test-unit,
# mutation, check) need only g++, make and Python 3.

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c
.DEFAULT_GOAL := help
COMPOSE ?= docker compose

# Browser tests run on the host, separately from the Docker web container.
# Keep their pinned Python dependencies isolated from pyenv/system Python.
BROWSER_VENV ?= .venv-browser
ifeq ($(OS),Windows_NT)
BROWSER_PYTHON ?= $(BROWSER_VENV)/Scripts/python.exe
else
BROWSER_PYTHON ?= $(BROWSER_VENV)/bin/python
endif

# The three secrets always come from .env.  Docker Compose prefers a value
# exported in the calling shell (for example after `set -a; . ./.env` of an
# older .env) over the .env file, and the web container would then start with
# a password the database does not have (seen in the CI regression run).
unexport MARIADB_ROOT_PASSWORD CAMPUS_APP_PASSWORD SECRET_KEY

# Everything that talks to the running server uses the root password from .env.
# It is passed to the client through the environment (MYSQL_PWD), not on the command line.
ADMIN_ENV = set -a; . ./.env; set +a; export MYSQL_PWD="$$MARIADB_ROOT_PASSWORD"; \
            export MARIADB_CLIENT="$(COMPOSE) exec -T -e MYSQL_PWD mariadb mariadb"

.PHONY: help up down reset logs sql demo examples doctor migrate repair-credentials reset-admin \
        test test-unit test-e2e test-db test-app browser-setup test-browser mutation check bench evidence

help:  ## list the targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-z0-9-]+:.*## / {printf "  make %-19s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.env:
	@bash scripts/make_env.sh

up: .env  ## build, start MariaDB 13.0.2, update the database, install the plugin, start the web app
	$(COMPOSE) up -d --build --wait mariadb
	@$(ADMIN_ENV); bash scripts/post_start.sh
	@$(COMPOSE) up -d --build --wait web || { echo; bash scripts/doctor.sh; exit 1; }
	@$(ADMIN_ENV); bash scripts/bootstrap_admin.sh
	@echo
	@web_port=$${WEB_PORT:-}; if [ -z "$$web_port" ]; then web_port=$$(sed -n 's/^WEB_PORT=//p' .env | tail -n 1); fi; web_port=$${web_port:-5080}; \
	  echo "Web app:      http://127.0.0.1:$$web_port"; \
	  echo "Guided tour:  http://127.0.0.1:$$web_port/lab   (student demo login alice.student@example.edu / campus-demo-2026)"
	@if [ -f .admin-credentials ]; then echo "Administrator credential: .admin-credentials (private local file; not printed)"; else echo "An administrator already exists; no credential was changed."; fi
	@echo "Next:         make demo"

down: .env  ## stop the containers (data and audit logs are kept)
	$(COMPOSE) down

reset: .env  ## stop and DELETE the database and audit-log volumes (all data is lost)
	$(COMPOSE) down -v

doctor: .env  ## read-only diagnosis: .env, volume age, root and campus_app logins, plugin, lab objects
	@bash scripts/doctor.sh

migrate: .env  ## apply migrations and triggers to an existing database volume (keeps data, no seed)
	@$(ADMIN_ENV); SKIP_SEED=1 bash scripts/setup_database.sh

repair-credentials: .env  ## set the passwords stored in the database volume to those in .env (keeps data)
	@bash scripts/repair_credentials.sh
	@$(MAKE) --no-print-directory up

reset-admin: .env  ## rotate the local administrator password and replace .admin-credentials
	@$(ADMIN_ENV); bash scripts/bootstrap_admin.sh --reset

logs: .env  ## last records of the plugin's JSON Lines file
	$(COMPOSE) exec mariadb tail -n 15 /var/log/campus_audit/campus_audit.jsonl

sql: .env  ## open an interactive SQL shell as root
	@$(ADMIN_ENV); $(COMPOSE) exec -e MYSQL_PWD mariadb mariadb -uroot

demo: .env  ## install the plugin, cause audited events, show the records (scripts/demo.sh)
	@$(ADMIN_ENV); bash scripts/demo.sh

examples: .env  ## run examples/01..06 in order and show every result (examples 02, 04 and 05 contain deliberate errors)
	@$(ADMIN_ENV); for f in examples/0*.sql; do \
	    printf '\n######## %s\n' "$$f"; \
	    $(COMPOSE) exec -T -e MYSQL_PWD mariadb mariadb -uroot --force --table < "$$f" 2>&1 \
	        || echo "(non-zero exit is expected for examples 02, 04 and 05: deliberate errors)"; \
	done

test-unit:  ## plugin unit tests + repository checks + credential/diagnostic script tests (g++, no server needed)
	$(MAKE) -C plugin test
	bash tests/shell/test_admin_auth.sh
	bash tests/shell/test_database_setup.sh
	python3 scripts/check_repo.py
	python3 tests/test_source_distribution.py

test-e2e: .env  ## end-to-end tests of the loaded plugin, incl. CHANGE_USER (tests/plugin/run_plugin_tests.sh)
	@$(ADMIN_ENV); export AUDIT_TEST_DIR=/var/log/campus_audit/; \
	  export CHANGE_USER_CLIENT="$(COMPOSE) exec -T --interactive=false -e CU_PW1 -e CU_PW2 mariadb campus_change_user"; \
	  bash tests/plugin/run_plugin_tests.sh

test-db: .env  ## database-side checks: migrations 004/006, triggers, app grants, password-hash helper; database_tests.sql with its expected errors
	@$(ADMIN_ENV); bash tests/database/test_legacy_admin_migration.sh && \
	  bash tests/database/test_cancelled_loan_migration.sh && bash tests/database/test_audit_triggers.sh && \
	  bash tests/database/test_app_account_grants.sh && \
	  bash tests/database/test_native_password_hash.sh && bash tests/database/run_database_tests.sh

test-app: .env  ## web app and Audit Lab tests incl. the database tests, run inside the web container
	@if [ -s .admin-credentials ]; then \
	  { IFS= read -r TEST_ADMIN_EMAIL; IFS= read -r TEST_ADMIN_PASSWORD; }; TEST_ADMIN_EMAIL=$${TEST_ADMIN_EMAIL%$$'\r'}; TEST_ADMIN_PASSWORD=$${TEST_ADMIN_PASSWORD%$$'\r'}; \
	  export TEST_ADMIN_EMAIL TEST_ADMIN_PASSWORD; \
	  $(COMPOSE) exec -T -e RUN_DB_TESTS=1 -e TEST_ADMIN_EMAIL -e TEST_ADMIN_PASSWORD web python -m pytest -q; \
	else \
	  $(COMPOSE) exec -T -e RUN_DB_TESTS=1 web python -m pytest -q; \
	fi

test: .env  ## run every Linux/Windows test suite in the shared runtime container (needs `make up` first)
	@set -a; . ./.env; set +a; \
	if [ -s .admin-credentials ]; then { IFS= read -r TEST_ADMIN_EMAIL; IFS= read -r TEST_ADMIN_PASSWORD; }; TEST_ADMIN_EMAIL=$${TEST_ADMIN_EMAIL%$$'\r'}; TEST_ADMIN_PASSWORD=$${TEST_ADMIN_PASSWORD%$$'\r'}; export TEST_ADMIN_EMAIL TEST_ADMIN_PASSWORD; fi; \
	$(COMPOSE) --profile test run --rm --build test-runner

browser-setup:  ## create an isolated browser-test environment and install Playwright + Chromium
	@command -v python3 >/dev/null 2>&1 || { echo "python3 is required to set up browser tests."; exit 1; }
	@python3 -m venv "$(BROWSER_VENV)" || { \
	  echo "Could not create the browser-test virtual environment."; \
	  echo "On Debian/Ubuntu, install it with: sudo apt install python3-venv"; \
	  exit 1; }
	@"$(BROWSER_PYTHON)" -m pip install -r frontend/requirements-browser.txt
	@if [ "$$(uname -s)" = "Linux" ]; then \
	  "$(BROWSER_PYTHON)" -m playwright install --with-deps chromium; \
	else \
	  "$(BROWSER_PYTHON)" -m playwright install chromium; \
	fi
	@echo "Browser-test environment ready. Run: make test-browser"

test-browser: .env  ## run the Audit Lab browser tests (sets up the isolated Playwright environment on first use)
	@if [ ! -x "$(BROWSER_PYTHON)" ] || ! "$(BROWSER_PYTHON)" -c 'import os, pytest; from playwright.sync_api import sync_playwright; p=sync_playwright().start(); ok=os.path.isfile(p.chromium.executable_path); p.stop(); raise SystemExit(0 if ok else 1)' >/dev/null 2>&1; then \
	  echo "Browser-test dependencies are missing; setting them up in $(BROWSER_VENV)..."; \
	  $(MAKE) --no-print-directory browser-setup; \
	fi
	@set -a; . ./.env; set +a; RUN_BROWSER_TESTS=1 LAB_BASE_URL="http://127.0.0.1:$${WEB_PORT:-5080}" \
	  "$(BROWSER_PYTHON)" -m pytest -q --confcutdir=frontend/tests/browser frontend/tests/browser

mutation:  ## inject bugs into the plugin code and check that the unit tests notice (g++, ~1.5 min in CI)
	python3 scripts/mutation_check.py

check:  ## repository consistency checks only
	python3 scripts/check_repo.py

bench: .env  ## overhead benchmark: no plugin vs campus_audit vs server_audit, two passes (scripts/benchmark.sh)
	@$(ADMIN_ENV); bash scripts/benchmark.sh

evidence: .env  ## run demo, tests and benchmark and save the outputs in docs/evidence/linux/
	@mkdir -p docs/evidence/linux
	@$(ADMIN_ENV); { echo "# $$(date -u +%FT%TZ) on $$(uname -srm)"; $(COMPOSE) version --short; } > docs/evidence/linux/environment.txt
	@$(ADMIN_ENV); bash scripts/demo.sh 2>&1 | tee docs/evidence/linux/demo.txt
	@$(ADMIN_ENV); export AUDIT_TEST_DIR=/var/log/campus_audit/; \
	  export CHANGE_USER_CLIENT="$(COMPOSE) exec -T --interactive=false -e CU_PW1 -e CU_PW2 mariadb campus_change_user"; \
	  bash tests/plugin/run_plugin_tests.sh 2>&1 | tee docs/evidence/linux/plugin-tests.txt
	@$(COMPOSE) exec -T -e RUN_DB_TESTS=1 web python -m pytest -q 2>&1 | tee docs/evidence/linux/app-tests.txt
	@$(ADMIN_ENV); BENCH_OUT=docs/evidence/linux/benchmark.csv bash scripts/benchmark.sh 2>&1 | tee docs/evidence/linux/benchmark.txt
