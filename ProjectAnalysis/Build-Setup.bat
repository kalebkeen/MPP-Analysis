@echo off
:: =============================================================================
:: Build-Setup.bat  —  PA Pipeline Setup Builder
:: =============================================================================
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
if "!SCRIPT_DIR:~-1!"=="\" set "SCRIPT_DIR=!SCRIPT_DIR:~0,-1!"

set "CS_FILE=!SCRIPT_DIR!\PA-Pipeline-Setup.cs"
set "OUT_EXE=!SCRIPT_DIR!\PA-Pipeline-Setup.exe"
set "ICON_PATH="
:: Bundled CPython installer and Java runtime, embedded as .NET PE resources
:: (NOT base64 string constants in the .cs - csc.exe hard-fails on
:: string-literal data this large with "No logical space left to create
:: more user strings"). Embed-Sources.ps1 copies both files here under
:: these exact names.
set "PYTHON_INSTALLER=!SCRIPT_DIR!\python-3.12.10-amd64.exe"
set "JAVA_RUNTIME_ZIP=!SCRIPT_DIR!\temurin-21-jre-windows-x64.zip"
:: Bundled Carlito font (SIL OFL, googlefonts/carlito), same rationale and
:: same PE-resource embedding as the two files above - a real test compile
:: showed this project's csc.exe hard-fails on base64 string constants this
:: large, so binary assets go in via /resource: instead.
set "CARLITO_FONTS_ZIP=!SCRIPT_DIR!\carlito-fonts.zip"

cls
echo.
echo =====================================================
echo   PA Pipeline  -  Setup Builder
echo =====================================================
echo.
echo   Working folder: !SCRIPT_DIR!
echo.

echo [1/4] Checking for PA-Pipeline-Setup.cs...
if not exist "!CS_FILE!" (
    echo.
    echo ERROR: Cannot find PA-Pipeline-Setup.cs
    echo        Expected at: !CS_FILE!
    echo.
    pause
    exit /b 1
)
echo       Found: !CS_FILE!
echo.

echo [2/4] Locating C# compiler (csc.exe)...
set "CSC="

for %%P in (
    "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    "C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    "C:\Windows\Microsoft.NET\Framework64\v3.5\csc.exe"
    "C:\Windows\Microsoft.NET\Framework\v3.5\csc.exe"
) do (
    echo       Checking: %%~P
    if exist %%P (
        if "!CSC!"=="" set "CSC=%%~P"
    )
)

if "!CSC!"=="" (
    echo.
    echo ERROR: csc.exe not found.
    echo Please install .NET Framework 4.x from:
    echo   https://dotnet.microsoft.com/download/dotnet-framework
    echo.
    pause
    exit /b 1
)
echo       Found: !CSC!
echo.

echo [3/4] Compiling PA-Pipeline-Setup.exe...
echo       (this usually takes 5-15 seconds)
echo.

set "ICON_ARG="
if not "!ICON_PATH!"=="" (
    if exist "!ICON_PATH!" (
        set "ICON_ARG=/win32icon:"!ICON_PATH!""
    ) else (
        echo       WARNING: Icon not found at !ICON_PATH! -- skipping.
    )
)

if not exist "!PYTHON_INSTALLER!" (
    echo.
    echo ERROR: Bundled Python installer not found.
    echo        Expected at: !PYTHON_INSTALLER!
    echo        Run Embed-Sources.ps1 -PythonInstallerPath ^<path^> first.
    echo.
    pause
    exit /b 1
)
if not exist "!JAVA_RUNTIME_ZIP!" (
    echo.
    echo ERROR: Bundled Java runtime not found.
    echo        Expected at: !JAVA_RUNTIME_ZIP!
    echo        Run Embed-Sources.ps1 -JavaRuntimePath ^<path^> first.
    echo.
    pause
    exit /b 1
)
if not exist "!CARLITO_FONTS_ZIP!" (
    echo.
    echo ERROR: Bundled Carlito fonts not found.
    echo        Expected at: !CARLITO_FONTS_ZIP!
    echo        Run Embed-Sources.ps1 -CarlitoFontZip ^<path^> first.
    echo.
    pause
    exit /b 1
)
set "PY_RESOURCE_ARG=/resource:"!PYTHON_INSTALLER!",PASetup.PythonInstaller.exe"
set "JAVA_RESOURCE_ARG=/resource:"!JAVA_RUNTIME_ZIP!",PASetup.JavaRuntime.zip"
set "CARLITO_RESOURCE_ARG=/resource:"!CARLITO_FONTS_ZIP!",PASetup.CarlitoFonts.zip"

"!CSC!" /nologo /target:winexe /optimize+ ^
    /r:System.dll ^
    /r:System.Drawing.dll ^
    /r:System.Windows.Forms.dll ^
    /r:System.IO.Compression.dll ^
    /r:System.IO.Compression.FileSystem.dll ^
    /out:"!OUT_EXE!" ^
    !ICON_ARG! ^
    !PY_RESOURCE_ARG! ^
    !JAVA_RESOURCE_ARG! ^
    !CARLITO_RESOURCE_ARG! ^
    "!CS_FILE!"

set "COMPILE_RESULT=!ERRORLEVEL!"
echo.
echo       csc.exe exit code: !COMPILE_RESULT!

if !COMPILE_RESULT! neq 0 (
    echo.
    echo ERROR: Compilation failed. See output above.
    echo.
    pause
    exit /b 1
)

echo.
echo [4/4] Verifying output...

if not exist "!OUT_EXE!" (
    echo.
    echo ERROR: Output file not created.
    echo.
    pause
    exit /b 1
)

for %%A in ("!OUT_EXE!") do set "FSIZE=%%~zA"
set /a FSIZE_KB=!FSIZE! / 1024
echo       Created: !OUT_EXE!
echo       Size   : ~!FSIZE_KB! KB

echo.
echo =====================================================
echo   BUILD SUCCESSFUL
echo =====================================================
echo.
echo   Distribute PA-Pipeline-Setup.exe to your users.
echo   They double-click it -- it will prompt for admin
echo   rights automatically (installs to Program Files),
echo   then install silently.
echo.
echo   NOTE: This rebuild only recompiles the .cs file as-is.
echo   If you edit PA-Pipeline.ps1 or any of the 9 Python
echo   stage scripts, those embedded copies need to be
echo   re-encoded into PA-Pipeline-Setup.cs before rebuilding,
echo   or this exe will still ship the older versions.
echo.
if "!ICON_PATH!"=="" (
    echo   REMINDER: When you have a .ico file, set ICON_PATH
    echo   at the top of this script and rebuild.
    echo.
)
pause
endlocal
