# Per-installation demo student for the Windows launcher (Windows PowerShell
# 5.1). Dot-sourced by frantastic.ps1 after windows_security.ps1 and
# windows_launcher.ps1; kept in its own file so that
# tests/windows/test_demo_credentials.ps1 can run the whole state machine
# against a simulated database by redefining the three Docker helpers below.
#
# Same rules as scripts/bootstrap_demo.sh (Linux; GNU stat/mv, untested on macOS):
#
#   file  account in MariaDB       ordinary start (frantastic.cmd up)
#   ----  -----------------------  ---------------------------------------------
#   no    missing                  generate, create the account, save the file
#   yes   matches the file         nothing
#   yes   missing                  create the account with the SAVED password
#   no    exists                   NOTHING is changed; the recovery is printed
#   yes   exists, does not match   NOTHING is changed; the recovery is printed
#
# The password is generated in the web container, travels only in process
# environment variables (docker compose exec -e NAME), is stored as a Werkzeug
# hash by migration 007's procedures and in plain text only in
# .demo-credentials, which gets the same owner-only DACL as .env and
# .admin-credentials. It is never written to the console.

$FrantasticDemoEmail = 'demo.student@frantastic.local'
$FrantasticDemoPasswordPattern = '^[A-Za-z0-9_-]{20,}$'
$FrantasticDemoHashPattern = '^(scrypt|pbkdf2):[A-Za-z0-9:._$-]+$'

function Read-FrantasticDemoCredential([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing symbolic-link/reparse-point credential file: $Path"
    }
    Protect-LocalFile $Path | Out-Null
    $lines = [IO.File]::ReadAllLines($Path)
    if ($lines.Count -ne 2 -or $lines[0] -cne $FrantasticDemoEmail -or $lines[1] -cnotmatch $FrantasticDemoPasswordPattern) {
        throw "Demo credential file '$(Split-Path -Leaf $Path)' is malformed. It was preserved and nothing was changed."
    }
    return [string]$lines[1]
}

function Write-FrantasticDemoCredential([string] $Path, [string] $Password) {
    $content = "$FrantasticDemoEmail`r`n$Password`r`n"
    [void](Write-ProtectedLocalFile $Path $content ([Text.UTF8Encoding]::new($false)) -ReplaceExisting)
    if ((Read-FrantasticDemoCredential $Path) -cne $Password) { throw "Saved demo credential did not verify after writing" }
}

# --- Docker helpers (the only functions that talk to the containers) ---------

# @{ Role = 'MISSING' | 'student' | 'admin'; Active = '-' | '0' | '1' }
function Get-FrantasticDemoState([string[]] $Compose) {
    $output = @(Invoke-Docker (@($Compose) + @("exec", "-T", "mariadb", "bash", "/usr/local/share/campus/scripts/provision_local_demo_db.sh", "state")))
    if ($output.Count -ne 1) { throw "MariaDB returned an invalid demo-account state" }
    $parts = ([string]$output[0]).Trim() -split '\s+'
    if ($parts.Count -ne 2) { throw "MariaDB returned an invalid demo-account state" }
    return @{ Role = $parts[0]; Active = $parts[1] }
}

# MATCH, MISMATCH, MISSING, NOT_STUDENT or INACTIVE: what the login route would decide.
function Test-FrantasticDemoPassword([string[]] $Compose, [string] $Password) {
    $output = @(Invoke-DockerWithEnvironment -Environment @{ FRANTASTIC_DEMO_PASSWORD = $Password } -Arguments (@($Compose) + @("exec", "-T", "-e", "FRANTASTIC_DEMO_PASSWORD", "web", "python", "/app/bootstrap_demo.py", "--check-environment")))
    if ($output.Count -ne 1) { throw "Could not verify the demo credential against MariaDB" }
    return ([string]$output[0]).Trim()
}

