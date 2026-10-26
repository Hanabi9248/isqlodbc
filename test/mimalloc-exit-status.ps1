param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$WorkRoot
)
$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This native command-boundary regression requires Windows, not a simulated MSBuild'
}
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
$privateItem = Get-Item -LiteralPath $WorkRoot
if (-not $privateItem.PSIsContainer -or $privateItem.PSProvider.Name -ne 'FileSystem') {
    throw 'Main must supply an existing private filesystem WorkRoot'
}
$privateRoot = [IO.Path]::GetFullPath($privateItem.FullName).TrimEnd('\', '/')
$privatePrefix = $privateRoot + [IO.Path]::DirectorySeparatorChar
$work = [IO.Path]::GetFullPath((Join-Path $privateRoot ('odbc-mimalloc-' + [Guid]::NewGuid().ToString('N'))))
if (-not $work.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($work)).StartsWith('odbc-mimalloc-', [StringComparison]::Ordinal)) {
    throw 'Refusing work directory outside Main private root'
}
[IO.Directory]::CreateDirectory($work) | Out-Null
$oldLocation = Get-Location
$oldExitCode = $global:LASTEXITCODE
$envNames = @('ODBC_FIXTURE_CALL_LOG', 'ODBC_FIXTURE_DEP_STATUS', 'ODBC_FIXTURE_DRIVER_STATUS')
$oldEnv = @{}
foreach ($name in $envNames) { $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$failures = 0

function Get-ActualFunction([string]$file, [string]$functionName) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) { throw "Production source parse errors: $file" }
    $matches = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true))
    if ($matches.Count -ne 1) { throw "Expected exactly one actual $functionName definition" }
    return $matches[0].Extent.Text
}

function Assert-Equal($expected, $actual, [string]$label) {
    if ($expected -cne $actual) { throw "$label expected <$expected>, got <$actual>" }
}

function Run-Case([string]$name, [string]$PlatformName, [bool]$UseAllocator,
    [string]$compilerVersion, [int]$dependencyStatus, [int]$driverStatus,
    [int]$expectedCalls, [int]$expectedExit, [string]$expectedIde) {
    $caseRoot = Join-Path $work $name
    [IO.Directory]::CreateDirectory($caseRoot) | Out-Null
    $pgRoot = Join-Path $caseRoot 'pg-input'
    foreach ($kind in @('include', 'lib', 'bin')) {
        [IO.Directory]::CreateDirectory((Join-Path $pgRoot $kind)) | Out-Null
    }
    # These empty directories ONLY satisfy actual getPGDir/Test-Path input
    # boundaries. They are not a PostgreSQL installation or fake VS tree.
    [xml]$configInfo = [IO.File]::ReadAllText((Join-Path $SourceRoot 'winbuild/configuration_template.xml'))
    foreach ($platformNode in @($configInfo.Configuration.x86, $configInfo.Configuration.x64)) {
        $platformNode.libpq.include = [string](Join-Path $pgRoot 'include')
        $platformNode.libpq.lib = [string](Join-Path $pgRoot 'lib')
        $platformNode.libpq.bin = [string](Join-Path $pgRoot 'bin')
        $platformNode.build_macros = '/p:FixtureMacro=present'
    }
    $logPath = Join-Path $caseRoot 'native-calls.txt'
    [IO.File]::WriteAllText($logPath, '', [Text.Encoding]::ASCII)
    $command = @'
@echo off
>>"%ODBC_FIXTURE_CALL_LOG%" echo %~1
if /I "%~nx1"=="mimalloc.vcxproj" exit /b %ODBC_FIXTURE_DEP_STATUS%
exit /b %ODBC_FIXTURE_DRIVER_STATUS%
'@
    $command = ($command -replace '\r?\n', [Environment]::NewLine) + [Environment]::NewLine
    $msbuildexe = Join-Path $caseRoot 'native-exit-fixture.cmd'
    [IO.File]::WriteAllText($msbuildexe, $command, [Text.Encoding]::ASCII)
    $env:ODBC_FIXTURE_CALL_LOG = $logPath
    $env:ODBC_FIXTURE_DEP_STATUS = [string]$dependencyStatus
    $env:ODBC_FIXTURE_DRIVER_STATUS = [string]$driverStatus
    $UseMimalloc = $UseAllocator
    $VCVersion = $compilerVersion
    $MSToolsV = 'Current'
    $Toolset = 'v142'
    if ($compilerVersion -eq '17.0') { $Toolset = 'v143' }
    $Configuration = 'Release'
    $target = 'Build'
    $DRIVERVERSION = 'fixture-version'
    Set-Location -LiteralPath $caseRoot
    try {
        $global:LASTEXITCODE = 0
        buildPlatform $configInfo $PlatformName
        $observedExit = $LASTEXITCODE
        $calls = @(Get-Content -LiteralPath $logPath)
        Assert-Equal $expectedCalls $calls.Count 'native invocation count'
        Assert-Equal $expectedExit $observedExit 'exit code visible to the existing caller'
        if ($UseAllocator) {
            if (-not $calls[0].Contains(('\' + $expectedIde + '\mimalloc.vcxproj'))) {
                throw 'Expected dependency project/version selection was not observed'
            }
        }
        if ($expectedCalls -gt 1 -or -not $UseAllocator) {
            if (-not $calls[-1].Contains('platformbuild.vcxproj')) { throw 'Expected driver invocation' }
        } elseif (@($calls | Where-Object { $_.Contains('platformbuild.vcxproj') }).Count -ne 0) {
            throw 'Driver must not be invoked after dependency failure'
        }
        Write-Output "PASS $name"
    } catch {
        Write-Output ('FAIL {0}: {1}' -f $name, $_.Exception.Message)
        $script:failures++
    }
}

try {
    # Entire actual definitions, verbatim. Never execute BuildAll top-level
    # discovery/build/install/result-save code or replace the production algorithm.
    . ([ScriptBlock]::Create((Get-ActualFunction (Join-Path $SourceRoot 'winbuild/BuildAll.ps1') 'buildPlatform')))
    . ([ScriptBlock]::Create((Get-ActualFunction (Join-Path $SourceRoot 'winbuild/Psqlodbc-config.psm1') 'getPGDir')))

    Run-Case 'win32-dependency-fails' 'Win32' $true '16.0' 7 0 1 7 'vs2019'
    Run-Case 'x64-dependency-fails' 'x64' $true '16.0' 7 0 1 7 'vs2019'
    Run-Case 'driver-failure-preserved' 'x64' $true '16.0' 0 9 2 9 'vs2019'
    Run-Case 'both-stages-success' 'x64' $true '16.0' 0 0 2 0 'vs2019'
    Run-Case 'without-mimalloc-driver-fails' 'Win32' $false '16.0' 7 9 1 9 ''
    Run-Case 'without-mimalloc-success' 'Win32' $false '16.0' 7 0 1 0 ''
    Run-Case 'vs2022-selection-control' 'x64' $true '17.0' 0 0 2 0 'vs2022'
} finally {
    Set-Location -LiteralPath $oldLocation.Path
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], 'Process') }
    $global:LASTEXITCODE = $oldExitCode
    $deleteTarget = [IO.Path]::GetFullPath($work)
    if (-not $deleteTarget.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($deleteTarget)).StartsWith('odbc-mimalloc-', [StringComparison]::Ordinal)) {
        throw 'Refusing recursive cleanup outside the verified private work directory'
    }
    Remove-Item -LiteralPath $deleteTarget -Recurse -Force
}
if ($failures -ne 0) { throw "$failures dependency-exit cases failed" }
