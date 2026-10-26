param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$WorkRoot
)
$ErrorActionPreference = 'Stop'
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
$privateItem = Get-Item -LiteralPath $WorkRoot
if (-not $privateItem.PSIsContainer -or $privateItem.PSProvider.Name -ne 'FileSystem') {
    throw 'WorkRoot must be a private filesystem directory supplied by Main'
}
$privateRoot = [IO.Path]::GetFullPath($privateItem.FullName).TrimEnd('\', '/')
$work = [IO.Path]::GetFullPath((Join-Path $privateRoot ('odbc-regress-' + [Guid]::NewGuid().ToString('N'))))
$privatePrefix = $privateRoot + [IO.Path]::DirectorySeparatorChar
if (-not $work.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($work)).StartsWith('odbc-regress-', [StringComparison]::Ordinal)) {
    throw 'Refusing private work path'
}
[IO.Directory]::CreateDirectory($work) | Out-Null
$originalLocation = Get-Location
$envNames = @('REG_COUNT_PATH', 'REG_FAIL_CALL', 'REG_RESET_STATUS',
    'COMMON_CONNECTION_STRING_FOR_REGRESSION_TEST', 'MIMALLOC_VERBOSE')
$oldEnv = @{}
foreach ($name in $envNames) {
    $oldEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$failures = 0

function Assert-Equal($expected, $actual, [string]$label) {
    if ($expected -cne $actual) {
        throw "$label expected <$expected>, got <$actual>"
    }
}

function Run-Case([string]$name, [string]$mode, [int]$failCall,
        [int]$resetStatus, [bool]$expectThrow, [int]$expectedCalls, [string]$errorText) {
    $caseRoot = Join-Path $work $name
    $scriptPath = Join-Path $caseRoot 'winbuild'
    $fixtureBin = Join-Path $caseRoot 'bin'
    $testDir = Join-Path $caseRoot 'test'
    foreach ($dir in @($scriptPath, $fixtureBin, $testDir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    # Readable input only: no fixture executes SQL or opens an ODBC connection.
    [IO.File]::WriteAllText((Join-Path $testDir 'sampletables.sql'), '-- boundary input')
    $counter = Join-Path $caseRoot 'calls.txt'
    [IO.File]::WriteAllText($counter, '0', [Text.Encoding]::ASCII)
    $resetCmd = @'
@echo off
exit /b %REG_RESET_STATUS%
'@
    $suiteCmd = @'
@echo off
set /p REG_CALLS=<"%REG_COUNT_PATH%"
set /a REG_CALLS+=1 >nul
>"%REG_COUNT_PATH%" echo %REG_CALLS%
echo fixture-runsuite-call-%REG_CALLS%
if "%REG_FAIL_CALL%"=="%REG_CALLS%" exit /b 7
exit /b 0
'@
    $resetCmd = ($resetCmd -replace '\r?\n', [Environment]::NewLine) + [Environment]::NewLine
    $suiteCmd = ($suiteCmd -replace '\r?\n', [Environment]::NewLine) + [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $fixtureBin 'reset-db.cmd'), $resetCmd, [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $fixtureBin 'runsuite.cmd'), $suiteCmd, [Text.Encoding]::ASCII)
    $env:REG_COUNT_PATH = $counter
    $env:REG_FAIL_CALL = [string]$failCall
    $env:REG_RESET_STATUS = [string]$resetStatus
    $env:COMMON_CONNECTION_STRING_FOR_REGRESSION_TEST = $null
    $env:MIMALLOC_VERBOSE = $null
    $DeclareFetch = $mode
    $SpecificDsn = ''
    $ExpectMimalloc = $false
    Set-Location -LiteralPath $fixtureBin
    try {
        $caught = $false
        $message = ''
        try {
            RunTest $scriptPath 'x64' @('connect')
        } catch {
            $caught = $true
            $message = $_.Exception.Message
        }
        Assert-Equal $expectThrow $caught 'failure propagation'
        Assert-Equal $expectedCalls ([int](Get-Content -LiteralPath $counter)) 'suite invocation count'
        if ($expectThrow -and -not $message.Contains($errorText)) {
            throw "unexpected exception: $message"
        }
        Assert-Equal $true ([string]::IsNullOrEmpty($env:COMMON_CONNECTION_STRING_FOR_REGRESSION_TEST)) 'connection env cleanup'
        Assert-Equal $true ([string]::IsNullOrEmpty($env:MIMALLOC_VERBOSE)) 'mimalloc env cleanup'
        Assert-Equal 'Stop' ([string]$ErrorActionPreference) 'error preference control'
        Write-Output "PASS $name"
    } catch {
        Write-Output ('FAIL {0}: {1}' -f $name, $_.Exception.Message)
        $script:failures++
    }
}

try {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $SourceRoot 'winbuild/regress.ps1'), [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) {
        throw 'Production script parse errors'
    }
    $definitions = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'RunTest'
    }, $true))
    if ($definitions.Count -ne 1) {
        throw 'Expected exactly one actual RunTest definition'
    }
    # Execute this exact complete function definition, not copied test logic.
    # The rest of regress.ps1 is NOT executed: no VS build, DSN registration or driver.
    . ([ScriptBlock]::Create($definitions[0].Extent.Text))

    Run-Case 'default-on-suite-fails' 'on' 1 0 $true 1 'runsuite error'
    Run-Case 'both-first-suite-fails' 'both' 1 0 $true 1 'runsuite error'
    Run-Case 'both-second-suite-fails' 'both' 2 0 $true 2 'runsuite error'
    Run-Case 'both-success-control' 'both' 0 0 $false 2 ''
    Run-Case 'reset-failure-control' 'on' 0 7 $true 0 'reset_db error'
} finally {
    Set-Location -LiteralPath $originalLocation.Path
    foreach ($name in $envNames) {
        [Environment]::SetEnvironmentVariable($name, $oldEnv[$name], 'Process')
    }
    $deleteTarget = [IO.Path]::GetFullPath($work)
    if (-not $deleteTarget.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($deleteTarget)).StartsWith('odbc-regress-', [StringComparison]::Ordinal)) {
        throw 'Refusing recursive cleanup outside private work path'
    }
    Remove-Item -LiteralPath $deleteTarget -Recurse -Force
}
if ($failures -ne 0) {
    throw "$failures regression-status cases failed"
}