# Runs migration 007's procedure with a freshly computed hash; returns its result word.
function Invoke-FrantasticDemoDbAction([string[]] $Compose, [string] $Action, [string] $Password) {
    $hashLines = @(Invoke-DockerWithEnvironment -Environment @{ FRANTASTIC_DEMO_PASSWORD = $Password } -Arguments (@($Compose) + @("exec", "-T", "-e", "FRANTASTIC_DEMO_PASSWORD", "web", "python", "/app/bootstrap_demo.py", "--hash-environment")))
    if ($hashLines.Count -ne 1 -or [string]$hashLines[0] -cnotmatch $FrantasticDemoHashPattern) { throw "Password hash generation failed" }
    $result = @(Invoke-DockerWithEnvironment -Environment @{ FRANTASTIC_DEMO_HASH = [string]$hashLines[0] } -Arguments (@($Compose) + @("exec", "-T", "-e", "FRANTASTIC_DEMO_HASH", "mariadb", "bash", "/usr/local/share/campus/scripts/provision_local_demo_db.sh", $Action)))
    if ($result.Count -ne 1) { throw "MariaDB returned an invalid answer for the demo-account $Action" }
    return ([string]$result[0]).Trim()
}

function New-FrantasticDemoPassword([string[]] $Compose) {
    $output = @(Invoke-Docker (@($Compose) + @("exec", "-T", "web", "python", "/app/bootstrap_demo.py", "--password-only")))
    if ($output.Count -ne 1 -or [string]$output[0] -cnotmatch $FrantasticDemoPasswordPattern) { throw "Demo password generation failed" }
    return [string]$output[0]
}

# ------------------------------------------------------------------------------

function Write-FrantasticDemoRecovery {
    Write-Host "  To issue a new demo password for THIS database (replaces the stored hash and"
    Write-Host "  writes a new .demo-credentials):   .\frantastic.cmd reset-demo"
    Write-Host "  Without it the application is unaffected: register an account on /register."
}

function Write-FrantasticDemoLocation {
    Write-Host "Demo student login: $FrantasticDemoEmail; password on line 2 of .demo-credentials (private local file; not printed)."
}

# Inserts the account with a password that is already stored in a protected
# file, then proves that the login works.
function New-FrantasticDemoAccount([string[]] $Compose, [string] $Password, [string] $Kept) {
    $result = Invoke-FrantasticDemoDbAction $Compose "bootstrap" $Password
    if ($result -cne "CREATED" -and $result -cne "EXISTS") { throw "Unexpected answer from MariaDB while creating the demo account; $Kept was preserved." }
    if ((Test-FrantasticDemoPassword $Compose $Password) -cne "MATCH") { throw "The new demo account did not authenticate; $Kept was preserved." }
}

