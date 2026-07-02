# =============================================================================
# PA-Pipeline.ps1
# Unified GUI tool: Configure -> Run -> Review a 9-stage construction
# schedule analytics pipeline (Python, driven via a managed venv).
#
# USAGE:
#   PowerShell -ExecutionPolicy Bypass -File "PA-Pipeline.ps1"
#
# REQUIREMENTS:
#   - Windows PowerShell 5.1 or PowerShell 7+
#   - Python 3.9+ (system Python only needed once, to create the venv)
#   - Java on PATH (required by MPXJ/JPype for stage C)
# =============================================================================

Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Collections

[System.Windows.Forms.Application]::EnableVisualStyles()

# =============================================================================
# HELPER: Resolve the folder this app is actually running from.
# $PSScriptRoot is not reliably populated once compiled to an .exe via
# PS2EXE, so fall through several other ways .NET/PowerShell can report
# the running script/assembly location before giving up and using cwd.
# =============================================================================
function Get-AppRoot {
    if ($PSScriptRoot -and $PSScriptRoot -ne '') { return $PSScriptRoot }
    try {
        if ($MyInvocation.MyCommand.Path) { return (Split-Path -Parent $MyInvocation.MyCommand.Path) }
    } catch { }
    try {
        $asmLoc = [System.Reflection.Assembly]::GetEntryAssembly().Location
        if ($asmLoc -and $asmLoc -ne '') { return (Split-Path -Parent $asmLoc) }
    } catch { }
    try {
        $base = [System.AppDomain]::CurrentDomain.BaseDirectory
        if ($base -and $base -ne '') { return $base.TrimEnd('\') }
    } catch { }
    return (Get-Location).Path
}
$script:AppRoot = Get-AppRoot

# =============================================================================
# HELPER: Resolve a per-user, ALWAYS-writable folder for live state
# (project_config.json, venv). $script:AppRoot is typically inside
# C:\Program Files\, which only the elevated installer can write to - the
# running app itself never elevates, so anything it needs to write at
# runtime (config saves, venv creation/reinstall from the Settings tab)
# must live somewhere a normal user can write without admin rights.
# =============================================================================
function Get-DataRoot {
    $dir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PA-Pipeline'
    if (-not (Test-Path -LiteralPath $dir)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch { }
    }
    return $dir
}
$script:DataRoot = Get-DataRoot

# =============================================================================
# GLOBAL STATE
# =============================================================================
$script:Config           = $null
$script:ConfigPath        = Join-Path $script:DataRoot 'project_config.json'

# One-time migration: earlier builds wrote project_config.json next to the
# exe (e.g. in Program Files). If that's the case and nothing has been saved
# to the new writable location yet, carry the old file forward so in-progress
# Tab 1 entries aren't silently lost when this fix takes effect.
if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
    $legacyConfigPath = Join-Path $script:AppRoot 'project_config.json'
    if (($legacyConfigPath -ne $script:ConfigPath) -and (Test-Path -LiteralPath $legacyConfigPath)) {
        try { Copy-Item -LiteralPath $legacyConfigPath -Destination $script:ConfigPath -Force } catch { }
    }
}

$script:Buildings         = [System.Collections.Generic.List[hashtable]]::new()
$script:CancelRequested   = $false
$script:RunningStageCode  = ''
$script:StageRunActive    = $false
$script:CurrentProcess    = $null
# One-time-per-session hint before the first Synthesize click, so a new user
# learns Synthesize needs the (unbundled) Claude Code CLI installed + logged in
# on this machine before they hit the auth-failure path. Declared here because
# Set-StrictMode -Version Latest throws on reading an uninitialized variable.
$script:SynthHintShown    = $false

# Stage definitions in pipeline order (matches the Tab 2 checklist / Run All order)
# Description is one-line summary text shown in the Tab 2 grid only — pulled
# from each script's own module docstring, not part of the project_config.json
# schema (so it carries no Merge-ConfigDefaults / BuildConfigJson parity concern).
$script:Stages = @(
    @{Code='C'; Script='extract_snapshots.py';    Name='Data Extraction';       Description='Parses MS Project XML snapshots into structured parquet data'},
    @{Code='D'; Script='resolve_wbs.py';           Name='WBS Resolver';          Description='Resolves the buyout WBS structure and groups packages by trade'},
    @{Code='E'; Script='construction_variance.py'; Name='Construction Variance'; Description='Rolls up construction schedule variance by bucket and trade'},
    @{Code='F'; Script='critical_path.py';         Name='Critical Path Ledger';  Description='Builds a week-by-week delay ledger from the driving path'},
    @{Code='G'; Script='forward_look.py';          Name='Forward Look';          Description='Building turnover, float health, and path-to-completion look-ahead'},
    @{Code='H'; Script='buyout_analysis.py';       Name='Buyout Analysis';       Description='Procurement and subcontracting workflow variance by package'},
    @{Code='K'; Script='generate_charts.py';       Name='Charting';              Description="Generates the brief's charts and an editable chart data workbook"},
    @{Code='L'; Script='assemble_pdf.py';          Name='PDF Assembly';          Description='Assembles the cover, TOC, and body into the final brief PDF'},
    @{Code='M'; Script='run_qc.py';                Name='Quality Control';       Description='Mechanical QC checks plus optional Opus narrative synthesis'}
)

# pip package name -> python import name, only where they differ
$script:PipImportMap = @{ 'jpype1' = 'jpype' }

# Deep venv smoke test. A plain "import X" per package is NOT enough: an
# interrupted wheel extraction can leave a stub package dir where the import
# succeeds as an empty namespace package (__file__ is None) - that exact state
# once made every pipeline stage die inside pandas' pyarrow compat shim while
# the old per-import check still reported the venv healthy. This imports every
# bootstrap package for real AND requires each to have a __file__. Module list
# must stay in lockstep with pip_packages in Get-DefaultConfig and with the
# same one-liner in PA-Pipeline-Setup.cs (VENV_SMOKE_TEST_CODE).
$script:VenvSmokeTestCode = "import mpxj,jpype,pandas,pyarrow,openpyxl,matplotlib,reportlab,pypdf,pikepdf,pdfplumber,sys; [sys.exit('CORRUPT:'+m.__name__) for m in (mpxj,jpype,pandas,pyarrow,openpyxl,matplotlib,reportlab,pypdf,pikepdf,pdfplumber) if getattr(m,'__file__',None) is None]; print('SMOKE-OK')"

# Strip any ==version pin, then map pip name -> import name.
function Get-PipImportName {
    param([string]$PipSpec)
    $name = ($PipSpec -split '==')[0].Trim()
    if ($script:PipImportMap.ContainsKey($name)) { return $script:PipImportMap[$name] }
    return $name
}

function Invoke-VenvSmokeTest {
    # Returns $true if every bootstrap package imports AND is a real (non-stub)
    # install. Callers that need per-package detail use the Env Check's own
    # per-package loop; this is the cheap pass/fail gate for install/repair.
    param([string]$VenvPython)
    & $VenvPython '-c' $script:VenvSmokeTestCode *> $null
    return ($LASTEXITCODE -eq 0)
}

# =============================================================================
# HELPER: Write text as UTF-8 with NO byte-order-mark.
# Python's json.load() chokes on a BOM, and PS 5.1's "-Encoding utf8" always
# writes one, so every JSON file in this app goes through here instead.
# =============================================================================
function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# =============================================================================
# HELPER: Recursively convert ConvertFrom-Json's PSCustomObject graph into
# nested [ordered hashtable]/arrays so the rest of the app can use one
# consistent shape (and dot-notation works on both equally in PowerShell).
# =============================================================================
function ConvertTo-HashtableDeep {
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = [ordered]@{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $hash[$prop.Name] = ConvertTo-HashtableDeep $prop.Value
        }
        return $hash
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and
        ($InputObject -isnot [string]) -and
        ($InputObject -isnot [System.Collections.IDictionary])) {
        $arr = @()
        foreach ($item in $InputObject) { $arr += ,(ConvertTo-HashtableDeep $item) }
        return ,$arr
    }

    return $InputObject
}

# =============================================================================
# HELPER: Build the default project_config.json structure
# =============================================================================
function Get-DefaultConfig {
    # NOTE: This shape matches what the 9 Python stage scripts actually read
    # (cfg["schedule"], cfg["buildings"]["names"], cfg["construction_variance"]["buckets"],
    # cfg["wbs_resolver"], cfg["paths"]["output_root"], etc.). Fields that require
    # project-specific domain values are scaffolded blank for the user to fill in.
    $venvDir = Join-Path $script:DataRoot 'venv'   # writable per-user location, NOT Program Files
    [ordered]@{
        project = [ordered]@{
            name                 = ''
            sci_project_number   = ''
            type                 = 'multifamily'
            contract_type        = 'GC'
            analysis_status_date = (Get-Date).ToString('yyyy-MM-dd')
        }
        paths = [ordered]@{
            xml_snapshots_folder = ''
            baseline_mpp         = ''
            output_root          = ''
            venv_dir             = $venvDir
            python_exe           = Join-Path $venvDir 'Scripts\python.exe'
            # Bootstrap interpreter used ONLY to create the venv above (python -m venv).
            # NOT the same thing as python_exe - that field is, and always has been, the
            # venv's own interpreter, which is what every pipeline stage actually runs
            # under. Defaults to the installer-bundled runtime next to the exe so venv
            # creation never depends on a PATH-resolved "python" (which on a clean
            # Windows box resolves to the Microsoft Store stub, not a real interpreter -
            # see the Settings tab hint). Override only for advanced/manual use.
            system_python_exe    = Join-Path $script:AppRoot 'python-runtime\python.exe'
        }
        schedule = [ordered]@{
            baseline_date                       = (Get-Date).ToString('yyyy-MM-dd')
            buyout_outline_prefixes             = @()     # REQUIRED — WBS outline number(s) under which ALL buyout work sits, e.g. @('1') or @('1','3.2') for scattered branches
            finish_milestone_task_name          = ''      # REQUIRED — exact name of the project finish-milestone task
            percent_complete_threshold_complete = 100
            buyout_baseline_number              = 0       # which MS Project baseline slot holds the buyout baseline (0 = primary "Baseline")
            construction_baseline_number        = 1       # construction work is commonly baselined into Baseline1
            analysis_snapshot                   = ''      # which snapshot stem stages D/E/H analyze; blank = latest by date
            snapshot_count                      = $null
        }
        buildings = [ordered]@{
            names  = @()    # REQUIRED — building summary-task names exactly as they appear in the schedule
            phases = @()    # optional — list of { phase_id, label, buildings: [names] }
        }
        construction_variance = [ordered]@{
            buckets                = @()    # REQUIRED — variance bucket names (e.g. Site Work, Site Concrete, ...)
            top_n_ranking          = 24
            per_building_top_n      = 10
            baseline_span_min_days  = 0.5
        }
        wbs_resolver = [ordered]@{
            buyout_work_outline_prefix   = ''    # REQUIRED — e.g. "1.1"
            lead_time_outline_prefix     = ''    # REQUIRED — e.g. "1.2"
            procurement_outline_suffix   = ''    # REQUIRED — e.g. "1"
            subcontracting_outline_suffix = ''   # REQUIRED — e.g. "2"
            bucket_overrides             = @()   # optional — list of { task_name: "..." }
        }
        working_calendar = [ordered]@{
            weekmask = '1111100'    # Mon-Fri working, Sat/Sun off
            holidays = @()
        }
        critical_path = [ordered]@{
            concurrent_paths_threshold_days = 3
        }
        charting = [ordered]@{
            dpi          = 150
            font_family  = 'Carlito'
            float_health_bands_days        = @(0, 5, 10, 20)
            completion_range_lookback_weeks = 8
            forecast_trend_chart = [ordered]@{ annotation_breakpoints = @() }
        }
        buyout_analysis = [ordered]@{
            # Priority-ordered: first stage whose keyword (case-insensitive
            # substring) appears in a buyout activity name wins. Keywords below
            # are seeded from typical SCI buyout activity naming - review/adjust
            # to match your schedule's wording. (buyout_analysis.py needs the
            # {stage, keywords} dict shape, NOT a bare list of stage names.)
            stage_classification = @(
                [ordered]@{ stage = 'Order/Procurement';  keywords = @('order') },
                [ordered]@{ stage = 'Subcontract Award';  keywords = @('subcontract','contract') },
                [ordered]@{ stage = 'Lead-Time/Delivery'; keywords = @('lead time','delivery','deliver') },
                [ordered]@{ stage = 'Submittal/Approval'; keywords = @('submittal','approv','selection','bid','quote') },
                [ordered]@{ stage = 'Milestone';          keywords = @('complete','milestone') }
            )
            stage_fallback      = 'Other'
            top_packages_count  = 25
        }
        qc = [ordered]@{
            uid_persistence_warn_threshold_pct = 99.0
            negative_variance_watch_buildings  = @()
        }
        pdf_assembly = [ordered]@{
            brief_title           = 'Executive Schedule Brief'
            brief_subtitle        = ''
            company_name          = 'SCI'
            report_date           = ''
            cover_toc_page_offset = 2
            font_family            = 'Carlito'
            toc_page_overrides     = [ordered]@{}
        }
        environment = [ordered]@{
            venv_created        = $false
            venv_python_version = ''
            packages_installed  = $false
            last_env_check      = ''
            # Defaults to the JRE bundled by the installer, same rationale as
            # paths.system_python_exe: a PATH-resolved "java" is unreliable when
            # multiple JVMs are installed (auto-detection has already been shown
            # to pick a 32-bit one over a working 64-bit one on this exact app).
            # Unlike python_exe, this field has no other competing meaning
            # elsewhere, so it doubles as both the bundled default and the
            # advanced override - editing it on the Settings tab and saving
            # just overwrites it, same as it already worked before bundling.
            java_home           = Join-Path $script:AppRoot 'java-runtime'
            # Blank = let the JVM pick its own default heap. Only needs setting for
            # very large .mpp/.xml snapshot files that overflow MPXJ's default heap
            # (surfaces as a Java OutOfMemoryError partway through Stage C). Value is
            # just the size (e.g. "2g", "512m") - start_jvm() in extract_snapshots.py
            # prepends the -Xmx itself.
            jvm_max_heap        = ''
            # Pinned exact versions, deliberately. Floating versions + an
            # interrupted wheel extraction during install once produced a venv
            # where "import pyarrow" succeeded (an empty stub package dir was
            # left behind) but the module had no contents - fatal to pandas at
            # import in every stage, and invisible to a plain import check.
            # Must stay in lockstep with Program.PipPackages in
            # PA-Pipeline-Setup.cs and with $script:VenvSmokeTestCode's module
            # list below.
            pip_packages = @(
                'mpxj==16.4.1','jpype1==1.7.1','pandas==3.0.3','pyarrow==24.0.0','openpyxl==3.1.5',
                'matplotlib==3.11.0','reportlab==5.0.0','pypdf==6.14.2','pikepdf==10.9.1','pdfplumber==0.11.10'
            )
        }
        # Output markers below match the filenames the scripts actually write.
        # Stage L's PDF is named dynamically, so its marker is a wildcard.
        pipeline_state = [ordered]@{
            # output_marker2 present (even if blank) on every stage, not just K - under
            # Set-StrictMode -Version Latest, dot-accessing a hashtable key that doesn't
            # exist AT ALL throws ("cannot be found on this object"), unlike a key that
            # exists with an empty value. Get-StageStatusText reads .output_marker2 on
            # every stage every time it's called, so every stage needs the key present.
            C = [ordered]@{ last_run=''; status='never'; output_marker='stage_c/extraction_report.json';   output_marker2='' }
            D = [ordered]@{ last_run=''; status='never'; output_marker='stage_d/resolver_report.json';     output_marker2='' }
            E = [ordered]@{ last_run=''; status='never'; output_marker='stage_e/bucket_summary.parquet';   output_marker2='' }
            F = [ordered]@{ last_run=''; status='never'; output_marker='stage_f/delay_ledger_report.json'; output_marker2='' }
            G = [ordered]@{ last_run=''; status='never'; output_marker='stage_g/forward_report.json';      output_marker2='' }
            H = [ordered]@{ last_run=''; status='never'; output_marker='stage_h/buyout_summary.parquet';   output_marker2='' }
            K = [ordered]@{ last_run=''; status='never'; output_marker='stage_k/forecast_trend.png';       output_marker2='stage_k/chart_data_workbook.xlsx' }
            J = [ordered]@{ last_run=''; status='never'; output_marker='stage_j/narrative.json';           output_marker2='' }
            L = [ordered]@{ last_run=''; status='never'; output_marker='stage_l/*_Executive_Brief_*.pdf';  output_marker2='' }
            M = [ordered]@{ last_run=''; status='never'; output_marker='stage_m/qc_report.json';           output_marker2='' }
        }
    }
}

