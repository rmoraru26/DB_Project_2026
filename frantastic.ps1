param(
    [Parameter(Position = 0)]
    [ValidateSet("up", "demo", "test", "down", "reset-admin", "help")]
    [string] $Command = "help"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Compose = @("compose")
. (Join-Path $ProjectRoot "scripts/windows_security.ps1")
. (Join-Path $ProjectRoot "scripts/windows_compose_url.ps1")
. (Join-Path $ProjectRoot "scripts/windows_launcher.ps1")

# Credentials: Docker Compose passes MARIADB_ROOT_PASSWORD and
# CAMPUS_APP_PASSWORD from .env to the mariadb service, and the scripts run
# inside that container take the root password from there
# (scripts/mariadb_admin_auth.sh). The launcher therefore forwards no database
# password itself; it only validates .env before anything starts.

function New-RandomHex([int] $ByteCount) {
    $bytes = [byte[]]::new($ByteCount)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return -join ($bytes | ForEach-Object { $_.ToString("x2") })
}

function Initialize-Environment {
    $envPath = Join-Path $ProjectRoot ".env"
    if (Test-Path -LiteralPath $envPath) {
        Protect-LocalFile $envPath | Out-Null
        Write-Host "Using the existing .env without changing it."
        return
    }
    $templatePath = Join-Path $ProjectRoot ".env.example"
    $content = [IO.File]::ReadAllText($templatePath)
    $rootPassword = "r$(New-RandomHex 24)"
    $appPassword = "a$(New-RandomHex 24)"
    $sessionKey = New-RandomHex 32
    $content = $content -replace '(?m)^MARIADB_ROOT_PASSWORD=.*$', "MARIADB_ROOT_PASSWORD=$rootPassword"
    $content = $content -replace '(?m)^CAMPUS_APP_PASSWORD=.*$', "CAMPUS_APP_PASSWORD=$appPassword"
    $content = $content -replace '(?m)^DB_PASSWORD=.*$', "DB_PASSWORD=$appPassword"
    $content = $content -replace '(?m)^SECRET_KEY=.*$', "SECRET_KEY=$sessionKey"
    $created = Write-ProtectedLocalFile $envPath $content ([Text.Encoding]::ASCII)
    if ($created) { Write-Host "Created .env with random local secrets (values are not displayed)." }
    else { Write-Host "Another setup created .env first; preserving it." }
}

function Read-Environment {
    $envPath = Join-Path $ProjectRoot ".env"
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        throw "No .env file in '$ProjectRoot'. Run '.\frantastic.cmd up' first; it creates .env with random secrets."
    }
    Protect-LocalFile $envPath | Out-Null
    return (Read-FrantasticEnvironment -Path $envPath)
}

function Read-AdminCredential([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing symbolic-link/reparse-point credential file: $Path"
    }
    Protect-LocalFile $Path | Out-Null
    $lines = [IO.File]::ReadAllLines($Path)
    if ($lines.Count -ne 2 -or $lines[0] -cne "admin@frantastic.local" -or $lines[1] -notmatch '^[A-Za-z0-9_-]{40,}$') {
        throw "Administrator credential file is malformed. Preserve it and use the documented recovery procedure."
    }
    return [string]$lines[1]
}

function Write-AdminCredential([string] $Path, [string] $Password) {
    $content = "admin@frantastic.local`r`n$Password`r`n"
    [void](Write-ProtectedLocalFile $Path $content ([Text.UTF8Encoding]::new($false)) -ReplaceExisting)
    if ((Read-AdminCredential $Path) -cne $Password) { throw "Saved credential did not verify after replacement" }
}

function Get-AdminDatabaseState {
    $output = @(Invoke-Docker (@($Compose) + @("exec", "-T", "mariadb", "bash", "/usr/local/share/campus/scripts/provision_local_admin_db.sh", "state")))
    if ($output.Count -ne 1) { throw "MariaDB returned invalid administrator state" }
    $parts = ([string]$output[0]).Trim() -split '\s+'
    if ($parts.Count -ne 3) { throw "MariaDB returned invalid administrator state" }
    return @{ Pending = $parts[0]; Admins = $parts[1]; Canonical = $parts[2] }
}

