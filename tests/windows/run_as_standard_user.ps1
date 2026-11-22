# Runs one test script of tests/windows as a throw-away standard (non-administrator)
# local user, on a disposable CI runner only.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\windows\run_as_standard_user.ps1 -Test test_local_file_acl
#
# Why: test_local_file_acl.ps1 refuses an elevated session, because an
# administrator's token can rewrite any DACL and a pass would then not show
# that a normal user can protect the credential files they own.  GitHub's
# Windows runners always run elevated.  This script therefore creates a local
# user that is a member of Users only, with a random password that is masked in
# the log and never printed, runs the test as that user (its own profile and
# TEMP directory), copies only the files the test needs into a directory that
# user may read, and removes the user, its profile and the directory again.
#
# It changes the machine's user accounts, so it refuses to run anywhere except
# an elevated GitHub Actions runner (GITHUB_ACTIONS=true, RUNNER_ENVIRONMENT=
# github-hosted).  On a development PC, run the test itself in a normal
# PowerShell window instead.
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^test_[a-z_]+$')][string] $Test
)
$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'run_as_standard_user.ps1 creates a local user account and runs only on a disposable GitHub-hosted runner.'
}
$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'run_as_standard_user.ps1 needs an elevated session to create the throw-away user.'
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$name = 'frt' + [Guid]::NewGuid().ToString('N').Substring(0, 12)
# 32 random bytes as Base64 plus fixed characters of each class: always meets
# the local complexity policy.  Masked before anything else can print it.
$bytes = [byte[]]::new(32)
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$plain = [Convert]::ToBase64String($bytes) + 'aA1!'
Write-Host "::add-mask::$plain"
$password = ConvertTo-SecureString $plain -AsPlainText -Force
$plain = $null

$work = Join-Path $env:SystemDrive ('frt-standard-user-' + [Guid]::NewGuid().ToString('N'))
$exitCode = 1
try {
    New-LocalUser -Name $name -Password $password -AccountNeverExpires -PasswordNeverExpires `
        -Description 'FRANtastic CI: throw-away standard user' | Out-Null
    Add-LocalGroupMember -Group (Get-LocalGroup -SID 'S-1-5-32-545') -Member $name   # BUILTIN\Users
    $sid = (Get-LocalUser -Name $name).SID.Value
    $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' | Where-Object { $_.SID.Value -eq $sid })
    if ($admins.Count -ne 0) { throw 'The throw-away user must not be an administrator.' }
    Write-Host "created standard user $name ($sid), member of Users only"

    # Only the test and the implementation it loads, readable (not writable) by the user.
    New-Item -ItemType Directory -Path (Join-Path $work 'tests\windows'), (Join-Path $work 'scripts') | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot "tests\windows\$Test.ps1") -Destination (Join-Path $work 'tests\windows')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts\windows_security.ps1') -Destination (Join-Path $work 'scripts')
    & icacls.exe $work /grant "${name}:(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed with exit code $LASTEXITCODE" }

    $stdout = Join-Path $work 'stdout.txt'
    $stderr = Join-Path $work 'stderr.txt'
    $credential = New-Object Management.Automation.PSCredential ($name, $password)
    $process = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $work "tests\windows\$Test.ps1")`"") `
        -Credential $credential -LoadUserProfile -WorkingDirectory $work -NoNewWindow `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -Wait -PassThru
    $exitCode = $process.ExitCode
    Write-Host "---- $Test.ps1 as $name (standard user), exit code $exitCode"
    if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout | ForEach-Object { Write-Host $_ } }
    if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr | ForEach-Object { Write-Host "stderr: $_" } }
} finally {
    Remove-LocalUser -Name $name -ErrorAction SilentlyContinue
    $profile = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -like "*\$name*" }
    if ($profile) { $profile | Remove-CimInstance -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($exitCode -ne 0) { throw "$Test failed as a standard user (exit code $exitCode)" }
