$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/windows_compose_url.ps1')

function Assert-Equal([string] $Actual, [string] $Expected, [string] $Label) {
    if ($Actual -cne $Expected) { throw "${Label}: expected '$Expected', received '$Actual'." }
    Write-Host "PASS: $Label"
}

function Assert-Throws([scriptblock] $Action, [string] $ExpectedMessage, [string] $Label) {
    $thrown = $false
    try { & $Action } catch {
        $thrown = $true
        if ($_.Exception.Message -notlike "*$ExpectedMessage*") { throw }
    }
    if (-not $thrown) { throw "${Label}: expected a safe failure." }
    Write-Host "PASS: $Label"
}

$defaultInvoker = {
    param([string[]] $Arguments)
    if (($Arguments -join ' ') -cne 'compose port --protocol tcp web 5000') {
        throw "Unexpected Docker Compose query: $($Arguments -join ' ')"
    }
    [pscustomobject]@{ Output = @('127.0.0.1:5080'); ExitCode = 0 }
}
$customInvoker = {
    param([string[]] $Arguments)
    if (($Arguments -join ' ') -cne 'compose port --protocol tcp web 5000') {
        throw "Unexpected Docker Compose query: $($Arguments -join ' ')"
    }
    [pscustomobject]@{ Output = @('127.0.0.1:15080'); ExitCode = 0 }
}

Assert-Equal (Get-FrantasticReadyUrl -DockerInvoker $defaultInvoker) 'http://127.0.0.1:5080/lab' 'default Compose mapping'
Assert-Equal (Get-FrantasticReadyUrl -DockerInvoker $customInvoker) 'http://127.0.0.1:15080/lab' 'custom Compose mapping'
Assert-Equal (ConvertTo-FrantasticReadyUrl -PortMapping @('[::1]:15080')) 'http://[::1]:15080/lab' 'IPv6 loopback mapping'

Assert-Throws { ConvertTo-FrantasticReadyUrl -PortMapping @('') } 'invalid host port mapping' 'empty Compose mapping'
Assert-Throws { ConvertTo-FrantasticReadyUrl -PortMapping @('0.0.0.0:15080') } 'not bound to a loopback address' 'wildcard binding rejected'
Assert-Throws { ConvertTo-FrantasticReadyUrl -PortMapping @('127.0.0.1:65536') } 'invalid published port' 'out-of-range port rejected'
Assert-Throws { ConvertTo-FrantasticReadyUrl -PortMapping @('127.0.0.1:15080', '127.0.0.1:15081') } 'Expected one Docker Compose port mapping' 'ambiguous mapping rejected'
Assert-Throws { Get-FrantasticReadyUrl -DockerInvoker { param($Arguments) [pscustomobject]@{ Output = @(); ExitCode = 1 } } } 'exit code 1' 'Compose query failure rejected'
Assert-Throws { Get-FrantasticReadyUrl -DockerInvoker { param($Arguments) [pscustomobject]@{ Output = @('not-a-port'); ExitCode = 0 } } } 'invalid host port mapping' 'malformed mapping rejected'
Assert-Throws { Get-FrantasticReadyUrl -DockerInvoker { param($Arguments) [pscustomobject]@{ Output = @(); ExitCode = 0 } } } 'no published web port' 'empty mapping rejected'
