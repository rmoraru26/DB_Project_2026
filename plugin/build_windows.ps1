<#
.SYNOPSIS
  Builds campus_audit.dll for a native Windows MariaDB server and runs the
  plugin unit tests.

.DESCRIPTION
  Uses Zig (a self-contained clang toolchain, no installer, no Visual Studio)
  and the server headers that every MariaDB Windows installation ships in
  <MariaDB>\include\mysql\server.  Tested with Zig 0.16.0 against the official
  mariadb-13.0.2-winx64 package.

  The DLL does not link mysqlservices.lib (an MSVC library that a GNU
  toolchain cannot link); src/service_symbols.cpp defines the two service
  pointers instead, and src/campus_audit.def lists the exports.

.EXAMPLE
  .\plugin\build_windows.ps1 -MariaDBDir "C:\Program Files\MariaDB 13.0" -Zig C:\tools\zig\zig.exe
#>
param(
    [string]$MariaDBDir = "C:\Program Files\MariaDB 13.0",
    [string]$Zig = "zig",
    [string]$OutDir = (Join-Path $PSScriptRoot "build"),
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

$include = Join-Path $MariaDBDir "include\mysql\server"
foreach ($header in @("mysql\plugin.h", "mysql\plugin_audit.h", "private\service_versions.h")) {
    if (-not (Test-Path (Join-Path $include $header))) {
        throw "MariaDB server header '$header' not found under '$include'. Pass -MariaDBDir <MariaDB installation directory>."
    }
}
if (-not (Get-Command $Zig -ErrorAction SilentlyContinue)) {
    throw "Zig compiler '$Zig' not found. Download it from https://ziglang.org/download/ and pass -Zig <path to zig.exe>."
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$src = $PSScriptRoot
$common = @("-std=c++11", "-O2", "-Wall", "-Wextra", "-I$src")

Write-Host "Building campus_audit.dll against $include"
& $Zig c++ -target x86_64-windows-gnu -shared -DMYSQL_DYNAMIC_PLUGIN @common `
    "-I$include" "-I$(Join-Path $include 'private')" `
    "$src\src\campus_audit.cpp" "$src\src\record_format.cpp" "$src\src\log_sink.cpp" `
    "$src\src\service_symbols.cpp" "$src\audit_file_check.cpp" "$src\audit_error_reporter.cpp" `
    "$src\src\campus_audit.def" -o (Join-Path $OutDir "campus_audit.dll")
if ($LASTEXITCODE -ne 0) { throw "plugin build failed" }
Write-Host "Built $(Join-Path $OutDir 'campus_audit.dll')"

if ($SkipTests) { exit 0 }

$tests = @{
    "test_record_format"    = @("$src\tests\test_record_format.cpp", "$src\src\record_format.cpp", "$src\audit_file_check.cpp")
    "test_log_sink"         = @("$src\tests\test_log_sink.cpp", "$src\src\log_sink.cpp", "$src\audit_file_check.cpp")
    "test_automatic_errors" = @("$src\tests\test_automatic_errors.cpp", "$src\audit_file_check.cpp")
    "test_error_reporter"   = @("$src\tests\test_error_reporter.cpp", "$src\audit_error_reporter.cpp")
}
$failed = 0
Push-Location $OutDir
try {
    foreach ($name in ($tests.Keys | Sort-Object)) {
        $exe = Join-Path $OutDir "$name.exe"
        & $Zig c++ @common @($tests[$name]) -o $exe
        if ($LASTEXITCODE -ne 0) { throw "build of $name failed" }
        & $exe
        if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: $name"; $failed++ } else { Write-Host "OK: $name" }
    }
} finally {
    Pop-Location
}
if ($failed -ne 0) { throw "$failed unit test program(s) failed" }
Write-Host "All unit test programs passed."