# =============================================================================
# HELPER: Load / Save project_config.json
# =============================================================================
function Merge-ConfigDefaults {
    # Recursively fills in any key missing from $Loaded with the value from
    # $Defaults, at every nesting depth - not just the top level. This is what
    # lets an older/partial project_config.json (e.g. from before a schema
    # change) self-heal instead of throwing PropertyNotFoundException under
    # Set-StrictMode the first time the app reads a key the old file lacks.
    # Existing values in $Loaded are always preserved; only gaps are filled.
    param($Loaded, $Defaults)
    foreach ($key in $Defaults.Keys) {
        if (-not $Loaded.Contains($key)) {
            $Loaded[$key] = $Defaults[$key]
        } elseif (($Defaults[$key] -is [System.Collections.IDictionary]) -and
                  ($Loaded[$key] -is [System.Collections.IDictionary])) {
            Merge-ConfigDefaults -Loaded $Loaded[$key] -Defaults $Defaults[$key]
        }
    }
}

function Load-ProjectConfigFile {
    param([string]$Path)
    $raw  = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $obj  = $raw | ConvertFrom-Json
    $hash = ConvertTo-HashtableDeep $obj

    # Backfill any section/key missing from an older/partial file, at any depth
    Merge-ConfigDefaults -Loaded $hash -Defaults (Get-DefaultConfig)

    # Shape migration: older configs stored buyout_analysis.stage_classification
    # as a bare list of stage-name strings, but the stages need the
    # {stage, keywords} dict shape (Stage H reads sd["keywords"]). The deep
    # merge above won't fix it because the key already exists - detect the old
    # string shape and replace it with the current default dict list.
    try {
        $sc = $hash.buyout_analysis.stage_classification
        $needsMigration = $false
        if ($null -eq $sc) {
            $needsMigration = $true
        } else {
            foreach ($entry in @($sc)) {
                if ($entry -isnot [System.Collections.IDictionary]) { $needsMigration = $true; break }
            }
        }
        if ($needsMigration) {
            $hash.buyout_analysis.stage_classification = (Get-DefaultConfig).buyout_analysis.stage_classification
        }
    } catch { }

    return $hash
}

function Save-ProjectConfig {
    param([string]$Path = $script:ConfigPath)
    $json = $script:Config | ConvertTo-Json -Depth 12
    Write-Utf8NoBom -Path $Path -Content $json
}

# =============================================================================
# HELPER: Remember the last opened/saved config path across launches, so a
# user working across multiple projects over time doesn't have to re-Load
# Config every time. Stored separately from project_config.json itself in
# $script:DataRoot (NOT next to the exe in $script:AppRoot - that location
# is reserved for the one-time legacy-config migration above and is exactly
# how an earlier build's decoy config file caused Load Config to silently
# repoint at a non-writable, wrong-shaped file; see handoff notes).
# =============================================================================
$script:LastConfigPointerPath = Join-Path $script:DataRoot 'last_config.txt'

function Get-LastConfigPath {
    if (-not (Test-Path -LiteralPath $script:LastConfigPointerPath)) { return $null }
    try {
        $p = (Get-Content -LiteralPath $script:LastConfigPointerPath -Raw -Encoding UTF8).Trim()
        if ($p -ne '' -and (Test-Path -LiteralPath $p)) { return $p }
    } catch { }
    return $null
}

function Set-LastConfigPath {
    param([string]$Path)
    try { Write-Utf8NoBom -Path $script:LastConfigPointerPath -Content $Path } catch { }
}

# =============================================================================
# HELPER: Enable/disable Tabs 2-4 and update the status bar based on whether
# a real project is currently loaded (vs. blank defaults with nothing ever
# saved or loaded). References $tabStages/$tabRunLog/$tabOutputs/$lblStatusBar,
# which don't exist yet at the point this function is defined - that's fine
# in PowerShell since the body only resolves them when actually called, and
# every call site below runs after the full UI is built.
# =============================================================================
$script:ProjectLoaded = $false

function Set-ProjectLoadedState {
    param([bool]$Loaded)
    $script:ProjectLoaded = $Loaded
    foreach ($t in @($tabStages, $tabRunLog, $tabOutputs)) {
        if ($null -ne $t) { $t.Enabled = $Loaded }
    }
    if ($null -ne $lblStatusBar) {
        if ($Loaded) { $lblStatusBar.Text = "Config file: $script:ConfigPath" }
        else         { $lblStatusBar.Text = 'No project loaded — set up a project on the Project Setup tab or load an existing config.' }
    }
}

# =============================================================================
# HELPER: Folder / file pickers
# =============================================================================
function Show-FolderPicker {
    param([string]$Title = 'Select Folder', [string]$StartPath = '')
    try {
        $shell  = New-Object -ComObject Shell.Application
        $folder = $shell.BrowseForFolder(0, $Title, 0x0041, 0)
        if ($null -ne $folder) {
            $item = $folder.Self()
            return $item.Path
        }
    } catch {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $Title
        if ($StartPath -ne '') { $dlg.SelectedPath = $StartPath }
        if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
    }
    return $null
}

function Show-OpenFilePicker {
    param([string]$Title = 'Select File', [string]$Filter = 'All Files (*.*)|*.*', [string]$StartPath = '')
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title  = $Title
    $dlg.Filter = $Filter
    if ($StartPath -ne '' -and (Test-Path $StartPath)) { $dlg.InitialDirectory = $StartPath }
    if ($dlg.ShowDialog() -eq 'OK') { return $dlg.FileName }
    return $null
}

# =============================================================================
# BUILD THE MAIN FORM
# =============================================================================
$form = New-Object System.Windows.Forms.Form
$form.Text          = 'PA Pipeline  —  Configure · Run · Review'
$form.Size          = New-Object System.Drawing.Size(1040, 820)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(920, 720)
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor     = [System.Drawing.Color]::FromArgb(245, 245, 248)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Font    = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$tabs.Padding = New-Object System.Drawing.Point(14, 4)
# Add to form FIRST, then set Dock - correct order for PS2EXE
$form.Controls.Add($tabs)
$tabs.Dock = [System.Windows.Forms.DockStyle]::Fill

# Status bar: shows the active config path, or a "no project loaded" prompt.
# Added after $tabs (Dock=Fill) so it claims the bottom strip and $tabs fills
# whatever remains - the standard WinForms dock-order convention.
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$lblStatusBar = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatusBar.Spring = $true
$lblStatusBar.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
[void]$statusStrip.Items.Add($lblStatusBar)
$form.Controls.Add($statusStrip)

# helper: standard GroupBox
function New-GroupBox {
    param($Text, $Left, $Top, $Width, $Height)
    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text  = $Text
    $gb.Left  = $Left; $gb.Top = $Top
    $gb.Width = $Width; $gb.Height = $Height
    $gb.Font  = New-Object System.Drawing.Font('Segoe UI', 9)
    return $gb
}

# helper: standard Label
function New-Label {
    param($Text, $Left, $Top, $Width = 120, $Height = 20)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Left = $Left; $l.Top = $Top
    $l.Width = $Width; $l.Height = $Height
    $l.TextAlign = 'MiddleLeft'
    return $l
}

# helper: standard TextBox
function New-Textbox {
    param($Left, $Top, $Width, $Text = '')
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Left = $Left; $tb.Top = $Top; $tb.Width = $Width
    $tb.Text = $Text
    return $tb
}

# helper: standard Button
function New-Btn {
    param($Text, $Left, $Top, $Width = 90, $Height = 28, $Color = $null)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Left = $Left; $b.Top = $Top
    $b.Width = $Width; $b.Height = $Height
    $b.FlatStyle = 'Flat'
    if ($null -ne $Color) {
        $b.BackColor = $Color
        $b.ForeColor = [System.Drawing.Color]::White
    }
    $b.FlatAppearance.BorderSize = 1
    return $b
}

# helper: standard NumericUpDown
function New-Numeric {
    param($Left, $Top, $Width, $Min, $Max, $Value)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Left = $Left; $n.Top = $Top; $n.Width = $Width
    $n.Minimum = $Min; $n.Maximum = $Max; $n.Value = $Value
    return $n
}

# helper: standard ComboBox (DropDownList)
function New-Combo {
    param($Left, $Top, $Width, $Items, $SelectedIndex = 0)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Left = $Left; $c.Top = $Top; $c.Width = $Width
    $c.DropDownStyle = 'DropDownList'
    $c.Items.AddRange($Items) | Out-Null
    if ($c.Items.Count -gt 0) { $c.SelectedIndex = $SelectedIndex }
    return $c
}

# =============================================================================
# TAB 1 — PROJECT SETUP
# =============================================================================
$tabSetup           = New-Object System.Windows.Forms.TabPage
$tabSetup.Text      = '  1 · Project Setup  '
$tabSetup.BackColor = [System.Drawing.Color]::FromArgb(245,245,248)
$tabSetup.AutoScroll = $true   # schema-B form is taller than the visible area
$tabs.TabPages.Add($tabSetup)

# ── Project Identity ──────────────────────────────────────────────────────
$gbIdentity = New-GroupBox 'Project Identity' 12 12 1000 104
$tabSetup.Controls.Add($gbIdentity)

$gbIdentity.Controls.Add((New-Label 'Project Name:' 10 28 110))
$tbProjName = New-Textbox 124 26 280
$gbIdentity.Controls.Add($tbProjName)

$gbIdentity.Controls.Add((New-Label 'SCI Project #:' 420 28 100))
$tbSciNumber = New-Textbox 524 26 160
$gbIdentity.Controls.Add($tbSciNumber)

$gbIdentity.Controls.Add((New-Label 'Contract Type:' 700 28 100))
$cboContractType = New-Combo 804 26 130 @('GC','CM','design-build') 0
$gbIdentity.Controls.Add($cboContractType)

