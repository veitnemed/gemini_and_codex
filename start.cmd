@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\menu.ps1"
set MENU_EXIT=%ERRORLEVEL%
if %MENU_EXIT% neq 0 (
    echo.
    echo Menu session ended with error code %MENU_EXIT%.
)
pause
exit /b %MENU_EXIT%
