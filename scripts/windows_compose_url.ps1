function ConvertTo-FrantasticReadyUrl {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string[]] $PortMapping)

    if ($PortMapping.Count -ne 1) {
        throw "Expected one Docker Compose port mapping, received $($PortMapping.Count)."
    }
    $mapping = $PortMapping[0].Trim()
    $portText = $null
    $hostText = $null
    $isIpv6 = $false

    $ipv4Match = [regex]::Match($mapping, '^(?<host>(?:[0-9]{1,3}\.){3}[0-9]{1,3}):(?<port>[0-9]+)$')
    $ipv6Match = [regex]::Match($mapping, '^\[(?<host>[0-9A-Fa-f:.]+)\]:(?<port>[0-9]+)$')
    if ($ipv4Match.Success) {
        $hostText = $ipv4Match.Groups['host'].Value
        $portText = $ipv4Match.Groups['port'].Value
    } elseif ($ipv6Match.Success) {
        $hostText = $ipv6Match.Groups['host'].Value
        $portText = $ipv6Match.Groups['port'].Value
        $isIpv6 = $true
    } else {
        throw "Docker Compose returned an invalid host port mapping: '$mapping'."
    }

    [Net.IPAddress]$address = [Net.IPAddress]::None
    if (-not [Net.IPAddress]::TryParse($hostText, [ref]$address) -or
        -not [Net.IPAddress]::IsLoopback($address) -or
        ($isIpv6 -and $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetworkV6) -or
        (-not $isIpv6 -and $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork)) {
        throw "Docker Compose port mapping is not bound to a loopback address: '$mapping'."
    }

    $port = 0
    if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "Docker Compose returned an invalid published port: '$portText'."
    }

    $urlHost = if ($isIpv6) { "[$($address.ToString())]" } else { $address.ToString() }
    return "http://${urlHost}:$port/lab"
}

function Get-FrantasticReadyUrl {
    param([scriptblock] $DockerInvoker)

    $arguments = @('compose', 'port', '--protocol', 'tcp', 'web', '5000')
    if ($null -eq $DockerInvoker) {
        $output = @(& docker @arguments)
        $exitCode = $LASTEXITCODE
    } else {
        $result = & $DockerInvoker $arguments
        if ($null -eq $result -or
            $null -eq $result.PSObject.Properties['Output'] -or
            $null -eq $result.PSObject.Properties['ExitCode']) {
            throw 'The Docker port query did not return Output and ExitCode.'
        }
        $output = @($result.Output)
        $exitCode = [int]$result.ExitCode
    }

    if ($exitCode -ne 0) {
        throw "Could not determine the published web port from Docker Compose (exit code $exitCode)."
    }
    if ($output.Count -eq 0) {
        throw 'Docker Compose returned no published web port for the web service.'
    }
    return (ConvertTo-FrantasticReadyUrl -PortMapping ([string[]]$output))
}
