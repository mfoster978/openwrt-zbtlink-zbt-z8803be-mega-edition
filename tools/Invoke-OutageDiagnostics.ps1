param(
    [string]$Router = '192.168.1.1',
    [ValidateSet('overview', 'details', 'cycle-link', 'reconnect', 'power-cycle', 'verify', 'usb-evidence')]
    [string]$Diagnostic = 'overview'
)

$workspace = Split-Path -Parent $PSScriptRoot
$artifactDirectory = Join-Path $workspace 'artifacts'
New-Item -ItemType Directory -Path $artifactDirectory -Force -ErrorAction Stop | Out-Null
$sshCommand = Get-Command ssh.exe -ErrorAction Stop
$scriptName = 'router-outage-diagnostics.sh'
if ($Diagnostic -eq 'details') { $scriptName = 'router-outage-details.sh' }
if ($Diagnostic -eq 'cycle-link') { $scriptName = 'router-cycle-modem1-link.sh' }
if ($Diagnostic -eq 'reconnect') { $scriptName = 'router-reconnect-modem1.sh' }
if ($Diagnostic -eq 'power-cycle') { $scriptName = 'router-power-cycle-modem1.sh' }
if ($Diagnostic -eq 'verify') { $scriptName = 'router-verify-recovery.sh' }
if ($Diagnostic -eq 'usb-evidence') { $scriptName = 'router-usb-evidence.sh' }
$scriptText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot $scriptName))
$sshArguments = @(
    '-T',
    '-o', 'ConnectTimeout=10',
    '-o', 'ConnectionAttempts=1',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'ForwardAgent=no',
    '-o', 'ForwardX11=no',
    '-o', 'NumberOfPasswordPrompts=1',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=2',
    ('root@' + $Router),
    "tr -d '\r' | sh"
)

# Credentials are entered only at SSH's terminal prompt and are not captured.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logPath = Join-Path $artifactDirectory ("outage-$Diagnostic-$stamp.txt")
$writer = [IO.StreamWriter]::new($logPath, $false, [Text.UTF8Encoding]::new($false))
try {
    $scriptText | & $sshCommand.Source @sshArguments | ForEach-Object {
        $writer.WriteLine([string]$_)
        $writer.Flush()
        Write-Output $_
    }
    $sshExitCode = $LASTEXITCODE
}
finally {
    $writer.Dispose()
}
Write-Output ("DiagnosticArtifact=" + $logPath)
if ($sshExitCode -ne 0) {
    throw "Router operation '$Diagnostic' exited with code $sshExitCode."
}
