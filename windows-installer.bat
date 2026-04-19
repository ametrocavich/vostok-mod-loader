@echo off
setlocal enabledelayedexpansion

echo.
echo === Road to Vostok Mod Loader Installer ===
echo.

:: --- Find game installation ---
set "GAME_PATH="

:: Check common Steam locations
for %%P in (
    "%ProgramFiles%\Steam\steamapps\common\Road to Vostok"
    "%ProgramFiles(x86)%\Steam\steamapps\common\Road to Vostok"
    "C:\Steam\steamapps\common\Road to Vostok"
    "D:\Steam\steamapps\common\Road to Vostok"
    "E:\Steam\steamapps\common\Road to Vostok"
    "C:\SteamLibrary\steamapps\common\Road to Vostok"
    "D:\SteamLibrary\steamapps\common\Road to Vostok"
    "E:\SteamLibrary\steamapps\common\Road to Vostok"
    "F:\SteamLibrary\steamapps\common\Road to Vostok"
) do (
    if exist "%%~P\RTV.exe" (
        set "GAME_PATH=%%~P"
        goto :found
    )
)

:: Not found - ask user
echo Could not find Road to Vostok automatically.
echo Please enter the path to your game folder (containing RTV.exe):
set /p "GAME_PATH=Game path: "

if not exist "%GAME_PATH%\RTV.exe" (
    echo ERROR: RTV.exe not found at "%GAME_PATH%"
    goto :error
)

:found
echo Found game at: %GAME_PATH%

:: --- Set up paths ---
set "MODLOADER_DEST=%GAME_PATH%\modloader.gd"
set "OVERRIDE_PATH=%GAME_PATH%\override.cfg"
set "MODS_PATH=%GAME_PATH%\mods"
:: GitHub's latest-release redirect serves whatever the most recent tagged
:: release uploaded as assets. Non-release commits on master don't ship here.
set "MODLOADER_URL=https://github.com/ametrocavich/vostok-mod-loader/releases/latest/download/modloader.gd"
set "OVERRIDE_URL=https://github.com/ametrocavich/vostok-mod-loader/releases/latest/download/override.cfg"

:: --- Download modloader.gd ---
:: Force TLS 1.2 (older PowerShell defaults to 1.1 which GitHub rejects).
:: Verify the response succeeded AND the file is non-empty before trusting it.
:: Download to a temp file first so a failed download doesn't overwrite or
:: delete a working existing installation.
set "MODLOADER_TMP=%MODLOADER_DEST%.new"
if exist "%MODLOADER_TMP%" del "%MODLOADER_TMP%" >nul 2>&1
echo Downloading mod loader...
powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; try { $r = Invoke-WebRequest -Uri '%MODLOADER_URL%' -OutFile '%MODLOADER_TMP%' -UseBasicParsing -PassThru; if ($r.StatusCode -ne 200) { exit 1 } } catch { exit 1 }"
set "DL_RC=!errorlevel!"
set "DL_OK=0"
if !DL_RC! equ 0 if exist "%MODLOADER_TMP%" (
    for %%F in ("%MODLOADER_TMP%") do if %%~zF gtr 0 set "DL_OK=1"
)
if !DL_OK! equ 1 (
    move /y "%MODLOADER_TMP%" "%MODLOADER_DEST%" >nul
    echo Downloaded modloader.gd to game folder
) else (
    if exist "%MODLOADER_TMP%" del "%MODLOADER_TMP%" >nul 2>&1
    if exist "%MODLOADER_DEST%" (
        echo WARNING: Download failed -- keeping existing modloader.gd
    ) else (
        echo ERROR: Failed to download modloader.gd
        echo You can manually download it from:
        echo   %MODLOADER_URL%
        echo And place it at:
        echo   %MODLOADER_DEST%
        goto :error
    )
)

:: --- Download repo's override.cfg template ---
:: The repo's override.cfg is the single source of truth for what mod loader
:: expects in [autoload]. We merge its entries into the user's existing
:: override.cfg so their other customizations ([display], [input], etc.) stay.
set "OVERRIDE_TMP=%OVERRIDE_PATH%.template"
if exist "%OVERRIDE_TMP%" del "%OVERRIDE_TMP%" >nul 2>&1
echo Fetching override.cfg template...
powershell -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; try { $r = Invoke-WebRequest -Uri '%OVERRIDE_URL%' -OutFile '%OVERRIDE_TMP%' -UseBasicParsing -PassThru; if ($r.StatusCode -ne 200) { exit 1 } } catch { exit 1 }"
set "OV_RC=!errorlevel!"
set "OV_OK=0"
if !OV_RC! equ 0 if exist "%OVERRIDE_TMP%" (
    for %%F in ("%OVERRIDE_TMP%") do if %%~zF gtr 0 set "OV_OK=1"
)
if !OV_OK! neq 1 (
    echo ERROR: Failed to download override.cfg template
    if exist "%OVERRIDE_TMP%" del "%OVERRIDE_TMP%" >nul 2>&1
    goto :error
)

