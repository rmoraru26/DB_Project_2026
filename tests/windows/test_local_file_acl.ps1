$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts/windows_security.ps1')

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal $identity
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this ACL test in a normal, non-elevated Windows PowerShell 5.1 session.'
}
Write-Host 'PASS: test process is not elevated'

$root = Join-Path ([IO.Path]::GetTempPath()) ('FRANtastic Windows Test ACL Tests ' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$path = Join-Path $root 'sensitive file.env'
$credential = Join-Path $root '.admin-credentials'
$fixture = "fixture=unchanged`r`n"
$testUserSid = $identity.User
$allow = [Security.AccessControl.AceQualifier]::AccessAllowed
$deny = [Security.AccessControl.AceQualifier]::AccessDenied
$none = [Security.AccessControl.AceFlags]::None
$full = [int][Security.AccessControl.FileSystemRights]::FullControl

function New-TestAcl([object[]] $Entries) {
    $acl = [Security.AccessControl.RawAcl]::new(2, $Entries.Count)
    foreach ($entry in $Entries) {
        [void]$acl.InsertAce($acl.Count, [Security.AccessControl.CommonAce]::new(
            $none, $entry.Qualifier, $entry.Mask, $entry.Sid, $false, $null))
    }
    return ,$acl
}

function Set-TestDacl([string] $Target, [Security.AccessControl.RawAcl] $Acl) {
    $bytes = New-Object byte[] $Acl.BinaryLength
    $Acl.GetBinaryForm($bytes, 0)
    $memory = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    try {
        [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $memory, $bytes.Length)
        $status = [Frantastic.DaclNative]::SetNamedSecurityInfoW(
            $Target, 1, [uint32]4, [IntPtr]::Zero, [IntPtr]::Zero, $memory, [IntPtr]::Zero)
        if ($status -ne 0) { throw [ComponentModel.Win32Exception]::new([int]$status) }
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($memory) }
}

function Assert-ProtectedFile([string] $Target, [string] $ExpectedContents) {
    $state = Assert-LocalFileDacl $Target $testUserSid.Value
    if ($state.Aces.Count -ne 3) { throw "Unexpected ACE count in $Target" }
    if ([IO.File]::ReadAllText($Target) -cne $ExpectedContents) { throw "Contents changed in $Target" }
}

try {
    $implementation = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'scripts/windows_security.ps1'))
    $unsignedConversionPattern = '\[Convert\]\s*::\s*ToUInt32\s*\(\s*''80000004''\s*,\s*16\s*\)'
    $oldSignedConversionPattern = '\$flags\s*=\s*\[uint32\]\s*0x80000004'
    if ($implementation -notmatch $unsignedConversionPattern -or
        $implementation -match $oldSignedConversionPattern) {
        throw 'windows_security.ps1 must convert the ACL flags using [Convert]::ToUInt32(''80000004'', 16).'
    }
    [uint64]$expectedFlags = 2147483652
    $flags = [Convert]::ToUInt32('80000004', 16)
    if ($flags.GetType() -ne [System.UInt32]) {
        throw "Expected System.UInt32 ACL flags, received $($flags.GetType().FullName)."
    }
    if ([uint64]$flags -ne $expectedFlags) {
        throw "Unexpected security-information flags value: $flags"
    }
    Write-Host 'PASS: DACL flags convert to UInt32 value 2147483652'

    # Seed explicit allow and deny ACEs for unexpected principals. The fixture
    # uses only DACL_SECURITY_INFORMATION and never reads or changes the SACL.
    [IO.File]::WriteAllText($path, $fixture)
    $unexpected = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')
    $testAcl = New-TestAcl @(
        @{ Sid = $testUserSid; Qualifier = $allow; Mask = $full },
        @{ Sid = $unexpected; Qualifier = $allow; Mask = 1179785 },
        @{ Sid = $unexpected; Qualifier = $deny; Mask = 1 }
    )
    if ($null -eq $testAcl -or $testAcl -isnot [Security.AccessControl.RawAcl]) {
        throw 'New-TestAcl must return exactly one System.Security.AccessControl.RawAcl object.'
    }
    Set-TestDacl $path $testAcl
    Write-Host 'PASS: New-TestAcl returns one RawAcl object'
    if (-not (Protect-LocalFile $path)) { throw 'Protection did not report success.' }
    Assert-ProtectedFile $path $fixture
    Write-Host 'PASS: spaced path, exact SID allowlist, deny/extra ACE removal, protected DACL and unchanged content'

    $first = Get-LocalFileDaclState $path
    $firstBytes = New-Object byte[] $first.Aces.BinaryLength
    $first.Aces.GetBinaryForm($firstBytes, 0)
    [void](Protect-LocalFile $path)
    [void](Protect-LocalFile $path)
    $second = Get-LocalFileDaclState $path
    $secondBytes = New-Object byte[] $second.Aces.BinaryLength
    $second.Aces.GetBinaryForm($secondBytes, 0)
    if ([Convert]::ToBase64String($firstBytes) -cne [Convert]::ToBase64String($secondBytes)) {
        throw 'Repeated protection changed or duplicated the DACL.'
    }
    Assert-ProtectedFile $path $fixture
    Write-Host 'PASS: repeated protection is idempotent'

    # Exercise both sensitive-file promotion cases using harmless fixtures.
    $envPath = Join-Path $root '.env'
    $envContent = "MARIADB_ROOT_PASSWORD=dummy`nSECRET_KEY=dummy`n"
    if (-not (Write-ProtectedLocalFile $envPath $envContent ([Text.Encoding]::ASCII))) { throw '.env was not created.' }
    Assert-ProtectedFile $envPath $envContent
    if (Write-ProtectedLocalFile $envPath 'MUST_NOT_REPLACE' ([Text.Encoding]::ASCII)) { throw 'Existing .env was overwritten.' }
    Assert-ProtectedFile $envPath $envContent

    $credentialContent = "admin@frantastic.local`r`ndummy-test-password-not-a-secret`r`n"
    if (-not (Write-ProtectedLocalFile $credential $credentialContent ([Text.UTF8Encoding]::new($false)) -ReplaceExisting)) {
        throw 'Initial credential fixture was not created.'
    }
    Assert-ProtectedFile $credential $credentialContent
    $rotatedCredential = "admin@frantastic.local`r`nrotated-dummy-password-not-a-secret`r`n"
    if (-not (Write-ProtectedLocalFile $credential $rotatedCredential ([Text.UTF8Encoding]::new($false)) -ReplaceExisting)) {
        throw 'Credential fixture was not replaced.'
    }
    Assert-ProtectedFile $credential $rotatedCredential
    Write-Host 'PASS: .env create-only and credential create/replace workflows verify final destinations'

    # Inject a failure only at temporary-file protection, after staging has
    # begun. The existing destination must survive and only this operation's
    # temporary artifact may be removed.
    $beforeFailure = [IO.File]::ReadAllText($credential)
    $script:originalNativeSetter = (Get-Command Set-LocalFileDaclNative -CommandType Function).ScriptBlock
    function Set-LocalFileDaclNative([string] $Target, [Security.AccessControl.RawAcl] $Dacl) {
        if ([IO.Path]::GetFileName($Target) -like '.frantastic-*.tmp') { throw 'injected native DACL failure' }
        & $script:originalNativeSetter $Target $Dacl
    }
    $reportedFailure = $false
    $errorText = ''
    $failedEnvPath = Join-Path $root '.env-failed'
    try { [void](Write-ProtectedLocalFile $failedEnvPath 'do-not-report-this-content' ([Text.Encoding]::ASCII)) }
    catch { $reportedFailure = $true; $errorText = $_.Exception.Message }
    if (-not $reportedFailure -or (Test-Path -LiteralPath $failedEnvPath)) {
        throw 'Failed .env staging did not fail closed or left a destination behind.'
    }
    if (@(Get-ChildItem -LiteralPath $root -Filter '.frantastic-*.tmp' -Force).Count -ne 0) {
        throw 'Failed .env staging left a temporary file.'
    }

    $reportedFailure = $false
    $errorText = ''
    try { [void](Write-ProtectedLocalFile $credential 'do-not-report-this-content' ([Text.UTF8Encoding]::new($false)) -ReplaceExisting) }
    catch { $reportedFailure = $true; $errorText = $_.Exception.Message }
    Remove-Item Function:\Set-LocalFileDaclNative -ErrorAction SilentlyContinue
    Remove-Variable originalNativeSetter -Scope Script -ErrorAction SilentlyContinue
    if (-not $reportedFailure -or $errorText -notmatch 'injected native DACL failure') { throw 'Injected DACL failure was not reported clearly.' }
    if ($errorText -match 'do-not-report-this-content') { throw 'Failure output disclosed fixture contents.' }
    if ([IO.File]::ReadAllText($credential) -cne $beforeFailure) { throw 'Failed credential replacement changed the existing destination.' }
    if (@(Get-ChildItem -LiteralPath $root -Filter '.frantastic-*.tmp' -Force).Count -ne 0) { throw 'Failed operation left a temporary file.' }
    Assert-ProtectedFile $credential $beforeFailure
    Write-Host 'PASS: injected ACL failure is fail-closed, redacted, cleans its temporary file, and preserves destination'

    # The API call remains DACL + protected-DACL only and passes a null SACL.
    if ($implementation -match 'SACL_SECURITY_INFORMATION|Get-Acl\s+-Audit|GetAuditRules') {
        throw 'DACL-only API contract was not found in the implementation.'
    }
    Write-Host 'PASS: implementation does not inspect or set audit rules'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
