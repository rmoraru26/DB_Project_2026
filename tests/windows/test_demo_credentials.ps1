$ErrorActionPreference = 'Stop'
# State-machine tests of the Windows demo-student provisioning
# (scripts/windows_demo_credentials.ps1, used by frantastic.ps1 up and
# reset-demo). The four functions that talk to the containers are replaced by
# an in-memory database after dot-sourcing, and the two Docker invokers throw,
# so nothing here can reach Docker. The credential files are real: they are
# written with the production writer and their DACL is verified.
#
# Mirrors tests/shell/test_demo_bootstrap.sh (Linux). The real containers are
# covered by tests/database/test_demo_student.sh and by the application tests
# that log in with the generated credential.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "Run this test under Windows PowerShell 5.1 (powershell.exe)."
}
. (Join-Path $repoRoot 'scripts/windows_security.ps1')
. (Join-Path $repoRoot 'scripts/windows_demo_credentials.ps1')

function Invoke-Docker { throw "TEST BUG: Invoke-Docker was reached; the Docker helpers must be simulated." }
function Invoke-DockerWithEnvironment { throw "TEST BUG: Invoke-DockerWithEnvironment was reached; the Docker helpers must be simulated." }

# ---- simulated database (replaces the Docker helpers of the script under test)
$script:Db = $null
$script:Calls = New-Object 'System.Collections.Generic.List[string]'
$script:Secrets = New-Object 'System.Collections.Generic.List[string]'
$script:FailOn = ''
function Reset-World {
    $script:Db = @{ Exists = $false; Password = $null; Role = 'student'; Active = '1' }
    $script:Calls.Clear()
    $script:FailOn = ''
    foreach ($leftover in @(Get-ChildItem -LiteralPath $project -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $leftover.FullName -Force
    }
}
function Get-FrantasticDemoState([string[]] $Compose) {
    $script:Calls.Add('state')
    if ($script:FailOn -ceq 'state') { throw "Docker command failed with exit code 1. See the output above." }
    if (-not $script:Db.Exists) { return @{ Role = 'MISSING'; Active = '-' } }
    return @{ Role = $script:Db.Role; Active = $script:Db.Active }
}
function Test-FrantasticDemoPassword([string[]] $Compose, [string] $Password) {
    $script:Calls.Add('check')
    if (-not $script:Db.Exists) { return 'MISSING' }
    if ($script:Db.Role -cne 'student') { return 'NOT_STUDENT' }
    if ($script:Db.Password -cne $Password) { return 'MISMATCH' }
    if ($script:Db.Active -cne '1') { return 'INACTIVE' }
    return 'MATCH'
}
function Invoke-FrantasticDemoDbAction([string[]] $Compose, [string] $Action, [string] $Password) {
    $script:Calls.Add($Action)
    if ($script:FailOn -ceq 'db') { throw "Docker command failed with exit code 1. See the output above." }
    $answer = $null
    if ($Action -ceq 'bootstrap') {
        if ($script:Db.Exists) { $answer = 'EXISTS' }
        else { $script:Db.Exists = $true; $script:Db.Password = $Password; $script:Db.Role = 'student'; $script:Db.Active = '1'; $answer = 'CREATED' }
    } elseif ($Action -ceq 'rotate') {
        if (-not $script:Db.Exists) { $answer = 'MISSING' }
        elseif ($script:Db.Role -cne 'student') { $answer = 'NOT_STUDENT' }
        else { $script:Db.Password = $Password; $answer = 'ROTATED' }
    } else { throw "TEST BUG: unexpected action $Action" }
    # The statement was committed, but the client reported a failure.
    if ($script:FailOn -ceq 'after-db') { throw "Docker command failed with exit code 1. See the output above." }
    return $answer
}
function New-FrantasticDemoPassword([string[]] $Compose) {
    $script:Calls.Add('generate')
    if ($script:FailOn -ceq 'generate') { throw "Demo password generation failed" }
    $bytes = New-Object byte[] 18
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $password = [Convert]::ToBase64String($bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=')
    $script:Secrets.Add($password)
    return $password
}

# ---- helpers
$script:Passed = 0
$script:AllOutput = New-Object 'System.Collections.Generic.List[string]'
function Assert-True([bool] $Condition, [string] $Label) {
    if (-not $Condition) { throw "FAIL: $Label" }
    $script:Passed++
    Write-Host "PASS: $Label"
}
# Runs the provisioning; returns @{ Status; Text; Error }. Console output of the
# function under test is captured, never shown (it must not contain a secret).
function Invoke-Provision([switch] $Rotate) {
    $script:Calls.Clear()
    $status = $null; $failure = $null
    $records = @()
    try {
        if ($Rotate) { $records = @(Invoke-FrantasticDemoProvision -ProjectRoot $project -Compose @('compose') -Rotate 6>&1) }
        else { $records = @(Invoke-FrantasticDemoProvision -ProjectRoot $project -Compose @('compose') 6>&1) }
    } catch { $failure = $_.Exception.Message }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($record in $records) {
        if ($record -is [Management.Automation.InformationRecord]) { $lines.Add([string]$record.MessageData) }
        else { $status = [string]$record }
    }
    $text = ($lines -join "`n")
    $script:AllOutput.Add($text)
    if ($failure) { $script:AllOutput.Add($failure) }
    return @{ Status = $status; Text = $text; Error = $failure }
}
function Get-Sha([string] $Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Get-FilePassword([string] $Path) { return [IO.File]::ReadAllLines($Path)[1] }
function New-OtherPassword { $p = 'Other-' + [Guid]::NewGuid().ToString('N'); $script:Secrets.Add($p); return $p }
function Write-TestFile([string] $Path, [string] $Password) { Write-FrantasticDemoCredential $Path $Password }
function Test-Called([string] $Name) { return ($script:Calls -contains $Name) }

$root = Join-Path ([IO.Path]::GetTempPath()) ('FRANtastic Demo Credential Tests ' + [Guid]::NewGuid().ToString('N'))
$project = Join-Path $root 'project copy'
New-Item -ItemType Directory -Path $project | Out-Null
$cred = Join-Path $project '.demo-credentials'
$pending = "$cred.pending"
# Owner of a file this process creates: the user, or the Administrators group
# in an elevated session. The DACL assertions compare against the file's own
# owner, so the test runs in both kinds of session.
function Get-OwnerSid([string] $Path) { return (Get-LocalFileDaclState $Path).OwnerSid }
$email = 'demo.student@frantastic.local'

try {
    # ------------------------------------------------------------ first installation
    Reset-World
    $r = Invoke-Provision
    $lines = [IO.File]::ReadAllLines($cred)
    Assert-True ($r.Status -ceq 'Created' -and $null -eq $r.Error -and $script:Db.Exists -and $script:Db.Role -ceq 'student') 'first start: the account is created as a student'
    Assert-True ($lines.Count -eq 2 -and $lines[0] -ceq $email -and $lines[1] -cmatch '^[A-Za-z0-9_-]{20,}$' -and $lines[1] -ceq $script:Db.Password) 'first start: the file holds the e-mail address and the password MariaDB accepted'
    Assert-True (-not (Test-Path -LiteralPath $pending)) 'first start: no pending file is left'
    [void](Assert-LocalFileDacl $cred (Get-OwnerSid $cred))
    Assert-True $true 'first start: the file has the owner-only DACL (current user, SYSTEM, Administrators; inheritance off)'
    Assert-True ($r.Text -like '*.demo-credentials*' -and $r.Text -like '*not printed*' -and -not $r.Text.Contains($lines[1])) 'first start: the output names the file and does not contain the password'
    $firstSha = Get-Sha $cred; $firstPassword = $lines[1]

    # ------------------------------------------------------------ ordinary restart
    $r = Invoke-Provision
    Assert-True ($r.Status -ceq 'Valid' -and $r.Text -like '*no rotation performed*' -and (Get-Sha $cred) -ceq $firstSha -and $script:Db.Password -ceq $firstPassword) 'restart: file and stored password unchanged'
    Assert-True (-not (Test-Called 'generate') -and -not (Test-Called 'bootstrap') -and -not (Test-Called 'rotate')) 'restart: nothing is generated and nothing is written to the database'
    [void](Invoke-Provision); [void](Invoke-Provision)
    Assert-True ((Get-Sha $cred) -ceq $firstSha -and $script:Db.Password -ceq $firstPassword) 'repeated restarts never rotate the credential'

    # ------------------------------------------------------------ existing database, local file missing
    Remove-Item -LiteralPath $cred -Force
    $r = Invoke-Provision
    Assert-True ($r.Status -ceq 'Unavailable' -and $null -eq $r.Error -and $r.Text -like '*NOT changed*' -and $r.Text -like '*frantastic.cmd reset-demo*') 'existing database without the local file: reported with the recovery command, not failed'
    Assert-True (-not (Test-Path -LiteralPath $cred) -and -not (Test-Path -LiteralPath $pending) -and $script:Db.Password -ceq $firstPassword -and -not (Test-Called 'generate') -and -not (Test-Called 'rotate')) 'existing database without the local file: no password changed, no file written'

    # ------------------------------------------------------------ a file with another password
    Write-TestFile $cred (New-OtherPassword); $foreignSha = Get-Sha $cred
    $r = Invoke-Provision
    Assert-True ($r.Status -ceq 'Unavailable' -and $r.Text -like '*does not match*' -and (Get-Sha $cred) -ceq $foreignSha -and $script:Db.Password -ceq $firstPassword -and -not (Test-Called 'rotate') -and -not (Test-Called 'bootstrap')) 'mismatching file: neither the file nor the stored password is changed'

    # ------------------------------------------------------------ re-created database, saved file reused
    Write-TestFile $cred $firstPassword; $savedSha = Get-Sha $cred
    $script:Db = @{ Exists = $false; Password = $null; Role = 'student'; Active = '1' }
    $r = Invoke-Provision
    Assert-True ($r.Status -ceq 'Reconciled' -and $script:Db.Exists -and $script:Db.Password -ceq $firstPassword -and (Get-Sha $cred) -ceq $savedSha -and -not (Test-Called 'generate')) 're-created database: the account is created with the SAVED password; the file is not replaced'

    # ------------------------------------------------------------ explicit rotation
    $r = Invoke-Provision -Rotate
    $rotated = Get-FilePassword $cred
    Assert-True ($r.Status -ceq 'Rotated' -and $rotated -cne $firstPassword -and $script:Db.Password -ceq $rotated -and -not (Test-Path -LiteralPath $pending) -and (Test-Called 'rotate')) 'reset-demo: a new password is stored and saved; the previous one no longer matches'
    [void](Assert-LocalFileDacl $cred (Get-OwnerSid $cred))
    Assert-True (-not $r.Text.Contains($rotated)) 'reset-demo: the replaced file keeps the owner-only DACL and the new password is not printed'
    Reset-World
    $r = Invoke-Provision -Rotate
    Assert-True ($r.Status -ceq 'Rotated' -and $script:Db.Exists -and $script:Db.Password -ceq (Get-FilePassword $cred) -and (Test-Called 'bootstrap') -and -not (Test-Called 'rotate')) 'reset-demo on a database without the account creates it'

    # ------------------------------------------------------------ interrupted runs
    Reset-World; $p = New-OtherPassword; Write-TestFile $pending $p
    $r = Invoke-Provision
    Assert-True ($null -eq $r.Error -and -not (Test-Path -LiteralPath $pending) -and (Get-FilePassword $cred) -ceq $p -and $script:Db.Password -ceq $p -and -not (Test-Called 'generate')) 'interrupted before the database was changed: the pending password is used, not a new one'

    Reset-World; [void](Invoke-Provision); $p = New-OtherPassword; $script:Db.Password = $p; Write-TestFile $pending $p
    $r = Invoke-Provision
    Assert-True ($null -eq $r.Error -and $r.Text -like '*already held the new password*' -and -not (Test-Path -LiteralPath $pending) -and (Get-FilePassword $cred) -ceq $p) 'interrupted after the database was changed: the pending password replaces the stale file'

    Reset-World; [void](Invoke-Provision); $keepSha = Get-Sha $cred; $keepPassword = $script:Db.Password; Write-TestFile $pending (New-OtherPassword)
    $r = Invoke-Provision
    Assert-True ($r.Status -ceq 'Valid' -and $r.Text -like '*never reached the database*' -and -not (Test-Path -LiteralPath $pending) -and (Get-Sha $cred) -ceq $keepSha -and $script:Db.Password -ceq $keepPassword) 'interrupted rotation that never reached the database: pending file discarded, working file kept'

    Reset-World; [void](Invoke-Provision); $keepPassword = $script:Db.Password
    Write-TestFile $cred (New-OtherPassword); Write-TestFile $pending (New-OtherPassword)
    $credSha = Get-Sha $cred; $pendingSha = Get-Sha $pending
    $r = Invoke-Provision
    Assert-True ($null -ne $r.Error -and $r.Error -like '*cannot be reconciled automatically*' -and $r.Error -like '*reset-demo*' -and (Get-Sha $cred) -ceq $credSha -and (Get-Sha $pending) -ceq $pendingSha -and $script:Db.Password -ceq $keepPassword) 'irreconcilable state: fails, both files preserved, database untouched, recovery named'
    $r = Invoke-Provision -Rotate
    Assert-True ($r.Status -ceq 'Rotated' -and -not (Test-Path -LiteralPath $pending) -and $script:Db.Password -ceq (Get-FilePassword $cred)) 'the explicit reset recovers from the irreconcilable state'

    # ------------------------------------------------------------ failures can be retried
    Reset-World; $script:FailOn = 'db'
    $r = Invoke-Provision
    Assert-True ($null -ne $r.Error -and -not (Test-Path -LiteralPath $cred) -and (Test-Path -LiteralPath $pending) -and -not $script:Db.Exists) 'database failure during the first start: fails, pending file kept, no account created'
    [void](Assert-LocalFileDacl $pending (Get-OwnerSid $pending))
    $kept = Get-FilePassword $pending; $script:FailOn = ''
    $r = Invoke-Provision
    Assert-True ($null -eq $r.Error -and -not (Test-Path -LiteralPath $pending) -and (Get-FilePassword $cred) -ceq $kept -and $script:Db.Password -ceq $kept) 'retry after that failure completes with the same password (pending file was protected)'

    Reset-World; $script:FailOn = 'after-db'
    $r = Invoke-Provision
    $kept = Get-FilePassword $pending
    Assert-True ($null -ne $r.Error -and -not (Test-Path -LiteralPath $cred) -and $script:Db.Password -ceq $kept) 'failure reported after the row was committed: pending file kept'
    $script:FailOn = ''
    $r = Invoke-Provision
    Assert-True ($null -eq $r.Error -and (Get-FilePassword $cred) -ceq $kept -and -not (Test-Called 'bootstrap') -and -not (Test-Called 'rotate')) 'retry after that failure promotes the pending password without touching the database'

    Reset-World; $script:FailOn = 'state'
    $r = Invoke-Provision
    Assert-True ($null -ne $r.Error -and -not (Test-Path -LiteralPath $cred) -and -not (Test-Path -LiteralPath $pending)) 'unreachable database: fails before any file is written'
    Reset-World; $script:FailOn = 'generate'
    $r = Invoke-Provision
    Assert-True ($null -ne $r.Error -and -not (Test-Path -LiteralPath $cred) -and -not (Test-Path -LiteralPath $pending) -and -not $script:Db.Exists) 'password generation failure: nothing written, nothing created'

    Reset-World; [void](Invoke-Provision); $keepSha = Get-Sha $cred; $keepPassword = $script:Db.Password; $script:FailOn = 'db'
    $r = Invoke-Provision -Rotate
    Assert-True ($null -ne $r.Error -and (Get-Sha $cred) -ceq $keepSha -and $script:Db.Password -ceq $keepPassword) 'failed rotation: the working credential file and the stored password are both unchanged'
    $script:FailOn = ''
    $r = Invoke-Provision
    Assert-True ($r.Status -ceq 'Valid' -and -not (Test-Path -LiteralPath $pending) -and (Get-Sha $cred) -ceq $keepSha) 'start after a failed rotation: pending file discarded, the working credential stays valid'

    # ------------------------------------------------------------ malformed or foreign files
    Reset-World; [void](Invoke-Provision); $keepPassword = $script:Db.Password
    [IO.File]::WriteAllText($cred, "$email`r`n$(New-OtherPassword)`r`nextra line`r`n"); $badSha = Get-Sha $cred
    $r = Invoke-Provision
    Assert-True ($null -ne $r.Error -and $r.Error -like '*malformed*' -and (Get-Sha $cred) -ceq $badSha -and $script:Db.Password -ceq $keepPassword) 'a malformed credential file is preserved and stops the run'
    [IO.File]::WriteAllText($cred, "someone.else@example.edu`r`n$(New-OtherPassword)`r`n")
    $r = Invoke-Provision
    Assert-True ($null -ne $r.Error -and $script:Db.Password -ceq $keepPassword) 'a file for another account is not used'
    [IO.File]::WriteAllText($cred, "$email`r`nshort`r`n")
    $r = Invoke-Provision
    Assert-True ($null -ne $r.Error -and $script:Db.Password -ceq $keepPassword) 'a file with an implausibly short password is not used'

    # ------------------------------------------------------------ the account must be a student
    Reset-World; [void](Invoke-Provision); $script:Db.Role = 'admin'; $keepSha = Get-Sha $cred; $keepPassword = $script:Db.Password
    $r = Invoke-Provision
    Assert-True ($null -ne $r.Error -and $r.Error -like '*not a student account*' -and (Get-Sha $cred) -ceq $keepSha -and $script:Db.Password -ceq $keepPassword) 'an account that is not a student is never managed (up)'
    $r = Invoke-Provision -Rotate
    Assert-True ($null -ne $r.Error -and $r.Error -like '*not a student account*' -and $script:Db.Password -ceq $keepPassword -and -not (Test-Called 'generate')) 'an account that is not a student never receives a new password (reset-demo)'

    Reset-World; [void](Invoke-Provision); $script:Db.Active = '0'; $keepSha = Get-Sha $cred
    $r = Invoke-Provision
    Assert-True ($r.Status -ceq 'Unavailable' -and $r.Text -like '*deactivated*' -and (Get-Sha $cred) -ceq $keepSha -and $script:Db.Active -ceq '0') 'a deactivated demo account is reported and not reactivated'

    # ------------------------------------------------------------ nothing secret in any output
    $leaks = @($script:AllOutput | Where-Object { $t = $_; @($script:Secrets | Where-Object { $t.Contains($_) }).Count -gt 0 })
    Assert-True ($script:Secrets.Count -ge 20 -and $leaks.Count -eq 0) "no password appears in any output or error message ($($script:Secrets.Count) generated passwords checked)"

    # The launcher wires the commands this file implements.
    $launcher = [IO.File]::ReadAllText((Join-Path $repoRoot 'frantastic.ps1'))
    Assert-True ($launcher -match 'windows_demo_credentials\.ps1' -and $launcher -match '"reset-demo"' -and $launcher -match 'Invoke-FrantasticDemoProvision -ProjectRoot \$ProjectRoot -Compose \$Compose -Rotate') 'frantastic.ps1 provides reset-demo and calls the provisioning on up'
    Assert-True ($launcher -notmatch 'campus-demo-2026' -and $launcher -notmatch 'alice\.student@example\.edu') 'frantastic.ps1 no longer advertises a shared demo password'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Demo credential tests: $script:Passed checks passed."
