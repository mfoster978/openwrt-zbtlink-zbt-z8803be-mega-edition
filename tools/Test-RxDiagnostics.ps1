$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'Invoke-PinnedRouterScript.ps1'
$builder = Join-Path $PSScriptRoot 'New-RxDiagnosticBundle.ps1'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('zbt-rx-fixtures-' + [Guid]::NewGuid().ToString('N') + '.sh')
try {
    & $builder -Mode Fixtures -OutputPath $temporary | Out-Null
    & $runner -ScriptPath $temporary -ArtifactName rx-fixture-syntax -TimeoutSeconds 15 -SyntaxOnly
    & $runner -ScriptPath $temporary -ArtifactName rx-isolated-fixtures -TimeoutSeconds 100
}
finally {
    if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
}