$gbIdentity.Controls.Add((New-Label 'Project Type:' 10 64 110))
$cboProjType = New-Combo 124 62 180 @('multifamily','commercial','renovation') 0
$gbIdentity.Controls.Add($cboProjType)

$gbIdentity.Controls.Add((New-Label 'Status Date:' 420 64 100))
$dtpStatusDate = New-Object System.Windows.Forms.DateTimePicker
$dtpStatusDate.Left = 524; $dtpStatusDate.Top = 62; $dtpStatusDate.Width = 160
$dtpStatusDate.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$dtpStatusDate.CustomFormat = 'yyyy-MM-dd'
$gbIdentity.Controls.Add($dtpStatusDate)

$gbIdentity.Controls.Add((New-Label 'Baseline Date:' 700 64 100))
$dtpBaselineDate = New-Object System.Windows.Forms.DateTimePicker
$dtpBaselineDate.Left = 804; $dtpBaselineDate.Top = 62; $dtpBaselineDate.Width = 130
$dtpBaselineDate.Format = [System.Windows.Forms.DateTimePickerFormat]::Custom
$dtpBaselineDate.CustomFormat = 'yyyy-MM-dd'
$gbIdentity.Controls.Add($dtpBaselineDate)

# ── Paths ──────────────────────────────────────────────────────────────────
$gbPaths = New-GroupBox 'Paths' 12 126 1000 140
$tabSetup.Controls.Add($gbPaths)

$gbPaths.Controls.Add((New-Label 'XML Snapshots Folder:' 10 28 140))
$tbSnapshotsDir = New-Textbox 154 26 700
$gbPaths.Controls.Add($tbSnapshotsDir)
$btnBrowseSnapshots = New-Btn 'Browse…' 862 24 120 28
$gbPaths.Controls.Add($btnBrowseSnapshots)
$btnBrowseSnapshots.Add_Click({
    $picked = Show-FolderPicker -Title 'Select the Snapshots folder' -StartPath $tbSnapshotsDir.Text
    if ($null -ne $picked -and $picked -ne '') { $tbSnapshotsDir.Text = $picked }
})

