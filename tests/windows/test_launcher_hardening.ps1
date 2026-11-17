$ErrorActionPreference = 'Stop'
# Regression tests for scripts/windows_launcher.ps1 and frantastic.ps1:
# .env validation, secret-override handling, environment forwarding and
# restoration, native stderr/exit-code handling, Docker readiness. Fake Docker
# invokers and dummy values only; nothing here talks to Docker.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repoRoot 'scripts/windows_launcher.ps1')

if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    throw "These tests must run under Windows PowerShell 5.1 (powershell.exe); this is $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)."
}
Write-Host "PASS: running under Windows PowerShell $($PSVersionTable.PSVersion)"

$script:Passed = 0
$script:Markers = New-Object 'System.Collections.Generic.List[string]'
$script:Observed = New-Object 'System.Collections.Generic.List[string]'
function New-Marker([string] $Prefix) {
    $marker = $Prefix + [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $script:Markers.Add($marker)
    return $marker
}
function Pass([string] $Label) { $script:Passed++; Write-Host "PASS: $Label" }
function Assert-True([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "FAIL: $Label" }
    Pass $Label
}
function Assert-Throws([scriptblock] $Action, [string] $ExpectedMessage, [string] $Label) {
    $message = $null
    try { & $Action } catch { $message = $_.Exception.Message }
    if ($null -eq $message) { throw "FAIL: ${Label}: expected an error containing '$ExpectedMessage'." }
    $script:Observed.Add($message)
    if ($message -notlike "*$ExpectedMessage*") { throw "FAIL: ${Label}: unexpected error: $message" }
    Pass $Label
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('FRANtastic Launcher Tests ' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$probeName = 'FRT_TEST_VAR_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$userScopeBefore = [Environment]::GetEnvironmentVariable($probeName, 'User')
$userRootBefore = [Environment]::GetEnvironmentVariable('MARIADB_ROOT_PASSWORD', 'User')
$processRootBefore = [Environment]::GetEnvironmentVariable('MARIADB_ROOT_PASSWORD', 'Process')

function Write-EnvFile([string] $Name, [string] $Content, [Text.Encoding] $Encoding) {
    if ($null -eq $Encoding) { $Encoding = New-Object Text.UTF8Encoding($false) }
    $path = Join-Path $root $Name
    [IO.File]::WriteAllText($path, $Content, $Encoding)
    return $path
}
function New-EnvContent([string] $Root, [string] $App, [string] $Key) {
    return "# comment`nMARIADB_ROOT_PASSWORD=$Root`nCAMPUS_APP_PASSWORD=$App`nSECRET_KEY=$Key`nMARIADB_PORT=3307`nDB_PASSWORD=$App`n"
}

try {
    # ------------------------------------------------------------ .env validation
    $rootValue = 'r' + (New-Marker 'aa')
    $appValue = 'a' + (New-Marker 'bb')
    $keyValue = New-Marker 'cc'
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'generated.env' (New-EnvContent $rootValue $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $rootValue -and $values['SECRET_KEY'] -ceq $keyValue) 'generated-style .env is accepted unchanged'

    $special = 'p!@#%^&*()_+-=[]{};:,.<>?/~|' + (New-Marker 'dd')
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'special.env' (New-EnvContent $special $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $special) 'special characters (without $) are accepted unquoted and not altered'

    # Compose interpolates $ in unquoted and double-quoted values; the launcher
    # does not evaluate references, so it must reject them, never accept them
    # as a literal that Compose would resolve differently (or to empty).
    $unset = 'FRT_UNSET_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    Assert-True ($null -eq [Environment]::GetEnvironmentVariable($unset, 'Process')) 'the unset-variable fixture is really unset'
    $refCases = [ordered]@{
        'unquoted ${ROOT_SECRET}' = '${ROOT_SECRET}'
        'double-quoted "${ROOT_SECRET}"' = '"${ROOT_SECRET}"'
        'unquoted reference to an unset variable' = ('${' + $unset + '}')
        'unquoted $NAME form of an unset variable' = ('$' + $unset)
        'double-quoted reference to an unset variable with a comment' = ('"${' + $unset + '}" # comment')
        'unquoted $ inside a password' = ('p$%' + (New-Marker 'hh'))
    }
    foreach ($case in $refCases.Keys) {
        $content = "ROOT_SECRET=$rootValue`n" + (New-EnvContent $refCases[$case] $appValue $keyValue)
        Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'interp.env' $content) } "contains '`$', which Docker Compose treats as a variable reference" "interpolation rejected: $case"
        Assert-True ($script:Observed[$script:Observed.Count - 1] -notlike '*ROOT_SECRET}*' -and $script:Observed[$script:Observed.Count - 1] -notlike "*$unset*") "rejection message for '$case' does not echo the value"
    }
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'sq-ref.env' ("ROOT_SECRET=$rootValue`n" + (New-EnvContent "'`${ROOT_SECRET}'" $appValue $keyValue)))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq '${ROOT_SECRET}') "single-quoted '`${ROOT_SECRET}' is accepted as the literal text (Compose does not interpolate it)"
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'other-key-ref.env' ((New-EnvContent $rootValue $appValue $keyValue) + "DB_HOST=`${$unset}`n"))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $rootValue) 'a reference in a non-secret key does not block the launcher'

    $inner = 'pass word ' + (New-Marker 'ee')
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'spaces.env' (New-EnvContent ('  ' + $inner + '  ') $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $inner) 'unquoted value: spaces around it are ignored (as Compose does), inner spaces kept'
    $padded = '  spaced ' + (New-Marker 'ef') + '  '
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'quoted-spaces.env' (New-EnvContent ('"' + $padded + '"') $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $padded) 'quoted value: intentional leading/trailing whitespace is preserved'

    $plain = New-Marker 'ff'
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'quoted.env' (New-EnvContent ("'" + $plain + "'") $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $plain) 'a single-quoted value is accepted without its quotes'

    # Compose's documented inline-comment rules (docs.docker.com, .env syntax)
    $c = New-Marker 'gg'
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'dq-comment.env' (New-EnvContent ('"' + $c + '" # comment') $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $c) 'VAR="VAL" # comment: the comment after the closing quote is ignored'
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'sq-comment.env' (New-EnvContent ("'" + $c + "'   # comment") $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $c) "VAR='VAL' # comment: the comment after the closing quote is ignored"
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'dq-hash.env' (New-EnvContent ('"' + $c + ' # not a comment"') $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq ($c + ' # not a comment')) "'#' inside a quoted value is kept"
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'uq-hash.env' (New-EnvContent ($c + '#not-a-comment') $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq ($c + '#not-a-comment')) "VAL#x: '#' without preceding whitespace is part of an unquoted value"
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'uq-comment.env' (New-EnvContent ($c + ' # comment') $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $c) 'VAL # comment: an unquoted value ends at a whitespace-preceded #'
    $sq = 'p #!@$%^&*() x' + (New-Marker 'gh')
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'sq-special.env' (New-EnvContent ("'" + $sq + "'") $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $sq) "special characters, '#' and spaces inside single quotes are kept literally"
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'dq-escape.env' (New-EnvContent ('"a\"b\\c' + $c + '"') $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq ('a"b\c' + $c)) 'double-quoted escapes \" and \\ are interpreted'
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'sq-escape.env' (New-EnvContent ("'it\'s" + $c + "'") $appValue $keyValue))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq ("it's" + $c)) "an escaped quote inside single quotes is interpreted"
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'spaced-eq.env' ("CAMPUS_APP_PASSWORD=$appValue`nMARIADB_ROOT_PASSWORD = $rootValue`nSECRET_KEY=$keyValue`n"))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $rootValue) "'KEY = value' (documented Compose syntax) is accepted"
    $values = Read-FrantasticEnvironment -Path (Write-EnvFile 'colon.env' ("MARIADB_ROOT_PASSWORD: $rootValue`nCAMPUS_APP_PASSWORD=$appValue`nSECRET_KEY=$keyValue`n"))
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $rootValue) "'KEY: value' (documented Compose syntax) is accepted"
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'dq-junk.env' (New-EnvContent ('"' + $c + '" trailing') $appValue $keyValue)) } 'unexpected text after the closing quote' 'text after a closing quote (other than a comment) is rejected'
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'only-comment.env' (New-EnvContent ' # only a comment' $appValue $keyValue)) } 'empty or contains only whitespace' 'a value that is only a comment counts as empty'

    $bomPath = Write-EnvFile 'bom-crlf.env' ((New-EnvContent $rootValue $appValue $keyValue) -replace "`n", "`r`n") (New-Object Text.UTF8Encoding($true))
    $values = Read-FrantasticEnvironment -Path $bomPath
    Assert-True ($values['MARIADB_ROOT_PASSWORD'] -ceq $rootValue) 'UTF-8 BOM and CRLF line endings are handled'

    Assert-Throws { Read-FrantasticEnvironment -Path (Join-Path $root 'absent.env') } 'No .env file' 'missing .env file is reported'
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'no-root.env' "CAMPUS_APP_PASSWORD=$appValue`nSECRET_KEY=$keyValue`n") } 'does not define MARIADB_ROOT_PASSWORD' 'missing root secret is rejected'
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'empty.env' (New-EnvContent '' $appValue $keyValue)) } 'MARIADB_ROOT_PASSWORD is empty or contains only whitespace' 'empty root secret is rejected'
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'blank.env' (New-EnvContent "  `t " $appValue $keyValue)) } 'empty or contains only whitespace' 'whitespace-only root secret is rejected'
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'empty-quotes.env' (New-EnvContent '""' $appValue $keyValue)) } 'empty or contains only whitespace' 'empty quoted root secret is rejected'
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'unclosed.env' (New-EnvContent ('"' + $rootValue) $appValue $keyValue)) } 'not closed' 'unclosed quote is rejected'
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'export.env' ("export MARIADB_ROOT_PASSWORD=$rootValue`nCAMPUS_APP_PASSWORD=$appValue`nSECRET_KEY=$keyValue`n")) } 'line 1: unsupported syntax for MARIADB_ROOT_PASSWORD' "'export KEY=value' is rejected with its line number"
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'dup.env' ((New-EnvContent $rootValue $appValue $keyValue) + "MARIADB_ROOT_PASSWORD=$special`n")) } 'more than once (lines 2 and 7)' 'duplicate root secret is rejected'
    Assert-Throws { Read-FrantasticEnvironment -Path (Write-EnvFile 'no-key.env' "MARIADB_ROOT_PASSWORD=$rootValue`nCAMPUS_APP_PASSWORD=$appValue`n") } 'does not define SECRET_KEY' 'other required secrets are checked too'

    # ------------------------------------------------------------ secret overrides
    $override = New-Marker 'override'
    [Environment]::SetEnvironmentVariable('MARIADB_ROOT_PASSWORD', $override, 'Process')
    $notice = @(Clear-FrantasticSecretOverrides 6>&1)
    $saved = @($notice | Where-Object { $_ -is [hashtable] })[0]
    $text = (@($notice | Where-Object { $_ -isnot [hashtable] }) | ForEach-Object { [string]$_ }) -join ' '
    $script:Observed.Add($text)
    Assert-True ($null -eq [Environment]::GetEnvironmentVariable('MARIADB_ROOT_PASSWORD', 'Process')) 'process override of a secret is removed before Docker runs'
    Assert-True ($text -like '*Ignoring MARIADB_ROOT_PASSWORD*' -and $text -notlike "*$override*") 'override notice names the variable but not its value'
    Restore-FrantasticProcessEnvironment $saved
    Assert-True ([Environment]::GetEnvironmentVariable('MARIADB_ROOT_PASSWORD', 'Process') -ceq $override) 'override is restored afterwards'
    [Environment]::SetEnvironmentVariable('MARIADB_ROOT_PASSWORD', $processRootBefore, 'Process')
    $noneSaved = Clear-FrantasticSecretOverrides -Names @($probeName)
    Assert-True ($noneSaved.Count -eq 0 -and $null -eq [Environment]::GetEnvironmentVariable($probeName, 'Process')) 'absent variables stay absent'

    # ------------------------------------------------------------ native commands
    $fake = Join-Path $root 'fake docker.cmd'
    $fakeLines = @(
        '@echo off',
        'if "%~1"=="ok" (echo out-line& echo err-line 1>&2& exit /b 0)',
        'if "%~1"=="fail" (echo out-line& echo err-line 1>&2& exit /b 7)',
        ('if "%~1"=="env" ((if defined ' + $probeName + ' (echo PRESENT) else (echo ABSENT))& exit /b 0)'),
        ('if "%~1"=="envfail" ((if defined ' + $probeName + ' (echo PRESENT) else (echo ABSENT))& exit /b 5)'),
        'exit /b 9'
    )
    [IO.File]::WriteAllText($fake, (($fakeLines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)

    $r = Invoke-FrantasticNativeWithTimeout -FilePath $fake -Arguments @('ok') -TimeoutSeconds 30
    Assert-True ($r.ExitCode -eq 0 -and -not $r.TimedOut -and (@($r.Output) -contains 'out-line') -and ((@($r.ErrorOutput) -join '') -like '*err-line*')) 'stderr with exit 0 is captured, not thrown (ErrorActionPreference=Stop)'
    $r = Invoke-FrantasticNativeWithTimeout -FilePath $fake -Arguments @('fail') -TimeoutSeconds 30
    Assert-True ($r.ExitCode -eq 7 -and (@($r.Output) -contains 'out-line') -and ((@($r.ErrorOutput) -join '') -like '*err-line*')) 'stderr with a failure exit code keeps the exit code and both streams'
    Assert-True ((@($r.Output) -join '') -notlike '*err-line*') 'stdout does not contain stderr lines'
    Assert-Throws { Invoke-FrantasticNativeWithTimeout -FilePath (Join-Path $root 'missing-docker.exe') } 'Program not found' 'missing program is reported instead of a stale exit code'
    Assert-True ((ConvertTo-FrantasticArgumentString @('info', '--format', '{{.OSType}}', 'a b', 'q"x', 'tail\', '')) -ceq 'info --format {{.OSType}} "a b" "q\"x" tail\ ""') 'arguments are quoted for the Windows command line'

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $clockWatch = [Diagnostics.Stopwatch]::StartNew()
    $hung = Invoke-FrantasticNativeWithTimeout -FilePath $windowsPowerShell -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120') -TimeoutSeconds 2
    $clockWatch.Stop()
    Assert-True ($hung.TimedOut -and $hung.ExitCode -eq -1) 'a hanging probe is reported as timed out'
    Assert-True ($clockWatch.Elapsed.TotalSeconds -lt 12) "a hanging probe returns within its time limit (took $([int]$clockWatch.Elapsed.TotalSeconds) s for a 2 s limit)"
    Assert-True ($null -eq (Get-Process -Id $hung.ProcessId -ErrorAction SilentlyContinue)) 'the timed-out process was terminated'

    # Process tree: the parent starts a child that shares its stdout/stderr
    # handles, records the child's PID, then hangs. Both must be terminated
    # (taskkill /T /F; Process.Kill(Boolean) does not exist on .NET Framework).
    $childPidFile = Join-Path $root 'child pid.txt'
    $parentCommand = "`$c = Start-Process -FilePath '$windowsPowerShell' -ArgumentList '-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 120' -NoNewWindow -PassThru; [IO.File]::WriteAllText('$childPidFile', [string]`$c.Id); Start-Sleep -Seconds 120"
    $treeWatch = [Diagnostics.Stopwatch]::StartNew()
    $tree = Invoke-FrantasticNativeWithTimeout -FilePath $windowsPowerShell -Arguments @('-NoProfile', '-NonInteractive', '-Command', $parentCommand) -TimeoutSeconds 6
    $treeWatch.Stop()
    $childPid = 0
    if (Test-Path -LiteralPath $childPidFile) { $childPid = [int]([IO.File]::ReadAllText($childPidFile).Trim()) }
    try {
        Assert-True ($childPid -gt 0) 'process-tree fixture: the parent started a child and recorded its PID before the timeout'
        Assert-True ($tree.TimedOut) 'process-tree fixture: the parent timed out'
        Start-Sleep -Milliseconds 500
        Assert-True ($null -eq (Get-Process -Id $tree.ProcessId -ErrorAction SilentlyContinue)) 'timed-out parent process was terminated'
        Assert-True ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'its child process (holding the same output pipe) was terminated too'
        Assert-True ($treeWatch.Elapsed.TotalSeconds -lt 20) "process-tree timeout returned in $([int]$treeWatch.Elapsed.TotalSeconds) s for a 6 s limit"
    } finally {
        if ($childPid -gt 0) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
    }
    $r = Invoke-FrantasticNativeWithTimeout -FilePath $windowsPowerShell -Arguments @('-NoProfile', '-NonInteractive', '-Command', "[Console]::Out.WriteLine('real-out'); [Console]::Error.WriteLine('real-err'); exit 3") -TimeoutSeconds 60
    Assert-True ($r.ExitCode -eq 3 -and -not $r.TimedOut -and (@($r.Output) -contains 'real-out') -and (@($r.ErrorOutput) -contains 'real-err')) 'a real executable: stdout, stderr and exit code are captured separately'

    $streamed = @(Invoke-Docker -Arguments @('env') -DockerCommand $fake)
    Assert-True ($streamed -contains 'ABSENT') 'Invoke-Docker passes stdout through'
    Assert-Throws { Invoke-Docker -Arguments @('fail') -DockerCommand $fake } 'exit code 7' 'Invoke-Docker reports the native exit code'

    # ------------------------------------------------------------ environment forwarding
    $forward = New-Marker 'fwd'
    $seen = @(Invoke-DockerWithEnvironment -Environment @{ $probeName = $forward } -Arguments @('env') -DockerCommand $fake)
    Assert-True ($seen -contains 'PRESENT') 'child process receives the forwarded variable'
    Assert-True ($null -eq [Environment]::GetEnvironmentVariable($probeName, 'Process')) 'a variable that did not exist before is absent afterwards'

    $before = New-Marker 'before'
    [Environment]::SetEnvironmentVariable($probeName, $before, 'Process')
    [void](Invoke-DockerWithEnvironment -Environment @{ $probeName = $forward } -Arguments @('env') -DockerCommand $fake)
    Assert-True ([Environment]::GetEnvironmentVariable($probeName, 'Process') -ceq $before) 'a pre-existing value is restored afterwards'
    Assert-Throws { Invoke-DockerWithEnvironment -Environment @{ $probeName = $forward } -Arguments @('envfail') -DockerCommand $fake } 'exit code 5' 'failing Docker call is reported'
    Assert-True ([Environment]::GetEnvironmentVariable($probeName, 'Process') -ceq $before) 'value is restored after a failing Docker call'
    Assert-Throws { Invoke-DockerWithEnvironment -Environment @{ $probeName = '' } -Arguments @('env') -DockerCommand $fake } 'no value to forward' 'an empty value is refused instead of forwarding an absent variable'
    Assert-Throws { Invoke-DockerWithEnvironment -Environment @{ $probeName = $null } -Arguments @('env') -DockerCommand $fake } 'no value to forward' 'a null value is refused'
    Assert-True ([Environment]::GetEnvironmentVariable($probeName, 'Process') -ceq $before) 'a refused call leaves the environment unchanged'
    [Environment]::SetEnvironmentVariable($probeName, $null, 'Process')

    # ------------------------------------------------------------ Docker CLI and Compose
    Assert-Throws { Assert-FrantasticDockerCli -Resolver { $null } } 'not found on PATH' 'missing Docker CLI is explained'
    Assert-FrantasticDockerCli -Resolver { [pscustomobject]@{ Source = 'docker.exe' } }
    Pass 'resolved Docker CLI is accepted'
    Assert-Throws { Assert-FrantasticDockerCompose -DockerInvoker { param($a) [pscustomobject]@{ Output = @(); ErrorOutput = @("docker: 'compose' is not a docker command."); ExitCode = 1 } } } "Docker Compose V2 is unavailable ('docker compose version' exited with 1: docker: 'compose' is not a docker command.)" 'missing Compose plugin is explained with the Docker message'

    # ------------------------------------------------------------ Docker readiness
    # Shared by reference: GetNewClosure() gives the fake invoker its own scope.
    $ctx = @{ Now = [DateTime]::new(2026, 11, 11, 0, 0, 0, [DateTimeKind]::Utc); Sleeps = 0; Calls = 0 }
    $clock = { $ctx.Now }.GetNewClosure()
    $sleep = { param([int] $Seconds) $ctx.Sleeps++; $ctx.Now = $ctx.Now.AddSeconds($Seconds) }.GetNewClosure()
    $pipeError = 'failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine; check if the path is correct and if the daemon is running: open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified.'
    function Reset-Clock { $ctx.Sleeps = 0; $ctx.Calls = 0 }
    function New-Invoker([int] $FailuresBeforeReady, [string] $OsType, [string] $ErrorText) {
        # GetNewClosure() copies only this function's local variables; make the
        # shared context one of them (same hashtable, by reference).
        $ctx = $ctx
        return {
            param([string[]] $Arguments)
            $ctx.Calls++
            if ($ctx.Calls -gt 200) { throw 'readiness loop did not terminate' }
            if (($Arguments -join ' ') -cne 'info --format {{.OSType}}') { throw "unexpected docker call: $($Arguments -join ' ')" }
            if ($FailuresBeforeReady -lt 0 -or $ctx.Calls -le $FailuresBeforeReady) {
                return [pscustomobject]@{ Output = @(); ErrorOutput = @($ErrorText); ExitCode = 1 }
            }
            return [pscustomobject]@{ Output = @($OsType); ErrorOutput = @('WARNING: a harmless engine warning'); ExitCode = 0 }
        }.GetNewClosure()
    }

    $desktopTarget = { [pscustomobject]@{ HostOverride = $false; Name = 'desktop-linux' } }
    Reset-Clock
    Wait-FrantasticDockerEngine -DockerInvoker (New-Invoker 0 'linux' '') -DesktopProbe { $true } -TargetProbe $desktopTarget -Sleep $sleep -Clock $clock
    Assert-True ($ctx.Sleeps -eq 0 -and $ctx.Calls -eq 1) 'ready engine (with stderr warning and exit 0) passes at once'

    Reset-Clock
    $progress = @(Wait-FrantasticDockerEngine -DockerInvoker (New-Invoker 2 'linux' $pipeError) -DesktopProbe { $true } -TargetProbe $desktopTarget -Sleep $sleep -Clock $clock -TimeoutSeconds 30 -IntervalSeconds 3 6>&1) -join ' '
    Assert-True ($ctx.Sleeps -eq 2 -and $ctx.Calls -eq 3) 'starting engine is retried until it answers'
    Assert-True ($progress -like '*waiting up to 30 seconds*' -and $progress -like '*engine is ready*') 'starting engine shows concise progress'

    Reset-Clock
    Assert-Throws { Wait-FrantasticDockerEngine -DockerInvoker (New-Invoker -1 'linux' $pipeError) -DesktopProbe { $false } -TargetProbe $desktopTarget -Sleep $sleep -Clock $clock } "context 'desktop-linux' is not reachable and no Docker Desktop process is running" 'Desktop context without a Docker Desktop process fails at once'
    Assert-True ($ctx.Sleeps -eq 0) 'no waiting when no Docker Desktop process exists'

    Reset-Clock
    Assert-Throws { Wait-FrantasticDockerEngine -DockerInvoker (New-Invoker -1 'linux' $pipeError) -DesktopProbe { $true } -TargetProbe $desktopTarget -Sleep $sleep -Clock $clock -TimeoutSeconds 10 -IntervalSeconds 3 6>$null } 'did not respond within 10 seconds' 'engine that never answers times out'
    Assert-True ($ctx.Sleeps -eq 4 -and $ctx.Calls -eq 5) 'timeout is bounded by the deadline'
    Assert-True ($script:Observed[$script:Observed.Count - 1] -like '*Last Docker message: failed to connect to the docker API*') 'timeout reports the last Docker message'

    Reset-Clock
    Assert-Throws { Wait-FrantasticDockerEngine -DockerInvoker (New-Invoker 0 'windows' '') -DesktopProbe { $true } -TargetProbe $desktopTarget -Sleep $sleep -Clock $clock } 'Windows containers' 'Windows-containers mode is rejected with a fix'

    Reset-Clock
    Assert-Throws { Wait-FrantasticDockerEngine -DockerInvoker (New-Invoker -1 'linux' 'open //./pipe/dockerDesktopLinuxEngine: Access is denied.') -DesktopProbe { $true } -TargetProbe $desktopTarget -Sleep $sleep -Clock $clock } 'docker-users group' 'permanent access error is not retried'
    Assert-True ($ctx.Sleeps -eq 0) 'permanent error causes no waiting'

    # Engines that Docker Desktop does not provide: no claim about Docker Desktop, no waiting.
    $ctx.DesktopChecks = 0
    $countingDesktop = { $ctx.DesktopChecks++; $false }.GetNewClosure()
    Reset-Clock
    Assert-Throws { Wait-FrantasticDockerEngine -DockerInvoker (New-Invoker -1 'linux' 'Cannot connect to the Docker daemon at tcp://lab-host:2376.') -DesktopProbe $countingDesktop -TargetProbe { [pscustomobject]@{ HostOverride = $true; Name = $null } } -Sleep $sleep -Clock $clock } 'selected by the DOCKER_HOST environment variable is not reachable' 'DOCKER_HOST engine failure names DOCKER_HOST'
    $hostMessage = $script:Observed[$script:Observed.Count - 1]
    Assert-True ($hostMessage -notlike '*Docker Desktop is not running*' -and $hostMessage -notlike '*no Docker Desktop process*' -and $ctx.DesktopChecks -eq 0 -and $ctx.Sleeps -eq 0) 'DOCKER_HOST case does not claim or check Docker Desktop and does not wait'
    Reset-Clock
    Assert-Throws { Wait-FrantasticDockerEngine -DockerInvoker (New-Invoker -1 'linux' 'error during connect: ssh: connect to host lab-host port 22: Connection refused') -DesktopProbe $countingDesktop -TargetProbe { [pscustomobject]@{ HostOverride = $false; Name = 'remote-lab' } } -Sleep $sleep -Clock $clock } "active context 'remote-lab' is not reachable" 'non-Desktop context failure names the context'
    $contextMessage = $script:Observed[$script:Observed.Count - 1]
    Assert-True ($contextMessage -like '*did not wait for Docker Desktop*' -and $contextMessage -notlike '*no Docker Desktop process*' -and $ctx.DesktopChecks -eq 0 -and $ctx.Sleeps -eq 0) 'non-Desktop context does not claim or check Docker Desktop and does not wait'
    Reset-Clock
    Assert-Throws { Wait-FrantasticDockerEngine -DockerInvoker (New-Invoker -1 'linux' $pipeError) -DesktopProbe $countingDesktop -TargetProbe { [pscustomobject]@{ HostOverride = $false; Name = $null } } -Sleep $sleep -Clock $clock } 'active Docker context could not be determined' 'undeterminable context is reported as such'

    # Per-probe time limit: a probe that hangs consumes at most its limit and never exceeds the time left.
    $ctx.ProbeLimits = New-Object 'System.Collections.Generic.List[int]'
    $hangingInvoker = {
        param([string[]] $Arguments, [int] $ProbeSeconds)
        $ctx.ProbeLimits.Add($ProbeSeconds)
        if ($ctx.ProbeLimits.Count -gt 50) { throw 'readiness loop did not terminate' }
        $ctx.Now = $ctx.Now.AddSeconds($ProbeSeconds)
        [pscustomobject]@{ Output = @(); ErrorOutput = @(); ExitCode = -1; TimedOut = $true }
    }.GetNewClosure()
    Reset-Clock
    $startedAt = $ctx.Now
    Assert-Throws { Wait-FrantasticDockerEngine -DockerInvoker $hangingInvoker -DesktopProbe { $true } -TargetProbe $desktopTarget -Sleep $sleep -Clock $clock -TimeoutSeconds 10 -IntervalSeconds 3 -ProbeTimeoutSeconds 4 6>$null } "did not answer within 3 seconds" 'hanging probes end in the deadline message'
    Assert-True ((@($ctx.ProbeLimits) -join ',') -ceq '4,3' -and ($ctx.Now - $startedAt).TotalSeconds -le 10) "each probe is limited to min(probe limit, time left): $(@($ctx.ProbeLimits) -join ',') s within a 10 s deadline"

    $realHang = { param([string[]] $Arguments, [int] $ProbeSeconds) Invoke-FrantasticNativeWithTimeout -FilePath $windowsPowerShell -Arguments @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 120') -TimeoutSeconds $ProbeSeconds }.GetNewClosure()
    $clockWatch = [Diagnostics.Stopwatch]::StartNew()
    Assert-Throws { Wait-FrantasticDockerEngine -DockerInvoker $realHang -DesktopProbe { $true } -TargetProbe $desktopTarget -Sleep { param([int] $Seconds) Start-Sleep -Seconds $Seconds } -TimeoutSeconds 4 -IntervalSeconds 1 -ProbeTimeoutSeconds 2 6>$null } 'did not respond within 4 seconds' 'real hanging processes cannot defeat the overall deadline'
    $clockWatch.Stop()
    Assert-True ($clockWatch.Elapsed.TotalSeconds -lt 20) "overall wait with hanging probes stays bounded (took $([int]$clockWatch.Elapsed.TotalSeconds) s for a 4 s deadline)"

    # ------------------------------------------------------------ launcher wiring
    $launcher = [IO.File]::ReadAllText((Join-Path $repoRoot 'frantastic.ps1'))
    Assert-True ($launcher -notmatch '\*>\s*\$null') 'launcher no longer discards native output with *> $null'
    Assert-True ($launcher -notmatch 'MYSQL_PWD') 'launcher forwards no root password from the host'
    Assert-True ($launcher -match 'Wait-FrantasticDockerEngine' -and $launcher -match 'Clear-FrantasticSecretOverrides') 'launcher uses the bounded readiness wait and the .env-only secret rule'

    # ------------------------------------------------------------ hygiene
    $leaks = @($script:Observed | Where-Object { $text = $_; @($script:Markers | Where-Object { $text -like "*$_*" }).Count -gt 0 })
    Assert-True ($leaks.Count -eq 0) 'no dummy secret appears in any diagnostic'
} finally {
    [Environment]::SetEnvironmentVariable($probeName, $null, 'Process')
    [Environment]::SetEnvironmentVariable('MARIADB_ROOT_PASSWORD', $processRootBefore, 'Process')
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Assert-True ([Environment]::GetEnvironmentVariable($probeName, 'User') -ceq $userScopeBefore -and [Environment]::GetEnvironmentVariable('MARIADB_ROOT_PASSWORD', 'User') -ceq $userRootBefore) 'no user-level environment variable was changed'
Write-Host "Launcher hardening tests: $script:Passed checks passed."
