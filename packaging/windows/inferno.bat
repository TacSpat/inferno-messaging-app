@echo off
setlocal

:: Windows launcher for Inferno.
:: Starts the Tebako-packaged Rails server and opens the browser.

set "INFERNO_DATA_DIR=%APPDATA%\Inferno"
set "RAILS_ENV=production"
set "SOLID_QUEUE_IN_PUMA=1"
set "PORT=3131"

:: Create data directories
if not exist "%INFERNO_DATA_DIR%\storage" mkdir "%INFERNO_DATA_DIR%\storage"
if not exist "%INFERNO_DATA_DIR%\tmp" mkdir "%INFERNO_DATA_DIR%\tmp"
if not exist "%INFERNO_DATA_DIR%\log" mkdir "%INFERNO_DATA_DIR%\log"

:: Persistent secret key
set "SECRET_FILE=%INFERNO_DATA_DIR%\.secret"
if exist "%SECRET_FILE%" (
    set /p SECRET_KEY_BASE=<"%SECRET_FILE%"
) else (
    :: Generate random secret using PowerShell
    for /f "delims=" %%i in ('powershell -NoProfile -Command "[System.Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(64)).ToLower()"') do set "SECRET_KEY_BASE=%%i"
    echo %SECRET_KEY_BASE%>"%SECRET_FILE%"
)

set "BINARY=%~dp0inferno.exe"

:: First-run: prepare database
echo [Inferno] Preparing database...
"%BINARY%" db:prepare 2>nul

:: Start server
echo [Inferno] Starting server on http://127.0.0.1:3131 ...
start "" "%BINARY%" server -b 127.0.0.1 -p 3131

:: Wait for server to be ready, then open browser
:wait_loop
timeout /t 1 /nobreak >nul
powershell -NoProfile -Command "try { (Invoke-WebRequest -Uri 'http://127.0.0.1:3131' -UseBasicParsing -TimeoutSec 1).StatusCode } catch { exit 1 }" >nul 2>&1
if errorlevel 1 goto wait_loop

start http://127.0.0.1:3131

echo [Inferno] Running. Close this window to stop the server.
pause >nul
