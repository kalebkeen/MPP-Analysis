<#
.SYNOPSIS
  Regenerates the embedded base64 payloads in PA-Pipeline-Setup.cs from the
  live source files (PA-Pipeline.ps1 and the 9 Python stage scripts), and
  stages the bundled CPython installer where Build-Setup.bat expects it.

.DESCRIPTION
  PA-Pipeline-Setup.cs embeds PA-Pipeline.ps1 and the 9 stage scripts as
  frozen base64 string constants so the compiled installer has zero external
  file dependencies for those. The embedding is a separate step from the
  compile, and this script IS that step. Build-Setup.bat now runs it
  automatically before every compile (its step 2), so a rebuild can no longer
  silently ship stale embedded sources; running it standalone is still fine
  when you only want to refresh the .cs without building.

  The bundled CPython installer (~26MB) and Java runtime (~47MB) are NOT
  embedded as base64 string constants like the other files - a real test
  compile showed csc.exe (v4.0.30319) hard-fails on that much string-literal
  data with "No logical space left to create more user strings" (the .NET
  #US metadata heap; splitting into smaller string literals doesn't help,
  since they all still share that one heap). Instead both are embedded as
  .NET PE resources via csc.exe's /resource: flag, wired up directly in
  Build-Setup.bat - which expects the raw files sitting next to
  PA-Pipeline-Setup.cs under exact names. This script copies them there.

.PARAMETER PythonInstallerPath
  Path to python-3.12.x-amd64.exe to stage as the bundled runtime. Omit to
  leave whatever's already next to PA-Pipeline-Setup.cs untouched (e.g. when
  you've only changed PA-Pipeline.ps1 or a stage script and the embedded
  Python version hasn't changed).

.PARAMETER JavaRuntimePath
  Path to a Temurin (or other redistribution-licensed) JRE .zip for Windows
  x64 to stage as the bundled JVM. Omit to leave whatever's already staged
  untouched. Expects the zip to have ONE top-level folder (as Temurin's
  does) - the installer moves that folder's contents up at install time, so
  it doesn't matter what that folder is named.

.PARAMETER CarlitoFontZip
  Path to a zip of the 4 Carlito TTFs (Regular/Bold/Italic/BoldItalic, SIL
  OFL) to stage as the bundled chart/PDF font. Omit to leave whatever's
  already staged untouched. Unlike the Java runtime zip, this one is
  extracted FLAT (no wrapping top-level folder expected).

.EXAMPLE
  .\Embed-Sources.ps1
    Re-embeds PA-Pipeline.ps1 and all 9 stage scripts only.

.EXAMPLE
  .\Embed-Sources.ps1 -PythonInstallerPath C:\downloads\python-3.12.10-amd64.exe -JavaRuntimePath C:\downloads\temurin-21-jre-windows-x64.zip -CarlitoFontZip C:\downloads\carlito-fonts.zip
    Also stages the bundled Python runtime, Java runtime, and Carlito fonts for Build-Setup.bat.
#>
param(
    [string]$SetupPath           = (Join-Path $PSScriptRoot 'PA-Pipeline-Setup.cs'),
    [string]$AppPs1Path          = (Join-Path $PSScriptRoot 'PA-Pipeline.ps1'),
    [string]$PythonInstallerPath = '',
    [string]$JavaRuntimePath     = '',
    [string]$CarlitoFontZip      = ''
)

$ErrorActionPreference = 'Stop'

# Must match Build-Setup.bat's PYTHON_INSTALLER/JAVA_RUNTIME_ZIP variables and
# the resource names baked into PA-Pipeline-Setup.cs
# (Program.GetPythonInstallerBytes / JAVA_RUNTIME_RESOURCE_NAME).
$PythonInstallerTargetName = 'python-3.12.10-amd64.exe'
$JavaRuntimeTargetName     = 'temurin-21-jre-windows-x64.zip'
$CarlitoFontTargetName     = 'carlito-fonts.zip'

function Get-Base64OfFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [Convert]::ToBase64String($bytes)
}

