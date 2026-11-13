$ErrorActionPreference = 'Stop'
# End-to-end test of frantastic.cmd -> frantastic.ps1 with a fake docker.cmd
# placed first on PATH, in a temporary copy of the launcher files (path with
# spaces). DOCKER_HOST points at a pipe that does not exist, so even an
# accidental call of the real docker.exe could not reach an engine. Dummy
# secrets only; nothing here talks to Docker.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts/windows_launcher.ps1')   # for Invoke-FrantasticNativeWithTimeout
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "Run this test under Windows PowerShell 5.1 (powershell.exe)."
}
$script:Passed = 0
function Assert-True([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "FAIL: $Label" }
    $script:Passed++
    Write-Host "PASS: $Label"
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('FRANtastic Launcher E2E ' + [Guid]::NewGuid().ToString('N'))
$project = Join-Path $root 'project copy'
$bin = Join-Path $root 'fake bin'
$log = Join-Path $root 'docker calls.log'
New-Item -ItemType Directory -Path (Join-Path $project 'scripts'), $bin | Out-Null
foreach ($file in 'frantastic.cmd', 'frantastic.ps1', '.env.example', 'scripts/windows_security.ps1', 'scripts/windows_compose_url.ps1', 'scripts/windows_launcher.ps1') {
    Copy-Item -LiteralPath (Join-Path $repoRoot $file) -Destination (Join-Path $project $file)
}
$fakeDocker = @(
    '@echo off',
    '>>"%FAKE_DOCKER_LOG%" echo ARGS %*',
    'if "%~1"=="compose" if "%~2"=="version" (echo Docker Compose version v0.0.0-fake& exit /b 0)',
    'if "%~1"=="info" (echo WARNING: fake engine warning on stderr 1>&2& echo linux& exit /b 0)',
    'if "%~1"=="compose" if "%~2"=="exec" goto exec',
    'if "%~1"=="compose" if "%~2"=="down" (echo fake down progress on stderr 1>&2& exit /b 0)',
    'echo fake docker: unexpected arguments 1>&2',
    'exit /b 64',
    ':exec',
    'if defined MARIADB_ROOT_PASSWORD (>>"%FAKE_DOCKER_LOG%" echo ENV MARIADB_ROOT_PASSWORD present) else (>>"%FAKE_DOCKER_LOG%" echo ENV MARIADB_ROOT_PASSWORD absent)',
    'if defined MYSQL_PWD (>>"%FAKE_DOCKER_LOG%" echo ENV MYSQL_PWD present) else (>>"%FAKE_DOCKER_LOG%" echo ENV MYSQL_PWD absent)',
    'echo fake exec stderr line 1>&2',
    'echo fake-exec-ran',
    'if defined FAKE_EXEC_EXIT exit /b %FAKE_EXEC_EXIT%',
    'exit /b 0'
)
[IO.File]::WriteAllText((Join-Path $bin 'docker.cmd'), (($fakeDocker -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)

$names = @('PATH', 'DOCKER_HOST', 'FAKE_DOCKER_LOG', 'FAKE_EXEC_EXIT', 'MARIADB_ROOT_PASSWORD', 'MYSQL_PWD')
$saved = @{}; foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
$markers = New-Object 'System.Collections.Generic.List[string]'
function New-Marker([string] $Prefix) { $m = $Prefix + [Guid]::NewGuid().ToString('N').Substring(0, 12); $markers.Add($m); return $m }
function Write-TestEnv([string] $RootValue) {
    $app = New-Marker 'app'
    $text = [IO.File]::ReadAllText((Join-Path $project '.env.example'))
    $text = $text -replace '(?m)^MARIADB_ROOT_PASSWORD=.*$', "MARIADB_ROOT_PASSWORD=$RootValue"
    $text = $text -replace '(?m)^CAMPUS_APP_PASSWORD=.*$', "CAMPUS_APP_PASSWORD=$app"
    $text = $text -replace '(?m)^DB_PASSWORD=.*$', "DB_PASSWORD=$app"
    $text = $text -replace '(?m)^SECRET_KEY=.*$', "SECRET_KEY=$(New-Marker 'key')"
    [IO.File]::WriteAllText((Join-Path $project '.env'), $text, [Text.Encoding]::ASCII)
}
$script:AllOutput = New-Object 'System.Collections.Generic.List[string]'
function Invoke-Launcher([string] $Command) {
    [IO.File]::WriteAllText($log, '')
    $result = Invoke-FrantasticNativeWithTimeout -FilePath (Join-Path $project 'frantastic.cmd') -Arguments @($Command) -TimeoutSeconds 120
    if ($result.TimedOut) { throw "FAIL: launcher '$Command' did not finish within 120 seconds" }
    $text = (@($result.Output) + @($result.ErrorOutput)) -join "`n"
    $script:AllOutput.Add($text)
    return [pscustomobject]@{ Text = $text; ExitCode = $result.ExitCode; Calls = @([IO.File]::ReadAllLines($log)) }
}

try {
    [Environment]::SetEnvironmentVariable('PATH', $bin + ';' + $saved['PATH'], 'Process')
    [Environment]::SetEnvironmentVariable('DOCKER_HOST', 'npipe:////./pipe/frantastic-e2e-no-engine', 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_DOCKER_LOG', $log, 'Process')
    [Environment]::SetEnvironmentVariable('FAKE_EXEC_EXIT', $null, 'Process')
    [Environment]::SetEnvironmentVariable('MYSQL_PWD', $null, 'Process')
    $resolved = (Get-Command docker -CommandType Application | Select-Object -First 1).Path
    Assert-True ($resolved -ceq (Join-Path $bin 'docker.cmd')) 'the fake docker.cmd is the first docker on PATH'

    $r = Invoke-Launcher 'help'
    Assert-True ($r.ExitCode -eq 0 -and $r.Text -like '*Usage: .\frantastic.cmd up|demo|test|down|reset-admin*' -and $r.Calls.Count -eq 0) 'help: dispatched without any Docker call'

    $r = Invoke-Launcher 'demo'
    Assert-True ($r.ExitCode -eq 1 -and $r.Text -like '*No .env file*' -and @($r.Calls | Where-Object { $_ -like 'ARGS compose exec*' }).Count -eq 0) 'demo without .env: stops before any container command'

    Write-TestEnv '   '
    $r = Invoke-Launcher 'demo'
    Assert-True ($r.ExitCode -eq 1 -and $r.Text -like '*MARIADB_ROOT_PASSWORD is empty or contains only whitespace*' -and @($r.Calls | Where-Object { $_ -like 'ARGS compose exec*' }).Count -eq 0) 'demo with a whitespace-only root secret: stops before any container command'

    $rootValue = New-Marker 'root'
    Write-TestEnv $rootValue
    $override = New-Marker 'override'
    [Environment]::SetEnvironmentVariable('MARIADB_ROOT_PASSWORD', $override, 'Process')
    $r = Invoke-Launcher 'demo'
    $expected = @('ARGS compose version', 'ARGS info --format {{.OSType}}', 'ARGS compose exec -T mariadb bash /usr/local/share/campus/scripts/demo.sh', 'ENV MARIADB_ROOT_PASSWORD absent', 'ENV MYSQL_PWD absent')
    Assert-True ($r.ExitCode -eq 0 -and $r.Text -like '*fake-exec-ran*') 'demo: succeeds although the fake engine and exec write to stderr'
    Assert-True ((($r.Calls) -join '|') -ceq ($expected -join '|')) "demo: exact Docker calls, no password forwarded: $(($r.Calls) -join ' | ')"
    Assert-True ($r.Text -like '*Ignoring MARIADB_ROOT_PASSWORD from the environment*') 'demo: the session override is announced and removed before Docker runs'

    [Environment]::SetEnvironmentVariable('FAKE_EXEC_EXIT', '7', 'Process')
    $r = Invoke-Launcher 'demo'
    [Environment]::SetEnvironmentVariable('FAKE_EXEC_EXIT', $null, 'Process')
    Assert-True ($r.ExitCode -eq 1 -and $r.Text -like '*Docker command failed with exit code 7*') 'demo: a non-zero Docker exit code is propagated'

    $r = Invoke-Launcher 'down'
    Assert-True ($r.ExitCode -eq 0 -and (($r.Calls) -join '|') -ceq 'ARGS compose version|ARGS info --format {{.OSType}}|ARGS compose down') 'down: dispatched to docker compose down'

    # In this process, so the launcher's finally block can be observed: the
    # removed session variable must be back afterwards.
    [IO.File]::WriteAllText($log, '')
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $inProcess = @(& (Join-Path $project 'frantastic.ps1') 'demo' 6>&1 | ForEach-Object { [string]$_ }); $inProcessCode = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    $script:AllOutput.Add(($inProcess -join "`n"))
    Assert-True ($inProcessCode -eq 0 -and @([IO.File]::ReadAllLines($log)) -contains 'ENV MARIADB_ROOT_PASSWORD absent') 'in-process run: the variable is absent for Docker'
    Assert-True ([Environment]::GetEnvironmentVariable('MARIADB_ROOT_PASSWORD', 'Process') -ceq $override) 'in-process run: the removed session variable is restored afterwards'

    $leaks = @($script:AllOutput | Where-Object { $t = $_; @($markers | Where-Object { $t.Contains($_) }).Count -gt 0 })
    Assert-True ($leaks.Count -eq 0) 'no dummy secret appears in any launcher output'
} finally {
    foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process') }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Launcher end-to-end tests: $script:Passed checks passed."
