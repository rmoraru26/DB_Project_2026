#!/usr/bin/env bash
# Native Windows unit-test programs, one by one (Git Bash), so that one program
# refused by application control does not stop the others (build_windows.ps1
# stops at the first one).  Two toolchains: Zig 0.16.0 with the flags of
# build_windows.ps1, and MSYS2 g++ 15.2 (-O2).  Exit 126 / "Application Control
# policy has blocked this file" = refused by Smart App Control, not a test result.
set -u
SRC=$1; OUT=$2
WN="<scratch-p1>/win-native"
ZIG="$WN/zig/zig-x86_64-windows-0.16.0/zig.exe"
GXX=/c/msys64/ucrt64/bin/g++.exe
B="$(dirname "$OUT")/native-unit-build"; mkdir -p "$OUT" "$B"
cd "$SRC/plugin" || exit 2
declare -A S=(
  [test_record_format]="tests/test_record_format.cpp src/record_format.cpp audit_file_check.cpp"
  [test_log_sink]="tests/test_log_sink.cpp src/log_sink.cpp audit_file_check.cpp"
  [test_automatic_errors]="tests/test_automatic_errors.cpp audit_file_check.cpp"
  [test_error_reporter]="tests/test_error_reporter.cpp audit_error_reporter.cpp"
  [test_runtime_config]="tests/test_runtime_config.cpp"
  [test_gap_accounting]="tests/test_gap_accounting.cpp"
  [test_statement_scope]="tests/test_statement_scope.cpp"
)
for tc in zig gxx; do
  for n in test_record_format test_log_sink test_automatic_errors test_error_reporter test_runtime_config test_gap_accounting test_statement_scope; do
    exe="$B/$tc-$n.exe"; log="$OUT/$tc-$n.txt"
    if [ $tc = zig ]; then
      # shellcheck disable=SC2086
      "$ZIG" c++ -std=c++11 -O2 -Wall -Wextra -I. ${S[$n]} -o "$(cygpath -w "$exe")" > "$log" 2>&1
    else
      # shellcheck disable=SC2086
      "$GXX" -std=c++11 -O2 -Wall -Wextra -I. ${S[$n]} -o "$exe" > "$log" 2>&1
    fi
    crc=$?
    if [ $crc -ne 0 ]; then echo "$tc $n: COMPILE FAILED (exit $crc)"; continue; fi
    ( cd "$B" && "$exe" ) >> "$log" 2>&1; rc=$?
    np=$(grep -ac '^PASS' "$log"); nf=$(grep -ac '^FAIL' "$log")
    if grep -aq "Application Control policy has blocked" "$log" || [ $rc -eq 126 ]; then echo "$tc $n: compiled; REFUSED by application control (exit $rc)"
    else echo "$tc $n: compiled; ran, exit $rc, $np PASS, $nf FAIL"; fi
  done
done
