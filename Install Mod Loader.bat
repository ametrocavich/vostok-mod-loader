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
set "USER_DATA=%APPDATA%\Road to Vostok"
set "MODLOADER_DEST=%USER_DATA%\modloader.gd"
set "OVERRIDE_PATH=%GAME_PATH%\override.cfg"
set "MODS_PATH=%GAME_PATH%\mods"
set "MODLOADER_URL=https://raw.githubusercontent.com/ametrocavich/vostok-mod-loader/master/modloader.gd"

:: --- Create user data directory ---
if not exist "%USER_DATA%" (
    mkdir "%USER_DATA%"
    echo Created user data directory
)

:: --- Download modloader.gd ---
echo Downloading mod loader...
powershell -Command "Invoke-WebRequest -Uri '%MODLOADER_URL%' -OutFile '%MODLOADER_DEST%' -UseBasicParsing" 2>nul
if exist "%MODLOADER_DEST%" (
    echo Downloaded modloader.gd
) else (
    echo WARNING: Failed to download modloader.gd
    echo You can manually download it from:
    echo   %MODLOADER_URL%
    echo And place it at:
    echo   %MODLOADER_DEST%
)

:: --- Create override.cfg ---
if exist "%OVERRIDE_PATH%" (
    findstr /i "modloader.gd" "%OVERRIDE_PATH%" >nul 2>&1
    if !errorlevel! equ 0 (
        echo override.cfg already configured
    ) else (
        echo Backing up existing override.cfg
        copy "%OVERRIDE_PATH%" "%OVERRIDE_PATH%.bak" >nul
        echo [autoload]> "%OVERRIDE_PATH%"
        echo ModLoader="user://modloader.gd">> "%OVERRIDE_PATH%"
        echo Created override.cfg
    )
) else (
    echo [autoload]> "%OVERRIDE_PATH%"
    echo ModLoader="user://modloader.gd">> "%OVERRIDE_PATH%"
    echo Created override.cfg
)

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
echo   - Use the Browse tab in the mod manager
echo   - Or place .vmz/.zip files in: %MODS_PATH%
echo.
echo Game path:  %GAME_PATH%
echo Mods path:  %MODS_PATH%
echo User data:  %USER_DATA%
echo.
goto :done

:error
echo.
echo Installation failed.
echo.

:done
echo Press any key to exit...
pause >nul