$gbPaths.Controls.Add((New-Label 'Baseline MPP/XML:' 10 64 140))
$tbBaselineMpp = New-Textbox 154 62 700
$gbPaths.Controls.Add($tbBaselineMpp)
$btnBrowseBaseline = New-Btn 'Browse…' 862 60 120 28
$gbPaths.Controls.Add($btnBrowseBaseline)
$btnBrowseBaseline.Add_Click({
    $picked = Show-OpenFilePicker -Title 'Select the baseline MPP/XML file' `
        -Filter 'Project Files (*.mpp;*.xml)|*.mpp;*.xml|All Files (*.*)|*.*' -StartPath $tbBaselineMpp.Text
    if ($null -ne $picked -and $picked -ne '') { $tbBaselineMpp.Text = $picked }
})

$gbPaths.Controls.Add((New-Label 'Output Root Folder:' 10 100 140))
$tbOutputDir = New-Textbox 154 98 700
$gbPaths.Controls.Add($tbOutputDir)
$btnBrowseOutput = New-Btn 'Browse…' 862 96 120 28
$gbPaths.Controls.Add($btnBrowseOutput)
$btnBrowseOutput.Add_Click({
    $picked = Show-FolderPicker -Title 'Select the Output folder' -StartPath $tbOutputDir.Text
    if ($null -ne $picked -and $picked -ne '') { $tbOutputDir.Text = $picked }
})

# ── Schedule ─────────────────────────────────────────────────────────────
$gbSchedule = New-GroupBox 'Schedule  (required by stages D, E, F, G, M)' 12 272 1000 150
$tabSetup.Controls.Add($gbSchedule)

$gbSchedule.Controls.Add((New-Label 'Buyout Outline Prefix(es):' 10 28 185))
$tbBuyoutPrefixes = New-Textbox 198 26 160
$gbSchedule.Controls.Add($tbBuyoutPrefixes)
$lblBuyoutHint = New-Label '(e.g. 1   or   1, 3.2 for scattered branches — leave blank if the project has no buyout phase)' 362 28 580
$lblBuyoutHint.ForeColor = [System.Drawing.Color]::Gray
$lblBuyoutHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$gbSchedule.Controls.Add($lblBuyoutHint)

$gbSchedule.Controls.Add((New-Label '% Complete Threshold:' 540 28 150))
$nudPctComplete = New-Numeric 694 26 70 0 100 100
$gbSchedule.Controls.Add($nudPctComplete)

$gbSchedule.Controls.Add((New-Label 'Finish Milestone Task Name:' 10 64 180))
$tbFinishMilestone = New-Textbox 194 62 740
$gbSchedule.Controls.Add($tbFinishMilestone)

# Row 3: per-section baseline slot + analysis snapshot picker
$gbSchedule.Controls.Add((New-Label 'Buyout Baseline #:' 10 102 120))
$nudBuyoutBaseline = New-Numeric 134 100 50 0 10 0
$gbSchedule.Controls.Add($nudBuyoutBaseline)

$gbSchedule.Controls.Add((New-Label 'Construction Baseline #:' 200 102 150))
$nudConstructionBaseline = New-Numeric 354 100 50 0 10 1
$gbSchedule.Controls.Add($nudConstructionBaseline)

$gbSchedule.Controls.Add((New-Label 'Analysis Snapshot:' 430 102 120))
$cboAnalysisSnapshot = New-Object System.Windows.Forms.ComboBox
$cboAnalysisSnapshot.Left = 552; $cboAnalysisSnapshot.Top = 100; $cboAnalysisSnapshot.Width = 390
$cboAnalysisSnapshot.DropDownStyle = 'DropDown'   # editable: allows manual stem entry
$gbSchedule.Controls.Add($cboAnalysisSnapshot)
$lblSnapHint = New-Label '0 = primary "Baseline", 1 = Baseline1, etc.   Snapshot blank/(latest) = newest by date.' 10 126 920
$lblSnapHint.ForeColor = [System.Drawing.Color]::Gray
$lblSnapHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$gbSchedule.Controls.Add($lblSnapHint)

# Populate the snapshot dropdown from the snapshots folder (input file stems)
function Refresh-SnapshotDropdown {
    $cboAnalysisSnapshot.Items.Clear()
    [void]$cboAnalysisSnapshot.Items.Add('(latest)')
    $dir = $tbSnapshotsDir.Text.Trim()
    if ($dir -ne '' -and (Test-Path -LiteralPath $dir)) {
        $stems = Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Extension -in @('.xml', '.mpp') } |
                 ForEach-Object { $_.BaseName } | Sort-Object
        foreach ($s in $stems) { [void]$cboAnalysisSnapshot.Items.Add($s) }
    }
}
$btnBrowseSnapshots.Add_Click({ Refresh-SnapshotDropdown })   # refresh list after re-browsing

# ── Buildings ────────────────────────────────────────────────────────────
$gbStructure = New-GroupBox 'Buildings  (names must match the summary-task names in the schedule)' 12 430 1000 250
$tabSetup.Controls.Add($gbStructure)

$gbStructure.Controls.Add((New-Label 'Building Count:' 10 28 110))
$nudBuildingCount = New-Numeric 124 26 60 1 50 1
$gbStructure.Controls.Add($nudBuildingCount)

$gbStructure.Controls.Add((New-Label 'Phase Count:' 210 28 100))
$nudPhaseCount = New-Numeric 314 26 60 1 10 1
$gbStructure.Controls.Add($nudPhaseCount)

$btnGenBuildings = New-Btn 'Generate Buildings' 400 24 170 28 ([System.Drawing.Color]::FromArgb(70,100,140))
$gbStructure.Controls.Add($btnGenBuildings)

$lblBuildingsHint = New-Label 'Edit Name/Phase directly. Phase groups buildings for turnover & variance reporting.' 584 28 400
$lblBuildingsHint.ForeColor = [System.Drawing.Color]::Gray
$gbStructure.Controls.Add($lblBuildingsHint)

$dgvBuildings = New-Object System.Windows.Forms.DataGridView
$dgvBuildings.Left = 10; $dgvBuildings.Top = 62
$dgvBuildings.Width = 970; $dgvBuildings.Height = 176
$dgvBuildings.AllowUserToAddRows    = $false
$dgvBuildings.AllowUserToDeleteRows = $false
$dgvBuildings.MultiSelect           = $false
$dgvBuildings.SelectionMode         = 'FullRowSelect'
$dgvBuildings.RowHeadersVisible     = $false
$dgvBuildings.AutoSizeColumnsMode   = 'Fill'
$dgvBuildings.BackgroundColor       = [System.Drawing.Color]::White
$dgvBuildings.BorderStyle           = 'None'
$dgvBuildings.EditMode              = 'EditOnKeystrokeOrF2'
foreach ($col in @(
    @{Name='name';  Header='Building Name'; FillW=260; RO=$false},
    @{Name='phase'; Header='Phase';         FillW=70;  RO=$false}
)) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $col.Name; $c.HeaderText = $col.Header
    $c.FillWeight = $col.FillW; $c.ReadOnly = $col.RO
    $dgvBuildings.Columns.Add($c) | Out-Null
}
$gbStructure.Controls.Add($dgvBuildings)

# ── Construction Variance ────────────────────────────────────────────────
$gbCV = New-GroupBox 'Construction Variance  (buckets required by stages E, F, M)' 12 688 1000 76
$tabSetup.Controls.Add($gbCV)
$gbCV.Controls.Add((New-Label 'Buckets (comma-separated):' 10 30 180))
$tbBuckets = New-Textbox 194 28 740 ''
$gbCV.Controls.Add($tbBuckets)
$lblBucketsHint = New-Label 'e.g. Site Work, Site Concrete, Site Finish, Structure, Envelope, Interiors' 194 52 740
$lblBucketsHint.ForeColor = [System.Drawing.Color]::Gray
$lblBucketsHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$gbCV.Controls.Add($lblBucketsHint)

# ── WBS Resolver ─────────────────────────────────────────────────────────
$gbWbs = New-GroupBox 'WBS Resolver  (MS Project outline numbering — leave all fields blank if the project has no buyout phase)' 12 772 1000 116
$tabSetup.Controls.Add($gbWbs)

$gbWbs.Controls.Add((New-Label 'Buyout Work Outline Prefix:' 10 28 180))
$tbBuyoutWorkPrefix = New-Textbox 194 26 120
$gbWbs.Controls.Add($tbBuyoutWorkPrefix)
$gbWbs.Controls.Add((New-Label '(e.g. 1.1 — blank if no buyout)' 320 28 100))

$gbWbs.Controls.Add((New-Label 'Lead-Time Outline Prefix:' 430 28 160))
$tbLeadTimePrefix = New-Textbox 594 26 120
$gbWbs.Controls.Add($tbLeadTimePrefix)
$gbWbs.Controls.Add((New-Label '(e.g. 1.2)' 720 28 90))

$gbWbs.Controls.Add((New-Label 'Procurement Outline Suffix:' 10 66 180))
$tbProcSuffix = New-Textbox 194 64 120
$gbWbs.Controls.Add($tbProcSuffix)
$gbWbs.Controls.Add((New-Label '(e.g. 1)' 320 66 90))

$gbWbs.Controls.Add((New-Label 'Subcontracting Outline Suffix:' 430 66 180))
$tbSubSuffix = New-Textbox 594 64 120
$gbWbs.Controls.Add($tbSubSuffix)
$gbWbs.Controls.Add((New-Label '(e.g. 2)' 720 66 90))

# ── Working Calendar ─────────────────────────────────────────────────────
$gbCal = New-GroupBox 'Working Calendar' 12 896 1000 64
$tabSetup.Controls.Add($gbCal)
$gbCal.Controls.Add((New-Label 'Week Mask:' 10 28 90))
$tbWeekmask = New-Textbox 104 26 120 '1111100'
$gbCal.Controls.Add($tbWeekmask)
$lblCalHint = New-Label '7 digits Mon-Sun, 1 = working day (default 1111100 = Mon-Fri). Holidays edit the JSON directly.' 234 28 700
$lblCalHint.ForeColor = [System.Drawing.Color]::Gray
$gbCal.Controls.Add($lblCalHint)

function Refresh-BuildingsGrid {
    $dgvBuildings.Rows.Clear()
    foreach ($b in $script:Buildings) {
        $dgvBuildings.Rows.Add($b.name, $b.phase) | Out-Null
    }
}

$btnGenBuildings.Add_Click({
    $count    = [int]$nudBuildingCount.Value
    $phases   = [int]$nudPhaseCount.Value
    $perPhase = [math]::Ceiling($count / [double]$phases)
    $list = [System.Collections.Generic.List[hashtable]]::new()
    for ($i = 1; $i -le $count; $i++) {
        $phase = [math]::Min($phases, [math]::Ceiling($i / $perPhase))
        $list.Add(@{ name = "Building $i"; phase = [int]$phase })
    }
    $script:Buildings = $list
    Refresh-BuildingsGrid
})

$dgvBuildings.Add_CellValueChanged({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $e.RowIndex -ge $script:Buildings.Count) { return }
    $colName = $dgvBuildings.Columns[$e.ColumnIndex].Name
    $val = $dgvBuildings.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value
    if ($colName -eq 'name') { $script:Buildings[$e.RowIndex].name = [string]$val }
    elseif ($colName -eq 'phase') {
        $p = 1; [void][int]::TryParse([string]$val, [ref]$p)
        $script:Buildings[$e.RowIndex].phase = $p
    }
})
$dgvBuildings.Add_CurrentCellDirtyStateChanged({
    if ($dgvBuildings.IsCurrentCellDirty) { $dgvBuildings.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
})

# ── Save / Load Config ──────────────────────────────────────────────────────
$btnSaveConfig = New-Btn '  Save Config' 760 972 120 34 ([System.Drawing.Color]::FromArgb(20,120,40))
$btnSaveConfig.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$tabSetup.Controls.Add($btnSaveConfig)

$btnLoadConfig = New-Btn '  Load Config' 888 972 124 34 ([System.Drawing.Color]::FromArgb(70,100,140))
$btnLoadConfig.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$tabSetup.Controls.Add($btnLoadConfig)

$lblConfigPath = New-Label '' 12 980 730 22
$lblConfigPath.ForeColor = [System.Drawing.Color]::FromArgb(100,100,140)
$lblConfigPath.Font = New-Object System.Drawing.Font('Segoe UI', 8.5)
$tabSetup.Controls.Add($lblConfigPath)

# =============================================================================
# HELPER: Sync between Tab 1 controls and $script:Config
# =============================================================================
function Save-ConfigFromUI {
    if ($null -eq $script:Config) { $script:Config = Get-DefaultConfig }

    $script:Config.environment.java_home = $tbJavaHome.Text.Trim()
    $script:Config.environment.jvm_max_heap = $tbJvmMaxHeap.Text.Trim()
    # Persist the Bootstrap Python field too - without this, an override typed
    # on the Settings tab only ever lived in the textbox for the current
    # session and silently reverted to the installer-bundled path on next
    # launch (the textbox is auto-repopulated from config on every refresh).
    $script:Config.paths.system_python_exe = $tbSystemPython.Text.Trim()

    $script:Config.project.name                 = $tbProjName.Text.Trim()
    $script:Config.project.sci_project_number   = $tbSciNumber.Text.Trim()
    $script:Config.project.type                 = $cboProjType.SelectedItem.ToString()
    $script:Config.project.contract_type        = $cboContractType.SelectedItem.ToString()
    $script:Config.project.analysis_status_date = $dtpStatusDate.Value.ToString('yyyy-MM-dd')

    $script:Config.paths.xml_snapshots_folder = $tbSnapshotsDir.Text.Trim()
    $script:Config.paths.baseline_mpp         = $tbBaselineMpp.Text.Trim()
    $script:Config.paths.output_root          = $tbOutputDir.Text.Trim()

    $script:Config.schedule.baseline_date                       = $dtpBaselineDate.Value.ToString('yyyy-MM-dd')
    $script:Config.schedule.buyout_outline_prefixes = @(
        $tbBuyoutPrefixes.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    )
    $script:Config.schedule.finish_milestone_task_name          = $tbFinishMilestone.Text.Trim()
    $script:Config.schedule.percent_complete_threshold_complete = [int]$nudPctComplete.Value
    $script:Config.schedule.buyout_baseline_number       = [int]$nudBuyoutBaseline.Value
    $script:Config.schedule.construction_baseline_number = [int]$nudConstructionBaseline.Value
    $snap = [string]$cboAnalysisSnapshot.Text.Trim()
    if ($snap -eq '(latest)') { $snap = '' }
    $script:Config.schedule.analysis_snapshot = $snap

    # buildings.names = ordered list of names; buildings.phases = grouped by phase
    $names = @()
    $phaseMap = [ordered]@{}
    foreach ($b in $script:Buildings) {
        $nm = [string]$b.name
        if ($nm.Trim() -eq '') { continue }
        $names += $nm
        $ph = [int]$b.phase
        if (-not $phaseMap.Contains([string]$ph)) { $phaseMap[[string]$ph] = @() }
        $phaseMap[[string]$ph] += $nm
    }
    $script:Config.buildings.names = $names
    $phasesArr = @()
    foreach ($phKey in ($phaseMap.Keys | Sort-Object { [int]$_ })) {
        $phasesArr += ,([ordered]@{
            phase_id  = [int]$phKey
            label     = "Phase $phKey"
            buildings = @($phaseMap[$phKey])
        })
    }
    $script:Config.buildings.phases = $phasesArr

    $script:Config.construction_variance.buckets = @(
        $tbBuckets.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    )

    $script:Config.wbs_resolver.buyout_work_outline_prefix    = $tbBuyoutWorkPrefix.Text.Trim()
    $script:Config.wbs_resolver.lead_time_outline_prefix      = $tbLeadTimePrefix.Text.Trim()
    $script:Config.wbs_resolver.procurement_outline_suffix    = $tbProcSuffix.Text.Trim()
    $script:Config.wbs_resolver.subcontracting_outline_suffix = $tbSubSuffix.Text.Trim()

    $script:Config.working_calendar.weekmask = $tbWeekmask.Text.Trim()
}

function Refresh-UIFromConfig {
    if ($null -eq $script:Config) { return }

    $tbProjName.Text   = [string]$script:Config.project.name
    $tbSciNumber.Text  = [string]$script:Config.project.sci_project_number
    $idx = $cboProjType.Items.IndexOf([string]$script:Config.project.type)
    $cboProjType.SelectedIndex = [math]::Max(0, $idx)
    $idx = $cboContractType.Items.IndexOf([string]$script:Config.project.contract_type)
    $cboContractType.SelectedIndex = [math]::Max(0, $idx)

    try { $dtpStatusDate.Value   = [datetime]$script:Config.project.analysis_status_date } catch { }
    try { $dtpBaselineDate.Value = [datetime]$script:Config.schedule.baseline_date } catch { }

    $tbSnapshotsDir.Text = [string]$script:Config.paths.xml_snapshots_folder
    $tbBaselineMpp.Text  = [string]$script:Config.paths.baseline_mpp
    $tbOutputDir.Text    = [string]$script:Config.paths.output_root

    $tbBuyoutPrefixes.Text   = ((@($script:Config.schedule.buyout_outline_prefixes)) -join ', ')
    $tbFinishMilestone.Text  = [string]$script:Config.schedule.finish_milestone_task_name
    $pct = 100; [void][int]::TryParse([string]$script:Config.schedule.percent_complete_threshold_complete, [ref]$pct)
    $nudPctComplete.Value    = [math]::Min(100, [math]::Max(0, $pct))

    $byb = 0; [void][int]::TryParse([string]$script:Config.schedule.buyout_baseline_number, [ref]$byb)
    $nudBuyoutBaseline.Value = [math]::Min(10, [math]::Max(0, $byb))
    $cob = 0; [void][int]::TryParse([string]$script:Config.schedule.construction_baseline_number, [ref]$cob)
    $nudConstructionBaseline.Value = [math]::Min(10, [math]::Max(0, $cob))
    Refresh-SnapshotDropdown
    $snap = [string]$script:Config.schedule.analysis_snapshot
    $cboAnalysisSnapshot.Text = if ($snap -eq '') { '(latest)' } else { $snap }

    # Rebuild the buildings grid from names[] + phases[]
    $nameToPhase = @{}
    foreach ($ph in @($script:Config.buildings.phases)) {
        foreach ($bn in @($ph.buildings)) { $nameToPhase[[string]$bn] = [int]$ph.phase_id }
    }
    $script:Buildings = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($nm in @($script:Config.buildings.names)) {
        $ph = 1
        if ($nameToPhase.ContainsKey([string]$nm)) { $ph = $nameToPhase[[string]$nm] }
        $script:Buildings.Add(@{ name = [string]$nm; phase = [int]$ph })
    }
    Refresh-BuildingsGrid
    $nudBuildingCount.Value = [math]::Min($nudBuildingCount.Maximum, [math]::Max($nudBuildingCount.Minimum, [math]::Max(1, $script:Buildings.Count)))
    $phaseCount = @($script:Config.buildings.phases).Count
    $nudPhaseCount.Value    = [math]::Min($nudPhaseCount.Maximum, [math]::Max($nudPhaseCount.Minimum, [math]::Max(1, $phaseCount)))

    $tbBuckets.Text = ((@($script:Config.construction_variance.buckets)) -join ', ')

    $tbBuyoutWorkPrefix.Text = [string]$script:Config.wbs_resolver.buyout_work_outline_prefix
    $tbLeadTimePrefix.Text   = [string]$script:Config.wbs_resolver.lead_time_outline_prefix
    $tbProcSuffix.Text       = [string]$script:Config.wbs_resolver.procurement_outline_suffix
    $tbSubSuffix.Text        = [string]$script:Config.wbs_resolver.subcontracting_outline_suffix

    $tbWeekmask.Text = [string]$script:Config.working_calendar.weekmask

    $lblConfigPath.Text = "Config file: $script:ConfigPath"
}

$btnSaveConfig.Add_Click({
    if ($tbProjName.Text.Trim() -eq '') {
        [System.Windows.Forms.MessageBox]::Show('Please enter a Project Name.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if ($tbOutputDir.Text.Trim() -eq '') {
        [System.Windows.Forms.MessageBox]::Show('Please choose an Output Folder.','Validation',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    Save-ConfigFromUI
    try {
        Save-ProjectConfig -Path $script:ConfigPath
        $lblConfigPath.Text = "Config file: $script:ConfigPath"
        Set-LastConfigPath -Path $script:ConfigPath
        Set-ProjectLoadedState -Loaded $true
        Refresh-StagesGrid
        [System.Windows.Forms.MessageBox]::Show("Saved to:`n$script:ConfigPath",'Save Config',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not save config:`n$($_.Exception.Message)",'Error',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

$btnLoadConfig.Add_Click({
    $picked = Show-OpenFilePicker -Title 'Load project_config.json' -Filter 'JSON Files (*.json)|*.json|All Files (*.*)|*.*' -StartPath $script:DataRoot
    if ($null -eq $picked -or $picked -eq '') { return }
    try {
        $script:Config     = Load-ProjectConfigFile -Path $picked
        $script:ConfigPath = $picked
        Refresh-UIFromConfig
        Refresh-StagesGrid
        Refresh-SettingsFromConfig
        Set-LastConfigPath -Path $picked
        Set-ProjectLoadedState -Loaded $true
        [System.Windows.Forms.MessageBox]::Show("Loaded:`n$picked",'Load Config',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not load config:`n$($_.Exception.Message)",'Error',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

# =============================================================================
# TAB 2 — PIPELINE STAGES
# =============================================================================
$tabStages           = New-Object System.Windows.Forms.TabPage
$tabStages.Text      = '  2 · Pipeline Stages  '
$tabStages.BackColor = [System.Drawing.Color]::FromArgb(245,245,248)
$tabs.TabPages.Add($tabStages)

$lblStagesInstr = New-Label "Check stages to run, then choose an action below.  Status reflects whether each stage's output marker file exists on disk — not just whether it was attempted." 12 12 1000 22
$lblStagesInstr.ForeColor = [System.Drawing.Color]::FromArgb(80,80,100)
$tabStages.Controls.Add($lblStagesInstr)

$dgvStages = New-Object System.Windows.Forms.DataGridView
$dgvStages.Left = 12; $dgvStages.Top = 44
$dgvStages.Width = 1000; $dgvStages.Height = 420
$dgvStages.AllowUserToAddRows    = $false
$dgvStages.AllowUserToDeleteRows = $false
$dgvStages.MultiSelect           = $false
$dgvStages.SelectionMode         = 'FullRowSelect'
$dgvStages.RowHeadersVisible     = $false
$dgvStages.AutoSizeColumnsMode   = 'Fill'
$dgvStages.BackgroundColor       = [System.Drawing.Color]::White
$dgvStages.BorderStyle           = 'None'
$dgvStages.EditMode              = 'EditOnKeystrokeOrF2'

$colRun = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colRun.Name = 'Run'; $colRun.HeaderText = 'Run?'; $colRun.FillWeight = 40
$dgvStages.Columns.Add($colRun) | Out-Null

foreach ($col in @(
    @{Name='Code';        Header='Stage';       FillW=50},
    @{Name='Name';        Header='Name';        FillW=170},
    @{Name='Description'; Header='Description'; FillW=330},
    @{Name='Status';      Header='Status';      FillW=120},
    @{Name='LastRun';     Header='Last Run';    FillW=160}
)) {
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.Name = $col.Name; $c.HeaderText = $col.Header
    $c.FillWeight = $col.FillW; $c.ReadOnly = $true
    $dgvStages.Columns.Add($c) | Out-Null
}
# Description text wraps and the row grows to fit, rather than silently
# truncating at a guessed pixel width (the grid is Fill-sized, so its
# columns - and therefore how much a description can fit on one line -
# change with the window/form size).
$dgvStages.Columns['Description'].DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
$dgvStages.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::AllCellsExceptHeaders
$tabStages.Controls.Add($dgvStages)

$dgvStages.Add_CurrentCellDirtyStateChanged({
    if ($dgvStages.IsCurrentCellDirty) { $dgvStages.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
})

# ── Stage J (manual narrative) + run buttons ───────────────────────────────
$pnlStageBtns = New-Object System.Windows.Forms.Panel
$pnlStageBtns.Left = 12; $pnlStageBtns.Top = 472; $pnlStageBtns.Width = 1000; $pnlStageBtns.Height = 40
$tabStages.Controls.Add($pnlStageBtns)

$btnOpenNarrative = New-Btn 'Open Narrative JSON  (Stage J)' 0 4 220 32 ([System.Drawing.Color]::FromArgb(100,100,140))
$btnRunSelected    = New-Btn '▶ Run Selected'          560 4 140 32 ([System.Drawing.Color]::FromArgb(31,78,120))
$btnRunAll         = New-Btn '▶▶ Run All'              708 4 110 32 ([System.Drawing.Color]::FromArgb(31,78,120))
$btnRunSynthesize  = New-Btn 'Run Selected + Synthesize' 826 4 174 32 ([System.Drawing.Color]::FromArgb(20,120,40))
$btnRunSelected.Font   = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnRunAll.Font        = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnRunSynthesize.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$pnlStageBtns.Controls.AddRange(@($btnOpenNarrative, $btnRunSelected, $btnRunAll, $btnRunSynthesize))

# =============================================================================
# HELPER: minimal narrative.json skeleton. Keys are exactly what
# assemble_pdf.py's narr()/risk_*/status_by_dimension calls read - run_qc.py's
# --synthesize now fills in every key here via Opus (all the narrative body
# text plus questions_for_next_review/watch_list/data_quality_notes/
# scope_gaps), so this template mainly exists for manual editing/overriding
# individual sections afterward, not as the primary fill-in path anymore.
# methodology_a/b/c are deliberately omitted - assemble_pdf.py already has
# built-in default text for those - as is toc_overrides, an advanced manual
# override with a different (list-of-tuples) shape, not part of the basic
# fill-in-the-blank template.
# =============================================================================
function Get-NarrativeTemplateJson {
    $skeleton = [ordered]@{
        bottom_line                  = ''
        executive_overview           = ''
        part_i_intro                 = ''
        part_i_trend_analysis        = ''
        part_i_bucket_analysis       = ''
        part_ii_intro                = ''
        part_ii_ledger_analysis      = ''
        part_iii_intro               = ''
        part_iii_per_building_note   = ''
        part_iv_intro                = ''
        part_vi_bottom_line          = ''
        part_vi_stage_breakdown_note = ''
        part_vi_methodology_d_note   = ''
        appendix_a_note              = ''
        risk_1                       = ''
        risk_2                       = ''
        risk_3                       = ''
        risk_4                       = ''
        status_by_dimension          = @()
        questions_for_next_review    = @()
        watch_list                   = @()
        data_quality_notes           = @()
        scope_gaps                   = @()
    }
    return ($skeleton | ConvertTo-Json -Depth 6)
}

# =============================================================================
# HELPER: small two-button "Create Empty Template / Cancel" dialog for the
# Stage J missing-file case. A stock Yes/No MessageBox can't carry these
# exact button labels, so this is a tiny purpose-built Form instead.
# =============================================================================
function Show-CreateTemplateDialog {
    param([string]$Message)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Narrative'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.ClientSize      = New-Object System.Drawing.Size(420, 140)

    $lbl = New-Label $Message 16 16 388 76
    $dlg.Controls.Add($lbl)

    $btnCreate = New-Btn 'Create Empty Template' 100 100 190 30 ([System.Drawing.Color]::FromArgb(20,120,40))
    $btnCreate.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $dlg.Controls.Add($btnCreate)

    $btnCancel = New-Btn 'Cancel' 304 100 100 30
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnCreate
    $dlg.CancelButton = $btnCancel
    return $dlg.ShowDialog()
}

$btnOpenNarrative.Add_Click({
    if ($null -eq $script:Config -or [string]$script:Config.paths.output_root -eq '') {
        [System.Windows.Forms.MessageBox]::Show('Set an Output Folder on the Project Setup tab first.','Narrative',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $stageJDir = Join-Path $script:Config.paths.output_root 'stage_j'
    $narrPath  = Join-Path $stageJDir 'narrative.json'

    if (Test-Path $narrPath) {
        Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$narrPath`""
        return
    }

    $choice = Show-CreateTemplateDialog -Message 'Narrative file not yet created. This is generated by Stage M''s --synthesize option ("Run Selected + Synthesize"), or you can create it manually.'
    if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if (-not (Test-Path $stageJDir)) { New-Item -ItemType Directory -Path $stageJDir -Force | Out-Null }
    Write-Utf8NoBom -Path $narrPath -Content (Get-NarrativeTemplateJson)
    Start-Process -FilePath 'notepad.exe' -ArgumentList "`"$narrPath`""
})

# =============================================================================
# HELPER: Stage status (computed from output_marker file existence, per spec)
# =============================================================================
function Get-StageStatusText {
    param([string]$Code)
    if ($script:RunningStageCode -eq $Code) { return 'running' }
    if ($null -eq $script:Config) { return 'never' }
    $st = $script:Config.pipeline_state.$Code
    if ($null -eq $st) { return 'never' }
    $outDir = [string]$script:Config.paths.output_root
    if ($outDir -ne '' -and [string]$st.output_marker -ne '') {
        $markerPath = Join-Path $outDir $st.output_marker
        # -Path (not -LiteralPath) so wildcard markers like stage_l/*_Executive_Brief_*.pdf resolve
        $marker1Exists = Test-Path -Path $markerPath
        # Some stages (K: PNGs + chart_data_workbook.xlsx) need a SECOND marker
        # present too before counting as success - a chart run that produces
        # the PNGs but fails partway through the workbook write should not
        # show green. Generic on purpose: any stage can opt in via output_marker2.
        $marker2 = [string]$st.output_marker2
        if ($marker2 -eq '') {
            if ($marker1Exists) { return 'success' }
        } elseif ($marker1Exists -and (Test-Path -Path (Join-Path $outDir $marker2))) {
            return 'success'
        }
    }
    if ([string]$st.last_run -ne '') { return 'failed' }
    return 'never'
}

function Get-StatusGlyph {
    param([string]$Status)
    switch ($Status) {
        'success' { return @{ Text = '✓ success'; Color = [System.Drawing.Color]::FromArgb(20,120,40)  } }
        'failed'  { return @{ Text = '✗ failed';   Color = [System.Drawing.Color]::FromArgb(190,30,30) } }
        'running' { return @{ Text = '▶ running';  Color = [System.Drawing.Color]::FromArgb(31,78,120) } }
        default   { return @{ Text = '— never';    Color = [System.Drawing.Color]::Gray              } }
    }
}

function Refresh-StagesGrid {
    $checkedCodes = @{}
    foreach ($row in $dgvStages.Rows) {
        $checkedCodes[[string]$row.Cells['Code'].Value] = [bool]$row.Cells['Run'].Value
    }
    $dgvStages.Rows.Clear()
    foreach ($stage in $script:Stages) {
        $status  = Get-StageStatusText -Code $stage.Code
        $glyph   = Get-StatusGlyph -Status $status
        $lastRun = ''
        if ($null -ne $script:Config) { $lastRun = [string]$script:Config.pipeline_state.($stage.Code).last_run }
        $wasChecked = $true
        if ($checkedCodes.ContainsKey($stage.Code)) { $wasChecked = $checkedCodes[$stage.Code] }
        $rowIdx = $dgvStages.Rows.Add($wasChecked, $stage.Code, $stage.Name, $stage.Description, $glyph.Text, $lastRun)
        $dgvStages.Rows[$rowIdx].Cells['Status'].Style.ForeColor = $glyph.Color
        $dgvStages.Rows[$rowIdx].Cells['Status'].Style.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    }
}

function Get-CheckedStages {
    $result = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($row in $dgvStages.Rows) {
        if ([bool]$row.Cells['Run'].Value) {
            $code  = [string]$row.Cells['Code'].Value
            $stage = $script:Stages | Where-Object { $_.Code -eq $code } | Select-Object -First 1
            if ($null -ne $stage) { $result.Add($stage) }
        }
    }
    return $result
}

$btnRunSelected.Add_Click({
    $selected = Get-CheckedStages
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No stages are checked.','Run Selected',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    Start-StageRun -StagesToRun $selected -Synthesize $false
})

$btnRunAll.Add_Click({
    $all = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($s in $script:Stages) { $all.Add($s) }
    Start-StageRun -StagesToRun $all -Synthesize $false
})

$btnRunSynthesize.Add_Click({
    $selected = Get-CheckedStages
    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('No stages are checked.','Run Selected + Synthesize',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    # Only Stage M ever actually calls Claude, so only gate on it being
    # checked - failing fast here saves running every other selected stage
    # first only to discover synthesis can't work at the very end.
    if ($selected | Where-Object { $_.Code -eq 'M' }) {
        # First-click-per-session hint: Synthesize depends on the Claude Code
        # CLI, which this app deliberately does NOT bundle or store credentials
        # for. Surface that once, up front, rather than only via the auth-error
        # path, so a new user knows it's a one-time external setup.
        if (-not $script:SynthHintShown) {
            $script:SynthHintShown = $true
            [System.Windows.Forms.MessageBox]::Show(
                "Synthesize uses Opus to write the brief's narrative, via the Claude Code CLI installed and logged in on THIS machine — a one-time setup this app does not bundle." + [Environment]::NewLine + [Environment]::NewLine +
                "If it isn't set up yet: install Claude Code, then run 'claude setup-token' (or 'claude login') once in a terminal. No API key or account info is ever stored by this app." + [Environment]::NewLine + [Environment]::NewLine +
                "See the Settings tab for details. Click OK to continue.",
                'Synthesize — one-time setup',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information)
        }
        $authCheck = Test-ClaudeCliAuth
        if (-not $authCheck.Ok) {
            [System.Windows.Forms.MessageBox]::Show($authCheck.Message,'Run Selected + Synthesize',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
    }
    Start-StageRun -StagesToRun $selected -Synthesize $true
})

# =============================================================================
# TAB 3 — RUN LOG
# =============================================================================
$tabRunLog           = New-Object System.Windows.Forms.TabPage
$tabRunLog.Text      = '  3 · Run Log  '
$tabRunLog.BackColor = [System.Drawing.Color]::FromArgb(245,245,248)
$tabs.TabPages.Add($tabRunLog)

$pgBar3 = New-Object System.Windows.Forms.ProgressBar
$pgBar3.Left = 12; $pgBar3.Top = 12; $pgBar3.Width = 1000; $pgBar3.Height = 24
$pgBar3.Style = 'Continuous'
$tabRunLog.Controls.Add($pgBar3)

$pnlRunLogBtns = New-Object System.Windows.Forms.Panel
$pnlRunLogBtns.Left = 12; $pnlRunLogBtns.Top = 44; $pnlRunLogBtns.Width = 1000; $pnlRunLogBtns.Height = 36
$tabRunLog.Controls.Add($pnlRunLogBtns)

$btnCancelRun = New-Btn '■  Cancel' 0 2 110 30 ([System.Drawing.Color]::FromArgb(160,30,30))
$btnCancelRun.Enabled = $false
$btnClearLog  = New-Btn 'Clear Log' 120 2 110 30
$pnlRunLogBtns.Controls.AddRange(@($btnCancelRun, $btnClearLog))

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Left = 12; $rtbLog.Top = 88; $rtbLog.Width = 1000; $rtbLog.Height = 600
$rtbLog.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$rtbLog.ReadOnly  = $true
$rtbLog.BackColor = [System.Drawing.Color]::FromArgb(20,20,30)
$rtbLog.ForeColor = [System.Drawing.Color]::FromArgb(200,220,200)
$rtbLog.Font      = New-Object System.Drawing.Font('Consolas', 8.5)
$rtbLog.ScrollBars = 'Vertical'
$tabRunLog.Controls.Add($rtbLog)

function Write-Log {
    param($Message, $Color = $null)
    $ts = (Get-Date).ToString('HH:mm:ss')
    $rtbLog.SelectionStart  = $rtbLog.TextLength
    $rtbLog.SelectionLength = 0
    if ($null -ne $Color) { $rtbLog.SelectionColor = $Color }
    else { $rtbLog.SelectionColor = [System.Drawing.Color]::FromArgb(200,220,200) }
    $rtbLog.AppendText("[$ts] $Message`n")
    $rtbLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

$btnClearLog.Add_Click({ $rtbLog.Clear() })
$btnCancelRun.Add_Click({
    $script:CancelRequested = $true
    Write-Log 'Cancel requested — finishing current stage…' ([System.Drawing.Color]::FromArgb(255,160,40))
    $btnCancelRun.Enabled = $false
    try { if ($null -ne $script:CurrentProcess -and -not $script:CurrentProcess.HasExited) { $script:CurrentProcess.Kill() } } catch {}
})

# =============================================================================
# HELPER: Run one python stage script, streaming stdout/stderr into the log.
# Output is produced on background threads (.NET process events), so the
# event handlers only push onto a thread-safe queue; the UI thread (this
# function, via DoEvents) is the only thing that ever touches rtbLog.
# =============================================================================
function Invoke-PythonStage {
    param([string]$ScriptPath, [string]$ConfigPath, [bool]$Synthesize)

    $queue = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $script:Config.paths.python_exe
    $argLine = "`"$ScriptPath`" --config `"$ConfigPath`""
    if ($Synthesize) { $argLine += ' --synthesize' }
    $psi.Arguments              = $argLine
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.WorkingDirectory       = $script:AppRoot
    # Force the python child to emit UTF-8 on stdout/stderr. When stdout is a
    # pipe (not a console) python defaults to the locale codepage (cp1252 on
    # most US Windows), which crashes the instant a script prints a non-cp1252
    # char like the status glyphs ✓ / ✗. Read it back as UTF-8 on this side too.
    $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
    $psi.EnvironmentVariables["PYTHONUTF8"]       = "1"
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true

    $outSub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $queue -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue(@{ Stream = 'out'; Text = $EventArgs.Data }) }
    }
    $errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $queue -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue(@{ Stream = 'err'; Text = $EventArgs.Data }) }
    }

    $item = $null
    try {
        [void]$proc.Start()
        $script:CurrentProcess = $proc
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        while (-not $proc.HasExited) {
            while ($queue.TryDequeue([ref]$item)) {
                if ($item.Stream -eq 'err') { Write-Log "  $($item.Text)" ([System.Drawing.Color]::FromArgb(255,140,140)) }
                else                        { Write-Log "  $($item.Text)" }
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 80
            if ($script:CancelRequested) {
                try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
                break
            }
        }

        Start-Sleep -Milliseconds 250   # let the last async reads land in the queue
        while ($queue.TryDequeue([ref]$item)) {
            if ($item.Stream -eq 'err') { Write-Log "  $($item.Text)" ([System.Drawing.Color]::FromArgb(255,140,140)) }
            else                        { Write-Log "  $($item.Text)" }
        }

        if ($proc.HasExited) { return $proc.ExitCode } else { return -1 }
    } finally {
        Unregister-Event -SourceIdentifier $outSub.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errSub.Name -ErrorAction SilentlyContinue
        Remove-Job -Name $outSub.Name -Force -ErrorAction SilentlyContinue
        Remove-Job -Name $errSub.Name -Force -ErrorAction SilentlyContinue
        $script:CurrentProcess = $null
    }
}

# =============================================================================
# HELPER: Pre-flight check for Synthesize - mirrors run_qc.py's
# check_claude_auth() so a bad auth state is caught before running any
# stages at all, not discovered only after Stage M finishes at the end of
# a run. Never triggers a login itself - `claude auth login` is inherently
# interactive (opens a browser) and cannot run headlessly, so if the user
# isn't authenticated the only correct move is to say so clearly and stop.
# No API key or account credential of any kind is read, stored, or passed
# by this app - it only checks the session the user already established
# via `claude setup-token`/`claude login` on their own, outside this app.
# =============================================================================
function Test-ClaudeCliAuth {
    $claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
    if ($null -eq $claudeCmd) {
        return @{ Ok = $false; Message = "Claude Code CLI not found on PATH. Install it, then run 'claude setup-token' once in a terminal before using Synthesize." }
    }
    try {
        & $claudeCmd.Source auth status *> $null
        if ($LASTEXITCODE -ne 0) {
            return @{ Ok = $false; Message = "Not logged in to Claude Code. Run 'claude setup-token' (or 'claude login') once in a terminal, then try Synthesize again. No API key or account info is ever stored by this app." }
        }
    } catch {
        return @{ Ok = $false; Message = "Could not check Claude Code auth status: $($_.Exception.Message)" }
    }
    return @{ Ok = $true; Message = 'Authenticated.' }
}

# =============================================================================
# HELPER: Orchestrate a run across multiple stages (used by Tab 2 buttons)
# =============================================================================
function Start-StageRun {
    param([System.Collections.Generic.List[hashtable]]$StagesToRun, [bool]$Synthesize)

    if ($null -eq $script:Config -or [string]$script:Config.paths.output_root -eq '') {
        [System.Windows.Forms.MessageBox]::Show('Please configure and Save Config on the Project Setup tab first (Output Folder is required).','Cannot Run',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if (-not (Test-Path -LiteralPath $script:Config.paths.python_exe)) {
        [System.Windows.Forms.MessageBox]::Show("Python executable not found:`n$($script:Config.paths.python_exe)`n`nCreate the venv on the Settings tab first.",'Cannot Run',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if ($script:StageRunActive) { return }

    Save-ConfigFromUI
    try {
        Save-ProjectConfig
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not save config before running stages - aborting so stages don't run against a stale file on disk:`n$($_.Exception.Message)`n`nConfig path: $script:ConfigPath",'Cannot Run',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    $script:StageRunActive   = $true
    $script:CancelRequested  = $false
    $script:SynthesisFailed  = $false
    $btnRunSelected.Enabled   = $false
    $btnRunAll.Enabled        = $false
    $btnRunSynthesize.Enabled = $false
    $btnCancelRun.Enabled     = $true

    $tabs.SelectedIndex = 2
    $pgBar3.Maximum = [math]::Max(1, $StagesToRun.Count)
    $pgBar3.Value   = 0
    $startTime = Get-Date

    Write-Log "Starting run of $($StagesToRun.Count) stage(s)." ([System.Drawing.Color]::FromArgb(150,220,255))

    $doneCount = 0
    foreach ($stage in $StagesToRun) {
        if ($script:CancelRequested) {
            Write-Log 'Run cancelled by user.' ([System.Drawing.Color]::FromArgb(255,160,40))
            break
        }
        $script:RunningStageCode = $stage.Code
        Refresh-StagesGrid

        Write-Log ('=' * 70) ([System.Drawing.Color]::FromArgb(90,90,110))
        Write-Log "Stage $($stage.Code) - $($stage.Name)  ($($stage.Script))" ([System.Drawing.Color]::FromArgb(150,200,255))

        $scriptPath = Join-Path $script:AppRoot $stage.Script
        if (-not (Test-Path -LiteralPath $scriptPath)) {
            Write-Log "ERROR: Script not found: $scriptPath" ([System.Drawing.Color]::FromArgb(255,80,80))
            $script:Config.pipeline_state.($stage.Code).last_run = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $script:Config.pipeline_state.($stage.Code).status   = 'failed'
            $script:RunningStageCode = ''
            Refresh-StagesGrid
            $doneCount++; $pgBar3.Value = $doneCount
            continue
        }

        $useSynthesize = ($Synthesize -and $stage.Code -eq 'M')
        $exitCode = Invoke-PythonStage -ScriptPath $scriptPath -ConfigPath $script:ConfigPath -Synthesize $useSynthesize

        $script:RunningStageCode = ''
        $script:Config.pipeline_state.($stage.Code).last_run = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $finalStatus = Get-StageStatusText -Code $stage.Code
        $script:Config.pipeline_state.($stage.Code).status = $finalStatus
        Save-ProjectConfig
        Refresh-StagesGrid

        if ($finalStatus -eq 'success') {
            Write-Log "Stage $($stage.Code) complete (exit code $exitCode)." ([System.Drawing.Color]::FromArgb(100,255,100))
        } else {
            Write-Log "Stage $($stage.Code) FAILED (exit code $exitCode)." ([System.Drawing.Color]::FromArgb(255,80,80))
        }

        # Stage M's output_marker is qc_report.json, which Part 1 (mechanical
        # QC) always writes regardless of synthesis outcome - so the generic
        # marker-based $finalStatus above can't tell whether --synthesize
        # itself actually succeeded. Check that separately so a failed Opus
        # call (bad auth, network, bad JSON) doesn't look like nothing
        # happened, which is exactly the bug report that led here.
        if ($useSynthesize -and $exitCode -ne 0) {
            $script:SynthesisFailed = $true
            Write-Log "Synthesis did not complete - narrative.json was not updated. See the stage output above for the reason (auth, network, or parsing failure)." ([System.Drawing.Color]::FromArgb(255,140,40))
        }

        $doneCount++; $pgBar3.Value = $doneCount
        [System.Windows.Forms.Application]::DoEvents()
    }

    $elapsed = (Get-Date) - $startTime
    Write-Log ('-' * 70) ([System.Drawing.Color]::FromArgb(90,90,110))
    Write-Log ('DONE.  {0}/{1} stage(s) attempted.  Total time: {2}m {3}s' -f $doneCount, $StagesToRun.Count, [int]$elapsed.TotalMinutes, $elapsed.Seconds) ([System.Drawing.Color]::FromArgb(150,220,255))

    $script:StageRunActive   = $false
    $btnRunSelected.Enabled   = $true
    $btnRunAll.Enabled        = $true
    $btnRunSynthesize.Enabled = $true
    $btnCancelRun.Enabled     = $false

    Refresh-OutputsTree

    # Surfaced separately from the per-stage grid/log lines above since
    # Stage M can look like a success there (qc_report.json always gets
    # written) even when synthesis itself failed - this is the one place
    # that's unmissable even if the Run Log tab wasn't being watched live.
    if ($script:SynthesisFailed) {
        [System.Windows.Forms.MessageBox]::Show(
            "Synthesis did not complete - narrative.json was not updated. See the Run Log tab for the specific reason (authentication, network, or parsing failure).",
            'Run Selected + Synthesize', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
}

# =============================================================================
# TAB 4 — OUTPUTS
# =============================================================================
$tabOutputs           = New-Object System.Windows.Forms.TabPage
$tabOutputs.Text      = '  4 · Outputs  '
$tabOutputs.BackColor = [System.Drawing.Color]::FromArgb(245,245,248)
$tabs.TabPages.Add($tabOutputs)

$pnlOutputBtns = New-Object System.Windows.Forms.Panel
$pnlOutputBtns.Left = 12; $pnlOutputBtns.Top = 12; $pnlOutputBtns.Width = 1000; $pnlOutputBtns.Height = 36
$tabOutputs.Controls.Add($pnlOutputBtns)

$btnRefreshOutputs   = New-Btn '↺ Refresh'              0   2 110 30 ([System.Drawing.Color]::FromArgb(100,100,140))
$btnOpenOutputFolder = New-Btn 'Open Output Folder'      120 2 180 30 ([System.Drawing.Color]::FromArgb(31,78,120))
$btnOpenPdf          = New-Btn 'Open PDF'                310 2 130 30 ([System.Drawing.Color]::FromArgb(20,120,40))
$pnlOutputBtns.Controls.AddRange(@($btnRefreshOutputs, $btnOpenOutputFolder, $btnOpenPdf))

$tvOutputs = New-Object System.Windows.Forms.TreeView
$tvOutputs.Left = 12; $tvOutputs.Top = 56; $tvOutputs.Width = 1000; $tvOutputs.Height = 630
$tvOutputs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tvOutputs.Font = New-Object System.Drawing.Font('Consolas', 9)
$tabOutputs.Controls.Add($tvOutputs)

function Add-TreeNodesForFolder {
    param($ParentNode, [string]$FolderPath)
    if (-not (Test-Path -LiteralPath $FolderPath)) { return }
    $dirs  = Get-ChildItem -LiteralPath $FolderPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    $files = Get-ChildItem -LiteralPath $FolderPath -File      -ErrorAction SilentlyContinue | Sort-Object Name
    foreach ($d in $dirs) {
        $node = New-Object System.Windows.Forms.TreeNode($d.Name)
        $node.Tag = $d.FullName
        [void]$ParentNode.Nodes.Add($node)
        Add-TreeNodesForFolder -ParentNode $node -FolderPath $d.FullName
    }
    foreach ($f in $files) {
        $node = New-Object System.Windows.Forms.TreeNode($f.Name)
        $node.Tag = $f.FullName
        [void]$ParentNode.Nodes.Add($node)
    }
}

function Refresh-OutputsTree {
    $tvOutputs.Nodes.Clear()
    if ($null -eq $script:Config -or [string]$script:Config.paths.output_root -eq '') { return }
    $outDir = [string]$script:Config.paths.output_root
    if (-not (Test-Path -LiteralPath $outDir)) { return }

    $stageFolders = @('stage_c','stage_d','stage_e','stage_f','stage_g','stage_h','stage_j','stage_k','stage_l','stage_m')
    foreach ($sf in $stageFolders) {
        $full = Join-Path $outDir $sf
        if (Test-Path -LiteralPath $full) {
            $rootNode = New-Object System.Windows.Forms.TreeNode($sf)
            $rootNode.Tag = $full
            Add-TreeNodesForFolder -ParentNode $rootNode -FolderPath $full
        } else {
            $rootNode = New-Object System.Windows.Forms.TreeNode("$sf  (not yet created)")
            $rootNode.Tag = $full
            $rootNode.ForeColor = [System.Drawing.Color]::Gray
        }
        [void]$tvOutputs.Nodes.Add($rootNode)
    }
}

$tvOutputs.Add_NodeMouseDoubleClick({
    param($s, $e)
    $path = $e.Node.Tag
    if ($null -ne $path -and (Test-Path -LiteralPath $path) -and -not (Get-Item -LiteralPath $path).PSIsContainer) {
        try { Start-Process -FilePath $path } catch {
            [System.Windows.Forms.MessageBox]::Show("Could not open file:`n$($_.Exception.Message)",'Open File',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
})

$btnRefreshOutputs.Add_Click({ Refresh-OutputsTree })

$btnOpenOutputFolder.Add_Click({
    if ($null -eq $script:Config -or [string]$script:Config.paths.output_root -eq '') {
        [System.Windows.Forms.MessageBox]::Show('Set an Output Folder on the Project Setup tab first.','Open Output Folder',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    if (Test-Path -LiteralPath $script:Config.paths.output_root) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:Config.paths.output_root)`""
    } else {
        [System.Windows.Forms.MessageBox]::Show('Output folder does not exist yet.','Open Output Folder',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

$btnOpenPdf.Add_Click({
    if ($null -eq $script:Config -or [string]$script:Config.paths.output_root -eq '') { return }
    # Stage L names the PDF dynamically: <Project>_Executive_Brief_<YYYYMMDD>.pdf
    $stageLDir = Join-Path $script:Config.paths.output_root 'stage_l'
    $pdf = $null
    if (Test-Path -LiteralPath $stageLDir) {
        $pdf = Get-ChildItem -LiteralPath $stageLDir -Filter '*_Executive_Brief_*.pdf' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($null -ne $pdf) {
        Start-Process -FilePath $pdf.FullName
    } else {
        [System.Windows.Forms.MessageBox]::Show("No Executive Brief PDF found yet in:`n$stageLDir",'Open PDF',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

# =============================================================================
# TAB 5 — SETTINGS
# =============================================================================
$tabSettings           = New-Object System.Windows.Forms.TabPage
$tabSettings.Text      = '  5 · Settings  '
$tabSettings.BackColor = [System.Drawing.Color]::FromArgb(245,245,248)
$tabSettings.AutoScroll = $true
$tabs.TabPages.Add($tabSettings)

# ── Venv Management ─────────────────────────────────────────────────────────
$gbVenv = New-GroupBox 'Venv Management' 12 12 1000 170
$tabSettings.Controls.Add($gbVenv)

$gbVenv.Controls.Add((New-Label 'Venv Path:' 10 28 100))
$lblVenvPathVal = New-Label '' 120 28 860
$lblVenvPathVal.ForeColor = [System.Drawing.Color]::FromArgb(60,60,80)
$gbVenv.Controls.Add($lblVenvPathVal)

$gbVenv.Controls.Add((New-Label 'Status:' 10 56 100))
$lblVenvStatusVal = New-Label 'Not Created' 120 56 200
$lblVenvStatusVal.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$lblVenvStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(190,30,30)
$gbVenv.Controls.Add($lblVenvStatusVal)

$btnCreateVenv      = New-Btn 'Create Venv'      10  92 160 30 ([System.Drawing.Color]::FromArgb(31,78,120))
$btnInstallPackages = New-Btn 'Install Packages' 180 92 170 30 ([System.Drawing.Color]::FromArgb(31,78,120))
$btnRepairPackages  = New-Btn 'Repair Packages'  360 92 170 30 ([System.Drawing.Color]::FromArgb(140,80,30))
$gbVenv.Controls.Add($btnCreateVenv)
$gbVenv.Controls.Add($btnInstallPackages)
$gbVenv.Controls.Add($btnRepairPackages)

$lblVenvActionStatus = New-Label '' 10 130 970 30
$lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(80,80,100)
$lblVenvActionStatus.AutoEllipsis = $true
$gbVenv.Controls.Add($lblVenvActionStatus)

# ── Bootstrap Python / Java ───────────────────────────────────────────────
$gbSystemPython = New-GroupBox 'Bootstrap Python  (creates the venv only — once it exists, all stage runs use the venv python)' 12 194 1000 160
$tabSettings.Controls.Add($gbSystemPython)

$gbSystemPython.Controls.Add((New-Label 'Bootstrap Python Path:' 10 18 150))
$tbSystemPython = New-Textbox 166 16 700
$gbSystemPython.Controls.Add($tbSystemPython)
$btnBrowseSystemPython = New-Btn 'Browse…' 874 14 120 28
$gbSystemPython.Controls.Add($btnBrowseSystemPython)
$btnBrowseSystemPython.Add_Click({
    $picked = Show-OpenFilePicker -Title 'Select python.exe' -Filter 'python.exe|python.exe|Executable Files (*.exe)|*.exe|All Files (*.*)|*.*' -StartPath 'C:\'
    if ($null -ne $picked -and $picked -ne '') { $tbSystemPython.Text = $picked }
})
$lblSystemPythonHint = New-Label 'Defaults to the Python runtime bundled by the installer. Only change this for advanced/manual use - never relies on a PATH-resolved "python" (which on a clean Windows box is usually the Microsoft Store stub, not a real interpreter).' 10 42 950 18
$lblSystemPythonHint.ForeColor = [System.Drawing.Color]::Gray
$lblSystemPythonHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$gbSystemPython.Controls.Add($lblSystemPythonHint)

$gbSystemPython.Controls.Add((New-Label 'Java Home (optional):' 10 66 150))
$tbJavaHome = New-Textbox 166 64 700
$gbSystemPython.Controls.Add($tbJavaHome)
$btnBrowseJavaHome = New-Btn 'Browse…' 874 62 120 28
$gbSystemPython.Controls.Add($btnBrowseJavaHome)
$lblJavaHomeHint = New-Label 'Defaults to the JRE bundled by the installer. Only change this if you need a different JVM (must be 64-bit, matching the venv python).' 10 90 950 18
$lblJavaHomeHint.ForeColor = [System.Drawing.Color]::Gray
$lblJavaHomeHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$gbSystemPython.Controls.Add($lblJavaHomeHint)
$btnBrowseJavaHome.Add_Click({
    $picked = Show-FolderPicker -Title 'Select the JDK/JRE home folder (e.g. C:\Program Files\Java\jdk-25.0.2)' -StartPath $tbJavaHome.Text
    if ($null -ne $picked -and $picked -ne '') { $tbJavaHome.Text = $picked }
})

$gbSystemPython.Controls.Add((New-Label 'JVM Max Heap (optional):' 10 114 150))
$tbJvmMaxHeap = New-Textbox 166 112 200
$gbSystemPython.Controls.Add($tbJvmMaxHeap)
$lblJvmMaxHeapHint = New-Label 'Blank = JVM default. Set only if Stage C runs out of memory on very large snapshots, e.g. 2g or 512m (this becomes the JVM''s -Xmx flag).' 10 138 950 18
$lblJvmMaxHeapHint.ForeColor = [System.Drawing.Color]::Gray
$lblJvmMaxHeapHint.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$gbSystemPython.Controls.Add($lblJvmMaxHeapHint)

# =============================================================================
# HELPER: Resolve the interpreter used to CREATE the venv (bootstrap), not
# the venv's own python. Override field wins if the user set one; otherwise
# falls back to the configured/bundled system_python_exe. Centralized here
# so Create Venv and the Environment Check (section C) can't drift apart.
# =============================================================================
function Get-ResolvedSystemPython {
    $override = $tbSystemPython.Text.Trim()
    if ($override -ne '') { return $override }
    if ($null -ne $script:Config -and [string]$script:Config.paths.system_python_exe -ne '') {
        return [string]$script:Config.paths.system_python_exe
    }
    return ''
}

# ── Environment Check ───────────────────────────────────────────────────────
$gbEnvCheck = New-GroupBox 'Environment Check' 12 364 1000 400
$tabSettings.Controls.Add($gbEnvCheck)

# ── Synthesize (Opus narrative) — external dependency note ────────────────
# Synthesize is the one feature this app does NOT self-contain: it shells out
# to the Claude Code CLI, which is not bundled and stores no credentials here.
# A fresh install on any machine has Synthesize dark until that machine's user
# installs the CLI and logs in once. This note makes that visible in-app.
$gbSynthNote = New-GroupBox 'Synthesize (Opus narrative) — one-time external setup' 12 772 1000 132
$tabSettings.Controls.Add($gbSynthNote)
$lblSynthNote = New-Label ("The ""Run Selected + Synthesize"" button on Tab 2 uses Opus to write the brief's narrative sections. It calls the Claude Code CLI installed on THIS machine — the app does not bundle it and never stores an API key or account information." + [Environment]::NewLine + [Environment]::NewLine +
    "One-time setup on each machine that will use Synthesize:" + [Environment]::NewLine +
    "   1. Install Claude Code (https://claude.ai/install.ps1)." + [Environment]::NewLine +
    "   2. In a terminal, run  claude setup-token  (or  claude login ) once and complete the browser login." + [Environment]::NewLine + [Environment]::NewLine +
    "Every other stage (C–L, mechanical QC) runs fully offline with the bundled Python/Java — only Synthesize needs this.") 12 26 976 96
$gbSynthNote.Controls.Add($lblSynthNote)

$btnRunEnvCheck = New-Btn 'Run Environment Check' 10 26 200 32 ([System.Drawing.Color]::FromArgb(70,100,140))
$gbEnvCheck.Controls.Add($btnRunEnvCheck)

$lstEnvResults = New-Object System.Windows.Forms.ListBox
$lstEnvResults.Left = 10; $lstEnvResults.Top = 68; $lstEnvResults.Width = 970; $lstEnvResults.Height = 320
$lstEnvResults.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$lstEnvResults.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
$lstEnvResults.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $text  = $lstEnvResults.Items[$e.Index].ToString()
    $color = [System.Drawing.Color]::Black
    if ($text.StartsWith('✓'))     { $color = [System.Drawing.Color]::FromArgb(20,120,40) }
    elseif ($text.StartsWith('✗')) { $color = [System.Drawing.Color]::FromArgb(190,30,30) }
    $e.DrawBackground()
    $brush = New-Object System.Drawing.SolidBrush($color)
    # NOTE: passing $e.Bounds (a Rectangle) directly here makes PowerShell's
    # overload resolution pick the wrong DrawString overload and try (and
    # fail) to convert it to a PointF - pass explicit float X/Y instead.
    $e.Graphics.DrawString($text, $e.Font, $brush, [float]$e.Bounds.X, [float]$e.Bounds.Y)
    $brush.Dispose()
    $e.DrawFocusRectangle()
})
$gbEnvCheck.Controls.Add($lstEnvResults)

# =============================================================================
# HELPER: Run a native exe, streaming each output line to a callback, while
# keeping the UI responsive (same producer/consumer-queue pattern as the
# stage runner, reused here for venv creation / pip install / env checks).
# =============================================================================
function Invoke-NativeProcessWithStatus {
    param([string]$FileName, [string]$Arguments, [scriptblock]$OnLine)

    $queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $FileName
    $psi.Arguments = $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    # Same UTF-8 hardening as Invoke-PythonStage - pip/venv output can contain
    # non-cp1252 characters that would otherwise crash the child on a piped stdout.
    $psi.EnvironmentVariables["PYTHONIOENCODING"] = "utf-8"
    $psi.EnvironmentVariables["PYTHONUTF8"]       = "1"
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $proc.EnableRaisingEvents = $true
    $outSub = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -MessageData $queue -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    }
    $errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -MessageData $queue -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
    }

    $line = $null
    try {
        [void]$proc.Start()
        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()
        while (-not $proc.HasExited) {
            while ($queue.TryDequeue([ref]$line)) { & $OnLine $line }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 80
        }
        Start-Sleep -Milliseconds 200
        while ($queue.TryDequeue([ref]$line)) { & $OnLine $line }
        return $proc.ExitCode
    } catch {
        & $OnLine "ERROR: $($_.Exception.Message)"
        return -1
    } finally {
        Unregister-Event -SourceIdentifier $outSub.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errSub.Name -ErrorAction SilentlyContinue
        Remove-Job -Name $outSub.Name -Force -ErrorAction SilentlyContinue
        Remove-Job -Name $errSub.Name -Force -ErrorAction SilentlyContinue
    }
}

function Refresh-SettingsFromConfig {
    if ($null -eq $script:Config) { return }
    $lblVenvPathVal.Text = [string]$script:Config.paths.venv_dir
    $venvPyExe = [string]$script:Config.paths.python_exe
    if (Test-Path -LiteralPath $venvPyExe) {
        $lblVenvStatusVal.Text      = 'Created'
        $lblVenvStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(20,120,40)
    } else {
        $lblVenvStatusVal.Text      = 'Not Created'
        $lblVenvStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(190,30,30)
    }
    if ($tbSystemPython.Text.Trim() -eq '') {
        # Default display only - the bundled runtime path from config, NEVER a
        # PATH-resolved "python.exe" (that's the exact lookup that picks the
        # Microsoft Store stub on a clean Windows box instead of a real
        # interpreter, which is the bug this field's redefinition fixes).
        $tbSystemPython.Text = [string]$script:Config.paths.system_python_exe
    }
    $tbJavaHome.Text = [string]$script:Config.environment.java_home
    if ($tbJavaHome.Text.Trim() -eq '') {
        # Same fallback Get-DefaultConfig itself uses for a brand-new config.
        # Needed here too because an app installed BEFORE Java bundling
        # existed has java_home already saved as "" in its config file -
        # Merge-ConfigDefaults only backfills keys that are entirely
        # missing, not ones that exist with a now-stale blank value, so a
        # pre-bundling config would otherwise never pick up the bundled
        # runtime even after reinstalling. Save Config persists this back
        # to disk via the existing environment.java_home write below, so
        # one Save Config (or any stage run, which saves first) heals it.
        $tbJavaHome.Text = Join-Path $script:AppRoot 'java-runtime'
    }
    $tbJvmMaxHeap.Text = [string]$script:Config.environment.jvm_max_heap
}

$btnCreateVenv.Add_Click({
    $sysPy = Get-ResolvedSystemPython
    if ($sysPy -eq '' -or -not (Test-Path -LiteralPath $sysPy)) {
        [System.Windows.Forms.MessageBox]::Show('Bootstrap Python not found. Reinstall the app, or set a valid override path on this tab.','Create Venv',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if ($null -eq $script:Config) { $script:Config = Get-DefaultConfig }
    $venvDir = [string]$script:Config.paths.venv_dir
    if ($venvDir -eq '') {
        [System.Windows.Forms.MessageBox]::Show('No venv path is configured. Save Config on the Project Setup tab first.','Create Venv',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $btnCreateVenv.Enabled = $false
    $btnInstallPackages.Enabled = $false
    $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(80,80,100)
    $lblVenvActionStatus.Text = "Running: $sysPy -m venv `"$venvDir`" …"
    [System.Windows.Forms.Application]::DoEvents()

    $exitCode = Invoke-NativeProcessWithStatus -FileName $sysPy -Arguments "-m venv `"$venvDir`"" -OnLine {
        param($line)
        $lblVenvActionStatus.Text = $line
        [System.Windows.Forms.Application]::DoEvents()
    }

    $pyExe = Join-Path $venvDir 'Scripts\python.exe'
    if ($exitCode -eq 0 -and (Test-Path -LiteralPath $pyExe)) {
        $script:Config.paths.python_exe = $pyExe
        $script:Config.environment.venv_created = $true
        try {
            $verOut = (& $pyExe '--version' 2>&1 | Out-String).Trim()
            $script:Config.environment.venv_python_version = $verOut
        } catch {}
        Save-ProjectConfig
        $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(20,120,40)
        $lblVenvActionStatus.Text = 'Venv created successfully.'
    } else {
        $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(190,30,30)
        $lblVenvActionStatus.Text = "Venv creation failed (exit code $exitCode)."
    }
    Refresh-SettingsFromConfig
    $btnCreateVenv.Enabled = $true
    $btnInstallPackages.Enabled = $true
})

$btnInstallPackages.Add_Click({
    if ($null -eq $script:Config) { return }
    $pyExe = [string]$script:Config.paths.python_exe
    if (-not (Test-Path -LiteralPath $pyExe)) {
        [System.Windows.Forms.MessageBox]::Show('Create the venv first.','Install Packages',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $packages = (@($script:Config.environment.pip_packages) -join ' ')

    $btnCreateVenv.Enabled = $false
    $btnInstallPackages.Enabled = $false
    $btnRepairPackages.Enabled = $false
    $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(80,80,100)
    $lblVenvActionStatus.Text = 'Installing packages — this can take a few minutes…'
    [System.Windows.Forms.Application]::DoEvents()

    $exitCode = Invoke-NativeProcessWithStatus -FileName $pyExe -Arguments "-m pip install $packages" -OnLine {
        param($line)
        $lblVenvActionStatus.Text = $line
        [System.Windows.Forms.Application]::DoEvents()
    }

    # pip exit 0 is necessary but not sufficient - a prior interrupted install
    # can leave stub packages pip considers satisfied. Only the deep smoke test
    # earns the green status.
    if ($exitCode -eq 0 -and (Invoke-VenvSmokeTest -VenvPython $pyExe)) {
        $script:Config.environment.packages_installed = $true
        Save-ProjectConfig
        $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(20,120,40)
        $lblVenvActionStatus.Text = 'Packages installed and verified (import smoke test passed).'
    } elseif ($exitCode -eq 0) {
        $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(190,30,30)
        $lblVenvActionStatus.Text = 'Environment damaged — install finished but packages fail to import. Click Repair Packages to rebuild.'
    } else {
        $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(190,30,30)
        $lblVenvActionStatus.Text = "Package install failed (exit code $exitCode)."
    }
    $btnCreateVenv.Enabled = $true
    $btnInstallPackages.Enabled = $true
    $btnRepairPackages.Enabled = $true
})

$btnRepairPackages.Add_Click({
    if ($null -eq $script:Config) { return }
    $pyExe = [string]$script:Config.paths.python_exe
    if (-not (Test-Path -LiteralPath $pyExe)) {
        [System.Windows.Forms.MessageBox]::Show('Create the venv first.','Repair Packages',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $packages = (@($script:Config.environment.pip_packages) -join ' ')

    $btnCreateVenv.Enabled = $false
    $btnInstallPackages.Enabled = $false
    $btnRepairPackages.Enabled = $false
    $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(80,80,100)
    $lblVenvActionStatus.Text = 'Repairing packages — this can take a few minutes…'
    [System.Windows.Forms.Application]::DoEvents()

    # --ignore-installed, NOT --force-reinstall: force-reinstall runs pip's
    # uninstall step first, which hard-fails on exactly the damage being
    # repaired ("Cannot uninstall pyarrow None ... no RECORD file was found"
    # - observed verbatim on a real corrupted venv). --ignore-installed skips
    # the uninstall and re-extracts every pinned wheel over the top, which is
    # idempotent and repairs partial extractions.
    $exitCode = Invoke-NativeProcessWithStatus -FileName $pyExe -Arguments "-m pip install --ignore-installed $packages" -OnLine {
        param($line)
        $lblVenvActionStatus.Text = $line
        [System.Windows.Forms.Application]::DoEvents()
    }

    if ($exitCode -eq 0 -and (Invoke-VenvSmokeTest -VenvPython $pyExe)) {
        $script:Config.environment.packages_installed = $true
        Save-ProjectConfig
        $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(20,120,40)
        $lblVenvActionStatus.Text = 'Repair complete — all packages verified (import smoke test passed).'
    } else {
        $lblVenvActionStatus.ForeColor = [System.Drawing.Color]::FromArgb(190,30,30)
        $lblVenvActionStatus.Text = 'Repair did not restore a healthy environment. Delete the venv folder and use Create Venv + Install Packages to rebuild from scratch.'
    }
    $btnCreateVenv.Enabled = $true
    $btnInstallPackages.Enabled = $true
    $btnRepairPackages.Enabled = $true
})

$btnRunEnvCheck.Add_Click({
    $lstEnvResults.Items.Clear()
    if ($null -eq $script:Config) { $script:Config = Get-DefaultConfig }

    # Check 1: bootstrap Python — three DISTINCT failure states, not one
    # generic "below 3.9". The original single regex-on-version-text check
    # is exactly how a Microsoft Store alias stub (exit code 9009, prints
    # "Python was not found; run without arguments to install from the
    # Microsoft Store...") got misdiagnosed as "below 3.9" - that text has
    # no parseable version number, so the regex just silently failed and
    # printed the unrelated stub message under a wrong heading. Each state
    # below gets looked for explicitly, in order, before falling through.
    $sysPy = Get-ResolvedSystemPython
    $isOverride = ($tbSystemPython.Text.Trim() -ne [string]$script:Config.paths.system_python_exe)
    if ($sysPy -eq '' -or -not (Test-Path -LiteralPath $sysPy)) {
        if ($isOverride) { [void]$lstEnvResults.Items.Add("✗ Override Python path not found: $sysPy") }
        else             { [void]$lstEnvResults.Items.Add('✗ Bundled Python runtime not found — reinstall the app') }
    } else {
        try {
            $verOutput = (& $sysPy '--version' 2>&1 | Out-String).Trim()
            $verExit   = $LASTEXITCODE
            $isStub    = ($verExit -ne 0) -or
                         ($verOutput -match 'Microsoft Store') -or
                         ($verOutput -match 'was not found; run without arguments')
            if ($isStub) {
                [void]$lstEnvResults.Items.Add('✗ Python interpreter is a Store alias stub, not a real install')
            } elseif ($verOutput -match '(\d+)\.(\d+)(\.\d+)?') {
                $maj = [int]$Matches[1]; $min = [int]$Matches[2]
                if ($maj -gt 3 -or ($maj -eq 3 -and $min -ge 9)) {
                    [void]$lstEnvResults.Items.Add("✓ Bootstrap Python: $verOutput")
                } else {
                    [void]$lstEnvResults.Items.Add("✗ Python $verOutput found, 3.9+ required")
                }
            } else {
                [void]$lstEnvResults.Items.Add("✗ Bootstrap Python: unrecognized --version output: $verOutput")
            }
        } catch {
            [void]$lstEnvResults.Items.Add('✗ Bootstrap Python: could not run --version')
        }
    }

    # Check 2: Java found (Java Home field, which defaults to the bundled JRE)
    # and 64-bit. A 32-bit JVM crashes Stage C with JVMNotSupportedException
    # since the venv python is always 64-bit. No PATH-based fallback here -
    # deliberately, same reasoning as the bootstrap Python check: a
    # PATH-resolved "java" is exactly the unreliable auto-detection that
    # used to pick a 32-bit JVM over a working 64-bit one on this machine.
    $javaHomeCfg    = $tbJavaHome.Text.Trim()
    $javaExeToCheck = $null
    if ($javaHomeCfg -ne '' -and (Test-Path -LiteralPath $javaHomeCfg)) {
        $candidate = Join-Path $javaHomeCfg 'bin\java.exe'
        if (Test-Path -LiteralPath $candidate) { $javaExeToCheck = $candidate }
    }
    if ($null -ne $javaExeToCheck) {
        try {
            $verText = (& $javaExeToCheck '-version' 2>&1 | Out-String)
            if ($verText -match '64-Bit') {
                [void]$lstEnvResults.Items.Add("✓ Java (64-bit) found: $javaExeToCheck")
            } else {
                [void]$lstEnvResults.Items.Add("✗ Java found but appears 32-bit (will crash Stage C - venv python is 64-bit): $javaExeToCheck")
            }
        } catch {
            [void]$lstEnvResults.Items.Add("✗ Java found but could not run -version: $javaExeToCheck")
        }
    } elseif ($javaHomeCfg -eq '') {
        [void]$lstEnvResults.Items.Add('✗ Java Home not set and no bundled runtime found — reinstall the app, or set Java Home above')
    } else {
        [void]$lstEnvResults.Items.Add("✗ Java not found at: $javaHomeCfg — reinstall the app, or fix the Java Home path above")
    }

    # Check 3: venv exists
    $venvPyExe = [string]$script:Config.paths.python_exe
    $venvOk = Test-Path -LiteralPath $venvPyExe
    if ($venvOk) { [void]$lstEnvResults.Items.Add("✓ Venv exists: $venvPyExe") }
    else         { [void]$lstEnvResults.Items.Add("✗ Venv not found: $venvPyExe") }

    # Check 4: every pip_package imports AND is a real (non-stub) install.
    # This is the fourth failure state (beyond bootstrap-Python, Java, and
    # missing-venv): a venv that EXISTS but is DAMAGED. A package left as an
    # empty stub by an interrupted wheel extraction imports fine yet has no
    # __file__ - the exact failure that killed a real run inside pandas'
    # pyarrow shim. Each package is classified as OK / missing / corrupted so
    # "reinstall the app" (missing runtime) is distinguishable from "click
    # Repair Packages" (damaged venv).
    if ($venvOk) {
        $missing   = @()
        $corrupted = @()
        foreach ($pkg in @($script:Config.environment.pip_packages)) {
            $importName = Get-PipImportName $pkg
            $probe = "import $importName as _m; import sys; sys.exit(2 if getattr(_m,'__file__',None) is None else 0)"
            & $venvPyExe '-c' $probe *> $null
            $rc = $LASTEXITCODE
            if     ($rc -eq 2) { $corrupted += (($pkg -split '==')[0]) }
            elseif ($rc -ne 0) { $missing   += (($pkg -split '==')[0]) }
        }
        if ($corrupted.Count -eq 0 -and $missing.Count -eq 0) {
            [void]$lstEnvResults.Items.Add('✓ All packages importable and verified in venv')
        } else {
            if ($missing.Count -gt 0)   { [void]$lstEnvResults.Items.Add("✗ Packages not importable (reinstall or use Install Packages): $($missing -join ', ')") }
            if ($corrupted.Count -gt 0) { [void]$lstEnvResults.Items.Add("✗ Environment damaged — corrupted packages (click Repair Packages on the Venv panel): $($corrupted -join ', ')") }
        }
    } else {
        [void]$lstEnvResults.Items.Add('✗ Packages importable: skipped (no venv)')
    }

    $script:Config.environment.last_env_check = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Save-ProjectConfig
})

# =============================================================================
# STARTUP — prefer the last-opened config (so working across multiple
# projects over time just remembers where you left off), fall back to the
# fixed DataRoot config, else start blank with Tabs 2-4 disabled.
# Deliberately does NOT check $script:AppRoot (the install dir) first - that
# location previously held a stale decoy config that silently hijacked the
# active config path after the schema-B rewrite; see the legacy-migration
# comment near the top of this file. AppRoot is only ever read once, for
# that one-time forward migration - never as an ongoing startup source.
# =============================================================================
$startupLoaded     = $true
$lastConfigPath    = Get-LastConfigPath
$startupConfigPath = if ($null -ne $lastConfigPath) { $lastConfigPath } else { $script:ConfigPath }

if (Test-Path -LiteralPath $startupConfigPath) {
    try {
        $script:Config     = Load-ProjectConfigFile -Path $startupConfigPath
        $script:ConfigPath = $startupConfigPath
    } catch {
        $script:Config  = Get-DefaultConfig
        $startupLoaded  = $false
    }
} else {
    $script:Config = Get-DefaultConfig
    $startupLoaded = $false
}

Refresh-UIFromConfig
Refresh-StagesGrid
Refresh-OutputsTree
Refresh-SettingsFromConfig
Set-ProjectLoadedState -Loaded $startupLoaded

# =============================================================================
# LAUNCH
# =============================================================================
$form.Add_Shown({
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $form.Refresh()
    $form.Activate()
})
[System.Windows.Forms.Application]::Run($form)
