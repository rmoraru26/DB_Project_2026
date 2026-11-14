# MariaDB 13.0.2 (official image, pinned by digest) with the campus_audit
# plugin compiled against the matching server headers.
#
# Build context: the repository root (see compose.yaml).

ARG MARIADB_IMAGE=mariadb:13.0.2-resolute@sha256:0e4bb0f339feba125d1154fbacd36c16ec8518f52e44e1f82ecec7d6771caf39

# ---------------------------------------------------------------- build stage
FROM ${MARIADB_IMAGE} AS build

# The official image keeps the MariaDB apt repository of its own version and
# exports MARIADB_VERSION, so the headers match the server exactly.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gcc g++ make \
        "libmariadbd-dev=${MARIADB_VERSION}" "libmariadb-dev=${MARIADB_VERSION}"; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src/plugin
COPY plugin/ ./
RUN make clean && make test && make plugin

# Test helper that sends COM_CHANGE_USER through the C API (the mariadb client
# cannot); used by tests/plugin/run_plugin_tests.sh (make test-e2e).
COPY tests/plugin/change_user.c /src/tests/change_user.c
RUN gcc -O2 -Wall -o /src/campus_change_user /src/tests/change_user.c $(mariadb_config --cflags --libs)

# The tutorial plugin of examples/skeleton_plugin (examples/06_skeleton_plugin.sql).
COPY examples/skeleton_plugin/skeleton_audit.cpp /src/skeleton/skeleton_audit.cpp
RUN g++ -std=c++11 -O2 -Wall -shared -fPIC -DMYSQL_DYNAMIC_PLUGIN \
        -I/usr/include/mariadb/server -I/usr/include/mariadb/server/private \
        /src/skeleton/skeleton_audit.cpp -o /src/skeleton/skeleton_audit.so

# Runtime test runner: suites execute for every `make test` / Windows `test`
# invocation, independently of Docker build cache. The MariaDB client and
# compiler in this image also let it run the existing integration scripts.
FROM build AS test-runner
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends python3 python3-venv python3-pip; \
    rm -rf /var/lib/apt/lists/*; \
    python3 -m venv /opt/frantastic-test-venv
WORKDIR /workspace
COPY frontend/requirements.txt frontend/requirements-dev.txt /tmp/frantastic-requirements/
RUN cd /tmp/frantastic-requirements && /opt/frantastic-test-venv/bin/pip install --no-cache-dir \
      -r requirements.txt -r requirements-dev.txt
COPY . .
RUN gcc -O2 -Wall -o /usr/local/bin/campus_change_user tests/plugin/change_user.c $(mariadb_config --cflags --libs)
ENTRYPOINT ["bash", "scripts/run_test_suites.sh"]
CMD []

# ---------------------------------------------------------------- runtime stage
FROM ${MARIADB_IMAGE}

RUN test -d /usr/lib/mysql/plugin
COPY --from=build /src/plugin/build/campus_audit.so /usr/lib/mysql/plugin/campus_audit.so
COPY --from=build /src/campus_change_user /usr/local/bin/campus_change_user
COPY --from=build /src/skeleton/skeleton_audit.so /usr/lib/mysql/plugin/skeleton_audit.so
COPY docker/mariadb/campus_audit.cnf /etc/mysql/conf.d/campus_audit.cnf
RUN chmod 0644 /etc/mysql/conf.d/campus_audit.cnf

# Audit log directory; also the only directory LOAD_FILE() may read
# (secure_file_priv, see campus_audit.cnf).
RUN mkdir -p /var/log/campus_audit && chown mysql:mysql /var/log/campus_audit && chmod 0750 /var/log/campus_audit

# First-start initialisation, executed in file-name order by the entrypoint
# when (and only when) the data volume is empty.  scripts/post_start.sh
# (make up) applies newer migrations to an older volume.  The order is the one
# of scripts/setup_database.sh (scripts/check_repo.py checks that they agree):
#   1x schema, 2x migrations 001-003, 30 triggers, 40 seed,
#   5x migrations 004-006 (after the seed: 004 demotes the seeded Dana
#   administrator, 005 then evaluates the local administrator gate),
#   60 application account.
COPY database/schema.sql /docker-entrypoint-initdb.d/10-schema.sql
COPY database/migrations/001_audit_events_trigger_ownership.sql /docker-entrypoint-initdb.d/20-migration-001.sql
COPY database/migrations/002_campus_audit_schema.sql /docker-entrypoint-initdb.d/21-migration-002.sql
COPY database/migrations/003_audit_lab.sql /docker-entrypoint-initdb.d/22-migration-003.sql
COPY database/triggers.sql /docker-entrypoint-initdb.d/30-triggers.sql
COPY database/seed.sql /docker-entrypoint-initdb.d/40-seed.sql
COPY database/migrations/004_remove_shared_admin.sql /docker-entrypoint-initdb.d/50-migration-004.sql
COPY database/migrations/005_local_admin_bootstrap_state.sql /docker-entrypoint-initdb.d/51-migration-005.sql
COPY database/migrations/006_cancelled_loan_status.sql /docker-entrypoint-initdb.d/52-migration-006.sql
COPY database/app_account.sh database/native_password_hash.sh /usr/local/share/campus/
COPY database/ /usr/local/share/campus/database/
COPY scripts/ /usr/local/share/campus/scripts/
COPY tests/ /usr/local/share/campus/tests/
COPY docker/mariadb/initdb/50-app-account.sh /docker-entrypoint-initdb.d/60-app-account.sh
# The official entrypoint sources non-executable .sh files into its own shell,
# where docker_process_sql is defined. Set and assert the final-image mode here
# so host/archive permission handling cannot turn this into a subprocess.
RUN set -eux; \
    init_script=/docker-entrypoint-initdb.d/60-app-account.sh; \
    chmod 0644 "$init_script"; \
    test -f "$init_script"; \
    test -r "$init_script"; \
    test ! -x "$init_script"; \
    test "$(stat -c '%a' "$init_script")" = 644