# Returns Valid, Created, Reconciled, Rotated or Unavailable. Unavailable means
# nothing was changed and the reason and the recovery were printed; every real
# failure throws, with the protected files left for the next run.
function Invoke-FrantasticDemoProvision {
    param(
        [Parameter(Mandatory = $true)][string] $ProjectRoot,
        [Parameter(Mandatory = $true)][string[]] $Compose,
        [switch] $Rotate
    )
    $credentialPath = Join-Path $ProjectRoot ".demo-credentials"
    $pendingPath = "$credentialPath.pending"
    $state = Get-FrantasticDemoState $Compose
    if ($state.Role -cne "MISSING" -and $state.Role -cne "student") {
        throw "$FrantasticDemoEmail is not a student account in this database; refusing to manage it."
    }

    if ($Rotate) {
        $password = New-FrantasticDemoPassword $Compose
        Write-FrantasticDemoCredential $pendingPath $password
        if ($state.Role -ceq "student") {
            $result = Invoke-FrantasticDemoDbAction $Compose "rotate" $password
            if ($result -cne "ROTATED") { throw "MariaDB did not rotate the demo password ($result); the protected pending file was retained." }
        } else {
            $result = Invoke-FrantasticDemoDbAction $Compose "bootstrap" $password
            if ($result -cne "CREATED") { throw "MariaDB did not create the demo account ($result); the protected pending file was retained." }
        }
        $verdict = Test-FrantasticDemoPassword $Compose $password
        if ($verdict -ceq "INACTIVE") { throw "The demo account is deactivated (is_active = 0); the new password is stored but cannot log in until an administrator reactivates the account." }
        if ($verdict -cne "MATCH") { throw "The new demo password did not authenticate ($verdict); the protected pending file was retained." }
        Write-FrantasticDemoCredential $credentialPath $password
        Remove-Item -LiteralPath $pendingPath -Force
        Write-Host "Demo student password was rotated and verified."
        Write-FrantasticDemoLocation
        return "Rotated"
    }

    # A pending file means an earlier run stopped between "password written"
    # and "file promoted". MariaDB decides which password is the real one.
    if (Test-Path -LiteralPath $pendingPath) {
        $pendingPassword = Read-FrantasticDemoCredential $pendingPath
        $verdict = Test-FrantasticDemoPassword $Compose $pendingPassword
        if ($verdict -ceq "MATCH" -or $verdict -ceq "INACTIVE") {
            Write-FrantasticDemoCredential $credentialPath $pendingPassword
            Remove-Item -LiteralPath $pendingPath -Force
            Write-Host "Completed an interrupted demo-credential update (the database already held the new password)."
        } elseif ($verdict -ceq "MISSING") {
            New-FrantasticDemoAccount $Compose $pendingPassword "the pending file"
            Write-FrantasticDemoCredential $credentialPath $pendingPassword
            Remove-Item -LiteralPath $pendingPath -Force
            Write-Host "Completed an interrupted demo-student bootstrap."
        } else {
            $finalPassword = $null
            if (Test-Path -LiteralPath $credentialPath) { $finalPassword = Read-FrantasticDemoCredential $credentialPath }
            if ($null -ne $finalPassword -and (Test-FrantasticDemoPassword $Compose $finalPassword) -ceq "MATCH") {
                Remove-Item -LiteralPath $pendingPath -Force
                Write-Host "Discarded an interrupted demo-credential update that never reached the database."
            } else {
                throw "An interrupted demo-credential update cannot be reconciled automatically. Nothing was changed; .demo-credentials and its .pending file were preserved. Run '.\frantastic.cmd reset-demo' to issue a new demo password."
            }
        }
        $state = Get-FrantasticDemoState $Compose
    }

    $existing = Read-FrantasticDemoCredential $credentialPath
    if ($null -ne $existing) {
        $verdict = Test-FrantasticDemoPassword $Compose $existing
        if ($verdict -ceq "MATCH") {
            Write-Host "Demo student credential is valid; no rotation performed."
            Write-FrantasticDemoLocation
            return "Valid"
        }
        if ($verdict -ceq "MISSING") {
            New-FrantasticDemoAccount $Compose $existing ".demo-credentials"
            Write-Host "Demo student was created in this database with the saved local credential."
            Write-FrantasticDemoLocation
            return "Reconciled"
        }
        if ($verdict -ceq "INACTIVE") {
            Write-Host "NOTICE: the demo student account is deactivated in this database (is_active = 0)."
            Write-Host "  Nothing was changed; the password in .demo-credentials is correct but cannot log in."
            return "Unavailable"
        }
        Write-Host "NOTICE: .demo-credentials does not match the demo student stored in this database"
        Write-Host "  (the password was changed in the web app, or the file belongs to another database)."
        Write-Host "  Nothing was changed: neither the file nor the stored password."
        Write-FrantasticDemoRecovery
        return "Unavailable"
    }

    if ($state.Role -cne "MISSING") {
        Write-Host "NOTICE: this database already has the demo student $FrantasticDemoEmail,"
        Write-Host "  but its credential file .demo-credentials is not on this machine."
        Write-Host "  The stored password was NOT changed and no file was written."
        Write-FrantasticDemoRecovery
        return "Unavailable"
    }

    $password = New-FrantasticDemoPassword $Compose
    Write-FrantasticDemoCredential $pendingPath $password
    New-FrantasticDemoAccount $Compose $password "the protected pending file"
    Write-FrantasticDemoCredential $credentialPath $password
    Remove-Item -LiteralPath $pendingPath -Force
    Write-Host "Demo student was created and verified (role: student)."
    Write-FrantasticDemoLocation
    return "Created"
}
