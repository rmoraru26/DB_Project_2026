# Builds the tutorial plugin on its own, against the headers of an installed
# MariaDB server (Debian/Ubuntu: libmariadbd-dev and libmariadb-dev of the
# server's exact version).
#
#   make -C examples/skeleton_plugin            -> skeleton_audit.so
#   make -C examples/skeleton_plugin experimental  -> skeleton_audit_exp.so (README, step 5)
#   make -C examples/skeleton_plugin install    copies the library to the server's plugin_dir (needs root)
#
# Without a local server: make plugin-lab (repository root) builds it in Docker
# and loads it into a throw-away MariaDB 13.0.2.

CXX ?= g++
MARIADB_CONFIG ?= mariadb_config
MARIADB_INCLUDE ?= /usr/include/mariadb
INCLUDES ?= -I$(MARIADB_INCLUDE)/server -I$(MARIADB_INCLUDE)/server/private
CXXFLAGS ?= -std=c++11 -O2 -Wall -Wextra
PLUGIN_DIR ?= $(shell $(MARIADB_CONFIG) --plugindir 2>/dev/null)

.PHONY: all experimental install clean

all: skeleton_audit.so

skeleton_audit.so: skeleton_audit.cpp
	$(CXX) $(CXXFLAGS) -shared -fPIC -DMYSQL_DYNAMIC_PLUGIN $(INCLUDES) $< -o $@

experimental: skeleton_audit.cpp
	$(CXX) $(CXXFLAGS) -shared -fPIC -DMYSQL_DYNAMIC_PLUGIN -DSKELETON_EXPERIMENTAL $(INCLUDES) $< -o skeleton_audit_exp.so

install: skeleton_audit.so
	@test -n "$(PLUGIN_DIR)" || { echo "set PLUGIN_DIR to the directory SELECT @@plugin_dir; names"; exit 1; }
	install -m 0755 skeleton_audit.so "$(PLUGIN_DIR)/"

clean:
	rm -f skeleton_audit.so skeleton_audit_exp.so
