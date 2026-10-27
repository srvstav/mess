@echo off
cd /d "%~dp0"
rem Windows: one double-click brings everything up (first run also builds the database).
if not exist "backend\.env" call setup.bat
if not exist "backend\.env" exit /b 1
start "MUJ Mess - live activity" /min cmd /c ""backend\.venv\Scripts\python.exe" demo_data.py live"
start "" cmd /c workbench.bat
call start.bat
