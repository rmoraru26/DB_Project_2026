# Linux build of the campus_audit plugin and its unit tests.
#
#   make                 build build/campus_audit.so
#   make test            build and run the unit tests (no MariaDB needed)
#   make SERVER_INCLUDE=/path/to/include/mysql/server
#
# Server headers: Debian/Ubuntu package libmariadbd-dev installs them in
# /usr/include/mariadb/server; libmariadb-dev provides libmysqlservices.a.
# Without libmysqlservices.a the build falls back to src/service_symbols.cpp.

CXX ?= g++
CXXFLAGS ?= -O2 -g
CXXFLAGS += -std=c++11 -Wall -Wextra -I.
SERVER_INCLUDE ?= /usr/include/mariadb/server
SERVICES_LIB ?= $(firstword $(wildcard /usr/lib/*/libmysqlservices.a /usr/lib/libmysqlservices.a /usr/lib64/libmysqlservices.a))
BUILD ?= build

PLUGIN_SOURCES = src/campus_audit.cpp src/record_format.cpp src/log_sink.cpp \
                 audit_file_check.cpp audit_error_reporter.cpp
ifeq ($(SERVICES_LIB),)
PLUGIN_SOURCES += src/service_symbols.cpp
endif

UNIT_TESTS = test_record_format test_log_sink test_automatic_errors test_error_reporter test_runtime_config test_gap_accounting

.PHONY: all plugin test check-headers clean

all: plugin

check-headers:
	@test -f "$(SERVER_INCLUDE)/mysql/plugin_audit.h" || { \
	  echo "error: MariaDB server headers not found: $(SERVER_INCLUDE)/mysql/plugin_audit.h"; \
	  echo "       install libmariadbd-dev or pass SERVER_INCLUDE=<dir containing mysql/plugin.h>"; \
	  exit 1; }

plugin: check-headers $(BUILD)/campus_audit.so

$(BUILD)/campus_audit.so: $(PLUGIN_SOURCES) src/*.h *.h | $(BUILD)
	$(CXX) $(CXXFLAGS) -shared -fPIC -DMYSQL_DYNAMIC_PLUGIN \
	  -I"$(SERVER_INCLUDE)" -I"$(SERVER_INCLUDE)/private" \
	  $(PLUGIN_SOURCES) $(SERVICES_LIB) -o $@
	@echo "built $@ (services: $(if $(SERVICES_LIB),$(SERVICES_LIB),src/service_symbols.cpp))"

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/test_record_format: tests/test_record_format.cpp src/record_format.cpp audit_file_check.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) $^ -o $@
$(BUILD)/test_log_sink: tests/test_log_sink.cpp src/log_sink.cpp audit_file_check.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) $^ -o $@
$(BUILD)/test_automatic_errors: tests/test_automatic_errors.cpp audit_file_check.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) $^ -o $@
$(BUILD)/test_error_reporter: tests/test_error_reporter.cpp audit_error_reporter.cpp | $(BUILD)
	$(CXX) $(CXXFLAGS) $^ -o $@
$(BUILD)/test_runtime_config: tests/test_runtime_config.cpp src/runtime_config.h | $(BUILD)
	$(CXX) $(CXXFLAGS) -pthread $< -o $@
$(BUILD)/test_gap_accounting: tests/test_gap_accounting.cpp src/gap_accounting.h | $(BUILD)
	$(CXX) $(CXXFLAGS) $< -o $@

# Tests create temporary files in the working directory, so run them in $(BUILD).
test: $(addprefix $(BUILD)/,$(UNIT_TESTS))
	@cd $(BUILD) && for t in $(UNIT_TESTS); do \
	  echo "== $$t"; ./$$t || exit 1; \
	done
	@echo "All unit test programs passed."

clean:
	rm -rf $(BUILD)
