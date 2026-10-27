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
echo MUJ Mess is starting on http://localhost:8000
echo   Student site : http://localhost:8000
echo   Live board   : http://localhost:8000/dashboard.html
echo   API docs     : http://localhost:8000/docs
echo Keep this window open. Close it to stop the server.
echo.
start "" /min cmd /c "timeout /t 4 /nobreak >nul && start http://localhost:8000"
cd backend
".venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8000
pause