function Test-AdminPassword([string] $Password) {
    $output = @(Invoke-DockerWithEnvironment -Environment @{ FRANTASTIC_ADMIN_PASSWORD = $Password } -Arguments (@($Compose) + @("exec", "-T", "-e", "FRANTASTIC_ADMIN_PASSWORD", "web", "python", "/app/bootstrap_admin.py", "--check-environment")))
    if ($output.Count -ne 1) { throw "Could not verify administrator credentials against MariaDB" }
    return ([string]$output[0]).Trim() -ceq "MATCH"
}

function Invoke-AdminDbAction([string] $Action, [string] $Password) {
    $hashLines = @(Invoke-DockerWithEnvironment -Environment @{ FRANTASTIC_ADMIN_PASSWORD = $Password } -Arguments (@($Compose) + @("exec", "-T", "-e", "FRANTASTIC_ADMIN_PASSWORD", "web", "python", "/app/bootstrap_admin.py", "--hash-environment")))
    if ($hashLines.Count -ne 1 -or [string]$hashLines[0] -notmatch '^(scrypt|pbkdf2):[A-Za-z0-9:._$-]+$') { throw "Password hash generation failed" }
    Invoke-DockerWithEnvironment -Environment @{ FRANTASTIC_ADMIN_HASH = [string]$hashLines[0] } -Arguments (@($Compose) + @("exec", "-T", "-e", "FRANTASTIC_ADMIN_HASH", "mariadb", "bash", "/usr/local/share/campus/scripts/provision_local_admin_db.sh", $Action))
}

function Invoke-AdminProvision([switch] $Rotate) {
    $credentialPath = Join-Path $ProjectRoot ".admin-credentials"
    $pendingPath = "$credentialPath.pending"
    $state = Get-AdminDatabaseState

    if ($Rotate) {
        if ($state.Canonical -ne "admin" -and $state.Admins -ne "0") { throw "Canonical local administrator is absent while other admins exist; use authorised DBA recovery." }
        $password = [string](@(Invoke-Docker (@($Compose) + @("exec", "-T", "web", "python", "/app/bootstrap_admin.py", "--password-only")))[0])
        Write-AdminCredential $pendingPath $password
        $action = if ($state.Canonical -eq "admin") { "rotate" } else { "bootstrap-force" }
        Invoke-AdminDbAction $action $password
        if (-not (Test-AdminPassword $password)) { throw "Database password update could not be verified; protected pending credential was retained." }
        Write-AdminCredential $credentialPath $password
        Remove-Item -LiteralPath $pendingPath -Force
        Write-Host "Local administrator credential was rotated and verified."
        return
    }

    if (Test-Path -LiteralPath $pendingPath) {
        $pendingPassword = Read-AdminCredential $pendingPath
        if (Test-AdminPassword $pendingPassword) {
            Write-AdminCredential $credentialPath $pendingPassword
            Remove-Item -LiteralPath $pendingPath -Force
        } elseif ($state.Admins -eq "0" -and $state.Canonical -eq "MISSING" -and $state.Pending -eq "1") {
            Invoke-AdminDbAction "bootstrap" $pendingPassword
            if (-not (Test-AdminPassword $pendingPassword)) { throw "Pending bootstrap did not authenticate; pending credential was retained." }
            Write-AdminCredential $credentialPath $pendingPassword
            Remove-Item -LiteralPath $pendingPath -Force
        } elseif (Test-Path -LiteralPath $credentialPath) {
            $currentPassword = Read-AdminCredential $credentialPath
            if ($null -ne $currentPassword -and (Test-AdminPassword $currentPassword)) {
                Remove-Item -LiteralPath $pendingPath -Force
            } else { throw "Interrupted credential update is not reconcilable automatically; preserve both files and use documented DBA recovery." }
        } else { throw "Interrupted credential update is not reconcilable automatically; preserve the pending file and use documented DBA recovery." }
        $state = Get-AdminDatabaseState
    }

    $existing = Read-AdminCredential $credentialPath
    if ($null -ne $existing) {
        if (Test-AdminPassword $existing) { Write-Host "Local administrator credential is valid; no rotation performed."; return }
        if ($state.Admins -eq "0" -and $state.Canonical -eq "MISSING" -and $state.Pending -eq "1") {
            Invoke-AdminDbAction "bootstrap" $existing
            if (-not (Test-AdminPassword $existing)) { throw "Fresh database bootstrap failed; saved credential was preserved." }
            Write-Host "Fresh database was reconciled with the saved local credential."; return
        }
        throw "Saved credential does not match the existing administrator; no account or password was changed."
    }
    if ($state.Admins -ne "0" -or $state.Canonical -ne "MISSING" -or $state.Pending -ne "1") {
        throw "No local credential exists for an existing or closed administrator state; no account was created. Use authorised DBA recovery."
    }
    $password = [string](@(Invoke-Docker (@($Compose) + @("exec", "-T", "web", "python", "/app/bootstrap_admin.py", "--password-only")))[0])
    Write-AdminCredential $pendingPath $password
    Invoke-AdminDbAction "bootstrap" $password
    if (-not (Test-AdminPassword $password)) { throw "New administrator authentication failed; protected pending credential was retained." }
    Write-AdminCredential $credentialPath $password
    Remove-Item -LiteralPath $pendingPath -Force
    Write-Host "First local administrator was provisioned and verified. Credential saved locally (not displayed)."
}

