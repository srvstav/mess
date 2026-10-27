@echo off
setlocal
cd /d "%~dp0"
set PYTHONUTF8=1
title MUJ Mess - server (close this window to stop)
if not exist "backend\.env" (
  echo Run setup.bat first.
  pause
  exit /b 1
)

rem 1. MySQL must be running, or every page says "Can't reach the mess server".
for %%S in (MySQL80 MySQL) do (
  sc query %%S >nul 2>nul && (
    sc query %%S | find "RUNNING" >nul || (
      echo Starting the %%S service...
      net start %%S >nul 2>nul || echo   Could not start %%S. Right-click start.bat - Run as administrator, or start MySQL80 in services.msc.
    )
  )
)

rem 2. Already running from an earlier start.bat? Just open the site.
netstat -ano | findstr /r /c:":8000 .*LISTENING" >nul && (
  echo The server is already running. Opening http://localhost:8000
  start "" http://localhost:8000
  exit /b 0
)

echo MUJ Mess is starting on http://localhost:8000
echo   Student site : http://localhost:8000
echo   Live board   : http://localhost:8000/dashboard.html
echo   Health check : http://localhost:8000/health
echo   API docs     : http://localhost:8000/docs
echo Keep this window open. Close it to stop the server.
echo.
rem 3. Open the browser only once /health answers (API and database both up), not after a fixed wait.
start "" /min powershell -NoProfile -Command "for($i=0;$i -lt 60;$i++){try{if((Invoke-WebRequest http://127.0.0.1:8000/health -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200){Start-Process http://localhost:8000; break}}catch{}; Start-Sleep 1}"
cd backend
".venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8000
echo.
echo The server stopped. Read the error above (MySQL not running? wrong password in backend\.env?).
pause
