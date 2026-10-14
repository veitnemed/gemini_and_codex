@echo off
setlocal
cd /d "%~dp0"
echo [1/2] Installing or updating the delegation configuration...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-antigravity.ps1" -Action Install
if errorlevel 1 goto failed
echo [2/2] Running one real Antigravity task through MCP...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-antigravity.ps1" -Action Test
if errorlevel 1 goto failed
echo Ready. Restart the Codex extension and open a new chat.
pause
exit /b 0
:failed
echo Setup or live verification FAILED. Read the output above.
pause
exit /b 1
