# DACL-only file protection for Windows PowerShell 5.1. Do not replace this
# with Set-Acl: its ObjectSecurity persistence abstraction can apply a broader
# security descriptor than the DACL-only operation required here.
if (-not ([System.Management.Automation.PSTypeName]'Frantastic.DaclNative').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Frantastic {
    public static class DaclNative {
        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern uint SetNamedSecurityInfoW(
            string objectName, int objectType, uint securityInfo,
            IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
        public static extern uint GetNamedSecurityInfoW(
            string objectName, int objectType, uint securityInfo,
            out IntPtr owner, out IntPtr group, out IntPtr dacl,
            out IntPtr sacl, out IntPtr securityDescriptor);

        [DllImport("advapi32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetSecurityDescriptorControl(
            IntPtr securityDescriptor, out ushort control, out uint revision);

        [DllImport("kernel32.dll")]
        public static extern IntPtr LocalFree(IntPtr memory);
    }
}
'@ -ErrorAction Stop
}

function Get-LocalFileDaclState([string] $Path) {
    # SE_FILE_OBJECT=1; DACL_SECURITY_INFORMATION=0x4;
    # OWNER_SECURITY_INFORMATION=0x1. No SACL flag is requested.
    $daclFlag = [uint32]4
    $ownerFlag = [uint32]1
    $owner = [IntPtr]::Zero
    $group = [IntPtr]::Zero
    $dacl = [IntPtr]::Zero
    $sacl = [IntPtr]::Zero
    $securityDescriptor = [IntPtr]::Zero
    $status = [Frantastic.DaclNative]::GetNamedSecurityInfoW(
        $Path, 1, ($daclFlag -bor $ownerFlag), [ref]$owner, [ref]$group,
        [ref]$dacl, [ref]$sacl, [ref]$securityDescriptor)
    if ($status -ne 0) { throw [ComponentModel.Win32Exception]::new([int]$status) }
    try {
        if ($dacl -eq [IntPtr]::Zero) { throw 'The file has a NULL DACL.' }
        $control = [uint16]0
        $revision = [uint32]0
        if (-not [Frantastic.DaclNative]::GetSecurityDescriptorControl(
            $securityDescriptor, [ref]$control, [ref]$revision)) {
            throw [ComponentModel.Win32Exception]::new([Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $aclHeader = New-Object byte[] 4
        [Runtime.InteropServices.Marshal]::Copy($dacl, $aclHeader, 0, 4)
        $aclSize = [BitConverter]::ToUInt16($aclHeader, 2)
        if ($aclSize -lt 8) { throw 'The file DACL has an invalid size.' }
        $aclBytes = New-Object byte[] $aclSize
        [Runtime.InteropServices.Marshal]::Copy($dacl, $aclBytes, 0, $aclSize)
        $rawAcl = [Security.AccessControl.RawAcl]::new($aclBytes, 0)
        $ownerSid = [Security.Principal.SecurityIdentifier]::new($owner)
        return [pscustomobject]@{
            OwnerSid = $ownerSid.Value
            DaclProtected = (($control -band 0x1000) -ne 0) # SE_DACL_PROTECTED
            Aces = $rawAcl
        }
    } finally {
        if ($securityDescriptor -ne [IntPtr]::Zero) {
            [void][Frantastic.DaclNative]::LocalFree($securityDescriptor)
        }
    }
}

# Kept as a small function boundary so the Windows test can inject a native
# failure without an environment-variable bypass or a production test mode.
function Set-LocalFileDaclNative([string] $Path, [Security.AccessControl.RawAcl] $Dacl) {
    $bytes = New-Object byte[] $Dacl.BinaryLength
    $Dacl.GetBinaryForm($bytes, 0)
    $memory = [Runtime.InteropServices.Marshal]::AllocHGlobal($bytes.Length)
    try {
        [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $memory, $bytes.Length)
        # DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION.
        # Owner, group and SACL pointers/flags are deliberately absent.
        $flags = [Convert]::ToUInt32('80000004', 16)
        $status = [Frantastic.DaclNative]::SetNamedSecurityInfoW(
            $Path, 1, $flags, [IntPtr]::Zero, [IntPtr]::Zero, $memory, [IntPtr]::Zero)
        if ($status -ne 0) { throw [ComponentModel.Win32Exception]::new([int]$status) }
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($memory)
    }
}

function Assert-LocalFileDacl([string] $Path, [string] $ExpectedOwnerSid) {
    $state = Get-LocalFileDaclState $Path
    if (-not $state.DaclProtected) { throw 'DACL inheritance remains enabled.' }
    if ($state.OwnerSid -cne $ExpectedOwnerSid) { throw 'File owner changed during DACL protection.' }
    $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $expected = @($currentSid, 'S-1-5-18', 'S-1-5-32-544' | Sort-Object -Unique)
    if ($expected.Count -ne 3) { throw 'The current user SID is not distinct from the required service principals.' }
    $found = @{}
    foreach ($ace in $state.Aces) {
        if (-not ($ace -is [Security.AccessControl.CommonAce]) -or
            $ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::AccessAllowed -or
            $ace.AceFlags -ne [Security.AccessControl.AceFlags]::None -or
            $ace.IsCallback -or
            $ace.AccessMask -ne [int][Security.AccessControl.FileSystemRights]::FullControl) {
            throw 'DACL contains a deny, inherited, special, or non-FullControl ACE.'
        }
        $sid = $ace.SecurityIdentifier.Value
        if ($found.ContainsKey($sid)) { throw "DACL contains duplicate ACEs for SID $sid." }
        $found[$sid] = $true
    }
    if ($found.Count -ne 3) { throw 'DACL does not contain exactly three access entries.' }
    foreach ($sid in $expected) {
        if (-not $found.ContainsKey($sid)) { throw "DACL is missing required SID $sid." }
    }
    return $state
}

function Protect-LocalFile([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Sensitive file does not exist: $Path" }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing a symbolic link or reparse point for sensitive file: $Path"
    }
    try {
        $before = Get-LocalFileDaclState $Path
        $ownerSid = $before.OwnerSid
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $sidList = @(
            $currentSid,
            [Security.Principal.SecurityIdentifier]::new('S-1-5-18'),
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
        )
        if (@($sidList | ForEach-Object Value | Sort-Object -Unique).Count -ne 3) {
            throw 'The current user SID is not distinct from the required service principals.'
        }
        $dacl = [Security.AccessControl.RawAcl]::new(2, 3)
        foreach ($sid in $sidList) {
            $ace = [Security.AccessControl.CommonAce]::new(
                [Security.AccessControl.AceFlags]::None,
                [Security.AccessControl.AceQualifier]::AccessAllowed,
                [int][Security.AccessControl.FileSystemRights]::FullControl,
                $sid, $false, $null)
            $dacl.InsertAce($dacl.Count, $ace)
        }
        Set-LocalFileDaclNative $Path $dacl
        [void](Assert-LocalFileDacl $Path $ownerSid)
        return $true
    } catch {
        throw "Could not apply and verify a restrictive DACL on '$Path': $($_.Exception.Message). Check that the current user owns the file and has DACL modification rights; no credential operation was completed."
    }
}

function Write-ProtectedLocalFile([string] $Path, [string] $Content,
    [Text.Encoding] $Encoding, [switch] $ReplaceExisting) {
    $directory = Split-Path -Parent $Path
    $temporary = Join-Path $directory ('.frantastic-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $directory ('.frantastic-' + [Guid]::NewGuid().ToString('N') + '.bak')
    $hadDestination = Test-Path -LiteralPath $Path -PathType Leaf
    $promoted = $false
    $preserveBackup = $false
    try {
        if ($hadDestination -and -not $ReplaceExisting) {
            [void](Protect-LocalFile $Path)
            return $false
        }
        if ($hadDestination) { [void](Protect-LocalFile $Path) }

        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        [void](Protect-LocalFile $temporary)

        $bytes = $Encoding.GetBytes($Content)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::Open,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [void](Protect-LocalFile $temporary)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $expectedHash = [Convert]::ToBase64String($sha.ComputeHash($bytes)) }
        finally { $sha.Dispose() }

        if ($hadDestination) {
            [IO.File]::Replace($temporary, $Path, $backup)
        } else {
            try { [IO.File]::Move($temporary, $Path) }
            catch [IO.IOException] {
                if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw }
                # A concurrent creator won. Preserve it; only verify its ACL.
                [void](Protect-LocalFile $Path)
                return $false
            }
        }
        $promoted = $true
        [void](Protect-LocalFile $Path)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) }
        finally { $sha.Dispose() }
        if ($actualHash -cne $expectedHash) { throw 'Final file contents did not match the staged content.' }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force }
        return $true
    } catch {
        if ($promoted) {
            if (Test-Path -LiteralPath $backup) {
                try {
                    [IO.File]::Replace($backup, $Path, $null)
                    $promoted = $false
                } catch {
                    $preserveBackup = $true
                    throw "Final-file verification failed and rollback was unsuccessful; the prior file is preserved at the protected recovery path '$backup'."
                }
            } elseif (-not $hadDestination -and (Test-Path -LiteralPath $Path)) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            }
        }
        throw "Could not securely write '$Path': $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if (-not $preserveBackup -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}
