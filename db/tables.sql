-- Every table of the mess database, with its rows. One result tab per table.
-- Workbench: click the lightning bolt (Execute all). Command line: source .../db/tables.sql
-- Small lookup tables show every row; big activity tables show the newest 20.
USE mess;
CALL sp_demo_week();  -- make sure today has data

-- Master / lookup tables
SELECT * FROM messes;
SELECT * FROM meal_slots;
SELECT * FROM programmes;
SELECT * FROM hostels;
SELECT * FROM ngos;
SELECT * FROM menu_items;
SELECT * FROM mess_costs;

-- Students
SELECT * FROM students ORDER BY id LIMIT 20;

-- Day-to-day records (newest first)
SELECT * FROM bookings     ORDER BY id DESC LIMIT 20;
SELECT * FROM attendance   ORDER BY id DESC LIMIT 20;
SELECT * FROM ratings      ORDER BY id DESC LIMIT 20;
SELECT * FROM pauses       ORDER BY id DESC LIMIT 20;
SELECT * FROM donations    ORDER BY id DESC LIMIT 20;
SELECT * FROM logins       ORDER BY id DESC LIMIT 20;
SELECT * FROM activity_log ORDER BY id DESC LIMIT 20;

-- How many rows each table holds
SELECT 'messes' AS `table`, COUNT(*) AS `rows` FROM messes
UNION ALL SELECT 'meal_slots',   COUNT(*) FROM meal_slots
UNION ALL SELECT 'programmes',   COUNT(*) FROM programmes
UNION ALL SELECT 'hostels',      COUNT(*) FROM hostels
UNION ALL SELECT 'ngos',         COUNT(*) FROM ngos
UNION ALL SELECT 'menu_items',   COUNT(*) FROM menu_items
UNION ALL SELECT 'mess_costs',   COUNT(*) FROM mess_costs
UNION ALL SELECT 'students',     COUNT(*) FROM students
UNION ALL SELECT 'bookings',     COUNT(*) FROM bookings
UNION ALL SELECT 'attendance',   COUNT(*) FROM attendance
UNION ALL SELECT 'ratings',      COUNT(*) FROM ratings
UNION ALL SELECT 'pauses',       COUNT(*) FROM pauses
UNION ALL SELECT 'donations',    COUNT(*) FROM donations
UNION ALL SELECT 'logins',       COUNT(*) FROM logins
UNION ALL SELECT 'activity_log', COUNT(*) FROM activity_log;