function Set-B64Const {
    param([string]$Text, [string]$ConstName, [string]$NewB64)
    $pattern = '(?m)^(\s*public const string ' + [regex]::Escape($ConstName) + '\s*=\s*")[^"]*(";\s*)$'
    $m = [regex]::Match($Text, $pattern)
    if (-not $m.Success) { throw "Could not find constant $ConstName in $SetupPath" }
    $replacement = $m.Groups[1].Value + $NewB64 + $m.Groups[2].Value
    return $Text.Substring(0, $m.Index) + $replacement + $Text.Substring($m.Index + $m.Length)
}

if (-not (Test-Path -LiteralPath $SetupPath))  { throw "Setup file not found: $SetupPath" }
if (-not (Test-Path -LiteralPath $AppPs1Path)) { throw "App script not found: $AppPs1Path" }

$content = [System.IO.File]::ReadAllText($SetupPath)

Write-Host "Re-embedding PA-Pipeline.ps1 -> APP_SOURCE_B64"
$content = Set-B64Const -Text $content -ConstName 'APP_SOURCE_B64' -NewB64 (Get-Base64OfFile $AppPs1Path)

$stageMap = [ordered]@{
    'extract_snapshots.py'     = 'SCRIPT_C_B64'
    'resolve_wbs.py'           = 'SCRIPT_D_B64'
    'construction_variance.py' = 'SCRIPT_E_B64'
    'critical_path.py'         = 'SCRIPT_F_B64'
    'forward_look.py'          = 'SCRIPT_G_B64'
    'buyout_analysis.py'       = 'SCRIPT_H_B64'
    'generate_charts.py'       = 'SCRIPT_K_B64'
    'assemble_pdf.py'          = 'SCRIPT_L_B64'
    'run_qc.py'                = 'SCRIPT_M_B64'
}
foreach ($file in $stageMap.Keys) {
    $path = Join-Path $PSScriptRoot $file
    if (Test-Path -LiteralPath $path) {
        Write-Host "Re-embedding $file -> $($stageMap[$file])"
        $content = Set-B64Const -Text $content -ConstName $stageMap[$file] -NewB64 (Get-Base64OfFile $path)
    } else {
        Write-Warning "Skipping $file - not found next to this script"
    }
}

[System.IO.File]::WriteAllText($SetupPath, $content, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Done. Wrote $SetupPath"

if ($PythonInstallerPath -ne '') {
    if (-not (Test-Path -LiteralPath $PythonInstallerPath)) { throw "Python installer not found: $PythonInstallerPath" }
    $target = Join-Path $PSScriptRoot $PythonInstallerTargetName
    Write-Host "Staging bundled Python installer -> $target"
    Copy-Item -LiteralPath $PythonInstallerPath -Destination $target -Force
} else {
    Write-Host "No -PythonInstallerPath given - leaving the staged Python installer (if any) untouched."
}

if ($JavaRuntimePath -ne '') {
    if (-not (Test-Path -LiteralPath $JavaRuntimePath)) { throw "Java runtime zip not found: $JavaRuntimePath" }
    $target = Join-Path $PSScriptRoot $JavaRuntimeTargetName
    Write-Host "Staging bundled Java runtime -> $target"
    Copy-Item -LiteralPath $JavaRuntimePath -Destination $target -Force
} else {
    Write-Host "No -JavaRuntimePath given - leaving the staged Java runtime (if any) untouched."
}

if ($CarlitoFontZip -ne '') {
    if (-not (Test-Path -LiteralPath $CarlitoFontZip)) { throw "Carlito font zip not found: $CarlitoFontZip" }
    $target = Join-Path $PSScriptRoot $CarlitoFontTargetName
    Write-Host "Staging bundled Carlito fonts -> $target"
    Copy-Item -LiteralPath $CarlitoFontZip -Destination $target -Force
} else {
    Write-Host "No -CarlitoFontZip given - leaving the staged Carlito fonts (if any) untouched."
}
