@echo off
rem JMD-2L CNC installer entry point
rem ASCII only: cmd.exe reads .cmd in the console code page.
setlocal
cd /d "%~dp0"

set "PS1=%~dp0install.ps1"
if not exist "%PS1%" (
  echo install.ps1 not found next to install.cmd
  pause
  exit /b 1
)

rem PowerShell 2.0 cannot read our syntax; 3.0+ can. Win7 ships with 2.0.
set "PSVER="
for /f "delims=" %%v in ('powershell -NoProfile -Command "$PSVersionTable.PSVersion.Major" 2^>nul') do set "PSVER=%%v"
if not defined PSVER (
  echo PowerShell not found. Install Windows Management Framework 3.5 or newer.
  pause
  exit /b 1
)
if %PSVER% LSS 3 (
  echo PowerShell %PSVER% found, need 3.0 or newer.
  echo Run: powershell -ExecutionPolicy Bypass -File "%PS1%"
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Installer failed, exit code %RC%. Log: %%TEMP%%\jmd2l-install.log
  pause
)
exit /b %RC%