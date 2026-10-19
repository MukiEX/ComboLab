@echo off
rem Updates ComboLab's program files (mod + page + server) from your hub or a git repo.
rem   run_update.bat              check, then update
rem   run_update.bat check        only show what would change
rem   run_update.bat source git https://github.com/you/ComboLab.git
cd /d "%~dp0"
set ARGS=%*
if "%ARGS%"=="" set ARGS=apply
where py >nul 2>nul && (py -3 combolab_update.py %ARGS%) || (python combolab_update.py %ARGS%)
pause
