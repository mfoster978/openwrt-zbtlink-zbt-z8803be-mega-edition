param(
    [string]$Router = '192.168.1.1'
)

$workspace = Split-Path -Parent $PSScriptRoot
$tarCommand = Get-Command tar.exe -ErrorAction Stop
$sshCommand = Get-Command ssh.exe -ErrorAction Stop
$sourceDirectory = Join-Path $workspace 'original'
$artifactDirectory = Join-Path $workspace 'artifacts'
New-Item -ItemType Directory -Path $sourceDirectory, $artifactDirectory -Force -ErrorAction Stop | Out-Null

$scriptText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'router-preflight.sh'))
$sshArguments = @(
    '-T',
    '-o', 'ConnectTimeout=10',
    '-o', 'ConnectionAttempts=1',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'ForwardAgent=no',
    '-o', 'ForwardX11=no',
    '-o', 'NumberOfPasswordPrompts=1',
    '-o', 'ServerAliveInterval=30',
    ('root@' + $Router),
    "tr -d '\r' | sh"
)

# SSH reads the password from its terminal; no credential is stored here.
$outputLines = @($scriptText | & $sshCommand.Source @sshArguments)
$sshExitCode = $LASTEXITCODE
if ($sshExitCode -ne 0) {
    foreach ($line in $outputLines) {
        if ($line -eq '_ZBT_PROGRAM_ARCHIVE_BEGIN_') { break }
        Write-Output $line
    }
    throw "Router preflight exited with code $sshExitCode. No deployment was attempted."
}

$begin = [Array]::IndexOf($outputLines, '_ZBT_PROGRAM_ARCHIVE_BEGIN_')
$end = [Array]::IndexOf($outputLines, '_ZBT_PROGRAM_ARCHIVE_END_')
if ($begin -lt 0 -or $end -le ($begin + 1)) {
    throw 'Preflight did not return a complete program archive. No deployment was attempted.'
}

$encodedArchive = ($outputLines[($begin + 1)..($end - 1)] -join '').Trim()
if ($encodedArchive.Length -gt 8388608 -or $encodedArchive -notmatch '^[A-Za-z0-9+/]*={0,2}$') {
    throw 'Unexpected program archive encoding or size.'
}
$archivePath = Join-Path $artifactDirectory 'router-programs-original.tar'
[IO.File]::WriteAllBytes($archivePath, [Convert]::FromBase64String($encodedArchive))

$archiveEntries = @(& $tarCommand.Source -tf $archivePath)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the source archive.' }
$allowedEntries = @(
    'usr/sbin/zbt-qmodem-watchdog-loop',
    'etc/init.d/zbt_qmodem_watchdog',
    'etc/hotplug.d/usb/40-zbt-qmodem-autoenable',
    'usr/sbin/zbt-modem-led-poller',
    'etc/init.d/zbt-modem-leds',
    'etc/hotplug.d/net/20-zbt-modem-led',
    'usr/share/qmodem/modem_dial.sh',
    'etc/init.d/qmodem_network',
    'usr/sbin/zbt-modem-nat-probe',
    'etc/hotplug.d/iface/60-zbt-ttl-probe',
    'etc/hotplug.d/net/15-zbt-rndis-auto'
)
foreach ($entry in $archiveEntries) {
    if ($allowedEntries -notcontains $entry) {
        throw "Unexpected source archive member: $entry"
    }
}
& $tarCommand.Source -xf $archivePath -C $sourceDirectory
if ($LASTEXITCODE -ne 0) { throw 'Could not extract the reviewed program source.' }

$safeOutput = @($outputLines[0..($begin - 1)])
$logPath = Join-Path $artifactDirectory 'preflight.txt'
[IO.File]::WriteAllLines($logPath, [string[]]$safeOutput, [Text.UTF8Encoding]::new($false))
$safeOutput | Write-Output
[pscustomobject]@{
    OriginalSource = $sourceDirectory
    PreflightOutput = $logPath
    ArchiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
} | Format-List
