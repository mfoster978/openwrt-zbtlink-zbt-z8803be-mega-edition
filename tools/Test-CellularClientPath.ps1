param(
    [switch]$Https
)

$routerRoute = Find-NetRoute -RemoteIPAddress '192.168.1.1' -ErrorAction Stop
$sourceAddress = @($routerRoute | Where-Object {
    $_.IPAddress -and $_.AddressFamily -eq 'IPv4'
} | Select-Object -ExpandProperty IPAddress)[0]
if (-not $sourceAddress) { throw 'No IPv4 source address toward the router was found.' }
$internetRoute = @(Find-NetRoute -RemoteIPAddress '1.1.1.1' -LocalIPAddress $sourceAddress |
    Where-Object { $_.NextHop })
if ($internetRoute.Count -ne 1 -or $internetRoute[0].NextHop -ne '192.168.1.1') {
    throw 'The diagnostic destination is not confirmed to route through this router.'
}
Write-Output ("VerifiedInterface=" + $internetRoute[0].InterfaceAlias)

# TTL is set only on each temporary test socket, not on Windows or the router.
$results = foreach ($ttl in @(128, 64, 65, 128)) {
    $localEndpoint = [Net.IPEndPoint]::new([Net.IPAddress]::Parse($sourceAddress), 0)
    $client = [Net.Sockets.TcpClient]::new($localEndpoint)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $connectMs = $null
    $outcome = 'not_started'
    $stage = 'tcp'
    $tlsStream = $null
    try {
        $client.Client.SetSocketOption(
            [Net.Sockets.SocketOptionLevel]::IP,
            [Net.Sockets.SocketOptionName]::IpTimeToLive,
            [int]$ttl
        )
        $port = 80
        if ($Https) { $port = 443 }
        if (-not $client.ConnectAsync('1.1.1.1', $port).Wait(4000)) {
            throw [TimeoutException]::new('Connection deadline exceeded.')
        }
        $connectMs = $timer.ElapsedMilliseconds
        $client.ReceiveTimeout = 3000
        $client.SendTimeout = 3000
        $stream = $client.GetStream()
        if ($Https) {
            $stage = 'tls'
            $tlsStream = [Net.Security.SslStream]::new($stream, $false)
            $certificates = [Security.Cryptography.X509Certificates.X509CertificateCollection]::new()
            $authentication = $tlsStream.AuthenticateAsClientAsync(
                'one.one.one.one', $certificates,
                [Security.Authentication.SslProtocols]::Tls12, $true
            )
            if (-not $authentication.Wait(4000)) {
                throw [TimeoutException]::new('TLS deadline exceeded.')
            }
            $tlsStream.ReadTimeout = 3000
            $tlsStream.WriteTimeout = 3000
            $stream = $tlsStream
        }
        $stage = 'http'
        $request = [Text.Encoding]::ASCII.GetBytes(
            "GET /cdn-cgi/trace HTTP/1.1`r`nHost: one.one.one.one`r`nConnection: close`r`n`r`n"
        )
        $stream.Write($request, 0, $request.Length)
        $buffer = New-Object byte[] 1024
        $received = $stream.Read($buffer, 0, $buffer.Length)
        $text = [Text.Encoding]::ASCII.GetString($buffer, 0, $received)
        if ($text -match '^(HTTP/1\.[01] [1-5][0-9]{2})') {
            $outcome = $Matches[1]
        }
        else {
            $outcome = 'no_recognized_http_status'
        }
    }
    catch {
        $outcome = $_.Exception.GetBaseException().GetType().Name
    }
    finally {
        $timer.Stop()
        $client.Close()
        if ($tlsStream) { $tlsStream.Dispose() }
    }
    [pscustomobject]@{
        PacketTtl = $ttl
        LastStage = $stage
        ConnectMs = $connectMs
        Result = $outcome
        TotalMs = $timer.ElapsedMilliseconds
    }
}
$results | Format-Table -AutoSize
