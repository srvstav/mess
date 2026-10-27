@echo off
setlocal
cd /d "%~dp0"
title MUJ Mess - starting everything
rem Windows: one double-click brings everything up: server + website + dashboard, live activity,
rem MySQL command line with every table shown, and Workbench if installed.
rem First run also builds the database. Right-click - Run as administrator if MySQL might be stopped.
if not exist "backend\.env" call setup.bat
if not exist "backend\.env" exit /b 1

start "MUJ Mess - server" cmd /c start.bat
echo Waiting for the server and the database...
powershell -NoProfile -Command "for($i=0;$i -lt 90;$i++){try{if((Invoke-WebRequest http://127.0.0.1:8000/health -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200){exit 0}}catch{}; Start-Sleep 1}; exit 1"
if errorlevel 1 (
  echo The server did not come up. Read the "MUJ Mess - server" window for the reason.
  pause
  exit /b 1
)

start "" http://localhost:8000/dashboard.html
start "MUJ Mess - live activity" /min cmd /c ""backend\.venv\Scripts\python.exe" demo_data.py live"
start "MUJ Mess - MySQL" cmd /c mysql_show.bat
if exist "%ProgramFiles%\MySQL\MySQL Workbench*" start "" cmd /c workbench.bat
echo.
echo Everything is up:
echo   Site      : http://localhost:8000
echo   Dashboard : http://localhost:8000/dashboard.html
echo   MySQL     : the "MUJ Mess - MySQL" window
timeout /t 8 >nul
