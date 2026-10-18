@echo off
cd /d "%~dp0"
where py >nul 2>nul && (py -3 combolab_server.py %*) || (python combolab_server.py %*)
pause