:: --- Install/merge override.cfg ---
:: For keys the template specifies, force the template's value (overwriting
:: outdated user values like a stale ModLoader path). Keys the user has that
:: template doesn't specify are left untouched.
if exist "%OVERRIDE_PATH%" (
    echo Merging override.cfg (preserving user sections, updating template keys)
    copy "%OVERRIDE_PATH%" "%OVERRIDE_PATH%.bak" >nul
    powershell -Command "$user = '%OVERRIDE_PATH%'; $tmpl = '%OVERRIDE_TMP%'; $tmplCfg = @{}; $curSec = $null; foreach ($line in Get-Content -LiteralPath $tmpl) { $t = $line.Trim(); if ($t -match '^\[(.+)\]$') { $curSec = $Matches[1]; if (-not $tmplCfg.ContainsKey($curSec)) { $tmplCfg[$curSec] = [ordered]@{} }; continue } if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#') -or $curSec -eq $null) { continue } $eq = $t.IndexOf('='); if ($eq -lt 0) { continue } $k = $t.Substring(0, $eq).Trim(); $v = $t.Substring($eq + 1); $tmplCfg[$curSec][$k] = $v } $out = New-Object System.Collections.Generic.List[string]; $seenSec = @{}; $curSec = $null; $sectionLines = New-Object System.Collections.Generic.List[string]; function Flush { param($sec, $lines, $out, $tmplCfg) $tmplKeys = @{}; if ($sec -ne $null -and $tmplCfg.ContainsKey($sec)) { foreach ($k in $tmplCfg[$sec].Keys) { $tmplKeys[$k] = $true } } $existingKeys = @{}; foreach ($ln in $lines) { $tr = $ln.Trim(); if ($tr -match '^\[.+\]$') { $out.Add($ln); continue } if ($tr -eq '' -or $tr.StartsWith(';') -or $tr.StartsWith('#')) { $out.Add($ln); continue } $eq = $tr.IndexOf('='); if ($eq -lt 0) { $out.Add($ln); continue } $k = $tr.Substring(0, $eq).Trim(); if ($tmplKeys.ContainsKey($k)) { $newVal = $tmplCfg[$sec][$k]; $out.Add(\"$k=$newVal\"); $existingKeys[$k] = $true } else { $out.Add($ln) } } if ($sec -ne $null -and $tmplCfg.ContainsKey($sec)) { foreach ($k in $tmplCfg[$sec].Keys) { if (-not $existingKeys.ContainsKey($k)) { $out.Add(\"$k=$($tmplCfg[$sec][$k])\") } } } } foreach ($line in Get-Content -LiteralPath $user) { $t = $line.Trim(); if ($t -match '^\[(.+)\]$') { Flush $curSec $sectionLines $out $tmplCfg; $sectionLines.Clear(); $curSec = $Matches[1]; $seenSec[$curSec] = $true; $sectionLines.Add($line); continue } $sectionLines.Add($line) } Flush $curSec $sectionLines $out $tmplCfg; foreach ($sec in $tmplCfg.Keys) { if (-not $seenSec.ContainsKey($sec)) { $out.Add(''); $out.Add(\"[$sec]\"); foreach ($k in $tmplCfg[$sec].Keys) { $out.Add(\"$k=$($tmplCfg[$sec][$k])\") } } } Set-Content -LiteralPath $user -Value $out"
    echo Updated override.cfg
) else (
    move /y "%OVERRIDE_TMP%" "%OVERRIDE_PATH%" >nul
    echo Installed override.cfg
)
if exist "%OVERRIDE_TMP%" del "%OVERRIDE_TMP%" >nul 2>&1

:: --- Create mods directory ---
if not exist "%MODS_PATH%" (
    mkdir "%MODS_PATH%"
    echo Created mods directory
) else (
    echo Mods directory already exists
)

:: --- Done ---
echo.
echo === Installation Complete ===
echo.
echo The mod loader is now installed. When you launch Road to Vostok,
echo a mod manager window will appear before the game loads.
echo.
echo To install mods:
echo   - Place .vmz/.zip files in: %MODS_PATH%
echo.
echo Game path:  %GAME_PATH%
echo Mods path:  %MODS_PATH%
echo.
goto :done

:error
echo.
echo Installation failed.
echo.

:done
echo Press any key to exit...
pause >nul