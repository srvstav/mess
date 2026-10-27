@echo off
setlocal
cd /d "%~dp0"
rem Opens MySQL Workbench already connected, with db\tables.sql loaded.
rem   workbench.bat         this laptops MySQL (root@127.0.0.1)
rem   workbench.bat cloud   the cloud MySQL (details saved by setup_cloud.bat)
set "WB="
for /d %%D in ("%ProgramFiles%\MySQL\MySQL Workbench*") do if exist "%%D\MySQLWorkbench.exe" set "WB=%%D\MySQLWorkbench.exe"
if not defined WB (
  echo MySQL Workbench is not installed. Get it from https://dev.mysql.com/downloads/workbench/
  pause
  exit /b 1
)
set "CONN=root@127.0.0.1:3306"
if /i "%~1"=="cloud" (
  if not exist "backend\.workbench_cloud" (
    echo No cloud details on this laptop. Run setup_cloud.bat first, or connect by hand: see WORKBENCH.md
    pause
    exit /b 1
  )
  set /p CONN=<"backend\.workbench_cloud"
)
echo Opening Workbench on %CONN% with db\tables.sql
echo It asks for the password once. Then click the lightning bolt to show every table.
start "" "%WB%" --query "%CONN%" --open "%~dp0db\tables.sql"
