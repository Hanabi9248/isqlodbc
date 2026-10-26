param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$WorkRoot
)
$ErrorActionPreference = 'Stop'
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath
$privateItem = Get-Item -LiteralPath $WorkRoot
if (-not $privateItem.PSIsContainer -or $privateItem.PSProvider.Name -ne 'FileSystem') {
    throw 'WorkRoot must be an existing private filesystem directory supplied by Main'
}
$privateRoot = [IO.Path]::GetFullPath($privateItem.FullName).TrimEnd('\', '/')
$work = [IO.Path]::GetFullPath((Join-Path $privateRoot ('odbc-config-' + [Guid]::NewGuid().ToString('N'))))
$privatePrefix = $privateRoot + [IO.Path]::DirectorySeparatorChar
if (-not $work.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase) -or
    -not ([IO.Path]::GetFileName($work)).StartsWith('odbc-config-', [StringComparison]::Ordinal)) {
    throw 'Refusing work directory outside the exact private root'
}
[IO.Directory]::CreateDirectory($work) | Out-Null
$originalLocation = Get-Location
$originalProcessDirectory = [Environment]::CurrentDirectory
$originalConfigEnv = $env:PSQLODBC_WCONFIG
$loadedModule = $null
$failures = 0

function Assert-Equal($expected, $actual, [string]$message) {
    if ($expected -cne $actual) {
        throw "$message expected <$expected>, got <$actual>"
    }
}

function Write-FixtureConfig([string]$path, [string]$version) {
    [xml]$xml = Get-Content -LiteralPath (Join-Path $SourceRoot 'winbuild/configuration_template.xml')
    $xml.Configuration.version = $version
    $xml.Save($path)
}

function Read-Version([string]$path) {
    [xml]$xml = Get-Content -LiteralPath $path
    return [string]$xml.Configuration.version
}

function Run-Case([string]$name, [scriptblock]$action) {
    $caseRoot = Join-Path $work $name
    $shellDir = Join-Path $caseRoot 'shell cwd'
    $processDir = Join-Path $caseRoot 'process cwd'
    $movedDir = Join-Path $caseRoot 'later shell cwd'
    $templateDir = Join-Path $caseRoot 'templates'
    foreach ($dir in @($shellDir, $processDir, $movedDir, $templateDir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $dir 'settings')) | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $SourceRoot 'winbuild/configuration_template.xml') -Destination (Join-Path $templateDir 'configuration_template.xml')
    Set-Location -LiteralPath $shellDir
    [Environment]::CurrentDirectory = $processDir
    $env:PSQLODBC_WCONFIG = $null
    try {
        & $action
        Write-Output "PASS $name"
    } catch {
        Write-Output ('FAIL {0}: {1}' -f $name, $_.Exception.Message)
        $script:failures++
    }
}

try {
    # Import the complete actual module; no cmdlet/module/.NET XML substitutes.
    $loadedModule = Import-Module (Join-Path $SourceRoot 'winbuild/Psqlodbc-config.psm1') -Force -PassThru

    Run-Case 'relative-existing-save' {
        $relative = 'settings/custom.xml'
        $intended = Join-Path $shellDir $relative
        $decoy = Join-Path $processDir $relative
        Write-FixtureConfig $intended '01.00.0001'
        Write-FixtureConfig $decoy '09.00.0009'
        $config = LoadConfiguration $relative $templateDir
        Assert-Equal '01.00.0001' ([string]$config.Configuration.version) 'load uses shell directory'
        $config.Configuration.version = '02.00.0002'
        Set-Location -LiteralPath $movedDir
        SaveConfiguration $config
        Assert-Equal '02.00.0002' (Read-Version $intended) 'save must update loaded config'
        Assert-Equal '09.00.0009' (Read-Version $decoy) 'process-CWD decoy must remain unchanged'
    }

    Run-Case 'relative-new-initialization' {
        $relative = 'settings/new.xml'
        $intended = Join-Path $shellDir $relative
        $decoy = Join-Path $processDir $relative
        $config = LoadConfiguration $relative $templateDir
        Assert-Equal $true (Test-Path -LiteralPath $intended) 'init must create under shell directory'
        Assert-Equal $false (Test-Path -LiteralPath $decoy) 'init must not create under process directory'
    }

    Run-Case 'relative-environment-path' {
        $relative = 'settings/environment.xml'
        $intended = Join-Path $shellDir $relative
        $decoy = Join-Path $processDir $relative
        Write-FixtureConfig $intended '01.00.0001'
        Write-FixtureConfig $decoy '09.00.0009'
        $env:PSQLODBC_WCONFIG = $relative
        $config = LoadConfiguration '' $templateDir
        $config.Configuration.version = '03.00.0003'
        Set-Location -LiteralPath $movedDir
        SaveConfiguration $config
        Assert-Equal '03.00.0003' (Read-Version $intended) 'environment path retains load location'
        Assert-Equal '09.00.0009' (Read-Version $decoy) 'environment decoy unchanged'
    }

    Run-Case 'absolute-config-control' {
        $intended = Join-Path $shellDir 'settings/absolute.xml'
        Write-FixtureConfig $intended '01.00.0001'
        $config = LoadConfiguration $intended $templateDir
        $config.Configuration.version = '04.00.0004'
        Set-Location -LiteralPath $movedDir
        SaveConfiguration $config
        Assert-Equal '04.00.0004' (Read-Version $intended) 'absolute path unchanged'
    }

    Run-Case 'default-config-control' {
        $intended = Join-Path $templateDir 'configuration.xml'
        $config = LoadConfiguration '' $templateDir
        Assert-Equal $true (Test-Path -LiteralPath $intended) 'default initialized under absolute script directory'
        $config.Configuration.version = '05.00.0005'
        Set-Location -LiteralPath $movedDir
        SaveConfiguration $config
        Assert-Equal '05.00.0005' (Read-Version $intended) 'default save path unchanged'
    }
} finally {
    $env:PSQLODBC_WCONFIG = $originalConfigEnv
    Set-Location -LiteralPath $originalLocation.Path
    [Environment]::CurrentDirectory = $originalProcessDirectory
    if ($null -ne $loadedModule) {
        Remove-Module -ModuleInfo $loadedModule
    }
    # Recheck the absolute deletion target before recursive cleanup.
    $deleteTarget = [IO.Path]::GetFullPath($work)
    if (-not $deleteTarget.StartsWith($privatePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($deleteTarget)).StartsWith('odbc-config-', [StringComparison]::Ordinal)) {
        throw 'Refusing cleanup outside private work directory'
    }
    Remove-Item -LiteralPath $deleteTarget -Recurse -Force
}
if ($failures -ne 0) {
    throw "$failures configuration path cases failed"
}

