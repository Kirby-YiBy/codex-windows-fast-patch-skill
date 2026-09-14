[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
$LogPrefix = '[test-computer-use-surface]'
$scriptPath = Join-Path $PSScriptRoot 'patch_codex_fast_mode_windows_msix.ps1'

$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
  $scriptPath,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -ne 0) {
  throw "patch script did not parse: $($parseErrors[0].Message)"
}

$patcherAst = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value.Contains("const marker = 'CODEX_CUA_WINDOWS_SURFACE_V1';") -and
      $node.Value.Contains('current CUA surface anchors not found exactly once')
  }, $true)
if (-not $patcherAst) {
  throw 'embedded Windows CUA surface patcher was not found in the patch script'
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
  $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
  throw 'node is required for the Windows CUA surface regression test'
}

$temp = [System.IO.Path]::GetFullPath($TemporaryRoot)
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$fixtureRoot = Join-Path $temp ('computer-use-surface-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
$patcherPath = Join-Path $fixtureRoot 'PatchComputerUseSurface.cjs'
[System.IO.File]::WriteAllText($patcherPath, $patcherAst.Value, [System.Text.UTF8Encoding]::new($false))

function Invoke-PatcherFixture {
  param(
    [string]$Name,
    [string]$Source,
    [int]$ExpectedExitCode
  )

  $assetPath = Join-Path $fixtureRoot ($Name + '.js')
  [System.IO.File]::WriteAllText($assetPath, $Source, [System.Text.UTF8Encoding]::new($false))
  $previousErrorActionPreference = $ErrorActionPreference
  $hasNativePreference = Test-Path Variable:\PSNativeCommandUseErrorActionPreference
  $previousNativePreference = $null
  try {
    $ErrorActionPreference = 'Continue'
    if ($hasNativePreference) {
      $previousNativePreference = $PSNativeCommandUseErrorActionPreference
      $PSNativeCommandUseErrorActionPreference = $false
    }
    $output = @(& $node.Source $patcherPath $assetPath 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($hasNativePreference) {
      $PSNativeCommandUseErrorActionPreference = $previousNativePreference
    }
  }
  if ($exitCode -ne $ExpectedExitCode) {
    throw "$Name patcher exit mismatch: expected=$ExpectedExitCode actual=$exitCode output=$($output -join ' | ')"
  }
  return [pscustomobject]@{
    AssetPath = $assetPath
    Output = (($output | ForEach-Object { [string]$_ }) -join "`n").Trim()
  }
}

$positiveSource = @'
function exposePlugin(){if(!r.installed||i==null||a&&e.platform!==`darwin`)return null;return true;}
function buildSurface(){p=f&&l.platform===`darwin`&&t.computerUse&&u.enabled&&u.paths.serviceAppPath!=null;return p;}
'@
$positive = Invoke-PatcherFixture -Name 'current-darwin-gates' -Source $positiveSource -ExpectedExitCode 0
if ($positive.Output -cne 'patched') {
  throw "positive fixture did not report patched: $($positive.Output)"
}
$patched = [System.IO.File]::ReadAllText($positive.AssetPath)
if (-not $patched.Contains('CODEX_CUA_WINDOWS_SURFACE_V1')) {
  throw 'positive fixture is missing the patch marker'
}
if (-not $patched.Contains('e.platform!==`darwin`&&e.platform!==`win32`')) {
  throw 'positive fixture did not admit win32 in the plugin exposure gate'
}
if (-not $patched.Contains('t.computerUse&&t.computerUseNodeRepl&&(l.platform===`win32`')) {
  throw 'positive fixture did not admit win32 in the generated CUA surface gate'
}
& $node.Source --check $positive.AssetPath 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw 'positive fixture produced invalid JavaScript'
}

$secondOutput = @(& $node.Source $patcherPath $positive.AssetPath 2>&1)
if ($LASTEXITCODE -ne 0 -or (($secondOutput -join "`n").Trim() -cne 'already-patched')) {
  throw "positive fixture was not idempotent: exit=$LASTEXITCODE output=$($secondOutput -join ' | ')"
}

$negativeSource = 'const unrelated={platform:`darwin`,computerUse:true};'
$negative = Invoke-PatcherFixture -Name 'unknown-layout' -Source $negativeSource -ExpectedExitCode 2
if ($negative.Output -cne 'current CUA surface anchors not found exactly once: plugin=0 surface=0') {
  throw "unknown layout failed for the wrong reason: $($negative.Output)"
}
if ([System.IO.File]::ReadAllText($negative.AssetPath) -cne $negativeSource) {
  throw 'unknown layout was modified'
}

$duplicateSource = $positiveSource + $positiveSource
$duplicate = Invoke-PatcherFixture -Name 'duplicate-anchors' -Source $duplicateSource -ExpectedExitCode 2
if ($duplicate.Output -cne 'current CUA surface anchors not found exactly once: plugin=2 surface=2') {
  throw "duplicate anchors failed for the wrong reason: $($duplicate.Output)"
}
if ([System.IO.File]::ReadAllText($duplicate.AssetPath) -cne $duplicateSource) {
  throw 'duplicate-anchor fixture was modified'
}

Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
Write-Output "Windows CUA surface regression passed: $fixtureRoot"
