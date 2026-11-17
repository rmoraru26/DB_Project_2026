# Launcher helpers for frantastic.ps1 (Windows PowerShell 5.1). Kept in a
# separate dot-sourced file so tests/windows/test_launcher_hardening.ps1 can
# exercise them with fake Docker invokers and dummy values only.

$FrantasticRequiredSecrets = @('MARIADB_ROOT_PASSWORD', 'CAMPUS_APP_PASSWORD', 'SECRET_KEY')

# Quotes arguments for a Windows command line (CommandLineToArgvW rules).
function ConvertTo-FrantasticArgumentString([string[]] $Arguments) {
    $parts = foreach ($argument in @($Arguments)) {
        if ($argument -eq '') { '""' }
        elseif ($argument -notmatch '[\s"]') { $argument }
        else {
            $escaped = [regex]::Replace($argument, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
            $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
            '"' + $escaped + '"'
        }
    }
    return (@($parts) -join ' ')
}

# Runs a native program with a time limit and captures stdout, stderr and the
# exit code separately; stderr text never becomes a PowerShell error (Windows
# PowerShell 5.1 turns redirected native stderr into ErrorRecords, which are
# terminating under $ErrorActionPreference = 'Stop'). A program that does not
# exit in time is terminated together with its child processes and reported
# with TimedOut = $true. Used for short probes (docker info, version, context),
# never for commands whose output the user should see live.
function Invoke-FrantasticNativeWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $Arguments = @(),
        [int] $TimeoutSeconds = 15
    )
    $command = Get-Command $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { throw "Program not found: $FilePath" }
    $path = $command.Path
    $argumentText = ConvertTo-FrantasticArgumentString $Arguments
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    if ($path -match '\.(cmd|bat)$') {
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /s /c ""' + $path + '" ' + $argumentText + '"'
    } else {
        $startInfo.FileName = $path
        $startInfo.Arguments = $argumentText
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $processId = $process.Id
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
        if ($timedOut) {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { [void](& "$env:SystemRoot\System32\taskkill.exe" /PID $processId /T /F 2>&1) } finally { $ErrorActionPreference = $previous }
            if (-not $process.HasExited) { try { $process.Kill() } catch { } }
            [void]$process.WaitForExit(5000)
            $exitCode = -1
        } else {
            $process.WaitForExit()
            $exitCode = $process.ExitCode
        }
        $stdout = if ($stdoutTask.Wait(2000)) { $stdoutTask.Result } else { '' }
        $stderr = if ($stderrTask.Wait(2000)) { $stderrTask.Result } else { '' }
    } finally { $process.Dispose() }
    $split = { param([string] $Text) @(($Text -split "\r?\n") | Where-Object { $_ -ne '' }) }
    return [pscustomobject]@{
        Output = [string[]](& $split $stdout); ErrorOutput = [string[]](& $split $stderr)
        ExitCode = $exitCode; TimedOut = $timedOut; ProcessId = $processId
    }
}

# First non-empty diagnostic line, shortened; Docker's engine/CLI messages do
# not contain project secrets, but keep the text bounded.
function Get-FrantasticFirstLine([string[]] $Lines) {
    foreach ($line in @($Lines)) {
        $text = ([string]$line).Trim()
        if ($text) {
            if ($text.Length -gt 300) { $text = $text.Substring(0, 300) + '...' }
            return $text
        }
    }
    return '(no message)'
}

# Streams a Docker command's output to the console (or to the caller's
# pipeline) and fails on a non-zero exit code.
function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [string] $DockerCommand = 'docker'
    )
    & $DockerCommand @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Docker command failed with exit code $exitCode. See the output above."
    }
}

# Sets variables in this process only, for one Docker call that forwards them
# by name (-e NAME), and restores the previous values afterwards. An empty
# value is refused: on Windows it would delete the variable, and Docker would
# then silently forward nothing.
function Invoke-DockerWithEnvironment {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Environment,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [string] $DockerCommand = 'docker'
    )
    foreach ($name in $Environment.Keys) {
        if ([string]::IsNullOrEmpty([string]$Environment[$name])) {
            throw "Internal error: no value to forward for $name; refusing to run Docker without it."
        }
    }
    $previous = @{}
    foreach ($name in $Environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        foreach ($name in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, [string]$Environment[$name], 'Process')
        }
        Invoke-Docker -Arguments $Arguments -DockerCommand $DockerCommand
    } finally {
        foreach ($name in $Environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process')
        }
    }
}

