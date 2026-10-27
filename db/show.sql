-- One-line demo for the MySQL 8.0 Command Line Client:
--   source C:/Users/<you>/Documents/mess/db/show.sql
-- Shows the whole database: structure, data, and the rules it enforces.

USE mess;
CALL sp_demo_week();  -- fill today's meals so "today" queries aren't empty

SELECT '== TABLES ==' AS '';
SHOW FULL TABLES WHERE Table_type = 'BASE TABLE';

SELECT '== ROWS PER TABLE ==' AS '';
SELECT table_name AS `table`, table_rows AS approx_rows
FROM information_schema.tables
WHERE table_schema = 'mess' AND table_type = 'BASE TABLE' ORDER BY table_name;

SELECT '== VIEWS ==' AS '';
SHOW FULL TABLES WHERE Table_type = 'VIEW';

SELECT '== TRIGGERS ==' AS '';
SELECT trigger_name, action_timing, event_manipulation, event_object_table
FROM information_schema.triggers WHERE trigger_schema = 'mess';

SELECT '== PROCEDURES AND FUNCTIONS ==' AS '';
SELECT routine_name, routine_type FROM information_schema.routines WHERE routine_schema = 'mess';

SELECT '== STUDENTS TABLE ==' AS '';
DESCRIBE students;

SELECT '== STUDENT ROSTER (first 10) ==' AS '';
SELECT reg_no, full_name, programme, hostel, meals_eaten FROM v_student_directory LIMIT 10;

SELECT '== TODAY: HOW MUCH EACH MESS COOKS ==' AS '';
SELECT mess, meal, booked, cook_for FROM v_daily_forecast WHERE meal_date = CURDATE() ORDER BY slot_id, mess_id;

SELECT '== FOOD DONATED TO NGOs ==' AS '';
SELECT * FROM v_ngo_totals;

SELECT '== LIVE ACTIVITY (written by triggers) ==' AS '';
SELECT id, at, event, detail FROM activity_log ORDER BY id DESC LIMIT 10;

SELECT '== THE DATABASE REFUSES BAD DATA: the next two lines must show ERROR ==' AS '';
-- trigger: male student in a girls' hostel -> ERROR 1644
INSERT INTO students (reg_no, full_name, gender, phone, email, programme_id, year_of_study, hostel_id, room_no, joined_on)
VALUES ('230100998', 'Wrong Hostel', 'M', '9876501235', 'w@muj.manipal.edu', 1, 1, 13, '101', '2023-07-24');
-- CHECK constraint: 5-digit phone -> ERROR 3819
INSERT INTO students (reg_no, full_name, gender, phone, email, programme_id, year_of_study, hostel_id, room_no, joined_on)
VALUES ('230100996', 'Bad Phone', 'M', '12345', 'p@muj.manipal.edu', 1, 1, 1, '101', '2023-07-24');
