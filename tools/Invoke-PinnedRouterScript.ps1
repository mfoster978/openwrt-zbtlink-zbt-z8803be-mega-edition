param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,
    [ValidatePattern('^[a-z0-9-]+$')]
    [string]$ArtifactName = 'diagnostic',
    [ValidateRange(5, 3600)]
    [int]$TimeoutSeconds = 120,
    [switch]$SyntaxOnly
)

$ErrorActionPreference = 'Stop'
$client = 'C:\Program Files\PuTTY\plink.exe'
if (-not (Test-Path -LiteralPath $client -PathType Leaf)) {
    throw 'The verified PuTTY client is unavailable.'
}
if ([string]::IsNullOrEmpty($env:ZBT_DIAG_PASSWORD)) {
    throw 'The process-only router credential is unavailable.'
}
$scriptText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScriptPath).Path)
$scriptText = $scriptText.Replace("`r`n", "`n").Replace("`r", "`n")
$readyMarker = 'ZBT_STDIN_READY_' + [Guid]::NewGuid().ToString('N')
$remoteShell = 'sh'
if ($SyntaxOnly) { $remoteShell = 'sh -n' }
$commandFile = Join-Path ([IO.Path]::GetTempPath()) ('zbt-command-' + [Guid]::NewGuid().ToString('N') + '.sh')
$workspace = Split-Path -Parent $PSScriptRoot
$artifactDirectory = Join-Path $workspace 'artifacts'
New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$artifactPath = Join-Path $artifactDirectory ("$ArtifactName-$stamp.txt")
$process = New-Object System.Diagnostics.Process

try {
    # Keep the SSH exec request small; send script bytes only after authentication.
    $remoteCommand = "printf '%s\n' '$readyMarker'; $remoteShell"
    [IO.File]::WriteAllText($commandFile, $remoteCommand, [Text.UTF8Encoding]::new($false))
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $client
    $startInfo.Arguments = '-ssh -T -noagent -noshare -no-trivial-auth -no-antispoof -hostkey "SHA256:VHfHLIf0EqZ5M11tTkBld5OQvywdm0jbMSfOy9/LIDI" -l root -m "' + $commandFile + '" 192.168.1.1'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables.Remove('ZBT_DIAG_PASSWORD')
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $errorTask = $process.StandardError.ReadToEndAsync()
    # The password is the only input available to Plink until the remote marker.
    $process.StandardInput.WriteLine($env:ZBT_DIAG_PASSWORD)
    $process.StandardInput.Flush()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $prefix = New-Object Text.StringBuilder
    $ready = $false
    while ($clock.ElapsedMilliseconds -lt 15000) {
        $lineTask = $process.StandardOutput.ReadLineAsync()
        $remaining = [Math]::Max(1, 15000 - [int]$clock.ElapsedMilliseconds)
        if (-not $lineTask.Wait($remaining)) { break }
        $line = $lineTask.Result
        if ($null -eq $line) { break }
        if ($line.EndsWith($readyMarker)) { $ready = $true; break }
        [void]$prefix.AppendLine($line.Replace("root@192.168.1.1's password: ", ''))
    }
    if (-not $ready) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        throw ('SSH did not reach the authenticated script-ready marker. ' + $errorTask.Result)
    }
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $process.StandardInput.Write($scriptText + "`n")
    $process.StandardInput.Close()
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        $process.Kill()
        $process.WaitForExit()
    }
    $exitCode = $process.ExitCode
    $output = $prefix.ToString() + $outputTask.Result.Replace("root@192.168.1.1's password: ", '')
    $errorOutput = $errorTask.Result.Replace("root@192.168.1.1's password: ", '')
    $artifact = $output + "`nSSH_EXIT=$exitCode`nLOCAL_TIMEOUT=$timedOut`n"
    if (-not [string]::IsNullOrWhiteSpace($errorOutput)) {
        $artifact += "SSH_STDERR`n$errorOutput"
    }
    [IO.File]::WriteAllText($artifactPath, $artifact, [Text.UTF8Encoding]::new($false))
    Write-Output $artifact
    Write-Output ("DiagnosticArtifact=" + $artifactPath)
    if ($timedOut) {
        throw 'The local SSH time limit expired; remote completion is not confirmed.'
    }
    if ($exitCode -ne 0) {
        throw "The router command exited with code $exitCode."
    }
}
finally {
    $process.Dispose()
    if ([IO.File]::Exists($commandFile)) {
        [IO.File]::Delete($commandFile)
    }
}