# Interprets the text after "KEY=" the way Docker Compose documents for .env
# files: spaces around the value are ignored; an unquoted value ends at an
# inline comment, which must be preceded by whitespace (VAL#x is a value, not a
# comment); a quoted value keeps everything between its quotes, including '#'
# and spaces, and may be followed only by whitespace and a comment. Double
# quotes support \" \\ \n \r \t; single quotes are literal except \'.
# Returns @{ Value; Error; Interpolated }; Error never contains the value.
# Interpolated is $true for an unquoted or double-quoted value containing '$':
# Compose substitutes variable references there (an unset one becomes empty),
# which this parser does not evaluate; only single-quoted values are literal.
# Multi-line quoted values are not supported.
function ConvertFrom-FrantasticDotenvValue([string] $Raw) {
    $text = $Raw.Trim()
    if ($text.Length -gt 0 -and ($text[0] -eq [char]'"' -or $text[0] -eq [char]"'")) {
        $quote = $text[0]
        $builder = New-Object Text.StringBuilder
        $closed = $false
        $i = 1
        while ($i -lt $text.Length) {
            $c = $text[$i]
            if ($c -eq [char]'\' -and $i + 1 -lt $text.Length) {
                $next = $text[$i + 1]
                if ($quote -eq [char]'"') {
                    switch -CaseSensitive ([string]$next) {
                        'n' { [void]$builder.Append("`n") } 'r' { [void]$builder.Append("`r") } 't' { [void]$builder.Append("`t") }
                        '\' { [void]$builder.Append('\') } '"' { [void]$builder.Append('"') }
                        default { [void]$builder.Append('\').Append($next) }
                    }
                } elseif ($next -eq [char]"'") { [void]$builder.Append("'") }
                else { [void]$builder.Append('\').Append($next) }
                $i += 2
                continue
            }
            if ($c -eq $quote) { $closed = $true; break }
            [void]$builder.Append($c)
            $i++
        }
        if (-not $closed) { return @{ Value = $null; Error = 'starts a quoted value that is not closed on this line (multi-line values are not supported here)'; Interpolated = $false } }
        $rest = $text.Substring($i + 1).Trim()
        if ($rest.Length -gt 0 -and -not $rest.StartsWith('#')) { return @{ Value = $null; Error = 'has unexpected text after the closing quote (only a # comment may follow)'; Interpolated = $false } }
        $value = $builder.ToString()
        return @{ Value = $value; Error = $null; Interpolated = ($quote -eq [char]'"' -and $value.Contains('$')) }
    }
    $comment = [regex]::Match($Raw, '(?<=\s)#')
    if ($comment.Success) { $text = $Raw.Substring(0, $comment.Index).Trim() }
    return @{ Value = $text; Error = $null; Interpolated = $text.Contains('$') }
}

# Validates .env for the launcher. Docker Compose reads .env itself and passes
# the secrets to the containers; the scripts inside the mariadb container take
# the root password from there. This check makes a missing, empty or
# unparsable definition of a required secret fail before anything starts, with
# the line number and never the value. Returns the interpreted values.
function Read-FrantasticEnvironment {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [string[]] $Required = $FrantasticRequiredSecrets
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "No .env file at '$Path'. Run '.\frantastic.cmd up' to create one with random secrets."
    }
    $values = @{}
    $lineNumbers = @{}
    $lines = [IO.File]::ReadAllLines($Path)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $number = $i + 1
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*[=:](.*)$') {
            $name = $Matches[1]
            $parsed = ConvertFrom-FrantasticDotenvValue $Matches[2]
            if ($Required -contains $name) {
                if ($lineNumbers.ContainsKey($name)) {
                    throw ".env defines $name more than once (lines $($lineNumbers[$name]) and $number). Keep exactly one definition."
                }
                $lineNumbers[$name] = $number
                if ($parsed.Error) { throw ".env line ${number}: the value of $name $($parsed.Error)." }
                if ($parsed.Interpolated) {
                    throw ".env line ${number}: the value of $name contains '`$', which Docker Compose treats as a variable reference in unquoted and double-quoted values (an unset variable becomes empty). The launcher does not evaluate such references. Write a literal value in single quotes ($name='...'), or a value without '`$'."
                }
            }
            $values[$name] = $parsed.Value
            continue
        }
        foreach ($name in $Required) {
            if ($line -match ('^\s*export\s+' + $name + '\s*[=:]')) {
                throw ".env line ${number}: unsupported syntax for $name. Write it as $name=value (without 'export')."
            }
        }
    }
    foreach ($name in $Required) {
        if (-not $values.ContainsKey($name)) {
            throw ".env does not define $name. Add a $name=... line or restore the .env you used before (values are not displayed)."
        }
        if ([string]::IsNullOrWhiteSpace([string]$values[$name])) {
            throw ".env line $($lineNumbers[$name]): $name is empty or contains only whitespace. Set a non-empty value or restore the .env you used before."
        }
    }
    return $values
}

# Docker Compose prefers a variable from the calling process environment over
# .env. The launcher follows the Makefile (`unexport`): .env is the only source
# of the project secrets, so session/user/system variables of the same name are
# removed from this process before Docker runs. The previous values are
# returned for Restore-FrantasticProcessEnvironment.
function Clear-FrantasticSecretOverrides {
    param([string[]] $Names = $FrantasticRequiredSecrets)
    $saved = @{}
    foreach ($name in $Names) {
        $current = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -ne $current) {
            $saved[$name] = $current
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
            Write-Host "Ignoring $name from the environment (value not shown); the launcher uses the value in .env."
        }
    }
    return $saved
}

