<#
.SYNOPSIS
  Regenerates the embedded base64 payloads in PA-Pipeline-Setup.cs from the
  live source files (PA-Pipeline.ps1 and the 9 Python stage scripts), and
  stages the bundled CPython installer where Build-Setup.bat expects it.

.DESCRIPTION
  PA-Pipeline-Setup.cs embeds PA-Pipeline.ps1 and the 9 stage scripts as
  frozen base64 string constants so the compiled installer has zero external
  file dependencies for those. Re-running Build-Setup.bat alone does NOT
  pick up edits to the .ps1 or any .py file - the embedding is a separate
  step, and this script IS that step. Run this whenever PA-Pipeline.ps1 or a
  stage script changes, before rebuilding the installer.

  The bundled CPython installer (~26MB) is NOT embedded as a base64 string
  constant like the other files - a real test compile showed csc.exe
  (v4.0.30319) hard-fails on that much string-literal data with "No logical
  space left to create more user strings" (the .NET #US metadata heap;
  splitting into smaller string literals doesn't help, since they all still
  share that one heap). Instead it's embedded as a .NET PE resource via
  csc.exe's /resource: flag, wired up directly in Build-Setup.bat - which
  expects the raw .exe sitting next to PA-Pipeline-Setup.cs under the exact
  name python-3.12.10-amd64.exe. This script copies it there for you.

.PARAMETER PythonInstallerPath
  Path to python-3.12.x-amd64.exe to stage as the bundled runtime. Omit to
  leave whatever's already next to PA-Pipeline-Setup.cs untouched (e.g. when
  you've only changed PA-Pipeline.ps1 or a stage script and the embedded
  Python version hasn't changed).

.EXAMPLE
  .\Embed-Sources.ps1
    Re-embeds PA-Pipeline.ps1 and all 9 stage scripts only.

.EXAMPLE
  .\Embed-Sources.ps1 -PythonInstallerPath C:\downloads\python-3.12.10-amd64.exe
    Also stages the bundled Python runtime installer for Build-Setup.bat.
#>
param(
    [string]$SetupPath           = (Join-Path $PSScriptRoot 'PA-Pipeline-Setup.cs'),
    [string]$AppPs1Path          = (Join-Path $PSScriptRoot 'PA-Pipeline.ps1'),
    [string]$PythonInstallerPath = ''
)

$ErrorActionPreference = 'Stop'

# Must match Build-Setup.bat's PYTHON_INSTALLER variable and the resource
# name baked into PA-Pipeline-Setup.cs (Program.GetPythonInstallerBytes).
$PythonInstallerTargetName = 'python-3.12.10-amd64.exe'

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
