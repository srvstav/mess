#!/usr/bin/env bash
# macOS: one command brings everything up: database (first run only), API + website, live activity,
# then opens the site, the dashboard and MySQL Workbench with every report query loaded.
#   ./spin.sh            (MySQL must be running: brew services start mysql)
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -x backend/.venv/bin/python ]; then
  python3 -m venv backend/.venv
  backend/.venv/bin/python -m pip install -q -r backend/requirements.txt
fi
# First run only: build the database (asks for the MySQL root password; Enter if there is none).
[ -f backend/.env ] || backend/.venv/bin/python setup.py local
pkill -f "uvicorn main:app" 2>/dev/null || true
pkill -f "demo_data.py live" 2>/dev/null || true
(cd backend && nohup .venv/bin/python -m uvicorn main:app --host 127.0.0.1 --port 8000 > ../server.log 2>&1 &)
for _ in $(seq 30); do curl -sf http://localhost:8000/health >/dev/null && break; sleep 0.5; done
nohup backend/.venv/bin/python demo_data.py live > live.log 2>&1 &
open http://localhost:8000/ http://localhost:8000/dashboard.html
[ -d /Applications/MySQLWorkbench.app ] && open -a MySQLWorkbench --args --query "root@127.0.0.1:3306" --open "$PWD/db/report_queries.sql"
echo "Running: site http://localhost:8000 · dashboard /dashboard.html · logs server.log, live.log. Stop: pkill -f uvicorn; pkill -f demo_data"