function Restore-FrantasticProcessEnvironment([hashtable] $Saved) {
    if ($null -eq $Saved) { return }
    foreach ($name in $Saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, [string]$Saved[$name], 'Process')
    }
}

function Assert-FrantasticDockerCli {
    param([scriptblock] $Resolver)
    if ($null -eq $Resolver) {
        $Resolver = { Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    }
    $command = & $Resolver
    if ($null -eq $command) {
        throw "The Docker CLI (docker.exe) was not found on PATH. Install Docker Desktop for Windows; if it is already installed, open a new PowerShell window (the installer adds Docker Desktop's resources\bin folder to PATH) and retry."
    }
}

function Assert-FrantasticDockerCompose {
    param([scriptblock] $DockerInvoker)
    if ($null -eq $DockerInvoker) { $DockerInvoker = { param([string[]] $Arguments) Invoke-FrantasticNativeWithTimeout -FilePath 'docker' -Arguments $Arguments -TimeoutSeconds 30 } }
    $result = & $DockerInvoker @('compose', 'version')
    if ($result.ExitCode -ne 0) {
        $detail = if ($result.TimedOut) { "'docker compose version' did not answer within its time limit" } else { "'docker compose version' exited with $($result.ExitCode): $(Get-FrantasticFirstLine (@($result.ErrorOutput) + @($result.Output)))" }
        throw "Docker Compose V2 is unavailable ($detail). Update or repair Docker Desktop."
    }
}

function Test-FrantasticDockerDesktopProcess {
    return (@(Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue).Count -gt 0)
}

# Which engine the Docker CLI talks to: DOCKER_HOST (overrides every context;
# its value is never shown) or the active context ('docker context show',
# which honours DOCKER_CONTEXT). Name is $null when it cannot be determined.
function Get-FrantasticDockerTarget {
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable('DOCKER_HOST', 'Process'))) {
        return [pscustomobject]@{ HostOverride = $true; Name = $null }
    }
    $name = $null
    try {
        $result = Invoke-FrantasticNativeWithTimeout -FilePath 'docker' -Arguments @('context', 'show') -TimeoutSeconds 10
        if ($result.ExitCode -eq 0 -and @($result.Output).Count -gt 0) { $name = ([string]$result.Output[0]).Trim() }
    } catch { $name = $null }
    return [pscustomobject]@{ HostOverride = $false; Name = $name }
}

# Contexts whose engine Docker Desktop provides on Windows.
$FrantasticDesktopContexts = @('desktop-linux', 'desktop-windows', 'default')

