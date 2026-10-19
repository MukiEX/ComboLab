@echo off
rem Runs only the hub sync agent (run_server.bat already includes it once sync.json exists).
rem First time:  run_sync.bat setup https://your-hub.example.com YOUR_TOKEN
cd /d "%~dp0"
where py >nul 2>nul && (py -3 combolab_sync.py %*) || (python combolab_sync.py %*)
pause
