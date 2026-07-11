@echo off
setlocal

set "UPDATER=%~dp0.ophclinic\Update-OPHclinic.ps1"
if not exist "%UPDATER%" (
  echo Updater not found: %UPDATER%
  pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%UPDATER%" -PortableRoot "%~dp0." %*
set "UPDATE_EXIT=%ERRORLEVEL%"

echo.
if not "%UPDATE_EXIT%"=="0" echo Update failed with exit code %UPDATE_EXIT%.
pause
exit /b %UPDATE_EXIT%