# Waits, bounded, until the Docker engine answers. Every 'docker info' probe
# has its own time limit (never longer than the time left), so a probe that
# hangs cannot defeat the overall deadline. Distinguishes: engine ready (Linux
# containers), Windows-containers mode, permanent errors, an engine selected by
# DOCKER_HOST or by a context that Docker Desktop does not provide (reported at
# once, without claiming anything about Docker Desktop), no Docker Desktop
# process (verified), and Docker Desktop still starting (retried until the
# deadline). Every dependency is injectable for tests.
function Wait-FrantasticDockerEngine {
    param(
        [scriptblock] $DockerInvoker,
        [scriptblock] $DesktopProbe,
        [scriptblock] $TargetProbe,
        [scriptblock] $Sleep,
        [scriptblock] $Clock,
        [int] $TimeoutSeconds = 120,
        [int] $IntervalSeconds = 3,
        [int] $ProbeTimeoutSeconds = 15
    )
    if ($null -eq $DockerInvoker) { $DockerInvoker = { param([string[]] $Arguments, [int] $ProbeSeconds) Invoke-FrantasticNativeWithTimeout -FilePath 'docker' -Arguments $Arguments -TimeoutSeconds $ProbeSeconds } }
    if ($null -eq $DesktopProbe) { $DesktopProbe = { Test-FrantasticDockerDesktopProcess } }
    if ($null -eq $TargetProbe) { $TargetProbe = { Get-FrantasticDockerTarget } }
    if ($null -eq $Sleep) { $Sleep = { param([int] $Seconds) Start-Sleep -Seconds $Seconds } }
    if ($null -eq $Clock) { $Clock = { [DateTime]::UtcNow } }
    if ($TimeoutSeconds -lt 0) { $TimeoutSeconds = 0 }
    if ($IntervalSeconds -lt 1) { $IntervalSeconds = 1 }
    if ($ProbeTimeoutSeconds -lt 1) { $ProbeTimeoutSeconds = 1 }

    $start = & $Clock
    $deadline = $start.AddSeconds($TimeoutSeconds)
    $announced = $false
    $target = $null
    while ($true) {
        $remaining = [int][Math]::Ceiling(($deadline - (& $Clock)).TotalSeconds)
        $probeSeconds = [Math]::Max(1, [Math]::Min($ProbeTimeoutSeconds, $remaining))
        $result = & $DockerInvoker @('info', '--format', '{{.OSType}}') $probeSeconds
        if ($result.ExitCode -eq 0 -and -not $result.TimedOut) {
            $osType = (Get-FrantasticFirstLine $result.Output)
            if ($osType -ceq 'linux') {
                if ($announced) { Write-Host 'Docker engine is ready.' }
                return
            }
            if ($osType -ceq 'windows') {
                throw "Docker Desktop is using Windows containers. Switch to Linux containers (Docker Desktop tray icon > 'Switch to Linux containers...'), then retry."
            }
            throw "The Docker engine reported an unexpected container OS type: '$osType'. FRANtastic needs Linux containers."
        }
        if ($result.TimedOut) { $detail = "'docker info' did not answer within $probeSeconds seconds" }
        else { $detail = Get-FrantasticFirstLine (@($result.ErrorOutput) + @($result.Output)) }
        if (-not $result.TimedOut -and $detail -match 'context not found|Access is denied|permission denied') {
            throw "Docker cannot use its engine: $detail. Check the Docker context ('docker context ls') and that your account may use Docker Desktop (the docker-users group), then retry."
        }
        if ($null -eq $target) { $target = & $TargetProbe }
        if ($target.HostOverride) {
            throw "The Docker engine selected by the DOCKER_HOST environment variable is not reachable (Docker reported: $detail). While DOCKER_HOST is set, Docker Desktop's engine is not used and the launcher does not wait for it. Start that engine, or remove DOCKER_HOST (Remove-Item Env:DOCKER_HOST) to use Docker Desktop, then retry."
        }
        if ([string]::IsNullOrEmpty($target.Name)) {
            throw "The Docker engine is not reachable and the active Docker context could not be determined (Docker reported: $detail). Check 'docker context ls', then retry."
        }
        if ($FrantasticDesktopContexts -notcontains $target.Name) {
            throw "The Docker engine of the active context '$($target.Name)' is not reachable (Docker reported: $detail). Docker Desktop does not provide this context, so the launcher did not wait for Docker Desktop. Start that engine, or switch with 'docker context use desktop-linux', then retry."
        }
        if (-not (& $DesktopProbe)) {
            throw "The Docker engine of context '$($target.Name)' is not reachable and no Docker Desktop process is running (Docker reported: $detail). Start Docker Desktop, wait until it shows 'Engine running', then retry."
        }
        $now = & $Clock
        if ($now -ge $deadline) {
            throw "Docker Desktop is running, but the engine of context '$($target.Name)' did not respond within $TimeoutSeconds seconds. Wait until Docker Desktop shows 'Engine running' (or restart Docker Desktop), then retry. Last Docker message: $detail"
        }
        if (-not $announced) {
            Write-Host "Docker Desktop is starting; waiting up to $TimeoutSeconds seconds for its engine..."
            $announced = $true
        }
        & $Sleep $IntervalSeconds
    }
}