Push-Location -LiteralPath $ProjectRoot
$savedSecretEnvironment = $null
try {
    if ($Command -eq "help") {
        Write-Host "Usage: .\frantastic.cmd up|demo|test|down|reset-admin"
        Write-Host "Requires Docker Desktop with Docker Compose V2."
        exit 0
    }
    Assert-FrantasticDockerCli
    Assert-FrantasticDockerCompose
    Wait-FrantasticDockerEngine
    $savedSecretEnvironment = Clear-FrantasticSecretOverrides

    switch ($Command) {
        "up" {
            Initialize-Environment
            [void](Read-Environment)
            Invoke-Docker (@($Compose) + @("up", "-d", "--build", "--wait", "mariadb"))
            Invoke-Docker (@($Compose) + @("exec", "-T", "mariadb", "bash", "/usr/local/share/campus/scripts/post_start.sh"))
            Invoke-Docker (@($Compose) + @("up", "-d", "--build", "--wait", "web"))
            Invoke-AdminProvision
            $readyUrl = Get-FrantasticReadyUrl
            Write-Host "FRANtastic is ready at $readyUrl"
            Write-Host "Student demo: alice.student@example.edu / campus-demo-2026"
        }
        "demo" {
            [void](Read-Environment)
            Invoke-Docker (@($Compose) + @("exec", "-T", "mariadb", "bash", "/usr/local/share/campus/scripts/demo.sh"))
        }
        "test" {
            Initialize-Environment
            [void](Read-Environment)
            & (Join-Path $ProjectRoot "tests/windows/test_local_file_acl.ps1")
            & (Join-Path $ProjectRoot "tests/windows/test_launcher_url.ps1")
            & (Join-Path $ProjectRoot "tests/windows/test_launcher_hardening.ps1")
            & (Join-Path $ProjectRoot "tests/windows/test_launcher_end_to_end.ps1")
            $credentialPath = Join-Path $ProjectRoot ".admin-credentials"
            $testEnvironment = @{}
            if (Test-Path -LiteralPath $credentialPath) {
                $adminPassword = Read-AdminCredential $credentialPath
                $testEnvironment = @{ TEST_ADMIN_EMAIL = "admin@frantastic.local"; TEST_ADMIN_PASSWORD = $adminPassword }
            }
            $testArguments = @($Compose) + @("--profile", "test", "run", "--rm", "--build", "test-runner")
            if ($testEnvironment.Count -gt 0) {
                Invoke-DockerWithEnvironment -Environment $testEnvironment -Arguments $testArguments
            } else { Invoke-Docker $testArguments }
        }
        "reset-admin" {
            [void](Read-Environment)
            Invoke-AdminProvision -Rotate
        }
        "down" { Invoke-Docker (@($Compose) + @("down")) }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("FRANtastic: $($_.Exception.Message)")
    exit 1
} finally {
    Restore-FrantasticProcessEnvironment $savedSecretEnvironment
    Pop-Location
}
