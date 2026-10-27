@echo off
setlocal
cd /d "%~dp0"
title MUJ Mess - MySQL
rem Opens the MySQL command line, shows every table (db\show.sql), then leaves you at the mysql> prompt.
set "MYSQL="
for /d %%D in ("%ProgramFiles%\MySQL\MySQL Server 8*") do if exist "%%D\bin\mysql.exe" set "MYSQL=%%D\bin\mysql.exe"
if not defined MYSQL (
  echo MySQL command line not found in "%ProgramFiles%\MySQL". Install MySQL Server 8.0.
  pause
  exit /b 1
)
rem Ask once, hidden; MYSQL_PWD lives only in this window. Empty answer = no password.
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$p = Read-Host 'MySQL root password' -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($p))"`) do set "MYSQL_PWD=%%P"
"%MYSQL%" -uroot --table --force mess < db\show.sql
echo.
echo ===== You are in MySQL now (database: mess). Type any query, or exit to close. =====
"%MYSQL%" -uroot mess
pause
