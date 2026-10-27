-- MUJ Mess: the WHOLE database in one script (made by `python setup.py bundle`; don't edit by hand).
-- MySQL Workbench: File -> Open SQL Script -> this file -> click the lightning bolt (Execute all).
-- It drops and rebuilds the `mess` database: tables, triggers, procedures, views, the roster and a demo week.

-- =====================================================================
-- MUJ Mess — one annual fee, eat at either mess, book every meal.
-- MySQL 8.0+. Run with:  python setup.py local   (or: setup.bat on Windows)
--
-- Tables (3NF):  programmes, hostels, students, logins, messes, meal_slots, mess_costs, menu_items,
--                bookings, pauses, attendance, ratings, ngos, donations, activity_log
-- Triggers:      check every student's hostel/year; log every enrolment, login, booking,
--                serve and donation; block bookings while paused
-- Function:      fn_short_name ('Aarav Sharma' -> 'Aarav S.') for the public feed
-- Views:         v_student_directory, v_live_bookings, v_daily_forecast, v_hostel_split,
--                v_meal_summary, v_mess_earnings, v_mess_ratings, v_ngo_totals
-- Event:         ev_close_meals closes every finished meal automatically (every 10 minutes)
-- Procedures:    sp_check_student (used by triggers), sp_pause_mess, sp_resume_mess,
--                sp_close_meal (transactions), sp_demo_day / sp_demo_week (demo data)
-- =====================================================================
DROP DATABASE IF EXISTS mess;
CREATE DATABASE mess CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE mess;

-- ---------- reference data ----------

CREATE TABLE messes (
  id   TINYINT UNSIGNED PRIMARY KEY,
  name VARCHAR(40) NOT NULL UNIQUE
);

CREATE TABLE meal_slots (
  id         TINYINT UNSIGNED PRIMARY KEY,
  code       VARCHAR(16) NOT NULL UNIQUE,
  name       VARCHAR(32) NOT NULL,
  starts_at  TIME NOT NULL,
  ends_at    TIME NOT NULL,
  -- What the university pays a mess for each plate it actually serves at this meal (out of the annual fee).
  paid_per_plate  DECIMAL(6,2) NOT NULL,
  CONSTRAINT chk_slot_time CHECK (ends_at > starts_at),
  CONSTRAINT chk_paid CHECK (paid_per_plate > 0)
);

-- What one plate costs each mess to cook, per meal (ingredients, gas, staff share).
-- Every plate cooked costs this, eaten or not, so over-cooking eats into profit.
CREATE TABLE mess_costs (
  mess_id         TINYINT UNSIGNED NOT NULL,
  slot_id         TINYINT UNSIGNED NOT NULL,
  cost_per_plate  DECIMAL(6,2) NOT NULL,
  PRIMARY KEY (mess_id, slot_id),
  FOREIGN KEY (mess_id) REFERENCES messes(id),
  FOREIGN KEY (slot_id) REFERENCES meal_slots(id),
  CONSTRAINT chk_cost CHECK (cost_per_plate > 0)
);

-- One row per dish. The same weekly menu is used every day in this demo.
CREATE TABLE menu_items (
  id       INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  mess_id  TINYINT UNSIGNED NOT NULL,
  slot_id  TINYINT UNSIGNED NOT NULL,
  dish     VARCHAR(80) NOT NULL,
  UNIQUE KEY uq_dish (mess_id, slot_id, dish),
  FOREIGN KEY (mess_id) REFERENCES messes(id),
  FOREIGN KEY (slot_id) REFERENCES meal_slots(id)
);

CREATE TABLE ngos (
  id             SMALLINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  name           VARCHAR(80) NOT NULL UNIQUE,
  area           VARCHAR(80) NOT NULL,
  contact_phone  CHAR(10) NOT NULL
);

-- ---------- people: the university's student roster ----------

CREATE TABLE programmes (
  id      TINYINT UNSIGNED PRIMARY KEY,
  code    VARCHAR(12) NOT NULL UNIQUE,
  name    VARCHAR(80) NOT NULL,
  school  VARCHAR(80) NOT NULL,
  years   TINYINT UNSIGNED NOT NULL,
  CONSTRAINT chk_prog_years CHECK (years BETWEEN 1 AND 5)
);

CREATE TABLE hostels (
  id          TINYINT UNSIGNED PRIMARY KEY,
  name        VARCHAR(40) NOT NULL UNIQUE,
  for_gender  ENUM('M','F') NOT NULL,
  rooms       SMALLINT UNSIGNED NOT NULL
);

-- Only students on this roster can log in. Phone is how they log in (SMS OTP).
-- Every student lives in a hostel (B1-B12 for boys, G1-G10 for girls); there are no day scholars.
CREATE TABLE students (
  id             INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  reg_no         CHAR(9) NOT NULL UNIQUE,
  full_name      VARCHAR(80) NOT NULL,
  gender         ENUM('M','F') NOT NULL,
  phone          CHAR(10) NOT NULL UNIQUE,
  email          VARCHAR(120) NOT NULL UNIQUE,
  programme_id   TINYINT UNSIGNED NOT NULL,
  year_of_study  TINYINT UNSIGNED NOT NULL,
  hostel_id      TINYINT UNSIGNED NOT NULL,
  room_no        VARCHAR(6) NOT NULL,
  status         ENUM('active','graduated','left') NOT NULL DEFAULT 'active',
  joined_on      DATE NOT NULL,
  created_at     DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_student_hostel (hostel_id),
  INDEX idx_student_programme (programme_id, year_of_study),
  FOREIGN KEY (programme_id) REFERENCES programmes(id),
  FOREIGN KEY (hostel_id)    REFERENCES hostels(id),
  CONSTRAINT chk_phone CHECK (REGEXP_LIKE(phone, '^[6-9][0-9]{9}$')),
  CONSTRAINT chk_reg_no CHECK (REGEXP_LIKE(reg_no, '^[0-9]{9}$')),
  CONSTRAINT chk_room CHECK (REGEXP_LIKE(room_no, '^[0-9]{3,4}$'))
);

-- One row per successful login. The SMS code itself is checked by Firebase;
-- firebase_uid is Firebase's id for that phone number.
-- (No last_login_at on students: it would repeat what this table already says.)
CREATE TABLE logins (
  id            BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  student_id    INT UNSIGNED NOT NULL,
  firebase_uid  VARCHAR(128) NOT NULL,
  at            DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_login_student (student_id, at),
  FOREIGN KEY (student_id) REFERENCES students(id)
);

-- ---------- the core: one choice per student per day per meal ----------
-- booked  = eating at mess_id          (counted)
-- skipped = not eating this meal       (not counted)
-- paused  = away from campus           (not counted, set by sp_pause_mess)
CREATE TABLE bookings (
  id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  student_id  INT UNSIGNED NOT NULL,
  meal_date   DATE NOT NULL,
  slot_id     TINYINT UNSIGNED NOT NULL,
  mess_id     TINYINT UNSIGNED NULL,
  status      ENUM('booked','skipped','paused') NOT NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_one_choice (student_id, meal_date, slot_id),
  INDEX idx_forecast (meal_date, slot_id, mess_id, status),
  FOREIGN KEY (student_id) REFERENCES students(id),
  FOREIGN KEY (slot_id)    REFERENCES meal_slots(id),
  FOREIGN KEY (mess_id)    REFERENCES messes(id),
  CONSTRAINT chk_status_mess CHECK ((status = 'booked') = (mess_id IS NOT NULL))
);

-- A student away from campus. ended_on is set when they come back early.
CREATE TABLE pauses (
  id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  student_id  INT UNSIGNED NOT NULL,
  from_date   DATE NOT NULL,
  to_date     DATE NOT NULL,
  ended_on    DATE NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX idx_pause_student (student_id, from_date, to_date),
  FOREIGN KEY (student_id) REFERENCES students(id),
  CONSTRAINT chk_pause_range CHECK (to_date >= from_date)
);

-- Who actually ate. Written by the face-recognition terminal at each mess counter (one row per face match).
-- A student with no booking at this mess is a walk-in (served from the 30% buffer).
CREATE TABLE attendance (
  id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  student_id  INT UNSIGNED NOT NULL,
  meal_date   DATE NOT NULL,
  slot_id     TINYINT UNSIGNED NOT NULL,
  mess_id     TINYINT UNSIGNED NOT NULL,
  served_at   DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_served_once (student_id, meal_date, slot_id),
  INDEX idx_att_meal (meal_date, slot_id, mess_id),
  FOREIGN KEY (student_id) REFERENCES students(id),
  FOREIGN KEY (slot_id)    REFERENCES meal_slots(id),
  FOREIGN KEY (mess_id)    REFERENCES messes(id)
);

-- A student's 1-5 star rating of a meal they ate. Only possible after eating it (trigger trg_rating_check_*).
CREATE TABLE ratings (
  id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  student_id  INT UNSIGNED NOT NULL,
  meal_date   DATE NOT NULL,
  slot_id     TINYINT UNSIGNED NOT NULL,
  mess_id     TINYINT UNSIGNED NOT NULL,
  stars       TINYINT UNSIGNED NOT NULL,
  comment     VARCHAR(200) NULL,
  rated_at    DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_one_rating (student_id, meal_date, slot_id),
  INDEX idx_rating_mess (mess_id, slot_id, meal_date),
  FOREIGN KEY (student_id) REFERENCES students(id),
  FOREIGN KEY (slot_id)    REFERENCES meal_slots(id),
  FOREIGN KEY (mess_id)    REFERENCES messes(id),
  CONSTRAINT chk_stars CHECK (stars BETWEEN 1 AND 5)
);

-- Food given away after a meal closes. One row per mess per meal.
CREATE TABLE donations (
  id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  meal_date   DATE NOT NULL,
  slot_id     TINYINT UNSIGNED NOT NULL,
  mess_id     TINYINT UNSIGNED NOT NULL,
  ngo_id      SMALLINT UNSIGNED NOT NULL,
  portions    INT UNSIGNED NOT NULL,
  created_at  DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_one_donation (meal_date, slot_id, mess_id),
  FOREIGN KEY (slot_id) REFERENCES meal_slots(id),
  FOREIGN KEY (mess_id) REFERENCES messes(id),
  FOREIGN KEY (ngo_id)  REFERENCES ngos(id)
);

-- Filled only by triggers — the live feed to watch in Workbench.
CREATE TABLE activity_log (
  id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  at          DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  event       VARCHAR(20) NOT NULL,
  student_id  INT UNSIGNED NULL,
  detail      VARCHAR(200) NOT NULL,
  INDEX idx_log_at (at)
);

-- =====================================================================
-- TRIGGERS
-- =====================================================================
DELIMITER $$

-- 'Aarav Sharma' -> 'Aarav S.' so the public live feed never shows full names or phones.
CREATE FUNCTION fn_short_name(p_name VARCHAR(80)) RETURNS VARCHAR(80)
DETERMINISTIC NO SQL
BEGIN
  DECLARE first_part VARCHAR(80) DEFAULT SUBSTRING_INDEX(TRIM(p_name), ' ', 1);
  DECLARE last_part VARCHAR(80) DEFAULT SUBSTRING_INDEX(TRIM(p_name), ' ', -1);
  RETURN IF(first_part = last_part, first_part, CONCAT(first_part, ' ', LEFT(last_part, 1), '.'));
END$$

-- Rules a CHECK constraint can't express (they need other tables):
-- the hostel must match the student's gender, and the year must exist in the programme.
CREATE PROCEDURE sp_check_student(IN p_gender CHAR(1), IN p_hostel TINYINT UNSIGNED,
                                  IN p_programme TINYINT UNSIGNED, IN p_year TINYINT UNSIGNED)
BEGIN
  IF (SELECT for_gender FROM hostels WHERE id = p_hostel) <> p_gender THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This hostel is for the other gender';
  END IF;
  IF p_year < 1 OR p_year > (SELECT years FROM programmes WHERE id = p_programme) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Year of study is outside this programme';
  END IF;
END$$

CREATE TRIGGER trg_student_check_ins BEFORE INSERT ON students FOR EACH ROW
BEGIN
  CALL sp_check_student(NEW.gender, NEW.hostel_id, NEW.programme_id, NEW.year_of_study);
END$$

CREATE TRIGGER trg_student_check_upd BEFORE UPDATE ON students FOR EACH ROW
BEGIN
  CALL sp_check_student(NEW.gender, NEW.hostel_id, NEW.programme_id, NEW.year_of_study);
END$$

CREATE TRIGGER trg_student_enrol AFTER INSERT ON students FOR EACH ROW
BEGIN
  INSERT INTO activity_log (event, student_id, detail)
  SELECT 'ENROL', NEW.id, CONCAT(fn_short_name(NEW.full_name), ' · ', p.code, ' year ', NEW.year_of_study,
                                 ' · ', h.name, ' room ', NEW.room_no)
  FROM programmes p JOIN hostels h ON h.id = NEW.hostel_id
  WHERE p.id = NEW.programme_id;
END$$

CREATE TRIGGER trg_login_log AFTER INSERT ON logins FOR EACH ROW
BEGIN
  INSERT INTO activity_log (event, student_id, detail)
  SELECT 'LOGIN', NEW.student_id, CONCAT(fn_short_name(s.full_name), ' logged in')
  FROM students s WHERE s.id = NEW.student_id;
END$$

-- Business rule enforced inside the database: no booking while the mess is paused.
CREATE TRIGGER trg_booking_paused_ins BEFORE INSERT ON bookings FOR EACH ROW
BEGIN
  IF NEW.status = 'booked' AND EXISTS (
       SELECT 1 FROM pauses p
       WHERE p.student_id = NEW.student_id
         AND NEW.meal_date BETWEEN p.from_date AND p.to_date
         AND (p.ended_on IS NULL OR NEW.meal_date < p.ended_on)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Your mess is paused for this date';
  END IF;
END$$

CREATE TRIGGER trg_booking_paused_upd BEFORE UPDATE ON bookings FOR EACH ROW
BEGIN
  IF NEW.status = 'booked' AND EXISTS (
       SELECT 1 FROM pauses p
       WHERE p.student_id = NEW.student_id
         AND NEW.meal_date BETWEEN p.from_date AND p.to_date
         AND (p.ended_on IS NULL OR NEW.meal_date < p.ended_on)) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Your mess is paused for this date';
  END IF;
END$$

CREATE TRIGGER trg_booking_log_ins AFTER INSERT ON bookings FOR EACH ROW
BEGIN
  INSERT INTO activity_log (event, student_id, detail)
  SELECT UPPER(IF(NEW.status = 'booked', 'book', NEW.status)), NEW.student_id,
         CONCAT(fn_short_name(s.full_name), ' · ', ms.name, ' · ', NEW.meal_date, ' · ', COALESCE(m.name, NEW.status))
  FROM students s
  JOIN meal_slots ms ON ms.id = NEW.slot_id
  LEFT JOIN messes m ON m.id = NEW.mess_id
  WHERE s.id = NEW.student_id;
END$$

CREATE TRIGGER trg_booking_log_upd AFTER UPDATE ON bookings FOR EACH ROW
BEGIN
  IF NOT (OLD.mess_id <=> NEW.mess_id) OR OLD.status <> NEW.status THEN
    INSERT INTO activity_log (event, student_id, detail)
    SELECT IF(NEW.status = 'paused', 'PAUSED', 'CHANGE'), NEW.student_id,
           CONCAT(fn_short_name(s.full_name), ' · ', ms.name, ' · ', NEW.meal_date, ' · ',
                  COALESCE(o.name, OLD.status), ' → ', COALESCE(n.name, NEW.status))
    FROM students s
    JOIN meal_slots ms ON ms.id = NEW.slot_id
    LEFT JOIN messes o ON o.id = OLD.mess_id
    LEFT JOIN messes n ON n.id = NEW.mess_id
    WHERE s.id = NEW.student_id;
  END IF;
END$$

CREATE TRIGGER trg_pause_log AFTER INSERT ON pauses FOR EACH ROW
BEGIN
  INSERT INTO activity_log (event, student_id, detail)
  SELECT 'PAUSE', NEW.student_id, CONCAT(fn_short_name(s.full_name), ' away ', NEW.from_date, ' to ', NEW.to_date)
  FROM students s WHERE s.id = NEW.student_id;
END$$

CREATE TRIGGER trg_resume_log AFTER UPDATE ON pauses FOR EACH ROW
BEGIN
  IF OLD.ended_on IS NULL AND NEW.ended_on IS NOT NULL THEN
    INSERT INTO activity_log (event, student_id, detail)
    SELECT 'RESUME', NEW.student_id, CONCAT(fn_short_name(s.full_name), ' back from ', NEW.ended_on)
    FROM students s WHERE s.id = NEW.student_id;
  END IF;
END$$

CREATE TRIGGER trg_attendance_log AFTER INSERT ON attendance FOR EACH ROW
BEGIN
  INSERT INTO activity_log (event, student_id, detail)
  SELECT 'SERVED', NEW.student_id,
         CONCAT(fn_short_name(s.full_name), ' · ', ms.name, ' · ', m.name,
                IF(EXISTS (SELECT 1 FROM bookings b
                           WHERE b.student_id = NEW.student_id AND b.meal_date = NEW.meal_date
                             AND b.slot_id = NEW.slot_id AND b.mess_id = NEW.mess_id
                             AND b.status = 'booked'), '', ' · walk-in'))
  FROM students s
  JOIN meal_slots ms ON ms.id = NEW.slot_id
  JOIN messes m ON m.id = NEW.mess_id
  WHERE s.id = NEW.student_id;
END$$

-- A rating is accepted only for a meal the student was actually served, at that mess.
CREATE TRIGGER trg_rating_check_ins BEFORE INSERT ON ratings FOR EACH ROW
BEGIN
  IF NOT EXISTS (SELECT 1 FROM attendance a WHERE a.student_id = NEW.student_id AND a.meal_date = NEW.meal_date
                   AND a.slot_id = NEW.slot_id AND a.mess_id = NEW.mess_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You can only rate a meal you have eaten';
  END IF;
END$$

CREATE TRIGGER trg_rating_check_upd BEFORE UPDATE ON ratings FOR EACH ROW
BEGIN
  IF NOT EXISTS (SELECT 1 FROM attendance a WHERE a.student_id = NEW.student_id AND a.meal_date = NEW.meal_date
                   AND a.slot_id = NEW.slot_id AND a.mess_id = NEW.mess_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'You can only rate a meal you have eaten';
  END IF;
END$$

CREATE TRIGGER trg_rating_log AFTER INSERT ON ratings FOR EACH ROW
BEGIN
  INSERT INTO activity_log (event, student_id, detail)
  SELECT 'RATED', NEW.student_id, CONCAT(fn_short_name(s.full_name), ' · ', ms.name, ' · ', m.name, ' · ', REPEAT('★', NEW.stars))
  FROM students s, meal_slots ms, messes m
  WHERE s.id = NEW.student_id AND ms.id = NEW.slot_id AND m.id = NEW.mess_id;
END$$

CREATE TRIGGER trg_donation_log AFTER INSERT ON donations FOR EACH ROW
BEGIN
  INSERT INTO activity_log (event, detail)
  SELECT 'DONATE', CONCAT(NEW.portions, ' portions · ', m.name, ' ', ms.name, ' ', NEW.meal_date, ' → ', n.name)
  FROM messes m, meal_slots ms, ngos n
  WHERE m.id = NEW.mess_id AND ms.id = NEW.slot_id AND n.id = NEW.ngo_id;
END$$

-- =====================================================================
-- STORED PROCEDURES (each one is a single transaction)
-- =====================================================================

-- Going home: record the pause and release every future meal in the range.
CREATE PROCEDURE sp_pause_mess(IN p_student INT UNSIGNED, IN p_from DATE, IN p_to DATE)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
    INSERT INTO pauses (student_id, from_date, to_date) VALUES (p_student, p_from, p_to);
    -- Meals already chosen in that range become 'paused' (not counted).
    UPDATE bookings SET status = 'paused', mess_id = NULL
    WHERE student_id = p_student AND meal_date BETWEEN p_from AND p_to;
  COMMIT;
END$$

-- Back early: end every pause that is still running or still in the future.
CREATE PROCEDURE sp_resume_mess(IN p_student INT UNSIGNED, IN p_today DATE)
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
  START TRANSACTION;
    UPDATE pauses SET ended_on = p_today
    WHERE student_id = p_student AND ended_on IS NULL AND to_date >= p_today;
    -- Released meals from today on go back to 'skipped' so the student can re-book.
    UPDATE bookings SET status = 'skipped'
    WHERE student_id = p_student AND status = 'paused' AND meal_date >= p_today;
  COMMIT;
END$$

-- After a meal: give the leftover to the NGO that has received the least so far.
-- Leftover to donate = unused buffer + 50% of the no-shows' portions (see v_meal_summary).
CREATE PROCEDURE sp_close_meal(IN p_date DATE, IN p_slot TINYINT UNSIGNED)
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE v_mess TINYINT UNSIGNED;
  DECLARE v_portions INT;
  DECLARE v_ngo SMALLINT UNSIGNED;
  DECLARE cur CURSOR FOR
    SELECT mess_id, donate FROM v_meal_summary
    WHERE meal_date = p_date AND slot_id = p_slot AND donate > 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

  START TRANSACTION;
    DELETE FROM donations WHERE meal_date = p_date AND slot_id = p_slot;
    OPEN cur;
    read_loop: LOOP
      FETCH cur INTO v_mess, v_portions;
      IF done THEN LEAVE read_loop; END IF;
      SELECT n.id INTO v_ngo
      FROM ngos n LEFT JOIN donations d ON d.ngo_id = n.id
      GROUP BY n.id ORDER BY COALESCE(SUM(d.portions), 0), n.id LIMIT 1;
      INSERT INTO donations (meal_date, slot_id, mess_id, ngo_id, portions)
      VALUES (p_date, p_slot, v_mess, v_ngo, v_portions);
    END LOOP;
    CLOSE cur;
  COMMIT;
END$$

-- Close every meal of today (India time) whose serving window has ended and that isn't closed yet.
-- Called every 10 minutes by the event ev_close_meals, so no one has to press a button.
CREATE PROCEDURE sp_close_finished_meals()
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE v_slot TINYINT UNSIGNED;
  DECLARE v_now DATETIME DEFAULT UTC_TIMESTAMP() + INTERVAL 330 MINUTE;  -- India time, whatever the server's zone
  DECLARE cur CURSOR FOR
    SELECT ms.id FROM meal_slots ms
    WHERE ms.ends_at <= TIME(v_now)
      AND NOT EXISTS (SELECT 1 FROM donations d WHERE d.meal_date = DATE(v_now) AND d.slot_id = ms.id);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  OPEN cur;
  close_loop: LOOP
    FETCH cur INTO v_slot;
    IF done THEN LEAVE close_loop; END IF;
    CALL sp_close_meal(DATE(v_now), v_slot);
  END LOOP;
  CLOSE cur;
END$$

CREATE EVENT ev_close_meals ON SCHEDULE EVERY 10 MINUTE
COMMENT 'Closes finished meals and hands leftovers to NGOs'
DO CALL sp_close_finished_meals()$$

-- Demo data made by the database itself (no Python needed): one CALL fills a day.
-- About 70% of students not on pause book each meal; some skip. With p_serve, about 85% of
-- bookers are served and every meal is closed (donations). A day that already has bookings is left alone.
CREATE PROCEDURE sp_demo_day(IN p_date DATE, IN p_serve BOOLEAN)
BEGIN
  IF NOT EXISTS (SELECT 1 FROM bookings WHERE meal_date = p_date) THEN
    -- NO_MERGE keeps each RAND() to one value per row, so mess and status always agree.
    INSERT INTO bookings (student_id, meal_date, slot_id, mess_id, status)
    SELECT /*+ NO_MERGE(r) */ r.sid, p_date, r.slot,
           IF(r.a < r.skip, NULL, IF(r.b < r.dove, 1, 2)),
           IF(r.a < r.skip, 'skipped', 'booked')
    FROM (
      SELECT s.id AS sid, ms.id AS slot, RAND() AS a, RAND() AS b,
             ELT(ms.id, 0.12, 0.08, 0.30, 0.10) AS skip,     -- share skipping each meal
             ELT(ms.id, 0.55, 0.40, 0.62, 0.47) AS dove      -- share of eaters picking BluDove
      FROM students s CROSS JOIN meal_slots ms
      WHERE s.status = 'active' AND RAND() < 0.7
        AND NOT EXISTS (SELECT 1 FROM pauses p WHERE p.student_id = s.id
                          AND p_date BETWEEN p.from_date AND p.to_date
                          AND (p.ended_on IS NULL OR p_date < p.ended_on))
    ) r;
    IF p_serve THEN
      INSERT INTO attendance (student_id, meal_date, slot_id, mess_id)
      SELECT student_id, meal_date, slot_id, mess_id FROM bookings
      WHERE meal_date = p_date AND status = 'booked' AND RAND() < 0.85;
      INSERT INTO ratings (student_id, meal_date, slot_id, mess_id, stars)
      SELECT student_id, meal_date, slot_id, mess_id,
             LEAST(5, GREATEST(1, ROUND(ELT((mess_id - 1) * 4 + slot_id, 4.1, 3.7, 3.4, 4.3, 3.6, 4.4, 4.0, 3.5) + (RAND() - 0.5) * 2.4)))
      FROM attendance WHERE meal_date = p_date AND RAND() < 0.3;
      CALL sp_close_meal(p_date, 1);
      CALL sp_close_meal(p_date, 2);
      CALL sp_close_meal(p_date, 3);
      CALL sp_close_meal(p_date, 4);
    END IF;
  END IF;
END$$

-- A full demo week: the last 6 days served and closed, plus today's bookings. CALL sp_demo_week();
CREATE PROCEDURE sp_demo_week()
BEGIN
  DECLARE d INT DEFAULT 6;
  WHILE d > 0 DO
    CALL sp_demo_day(CURDATE() - INTERVAL d DAY, TRUE);
    SET d = d - 1;
  END WHILE;
  CALL sp_demo_day(CURDATE(), FALSE);
END$$

DELIMITER ;

-- =====================================================================
-- VIEWS
-- =====================================================================

-- Every student's choice, readable, newest first.
CREATE VIEW v_live_bookings AS
SELECT b.updated_at AS at, s.reg_no, s.full_name, b.meal_date, ms.name AS meal,
       COALESCE(m.name, '—') AS mess, b.status
FROM bookings b
JOIN students s    ON s.id = b.student_id
JOIN meal_slots ms ON ms.id = b.slot_id
LEFT JOIN messes m ON m.id = b.mess_id
ORDER BY b.updated_at DESC;

-- The roster, readable: who, what they study, where they live, and how they use the mess.
CREATE VIEW v_student_directory AS
SELECT s.id, s.reg_no, s.full_name, s.gender, s.phone, s.email,
       p.code AS programme, p.school, s.year_of_study,
       h.name AS hostel, s.room_no, s.status,
       (SELECT MAX(l.at) FROM logins l WHERE l.student_id = s.id)              AS last_login,
       (SELECT COUNT(*) FROM bookings b WHERE b.student_id = s.id
          AND b.status = 'booked')                                            AS meals_booked,
       (SELECT COUNT(*) FROM attendance a WHERE a.student_id = s.id)          AS meals_eaten
FROM students s
JOIN programmes p    ON p.id = s.programme_id
JOIN hostels h       ON h.id = s.hostel_id;

-- How much each mess cooks: booked heads + 30% buffer. Skipped and paused are not counted.
CREATE VIEW v_daily_forecast AS
SELECT b.meal_date, m.id AS mess_id, m.name AS mess, ms.id AS slot_id, ms.name AS meal,
       COUNT(*)                                     AS booked,
       CAST(CEIL(COUNT(*) * 1.30) AS SIGNED)        AS cook_for
FROM bookings b
JOIN messes m      ON m.id = b.mess_id
JOIN meal_slots ms ON ms.id = b.slot_id
WHERE b.status = 'booked'
GROUP BY b.meal_date, m.id, m.name, ms.id, ms.name;

-- Which hostel eats where: booked plates per hostel, per mess, per meal.
CREATE VIEW v_hostel_split AS
SELECT b.meal_date, ms.id AS slot_id, ms.name AS meal,
       h.id AS hostel_id, h.name AS hostel,
       m.id AS mess_id, m.name AS mess, COUNT(*) AS booked
FROM bookings b
JOIN students s      ON s.id = b.student_id
JOIN messes m        ON m.id = b.mess_id
JOIN meal_slots ms   ON ms.id = b.slot_id
JOIN hostels h       ON h.id = s.hostel_id
WHERE b.status = 'booked'
GROUP BY b.meal_date, ms.id, ms.name, h.id, h.name, m.id, m.name;

-- After the meal: what was cooked, who came, and what goes to NGOs.
--   no_shows  = booked here but not served
--   walk_ins  = served here without a booking here (eaten from the buffer)
--   buffer_left = buffer not eaten by walk-ins
--   donate    = buffer_left + 50% of no-show portions (never more than what is left)
CREATE VIEW v_meal_summary AS
SELECT k.meal_date, k.mess_id, m.name AS mess, k.slot_id, ms.name AS meal,
       CAST(COALESCE(f.booked, 0) AS SIGNED)                         AS booked,
       CAST(COALESCE(f.cook_for, 0) AS SIGNED)                       AS cooked,
       CAST(COALESCE(a.served, 0) AS SIGNED)                         AS served,
       CAST(COALESCE(f.booked, 0) - COALESCE(a.served_booked, 0) AS SIGNED) AS no_shows,
       CAST(COALESCE(a.served, 0) - COALESCE(a.served_booked, 0) AS SIGNED) AS walk_ins,
       CAST(GREATEST(COALESCE(f.cook_for, 0) - COALESCE(f.booked, 0)
                - (COALESCE(a.served, 0) - COALESCE(a.served_booked, 0)), 0) AS SIGNED) AS buffer_left,
       CAST(LEAST(
         GREATEST(COALESCE(f.cook_for, 0) - COALESCE(a.served, 0), 0),
         GREATEST(COALESCE(f.cook_for, 0) - COALESCE(f.booked, 0)
                  - (COALESCE(a.served, 0) - COALESCE(a.served_booked, 0)), 0)
         + FLOOR((COALESCE(f.booked, 0) - COALESCE(a.served_booked, 0)) * 0.5)
       ) AS SIGNED)                                                  AS donate
FROM (
  SELECT meal_date, mess_id, slot_id FROM bookings WHERE status = 'booked'
  UNION
  SELECT meal_date, mess_id, slot_id FROM attendance
) k
JOIN messes m      ON m.id = k.mess_id
JOIN meal_slots ms ON ms.id = k.slot_id
LEFT JOIN v_daily_forecast f
       ON f.meal_date = k.meal_date AND f.mess_id = k.mess_id AND f.slot_id = k.slot_id
LEFT JOIN (
  SELECT att.meal_date, att.mess_id, att.slot_id,
         COUNT(*) AS served,
         SUM(EXISTS (SELECT 1 FROM bookings b
                     WHERE b.student_id = att.student_id AND b.meal_date = att.meal_date
                       AND b.slot_id = att.slot_id AND b.mess_id = att.mess_id
                       AND b.status = 'booked')) AS served_booked
  FROM attendance att
  GROUP BY att.meal_date, att.mess_id, att.slot_id
) a ON a.meal_date = k.meal_date AND a.mess_id = k.mess_id AND a.slot_id = k.slot_id;

-- The business side, per mess per meal: the mess earns for plates SERVED and pays for plates COOKED.
--   revenue = served × paid_per_plate      food_cost = cooked × cost_per_plate
--   profit  = revenue − food_cost          wasted  = cooked − served − donated
CREATE VIEW v_mess_earnings AS
SELECT s.meal_date, s.mess_id, s.mess, s.slot_id, s.meal, ms.starts_at,
       s.booked, s.cooked, s.served, s.no_shows, s.walk_ins,
       COALESCE(d.portions, 0)                                         AS donated,
       GREATEST(s.cooked - s.served - COALESCE(d.portions, 0), 0)      AS wasted,
       CAST(s.served * ms.paid_per_plate AS DECIMAL(10,2))             AS revenue,
       CAST(s.cooked * c.cost_per_plate AS DECIMAL(10,2))              AS food_cost,
       CAST(s.served * ms.paid_per_plate - s.cooked * c.cost_per_plate AS DECIMAL(10,2)) AS profit
FROM v_meal_summary s
JOIN meal_slots ms  ON ms.id = s.slot_id
JOIN mess_costs c   ON c.mess_id = s.mess_id AND c.slot_id = s.slot_id
LEFT JOIN donations d ON d.meal_date = s.meal_date AND d.slot_id = s.slot_id AND d.mess_id = s.mess_id;

-- How each mess's meals are rated: average stars and number of ratings, per day and meal.
CREATE VIEW v_mess_ratings AS
SELECT r.meal_date, r.mess_id, m.name AS mess, r.slot_id, ms.name AS meal,
       ROUND(AVG(r.stars), 2) AS avg_stars, COUNT(*) AS ratings,
       SUM(r.stars <= 2) AS unhappy
FROM ratings r
JOIN messes m      ON m.id = r.mess_id
JOIN meal_slots ms ON ms.id = r.slot_id
GROUP BY r.meal_date, r.mess_id, m.name, r.slot_id, ms.name;

-- Total food each NGO has received.
CREATE VIEW v_ngo_totals AS
SELECT n.id, n.name, n.area, COUNT(d.id) AS deliveries, CAST(COALESCE(SUM(d.portions), 0) AS SIGNED) AS portions
FROM ngos n LEFT JOIN donations d ON d.ngo_id = n.id
GROUP BY n.id, n.name, n.area;


USE mess;

INSERT INTO messes (id, name) VALUES (1, 'BluDove'), (2, 'BluSpring');

-- paid_per_plate: what the university pays a mess per plate served (₹), the same for both messes.
INSERT INTO meal_slots (id, code, name, starts_at, ends_at, paid_per_plate) VALUES
  (1, 'breakfast', 'Breakfast', '07:30', '09:30', 60.00),
  (2, 'lunch',     'Lunch',     '12:30', '14:30', 85.00),
  (3, 'hitea',     'Hi-Tea',    '17:00', '18:00', 40.00),
  (4, 'dinner',    'Dinner',    '19:30', '21:30', 95.00);

-- What a plate costs each mess to cook (₹). Pizza night and pancakes cost more; dal-baati less.
INSERT INTO mess_costs (mess_id, slot_id, cost_per_plate) VALUES
  (1, 1, 31.00), (1, 2, 49.00), (1, 3, 18.00), (1, 4, 60.00),
  (2, 1, 37.00), (2, 2, 46.00), (2, 3, 23.00), (2, 4, 51.00);

INSERT INTO menu_items (mess_id, slot_id, dish) VALUES
  -- BluDove
  (1, 1, 'Aloo Paratha'), (1, 1, 'Curd'), (1, 1, 'Masala Chai'), (1, 1, 'Banana'),
  (1, 2, 'Rajma'), (1, 2, 'Jeera Rice'), (1, 2, 'Tawa Roti'), (1, 2, 'Boondi Raita'), (1, 2, 'Salad'),
  (1, 3, 'Samosa'), (1, 3, 'Green Chutney'), (1, 3, 'Masala Chai'),
  (1, 4, 'Farmhouse Pizza'), (1, 4, 'Veg Burger'), (1, 4, 'Garlic Bread'), (1, 4, 'Gulab Jamun'),
  -- BluSpring
  (2, 1, 'Berry Pancakes'), (2, 1, 'Boiled Eggs'), (2, 1, 'Bread Butter Jam'), (2, 1, 'Cold Coffee'),
  (2, 2, 'Chole'), (2, 2, 'Bhature'), (2, 2, 'Veg Pulao'), (2, 2, 'Lassi'),
  (2, 3, 'Pineapple Upside-down Cake'), (2, 3, 'Veg Sandwich'), (2, 3, 'Lemon Tea'),
  (2, 4, 'Dal Baati Churma'), (2, 4, 'Gatte ki Sabzi'), (2, 4, 'Chapati'), (2, 4, 'Kheer');

-- Sample NGOs near campus. Fictional names and numbers, for the demo only.
INSERT INTO ngos (name, area, contact_phone) VALUES
  ('Sahyog Food Shelf',       'Bagru',        '9000000001'),
  ('Ann Seva Night Shelter',  'Sanganer',     '9000000002'),
  ('Dahmi Community Kitchen', 'Dahmi Kalan',  '9000000003');

-- Programmes and hostels. Students themselves come from db/students.csv (loaded by setup.py).
INSERT INTO programmes (id, code, name, school, years) VALUES
  (1,  'BTECH-CSE', 'B.Tech Computer Science',         'School of Computing',           4),
  (2,  'BTECH-IT',  'B.Tech Information Technology',   'School of Computing',           4),
  (3,  'BTECH-CCE', 'B.Tech Computer & Communication', 'School of Computing',           4),
  (4,  'BTECH-ECE', 'B.Tech Electronics & Comm.',      'School of Electrical',          4),
  (5,  'BTECH-ME',  'B.Tech Mechanical',               'School of Mechanical',          4),
  (6,  'BTECH-CE',  'B.Tech Civil',                    'School of Civil',               4),
  (7,  'BCA',       'Bachelor of Computer Applications','School of Computing',          3),
  (8,  'BBA',       'Bachelor of Business Admin.',     'School of Business',            3),
  (9,  'BARCH',     'Bachelor of Architecture',        'School of Architecture',        5),
  (10, 'BDES',      'Bachelor of Design',              'School of Design',              4),
  (11, 'MBA',       'Master of Business Admin.',       'School of Business',            2),
  (12, 'MTECH',     'M.Tech',                          'School of Computing',           2);

-- Hostels: B1-B12 for boys, G1-G10 for girls.
INSERT INTO hostels (id, name, for_gender, rooms) VALUES
  (1, 'B1', 'M', 320),
  (2, 'B2', 'M', 340),
  (3, 'B3', 'M', 360),
  (4, 'B4', 'M', 300),
  (5, 'B5', 'M', 320),
  (6, 'B6', 'M', 340),
  (7, 'B7', 'M', 360),
  (8, 'B8', 'M', 300),
  (9, 'B9', 'M', 320),
  (10, 'B10', 'M', 340),
  (11, 'B11', 'M', 360),
  (12, 'B12', 'M', 300),
  (13, 'G1', 'F', 300),
  (14, 'G2', 'F', 320),
  (15, 'G3', 'F', 280),
  (16, 'G4', 'F', 300),
  (17, 'G5', 'F', 320),
  (18, 'G6', 'F', 280),
  (19, 'G7', 'F', 300),
  (20, 'G8', 'F', 320),
  (21, 'G9', 'F', 280),
  (22, 'G10', 'F', 300);


-- The student roster (from db/students.csv)
INSERT INTO students (reg_no, full_name, gender, phone, email, programme_id, year_of_study, hostel_id, room_no, joined_on) VALUES
('260600001', 'Anvi Das', 'F', '7000000001', 'anvi.260600001@muj.manipal.edu', 6, 1, 16, '927', '2026-07-30'),
('260100002', 'Ansh Nair', 'M', '7000000002', 'ansh.260100002@muj.manipal.edu', 1, 1, 2, '507', '2026-07-29'),
('240100003', 'Siya Malhotra', 'F', '7000000003', 'siya.240100003@muj.manipal.edu', 1, 3, 18, '625', '2024-07-31'),
('240400004', 'Yash Mehta', 'M', '7000000004', 'yash.240400004@muj.manipal.edu', 4, 3, 5, '810', '2024-07-24'),
('260300005', 'Aditi Goyal', 'F', '7000000005', 'aditi.260300005@muj.manipal.edu', 3, 1, 19, '932', '2026-07-18'),
('240200006', 'Mihir Rao', 'M', '7000000006', 'mihir.240200006@muj.manipal.edu', 2, 3, 7, '833', '2024-07-31'),
('260800007', 'Arnav Joshi', 'M', '7000000007', 'arnav.260800007@muj.manipal.edu', 8, 1, 12, '907', '2026-07-28'),
('260900008', 'Aryan Joshi', 'M', '7000000008', 'aryan.260900008@muj.manipal.edu', 9, 1, 11, '831', '2026-07-23'),
('240800009', 'Rohan Bose', 'M', '7000000009', 'rohan.240800009@muj.manipal.edu', 8, 3, 12, '826', '2024-07-28'),
('230100010', 'Nisha Sharma', 'F', '7000000010', 'nisha.230100010@muj.manipal.edu', 1, 4, 21, '824', '2023-07-21'),
('230400011', 'Siya Iyer', 'F', '7000000011', 'siya.230400011@muj.manipal.edu', 4, 4, 19, '903', '2023-07-24'),
('240700012', 'Anika Nair', 'F', '7000000012', 'anika.240700012@muj.manipal.edu', 7, 3, 17, '812', '2024-07-28'),
('230600013', 'Aryan Jain', 'M', '7000000013', 'aryan.230600013@muj.manipal.edu', 6, 4, 6, '213', '2023-07-28'),
('260100014', 'Aadhya Mehta', 'F', '7000000014', 'aadhya.260100014@muj.manipal.edu', 1, 1, 22, '416', '2026-07-18'),
('240700015', 'Rudra Tiwari', 'M', '7000000015', 'rudra.240700015@muj.manipal.edu', 7, 3, 6, '301', '2024-07-25'),
('260700016', 'Arnav Rao', 'M', '7000000016', 'arnav.260700016@muj.manipal.edu', 7, 1, 9, '431', '2026-07-19'),
('250100017', 'Lakshya Saxena', 'M', '7000000017', 'lakshya.250100017@muj.manipal.edu', 1, 2, 3, '533', '2025-07-28'),
('250800018', 'Ira Banerjee', 'F', '7000000018', 'ira.250800018@muj.manipal.edu', 8, 2, 13, '225', '2025-07-17'),
('261100019', 'Tanvi Bansal', 'F', '7000000019', 'tanvi.261100019@muj.manipal.edu', 11, 1, 13, '931', '2026-07-25'),
('231000020', 'Tanmay Malhotra', 'M', '7000000020', 'tanmay.231000020@muj.manipal.edu', 10, 4, 8, '310', '2023-07-31'),
('250300021', 'Zoya Khanna', 'F', '7000000021', 'zoya.250300021@muj.manipal.edu', 3, 2, 14, '926', '2025-07-16'),
('260600022', 'Riya Gupta', 'F', '7000000022', 'riya.260600022@muj.manipal.edu', 6, 1, 20, '431', '2026-07-15'),
('240800023', 'Mahira Shah', 'F', '7000000023', 'mahira.240800023@muj.manipal.edu', 8, 3, 15, '312', '2024-07-27'),
('230900024', 'Aisha Bhatia', 'F', '7000000024', 'aisha.230900024@muj.manipal.edu', 9, 4, 17, '323', '2023-07-20'),
('250100025', 'Siya Bhatia', 'F', '7000000025', 'siya.250100025@muj.manipal.edu', 1, 2, 18, '931', '2025-07-29'),
('260800026', 'Mahira Tiwari', 'F', '7000000026', 'mahira.260800026@muj.manipal.edu', 8, 1, 16, '106', '2026-07-29'),
('240800027', 'Rahul Mukherjee', 'M', '7000000027', 'rahul.240800027@muj.manipal.edu', 8, 3, 3, '123', '2024-07-20'),
('240100028', 'Divya Mukherjee', 'F', '7000000028', 'divya.240100028@muj.manipal.edu', 1, 3, 21, '437', '2024-07-24'),
('240100029', 'Veer Shekhawat', 'M', '7000000029', 'veer.240100029@muj.manipal.edu', 1, 3, 2, '711', '2024-07-18'),
('260600030', 'Harsh Yadav', 'M', '7000000030', 'harsh.260600030@muj.manipal.edu', 6, 1, 9, '618', '2026-07-17'),
('260100031', 'Pooja Meena', 'F', '7000000031', 'pooja.260100031@muj.manipal.edu', 1, 1, 13, '717', '2026-07-28'),
('240100032', 'Vihaan Singh', 'M', '7000000032', 'vihaan.240100032@muj.manipal.edu', 1, 3, 2, '236', '2024-07-26'),
('260600033', 'Prisha Khan', 'F', '7000000033', 'prisha.260600033@muj.manipal.edu', 6, 1, 19, '639', '2026-07-21'),
('240700034', 'Manav Rathore', 'M', '7000000034', 'manav.240700034@muj.manipal.edu', 7, 3, 11, '525', '2024-07-24'),
('250700035', 'Harsh Agarwal', 'M', '7000000035', 'harsh.250700035@muj.manipal.edu', 7, 2, 1, '522', '2025-07-24'),
('250800036', 'Ayaan Kapoor', 'M', '7000000036', 'ayaan.250800036@muj.manipal.edu', 8, 2, 10, '135', '2025-07-25'),
('260100037', 'Saanvi Rathore', 'F', '7000000037', 'saanvi.260100037@muj.manipal.edu', 1, 1, 14, '109', '2026-07-31'),
('250300038', 'Shreya Verma', 'F', '7000000038', 'shreya.250300038@muj.manipal.edu', 3, 2, 18, '725', '2025-07-27'),
('260800039', 'Khushi Joshi', 'F', '7000000039', 'khushi.260800039@muj.manipal.edu', 8, 1, 21, '135', '2026-07-27'),
('240100040', 'Ishaan Joshi', 'M', '7000000040', 'ishaan.240100040@muj.manipal.edu', 1, 3, 9, '827', '2024-07-23'),
('250100041', 'Krishna Deshpande', 'M', '7000000041', 'krishna.250100041@muj.manipal.edu', 1, 2, 9, '133', '2025-07-23'),
('260100042', 'Mahira Malhotra', 'F', '7000000042', 'mahira.260100042@muj.manipal.edu', 1, 1, 16, '804', '2026-07-22'),
('250700043', 'Ishaan Arora', 'M', '7000000043', 'ishaan.250700043@muj.manipal.edu', 7, 2, 4, '918', '2025-07-25'),
('230300044', 'Parth Bansal', 'M', '7000000044', 'parth.230300044@muj.manipal.edu', 3, 4, 9, '838', '2023-07-24'),
('260400045', 'Khushi Choudhary', 'F', '7000000045', 'khushi.260400045@muj.manipal.edu', 4, 1, 18, '927', '2026-07-16'),
('240200046', 'Sai Kapoor', 'M', '7000000046', 'sai.240200046@muj.manipal.edu', 2, 3, 3, '202', '2024-07-21'),
('230500047', 'Ansh Kapoor', 'M', '7000000047', 'ansh.230500047@muj.manipal.edu', 5, 4, 7, '934', '2023-07-20'),
('230100048', 'Reyansh Mehta', 'M', '7000000048', 'reyansh.230100048@muj.manipal.edu', 1, 4, 6, '917', '2023-07-24'),
('240100049', 'Radhika Patel', 'F', '7000000049', 'radhika.240100049@muj.manipal.edu', 1, 3, 17, '919', '2024-07-26'),
('261200050', 'Simran Patel', 'F', '7000000050', 'simran.261200050@muj.manipal.edu', 12, 1, 22, '828', '2026-07-26'),
('260700051', 'Rudra Meena', 'M', '7000000051', 'rudra.260700051@muj.manipal.edu', 7, 1, 3, '635', '2026-07-19'),
('240700052', 'Navya Das', 'F', '7000000052', 'navya.240700052@muj.manipal.edu', 7, 3, 13, '605', '2024-07-26'),
('250500053', 'Aisha Choudhary', 'F', '7000000053', 'aisha.250500053@muj.manipal.edu', 5, 2, 15, '221', '2025-07-30'),
('240100054', 'Aarohi Mittal', 'F', '7000000054', 'aarohi.240100054@muj.manipal.edu', 1, 3, 14, '631', '2024-07-30'),
('240800055', 'Mahira Mishra', 'F', '7000000055', 'mahira.240800055@muj.manipal.edu', 8, 3, 20, '606', '2024-07-17'),
('250800056', 'Sai Rao', 'M', '7000000056', 'sai.250800056@muj.manipal.edu', 8, 2, 11, '411', '2025-07-25'),
('230200057', 'Veer Khanna', 'M', '7000000057', 'veer.230200057@muj.manipal.edu', 2, 4, 7, '612', '2023-07-21'),
('250800058', 'Advait Bansal', 'M', '7000000058', 'advait.250800058@muj.manipal.edu', 8, 2, 7, '714', '2025-07-19'),
('240300059', 'Arnav Shekhawat', 'M', '7000000059', 'arnav.240300059@muj.manipal.edu', 3, 3, 2, '618', '2024-07-29'),
('250100060', 'Aisha Tiwari', 'F', '7000000060', 'aisha.250100060@muj.manipal.edu', 1, 2, 21, '218', '2025-07-24'),
('240100061', 'Siddharth Arora', 'M', '7000000061', 'siddharth.240100061@muj.manipal.edu', 1, 3, 11, '722', '2024-07-18'),
('230400062', 'Dev Mukherjee', 'M', '7000000062', 'dev.230400062@muj.manipal.edu', 4, 4, 6, '604', '2023-07-27'),
('240400063', 'Aarav Tiwari', 'M', '7000000063', 'aarav.240400063@muj.manipal.edu', 4, 3, 3, '638', '2024-07-28'),
('260200064', 'Aryan Reddy', 'M', '7000000064', 'aryan.260200064@muj.manipal.edu', 2, 1, 4, '218', '2026-07-25'),
('240400065', 'Sara Iyer', 'F', '7000000065', 'sara.240400065@muj.manipal.edu', 4, 3, 14, '913', '2024-07-15'),
('251200066', 'Ishaan Khanna', 'M', '7000000066', 'ishaan.251200066@muj.manipal.edu', 12, 2, 4, '320', '2025-07-17'),
('260400067', 'Om Deshpande', 'M', '7000000067', 'om.260400067@muj.manipal.edu', 4, 1, 1, '527', '2026-07-16'),
('251200068', 'Anvi Joshi', 'F', '7000000068', 'anvi.251200068@muj.manipal.edu', 12, 2, 18, '623', '2025-07-25'),
('241000069', 'Kabir Rao', 'M', '7000000069', 'kabir.241000069@muj.manipal.edu', 10, 3, 1, '809', '2024-07-15'),
('230900070', 'Parth Pandey', 'M', '7000000070', 'parth.230900070@muj.manipal.edu', 9, 4, 4, '618', '2023-07-31'),
('260100071', 'Siddharth Kapoor', 'M', '7000000071', 'siddharth.260100071@muj.manipal.edu', 1, 1, 7, '233', '2026-07-24'),
('220900072', 'Varun Mehta', 'M', '7000000072', 'varun.220900072@muj.manipal.edu', 9, 5, 10, '632', '2022-07-25'),
('250100073', 'Parth Yadav', 'M', '7000000073', 'parth.250100073@muj.manipal.edu', 1, 2, 5, '934', '2025-07-27'),
('250100074', 'Mihir Shah', 'M', '7000000074', 'mihir.250100074@muj.manipal.edu', 1, 2, 4, '733', '2025-07-31'),
('240800075', 'Sara Tiwari', 'F', '7000000075', 'sara.240800075@muj.manipal.edu', 8, 3, 20, '336', '2024-07-25'),
('250500076', 'Muskan Mukherjee', 'F', '7000000076', 'muskan.250500076@muj.manipal.edu', 5, 2, 15, '910', '2025-07-19'),
('260800077', 'Divya Agarwal', 'F', '7000000077', 'divya.260800077@muj.manipal.edu', 8, 1, 17, '512', '2026-07-19'),
('250100078', 'Aisha Bansal', 'F', '7000000078', 'aisha.250100078@muj.manipal.edu', 1, 2, 15, '112', '2025-07-19'),
('261000079', 'Zoya Rao', 'F', '7000000079', 'zoya.261000079@muj.manipal.edu', 10, 1, 17, '433', '2026-07-26'),
('250700080', 'Sai Iyer', 'M', '7000000080', 'sai.250700080@muj.manipal.edu', 7, 2, 3, '610', '2025-07-31'),
('240100081', 'Aadhya Agarwal', 'F', '7000000081', 'aadhya.240100081@muj.manipal.edu', 1, 3, 18, '111', '2024-07-31'),
('260700082', 'Pari Sethi', 'F', '7000000082', 'pari.260700082@muj.manipal.edu', 7, 1, 15, '415', '2026-07-30'),
('251200083', 'Kiara Mukherjee', 'F', '7000000083', 'kiara.251200083@muj.manipal.edu', 12, 2, 19, '824', '2025-07-21'),
('260500084', 'Tanmay Bose', 'M', '7000000084', 'tanmay.260500084@muj.manipal.edu', 5, 1, 4, '408', '2026-07-17'),
('250100085', 'Zoya Meena', 'F', '7000000085', 'zoya.250100085@muj.manipal.edu', 1, 2, 19, '428', '2025-07-15'),
('240100086', 'Ishaan Tiwari', 'M', '7000000086', 'ishaan.240100086@muj.manipal.edu', 1, 3, 7, '131', '2024-07-31'),
('250400087', 'Ritvik Bansal', 'M', '7000000087', 'ritvik.250400087@muj.manipal.edu', 4, 2, 2, '336', '2025-07-22'),
('260500088', 'Nikhil Mittal', 'M', '7000000088', 'nikhil.260500088@muj.manipal.edu', 5, 1, 12, '921', '2026-07-23'),
('260800089', 'Rudra Banerjee', 'M', '7000000089', 'rudra.260800089@muj.manipal.edu', 8, 1, 5, '503', '2026-07-17'),
('261100090', 'Arjun Banerjee', 'M', '7000000090', 'arjun.261100090@muj.manipal.edu', 11, 1, 7, '840', '2026-07-30'),
('260100091', 'Ishaan Malhotra', 'M', '7000000091', 'ishaan.260100091@muj.manipal.edu', 1, 1, 7, '211', '2026-07-23'),
('240800092', 'Diya Jain', 'F', '7000000092', 'diya.240800092@muj.manipal.edu', 8, 3, 14, '610', '2024-07-24'),
('250700093', 'Dhruv Malhotra', 'M', '7000000093', 'dhruv.250700093@muj.manipal.edu', 7, 2, 12, '426', '2025-07-22'),
('250100094', 'Karan Bhatia', 'M', '7000000094', 'karan.250100094@muj.manipal.edu', 1, 2, 10, '329', '2025-07-21'),
('230500095', 'Ansh Reddy', 'M', '7000000095', 'ansh.230500095@muj.manipal.edu', 5, 4, 9, '132', '2023-07-21'),
('250300096', 'Diya Banerjee', 'F', '7000000096', 'diya.250300096@muj.manipal.edu', 3, 2, 17, '434', '2025-07-25'),
('250100097', 'Ishita Deshpande', 'F', '7000000097', 'ishita.250100097@muj.manipal.edu', 1, 2, 21, '237', '2025-07-26'),
('230400098', 'Ansh Jain', 'M', '7000000098', 'ansh.230400098@muj.manipal.edu', 4, 4, 7, '207', '2023-07-28'),
('240100099', 'Aadhya Mishra', 'F', '7000000099', 'aadhya.240100099@muj.manipal.edu', 1, 3, 15, '918', '2024-07-26'),
('260100100', 'Kiara Gupta', 'F', '7000000100', 'kiara.260100100@muj.manipal.edu', 1, 1, 20, '903', '2026-07-26'),
('260600101', 'Nikhil Das', 'M', '7000000101', 'nikhil.260600101@muj.manipal.edu', 6, 1, 4, '804', '2026-07-24'),
('240100102', 'Aarohi Tiwari', 'F', '7000000102', 'aarohi.240100102@muj.manipal.edu', 1, 3, 22, '131', '2024-07-23'),
('250400103', 'Aisha Meena', 'F', '7000000103', 'aisha.250400103@muj.manipal.edu', 4, 2, 20, '135', '2025-07-26'),
('260100104', 'Muskan Iyer', 'F', '7000000104', 'muskan.260100104@muj.manipal.edu', 1, 1, 13, '725', '2026-07-17'),
('250100105', 'Varun Yadav', 'M', '7000000105', 'varun.250100105@muj.manipal.edu', 1, 2, 9, '433', '2025-07-25'),
('240100106', 'Kiara Iyer', 'F', '7000000106', 'kiara.240100106@muj.manipal.edu', 1, 3, 14, '337', '2024-07-31'),
('250700107', 'Aryan Choudhary', 'M', '7000000107', 'aryan.250700107@muj.manipal.edu', 7, 2, 3, '836', '2025-07-18'),
('251100108', 'Simran Mehta', 'F', '7000000108', 'simran.251100108@muj.manipal.edu', 11, 2, 19, '633', '2025-07-26'),
('250600109', 'Radhika Verma', 'F', '7000000109', 'radhika.250600109@muj.manipal.edu', 6, 2, 14, '716', '2025-07-24'),
('260100110', 'Arnav Kulkarni', 'M', '7000000110', 'arnav.260100110@muj.manipal.edu', 1, 1, 1, '612', '2026-07-29'),
('260800111', 'Dhruv Reddy', 'M', '7000000111', 'dhruv.260800111@muj.manipal.edu', 8, 1, 10, '931', '2026-07-18'),
('250400112', 'Aadhya Ahmed', 'F', '7000000112', 'aadhya.250400112@muj.manipal.edu', 4, 2, 19, '502', '2025-07-29'),
('260600113', 'Ishaan Mittal', 'M', '7000000113', 'ishaan.260600113@muj.manipal.edu', 6, 1, 8, '207', '2026-07-22'),
('240900114', 'Tanmay Jain', 'M', '7000000114', 'tanmay.240900114@muj.manipal.edu', 9, 3, 8, '820', '2024-07-23'),
('240300115', 'Varun Bhatia', 'M', '7000000115', 'varun.240300115@muj.manipal.edu', 3, 3, 3, '240', '2024-07-15'),
('240100116', 'Kavya Arora', 'F', '7000000116', 'kavya.240100116@muj.manipal.edu', 1, 3, 15, '215', '2024-07-27'),
('240200117', 'Sneha Mukherjee', 'F', '7000000117', 'sneha.240200117@muj.manipal.edu', 2, 3, 21, '925', '2024-07-23'),
('240100118', 'Jiya Mishra', 'F', '7000000118', 'jiya.240100118@muj.manipal.edu', 1, 3, 13, '420', '2024-07-20'),
('230300119', 'Ansh Shekhawat', 'M', '7000000119', 'ansh.230300119@muj.manipal.edu', 3, 4, 11, '804', '2023-07-24'),
('240200120', 'Mihir Das', 'M', '7000000120', 'mihir.240200120@muj.manipal.edu', 2, 3, 7, '435', '2024-07-31'),
('240200121', 'Zoya Das', 'F', '7000000121', 'zoya.240200121@muj.manipal.edu', 2, 3, 19, '915', '2024-07-15'),
('240600122', 'Manav Mittal', 'M', '7000000122', 'manav.240600122@muj.manipal.edu', 6, 3, 4, '938', '2024-07-27'),
('250100123', 'Ananya Singh', 'F', '7000000123', 'ananya.250100123@muj.manipal.edu', 1, 2, 20, '731', '2025-07-20'),
('260100124', 'Advik Goyal', 'M', '7000000124', 'advik.260100124@muj.manipal.edu', 1, 1, 2, '214', '2026-07-27'),
('260600125', 'Naina Bansal', 'F', '7000000125', 'naina.260600125@muj.manipal.edu', 6, 1, 19, '421', '2026-07-24'),
('240800126', 'Reyansh Jain', 'M', '7000000126', 'reyansh.240800126@muj.manipal.edu', 8, 3, 3, '827', '2024-07-18'),
('240900127', 'Advik Bose', 'M', '7000000127', 'advik.240900127@muj.manipal.edu', 9, 3, 10, '308', '2024-07-17'),
('260300128', 'Ira Nair', 'F', '7000000128', 'ira.260300128@muj.manipal.edu', 3, 1, 21, '709', '2026-07-17'),
('261000129', 'Prisha Sethi', 'F', '7000000129', 'prisha.261000129@muj.manipal.edu', 10, 1, 20, '804', '2026-07-29'),
('230300130', 'Reyansh Agarwal', 'M', '7000000130', 'reyansh.230300130@muj.manipal.edu', 3, 4, 11, '217', '2023-07-31'),
('261100131', 'Anika Bansal', 'F', '7000000131', 'anika.261100131@muj.manipal.edu', 11, 1, 15, '517', '2026-07-28'),
('261100132', 'Advait Goyal', 'M', '7000000132', 'advait.261100132@muj.manipal.edu', 11, 1, 7, '237', '2026-07-23'),
('250200133', 'Zoya Deshpande', 'F', '7000000133', 'zoya.250200133@muj.manipal.edu', 2, 2, 21, '717', '2025-07-16'),
('230300134', 'Kabir Banerjee', 'M', '7000000134', 'kabir.230300134@muj.manipal.edu', 3, 4, 12, '514', '2023-07-29'),
('251100135', 'Mahira Kapoor', 'F', '7000000135', 'mahira.251100135@muj.manipal.edu', 11, 2, 14, '401', '2025-07-21'),
('240700136', 'Yash Malhotra', 'M', '7000000136', 'yash.240700136@muj.manipal.edu', 7, 3, 2, '626', '2024-07-28'),
('250700137', 'Mihir Mittal', 'M', '7000000137', 'mihir.250700137@muj.manipal.edu', 7, 2, 7, '838', '2025-07-25'),
('250800138', 'Harsh Sharma', 'M', '7000000138', 'harsh.250800138@muj.manipal.edu', 8, 2, 12, '617', '2025-07-30'),
('260100139', 'Khushi Iyer', 'F', '7000000139', 'khushi.260100139@muj.manipal.edu', 1, 1, 17, '935', '2026-07-16'),
('240100140', 'Sneha Sethi', 'F', '7000000140', 'sneha.240100140@muj.manipal.edu', 1, 3, 17, '114', '2024-07-21'),
('240100141', 'Meera Yadav', 'F', '7000000141', 'meera.240100141@muj.manipal.edu', 1, 3, 22, '930', '2024-07-18'),
('230100142', 'Vihaan Saxena', 'M', '7000000142', 'vihaan.230100142@muj.manipal.edu', 1, 4, 4, '205', '2023-07-18'),
('231000143', 'Arjun Deshpande', 'M', '7000000143', 'arjun.231000143@muj.manipal.edu', 10, 4, 1, '329', '2023-07-15'),
('251100144', 'Aniket Bhatia', 'M', '7000000144', 'aniket.251100144@muj.manipal.edu', 11, 2, 4, '127', '2025-07-24'),
('230300145', 'Saanvi Jain', 'F', '7000000145', 'saanvi.230300145@muj.manipal.edu', 3, 4, 20, '810', '2023-07-15'),
('240300146', 'Anika Shekhawat', 'F', '7000000146', 'anika.240300146@muj.manipal.edu', 3, 3, 20, '940', '2024-07-19'),
('260100147', 'Kiara Saxena', 'F', '7000000147', 'kiara.260100147@muj.manipal.edu', 1, 1, 16, '825', '2026-07-17'),
('260200148', 'Aarohi Sharma', 'F', '7000000148', 'aarohi.260200148@muj.manipal.edu', 2, 1, 17, '915', '2026-07-21'),
('260400149', 'Pari Kapoor', 'F', '7000000149', 'pari.260400149@muj.manipal.edu', 4, 1, 21, '215', '2026-07-29'),
('240100150', 'Krishna Meena', 'M', '7000000150', 'krishna.240100150@muj.manipal.edu', 1, 3, 11, '225', '2024-07-23'),
('250100151', 'Aryan Goyal', 'M', '7000000151', 'aryan.250100151@muj.manipal.edu', 1, 2, 6, '805', '2025-07-19'),
('240100152', 'Aniket Mukherjee', 'M', '7000000152', 'aniket.240100152@muj.manipal.edu', 1, 3, 4, '531', '2024-07-16'),
('240200153', 'Reyansh Shah', 'M', '7000000153', 'reyansh.240200153@muj.manipal.edu', 2, 3, 11, '705', '2024-07-30'),
('261200154', 'Shreya Shekhawat', 'F', '7000000154', 'shreya.261200154@muj.manipal.edu', 12, 1, 14, '528', '2026-07-17'),
('240100155', 'Advik Mukherjee', 'M', '7000000155', 'advik.240100155@muj.manipal.edu', 1, 3, 4, '121', '2024-07-18'),
('240700156', 'Mahira Bhatia', 'F', '7000000156', 'mahira.240700156@muj.manipal.edu', 7, 3, 22, '403', '2024-07-26'),
('240100157', 'Dev Sethi', 'M', '7000000157', 'dev.240100157@muj.manipal.edu', 1, 3, 6, '435', '2024-07-23'),
('240800158', 'Om Bansal', 'M', '7000000158', 'om.240800158@muj.manipal.edu', 8, 3, 2, '128', '2024-07-29'),
('250100159', 'Vihaan Khan', 'M', '7000000159', 'vihaan.250100159@muj.manipal.edu', 1, 2, 11, '826', '2025-07-18'),
('250100160', 'Harsh Rathore', 'M', '7000000160', 'harsh.250100160@muj.manipal.edu', 1, 2, 7, '414', '2025-07-23'),
('230100161', 'Nikhil Sharma', 'M', '7000000161', 'nikhil.230100161@muj.manipal.edu', 1, 4, 6, '326', '2023-07-19'),
('230100162', 'Mihir Kapoor', 'M', '7000000162', 'mihir.230100162@muj.manipal.edu', 1, 4, 5, '728', '2023-07-28'),
('250900163', 'Muskan Mittal', 'F', '7000000163', 'muskan.250900163@muj.manipal.edu', 9, 2, 22, '939', '2025-07-30'),
('240700164', 'Pooja Mishra', 'F', '7000000164', 'pooja.240700164@muj.manipal.edu', 7, 3, 18, '906', '2024-07-21'),
('250300165', 'Atharv Mehta', 'M', '7000000165', 'atharv.250300165@muj.manipal.edu', 3, 2, 12, '420', '2025-07-28'),
('251100166', 'Nikhil Gupta', 'M', '7000000166', 'nikhil.251100166@muj.manipal.edu', 11, 2, 12, '203', '2025-07-23'),
('260700167', 'Nikhil Khanna', 'M', '7000000167', 'nikhil.260700167@muj.manipal.edu', 7, 1, 7, '933', '2026-07-28'),
('240100168', 'Rahul Mehta', 'M', '7000000168', 'rahul.240100168@muj.manipal.edu', 1, 3, 2, '134', '2024-07-19'),
('251000169', 'Pooja Kulkarni', 'F', '7000000169', 'pooja.251000169@muj.manipal.edu', 10, 2, 17, '501', '2025-07-24'),
('250800170', 'Arnav Tiwari', 'M', '7000000170', 'arnav.250800170@muj.manipal.edu', 8, 2, 8, '905', '2025-07-19'),
('230100171', 'Nisha Arora', 'F', '7000000171', 'nisha.230100171@muj.manipal.edu', 1, 4, 14, '626', '2023-07-15'),
('260100172', 'Aarav Jain', 'M', '7000000172', 'aarav.260100172@muj.manipal.edu', 1, 1, 12, '121', '2026-07-19'),
('240800173', 'Siya Agarwal', 'F', '7000000173', 'siya.240800173@muj.manipal.edu', 8, 3, 14, '804', '2024-07-21'),
('250400174', 'Mihir Choudhary', 'M', '7000000174', 'mihir.250400174@muj.manipal.edu', 4, 2, 1, '629', '2025-07-16'),
('251200175', 'Shreya Banerjee', 'F', '7000000175', 'shreya.251200175@muj.manipal.edu', 12, 2, 20, '907', '2025-07-28'),
('241000176', 'Siddharth Jain', 'M', '7000000176', 'siddharth.241000176@muj.manipal.edu', 10, 3, 7, '423', '2024-07-17'),
('250100177', 'Riya Verma', 'F', '7000000177', 'riya.250100177@muj.manipal.edu', 1, 2, 13, '120', '2025-07-15'),
('230200178', 'Aarav Sharma', 'M', '7000000178', 'aarav.230200178@muj.manipal.edu', 2, 4, 4, '806', '2023-07-28'),
('250100179', 'Yash Bansal', 'M', '7000000179', 'yash.250100179@muj.manipal.edu', 1, 2, 1, '209', '2025-07-28'),
('240800180', 'Lakshya Mehta', 'M', '7000000180', 'lakshya.240800180@muj.manipal.edu', 8, 3, 8, '802', '2024-07-25'),
('250500181', 'Mihir Yadav', 'M', '7000000181', 'mihir.250500181@muj.manipal.edu', 5, 2, 4, '905', '2025-07-21'),
('261200182', 'Saanvi Shekhawat', 'F', '7000000182', 'saanvi.261200182@muj.manipal.edu', 12, 1, 21, '708', '2026-07-26'),
('240800183', 'Ayaan Shekhawat', 'M', '7000000183', 'ayaan.240800183@muj.manipal.edu', 8, 3, 10, '219', '2024-07-30'),
('250800184', 'Siddharth Reddy', 'M', '7000000184', 'siddharth.250800184@muj.manipal.edu', 8, 2, 5, '921', '2025-07-16'),
('230100185', 'Advait Khanna', 'M', '7000000185', 'advait.230100185@muj.manipal.edu', 1, 4, 7, '910', '2023-07-25'),
('260400186', 'Advik Pandey', 'M', '7000000186', 'advik.260400186@muj.manipal.edu', 4, 1, 3, '508', '2026-07-29'),
('230100187', 'Shaurya Mittal', 'M', '7000000187', 'shaurya.230100187@muj.manipal.edu', 1, 4, 7, '334', '2023-07-20'),
('240700188', 'Varun Yadav', 'M', '7000000188', 'varun.240700188@muj.manipal.edu', 7, 3, 3, '510', '2024-07-19'),
('250300189', 'Kavya Shekhawat', 'F', '7000000189', 'kavya.250300189@muj.manipal.edu', 3, 2, 20, '139', '2025-07-26'),
('250700190', 'Mahira Deshpande', 'F', '7000000190', 'mahira.250700190@muj.manipal.edu', 7, 2, 13, '508', '2025-07-25'),
('260800191', 'Aisha Agarwal', 'F', '7000000191', 'aisha.260800191@muj.manipal.edu', 8, 1, 16, '322', '2026-07-20'),
('260700192', 'Aditi Sethi', 'F', '7000000192', 'aditi.260700192@muj.manipal.edu', 7, 1, 20, '909', '2026-07-29'),
('230100193', 'Diya Das', 'F', '7000000193', 'diya.230100193@muj.manipal.edu', 1, 4, 14, '307', '2023-07-21'),
('260100194', 'Harsh Arora', 'M', '7000000194', 'harsh.260100194@muj.manipal.edu', 1, 1, 1, '309', '2026-07-21'),
('240500195', 'Ansh Arora', 'M', '7000000195', 'ansh.240500195@muj.manipal.edu', 5, 3, 4, '515', '2024-07-19'),
('260900196', 'Siddharth Malhotra', 'M', '7000000196', 'siddharth.260900196@muj.manipal.edu', 9, 1, 2, '424', '2026-07-18'),
('230100197', 'Saanvi Sethi', 'F', '7000000197', 'saanvi.230100197@muj.manipal.edu', 1, 4, 14, '805', '2023-07-18'),
('240100198', 'Nisha Joshi', 'F', '7000000198', 'nisha.240100198@muj.manipal.edu', 1, 3, 14, '722', '2024-07-26'),
('261200199', 'Neha Bhatia', 'F', '7000000199', 'neha.261200199@muj.manipal.edu', 12, 1, 14, '617', '2026-07-21'),
('260100200', 'Aarohi Gupta', 'F', '7000000200', 'aarohi.260100200@muj.manipal.edu', 1, 1, 15, '323', '2026-07-15'),
('260100201', 'Tanvi Meena', 'F', '7000000201', 'tanvi.260100201@muj.manipal.edu', 1, 1, 14, '535', '2026-07-19'),
('260800202', 'Kabir Rathore', 'M', '7000000202', 'kabir.260800202@muj.manipal.edu', 8, 1, 5, '237', '2026-07-15'),
('251200203', 'Krishna Shah', 'M', '7000000203', 'krishna.251200203@muj.manipal.edu', 12, 2, 12, '215', '2025-07-26'),
('231000204', 'Pranav Banerjee', 'M', '7000000204', 'pranav.231000204@muj.manipal.edu', 10, 4, 4, '835', '2023-07-29'),
('250700205', 'Aditya Saxena', 'M', '7000000205', 'aditya.250700205@muj.manipal.edu', 7, 2, 5, '319', '2025-07-27'),
('250700206', 'Karan Saxena', 'M', '7000000206', 'karan.250700206@muj.manipal.edu', 7, 2, 3, '828', '2025-07-23'),
('230500207', 'Arjun Meena', 'M', '7000000207', 'arjun.230500207@muj.manipal.edu', 5, 4, 5, '529', '2023-07-27'),
('250100208', 'Nisha Iyer', 'F', '7000000208', 'nisha.250100208@muj.manipal.edu', 1, 2, 19, '124', '2025-07-25'),
('230200209', 'Divya Arora', 'F', '7000000209', 'divya.230200209@muj.manipal.edu', 2, 4, 13, '704', '2023-07-25'),
('230100210', 'Advait Joshi', 'M', '7000000210', 'advait.230100210@muj.manipal.edu', 1, 4, 11, '325', '2023-07-30'),
('240800211', 'Aarav Ahmed', 'M', '7000000211', 'aarav.240800211@muj.manipal.edu', 8, 3, 7, '517', '2024-07-24'),
('260800212', 'Naina Kapoor', 'F', '7000000212', 'naina.260800212@muj.manipal.edu', 8, 1, 16, '812', '2026-07-15'),
('260800213', 'Aisha Mishra', 'F', '7000000213', 'aisha.260800213@muj.manipal.edu', 8, 1, 19, '701', '2026-07-30'),
('251100214', 'Anvi Deshpande', 'F', '7000000214', 'anvi.251100214@muj.manipal.edu', 11, 2, 14, '720', '2025-07-16'),
('250100215', 'Om Yadav', 'M', '7000000215', 'om.250100215@muj.manipal.edu', 1, 2, 10, '711', '2025-07-20'),
('240300216', 'Aisha Nair', 'F', '7000000216', 'aisha.240300216@muj.manipal.edu', 3, 3, 16, '806', '2024-07-18'),
('230500217', 'Divya Banerjee', 'F', '7000000217', 'divya.230500217@muj.manipal.edu', 5, 4, 19, '102', '2023-07-20'),
('251100218', 'Dev Verma', 'M', '7000000218', 'dev.251100218@muj.manipal.edu', 11, 2, 10, '340', '2025-07-31'),
('260400219', 'Riya Rao', 'F', '7000000219', 'riya.260400219@muj.manipal.edu', 4, 1, 19, '318', '2026-07-23'),
('230100220', 'Prisha Nair', 'F', '7000000220', 'prisha.230100220@muj.manipal.edu', 1, 4, 17, '411', '2023-07-21'),
('250300221', 'Vanya Nair', 'F', '7000000221', 'vanya.250300221@muj.manipal.edu', 3, 2, 14, '506', '2025-07-26'),
('230100222', 'Pranav Saxena', 'M', '7000000222', 'pranav.230100222@muj.manipal.edu', 1, 4, 8, '323', '2023-07-20'),
('250100223', 'Radhika Kulkarni', 'F', '7000000223', 'radhika.250100223@muj.manipal.edu', 1, 2, 16, '305', '2025-07-19'),
('250300224', 'Siddharth Das', 'M', '7000000224', 'siddharth.250300224@muj.manipal.edu', 3, 2, 3, '806', '2025-07-22'),
('241000225', 'Ayaan Yadav', 'M', '7000000225', 'ayaan.241000225@muj.manipal.edu', 10, 3, 12, '806', '2024-07-26'),
('250200226', 'Krishna Ahmed', 'M', '7000000226', 'krishna.250200226@muj.manipal.edu', 2, 2, 1, '819', '2025-07-20'),
('250500227', 'Pooja Rao', 'F', '7000000227', 'pooja.250500227@muj.manipal.edu', 5, 2, 20, '232', '2025-07-27'),
('260300228', 'Pooja Choudhary', 'F', '7000000228', 'pooja.260300228@muj.manipal.edu', 3, 1, 19, '521', '2026-07-15'),
('240100229', 'Arjun Jain', 'M', '7000000229', 'arjun.240100229@muj.manipal.edu', 1, 3, 7, '137', '2024-07-28'),
('260200230', 'Rudra Saxena', 'M', '7000000230', 'rudra.260200230@muj.manipal.edu', 2, 1, 1, '818', '2026-07-31'),
('260100231', 'Kavya Mukherjee', 'F', '7000000231', 'kavya.260100231@muj.manipal.edu', 1, 1, 14, '416', '2026-07-17'),
('260100232', 'Parth Sethi', 'M', '7000000232', 'parth.260100232@muj.manipal.edu', 1, 1, 9, '430', '2026-07-31'),
('230200233', 'Arjun Khan', 'M', '7000000233', 'arjun.230200233@muj.manipal.edu', 2, 4, 2, '105', '2023-07-16'),
('251100234', 'Sneha Saxena', 'F', '7000000234', 'sneha.251100234@muj.manipal.edu', 11, 2, 19, '224', '2025-07-18'),
('260800235', 'Dev Bansal', 'M', '7000000235', 'dev.260800235@muj.manipal.edu', 8, 1, 10, '305', '2026-07-16'),
('260500236', 'Harsh Saxena', 'M', '7000000236', 'harsh.260500236@muj.manipal.edu', 5, 1, 11, '305', '2026-07-31'),
('241000237', 'Yash Mishra', 'M', '7000000237', 'yash.241000237@muj.manipal.edu', 10, 3, 3, '432', '2024-07-22'),
('240800238', 'Simran Kulkarni', 'F', '7000000238', 'simran.240800238@muj.manipal.edu', 8, 3, 18, '227', '2024-07-31'),
('240100239', 'Kavya Choudhary', 'F', '7000000239', 'kavya.240100239@muj.manipal.edu', 1, 3, 17, '901', '2024-07-25'),
('240200240', 'Mihir Das', 'M', '7000000240', 'mihir.240200240@muj.manipal.edu', 2, 3, 9, '628', '2024-07-19'),
('230100241', 'Atharv Mukherjee', 'M', '7000000241', 'atharv.230100241@muj.manipal.edu', 1, 4, 2, '927', '2023-07-21'),
('240100242', 'Tanvi Arora', 'F', '7000000242', 'tanvi.240100242@muj.manipal.edu', 1, 3, 20, '602', '2024-07-28'),
('230300243', 'Aniket Meena', 'M', '7000000243', 'aniket.230300243@muj.manipal.edu', 3, 4, 11, '908', '2023-07-24'),
('260300244', 'Dhruv Jain', 'M', '7000000244', 'dhruv.260300244@muj.manipal.edu', 3, 1, 5, '402', '2026-07-30'),
('230200245', 'Jiya Nair', 'F', '7000000245', 'jiya.230200245@muj.manipal.edu', 2, 4, 22, '235', '2023-07-15'),
('260400246', 'Nisha Jain', 'F', '7000000246', 'nisha.260400246@muj.manipal.edu', 4, 1, 16, '503', '2026-07-28'),
('261100247', 'Karan Sethi', 'M', '7000000247', 'karan.261100247@muj.manipal.edu', 11, 1, 5, '438', '2026-07-26'),
('230400248', 'Siddharth Rathore', 'M', '7000000248', 'siddharth.230400248@muj.manipal.edu', 4, 4, 6, '729', '2023-07-18'),
('250100249', 'Siddharth Saxena', 'M', '7000000249', 'siddharth.250100249@muj.manipal.edu', 1, 2, 1, '333', '2025-07-23'),
('260800250', 'Krishna Khanna', 'M', '7000000250', 'krishna.260800250@muj.manipal.edu', 8, 1, 3, '630', '2026-07-29'),
('230400251', 'Dev Mittal', 'M', '7000000251', 'dev.230400251@muj.manipal.edu', 4, 4, 9, '537', '2023-07-27'),
('240500252', 'Ayaan Rao', 'M', '7000000252', 'ayaan.240500252@muj.manipal.edu', 5, 3, 6, '822', '2024-07-28'),
('251100253', 'Parth Goyal', 'M', '7000000253', 'parth.251100253@muj.manipal.edu', 11, 2, 11, '913', '2025-07-28'),
('240700254', 'Rudra Mukherjee', 'M', '7000000254', 'rudra.240700254@muj.manipal.edu', 7, 3, 6, '405', '2024-07-27'),
('231000255', 'Kabir Kapoor', 'M', '7000000255', 'kabir.231000255@muj.manipal.edu', 10, 4, 2, '829', '2023-07-23'),
('260600256', 'Advik Bhatia', 'M', '7000000256', 'advik.260600256@muj.manipal.edu', 6, 1, 4, '301', '2026-07-17'),
('220900257', 'Tanmay Meena', 'M', '7000000257', 'tanmay.220900257@muj.manipal.edu', 9, 5, 1, '421', '2022-07-29'),
('230100258', 'Pooja Banerjee', 'F', '7000000258', 'pooja.230100258@muj.manipal.edu', 1, 4, 20, '922', '2023-07-24'),
('230100259', 'Radhika Mehta', 'F', '7000000259', 'radhika.230100259@muj.manipal.edu', 1, 4, 22, '340', '2023-07-21'),
('260100260', 'Om Patel', 'M', '7000000260', 'om.260100260@muj.manipal.edu', 1, 1, 8, '521', '2026-07-18'),
('260200261', 'Ritvik Shah', 'M', '7000000261', 'ritvik.260200261@muj.manipal.edu', 2, 1, 2, '637', '2026-07-21'),
('230100262', 'Lakshya Nair', 'M', '7000000262', 'lakshya.230100262@muj.manipal.edu', 1, 4, 8, '531', '2023-07-17'),
('260100263', 'Prisha Patel', 'F', '7000000263', 'prisha.260100263@muj.manipal.edu', 1, 1, 15, '524', '2026-07-19'),
('250300264', 'Veer Rao', 'M', '7000000264', 'veer.250300264@muj.manipal.edu', 3, 2, 3, '818', '2025-07-23'),
('260100265', 'Aarav Saxena', 'M', '7000000265', 'aarav.260100265@muj.manipal.edu', 1, 1, 10, '718', '2026-07-20'),
('240900266', 'Rohan Shah', 'M', '7000000266', 'rohan.240900266@muj.manipal.edu', 9, 3, 4, '422', '2024-07-17'),
('261000267', 'Lakshya Shah', 'M', '7000000267', 'lakshya.261000267@muj.manipal.edu', 10, 1, 11, '540', '2026-07-25'),
('240100268', 'Aniket Saxena', 'M', '7000000268', 'aniket.240100268@muj.manipal.edu', 1, 3, 9, '726', '2024-07-20'),
('240100269', 'Parth Choudhary', 'M', '7000000269', 'parth.240100269@muj.manipal.edu', 1, 3, 11, '326', '2024-07-26'),
('240100270', 'Sai Mittal', 'M', '7000000270', 'sai.240100270@muj.manipal.edu', 1, 3, 9, '423', '2024-07-16'),
('251200271', 'Aarohi Agarwal', 'F', '7000000271', 'aarohi.251200271@muj.manipal.edu', 12, 2, 15, '926', '2025-07-26'),
('240100272', 'Rohan Sethi', 'M', '7000000272', 'rohan.240100272@muj.manipal.edu', 1, 3, 2, '915', '2024-07-16'),
('230100273', 'Diya Nair', 'F', '7000000273', 'diya.230100273@muj.manipal.edu', 1, 4, 18, '622', '2023-07-29'),
('220900274', 'Shaurya Shah', 'M', '7000000274', 'shaurya.220900274@muj.manipal.edu', 9, 5, 9, '915', '2022-07-16'),
('240200275', 'Shaurya Choudhary', 'M', '7000000275', 'shaurya.240200275@muj.manipal.edu', 2, 3, 5, '134', '2024-07-31'),
('260800276', 'Avni Das', 'F', '7000000276', 'avni.260800276@muj.manipal.edu', 8, 1, 13, '638', '2026-07-15'),
('230100277', 'Ayaan Ahmed', 'M', '7000000277', 'ayaan.230100277@muj.manipal.edu', 1, 4, 6, '615', '2023-07-25'),
('240100278', 'Avni Pandey', 'F', '7000000278', 'avni.240100278@muj.manipal.edu', 1, 3, 17, '606', '2024-07-25'),
('250600279', 'Parth Ahmed', 'M', '7000000279', 'parth.250600279@muj.manipal.edu', 6, 2, 10, '906', '2025-07-29'),
('250100280', 'Isha Bhatia', 'F', '7000000280', 'isha.250100280@muj.manipal.edu', 1, 2, 21, '814', '2025-07-15'),
('230100281', 'Tanmay Goyal', 'M', '7000000281', 'tanmay.230100281@muj.manipal.edu', 1, 4, 9, '121', '2023-07-30'),
('260200282', 'Rahul Agarwal', 'M', '7000000282', 'rahul.260200282@muj.manipal.edu', 2, 1, 11, '914', '2026-07-30'),
('250100283', 'Ira Khanna', 'F', '7000000283', 'ira.250100283@muj.manipal.edu', 1, 2, 18, '821', '2025-07-22'),
('260100284', 'Aryan Patel', 'M', '7000000284', 'aryan.260100284@muj.manipal.edu', 1, 1, 10, '135', '2026-07-27'),
('230100285', 'Tanmay Iyer', 'M', '7000000285', 'tanmay.230100285@muj.manipal.edu', 1, 4, 5, '521', '2023-07-20'),
('260600286', 'Advait Bhatia', 'M', '7000000286', 'advait.260600286@muj.manipal.edu', 6, 1, 5, '408', '2026-07-16'),
('260100287', 'Anika Rao', 'F', '7000000287', 'anika.260100287@muj.manipal.edu', 1, 1, 17, '311', '2026-07-25'),
('260100288', 'Reyansh Malhotra', 'M', '7000000288', 'reyansh.260100288@muj.manipal.edu', 1, 1, 7, '631', '2026-07-27'),
('261100289', 'Harsh Choudhary', 'M', '7000000289', 'harsh.261100289@muj.manipal.edu', 11, 1, 6, '906', '2026-07-31'),
('260800290', 'Harsh Mukherjee', 'M', '7000000290', 'harsh.260800290@muj.manipal.edu', 8, 1, 9, '411', '2026-07-15'),
('260100291', 'Tanmay Reddy', 'M', '7000000291', 'tanmay.260100291@muj.manipal.edu', 1, 1, 4, '229', '2026-07-25'),
('230100292', 'Kunal Agarwal', 'M', '7000000292', 'kunal.230100292@muj.manipal.edu', 1, 4, 8, '720', '2023-07-23'),
('261100293', 'Mihir Nair', 'M', '7000000293', 'mihir.261100293@muj.manipal.edu', 11, 1, 8, '733', '2026-07-18'),
('260700294', 'Nikhil Sethi', 'M', '7000000294', 'nikhil.260700294@muj.manipal.edu', 7, 1, 5, '313', '2026-07-27'),
('251100295', 'Divya Bhatia', 'F', '7000000295', 'divya.251100295@muj.manipal.edu', 11, 2, 13, '328', '2025-07-22'),
('250800296', 'Yash Tiwari', 'M', '7000000296', 'yash.250800296@muj.manipal.edu', 8, 2, 2, '619', '2025-07-30'),
('230600297', 'Advik Shah', 'M', '7000000297', 'advik.230600297@muj.manipal.edu', 6, 4, 5, '428', '2023-07-27'),
('251100298', 'Advik Sharma', 'M', '7000000298', 'advik.251100298@muj.manipal.edu', 11, 2, 5, '707', '2025-07-17'),
('230100299', 'Anvi Mishra', 'F', '7000000299', 'anvi.230100299@muj.manipal.edu', 1, 4, 21, '304', '2023-07-25'),
('250100300', 'Shreya Kulkarni', 'F', '7000000300', 'shreya.250100300@muj.manipal.edu', 1, 2, 15, '227', '2025-07-31'),
('240700301', 'Aniket Pandey', 'M', '7000000301', 'aniket.240700301@muj.manipal.edu', 7, 3, 4, '230', '2024-07-22'),
('250100302', 'Vanya Bansal', 'F', '7000000302', 'vanya.250100302@muj.manipal.edu', 1, 2, 20, '324', '2025-07-26'),
('240100303', 'Manav Malhotra', 'M', '7000000303', 'manav.240100303@muj.manipal.edu', 1, 3, 8, '327', '2024-07-16'),
('250100304', 'Pari Shekhawat', 'F', '7000000304', 'pari.250100304@muj.manipal.edu', 1, 2, 19, '712', '2025-07-29'),
('230300305', 'Pranav Bhatia', 'M', '7000000305', 'pranav.230300305@muj.manipal.edu', 3, 4, 7, '740', '2023-07-30'),
('250600306', 'Simran Deshpande', 'F', '7000000306', 'simran.250600306@muj.manipal.edu', 6, 2, 14, '718', '2025-07-18'),
('250500307', 'Ritvik Verma', 'M', '7000000307', 'ritvik.250500307@muj.manipal.edu', 5, 2, 12, '837', '2025-07-29'),
('240100308', 'Simran Meena', 'F', '7000000308', 'simran.240100308@muj.manipal.edu', 1, 3, 22, '103', '2024-07-23'),
('260600309', 'Veer Kapoor', 'M', '7000000309', 'veer.260600309@muj.manipal.edu', 6, 1, 8, '911', '2026-07-28'),
('261100310', 'Mihir Bansal', 'M', '7000000310', 'mihir.261100310@muj.manipal.edu', 11, 1, 5, '439', '2026-07-30'),
('250100311', 'Kabir Kapoor', 'M', '7000000311', 'kabir.250100311@muj.manipal.edu', 1, 2, 2, '703', '2025-07-30'),
('241000312', 'Dhruv Mukherjee', 'M', '7000000312', 'dhruv.241000312@muj.manipal.edu', 10, 3, 4, '608', '2024-07-16'),
('250800313', 'Saanvi Banerjee', 'F', '7000000313', 'saanvi.250800313@muj.manipal.edu', 8, 2, 19, '216', '2025-07-30'),
('250700314', 'Tara Khan', 'F', '7000000314', 'tara.250700314@muj.manipal.edu', 7, 2, 22, '226', '2025-07-20'),
('250700315', 'Krishna Mittal', 'M', '7000000315', 'krishna.250700315@muj.manipal.edu', 7, 2, 10, '308', '2025-07-29'),
('230400316', 'Vivaan Nair', 'M', '7000000316', 'vivaan.230400316@muj.manipal.edu', 4, 4, 5, '617', '2023-07-19'),
('250100317', 'Kabir Malhotra', 'M', '7000000317', 'kabir.250100317@muj.manipal.edu', 1, 2, 11, '602', '2025-07-23'),
('231000318', 'Karan Mehta', 'M', '7000000318', 'karan.231000318@muj.manipal.edu', 10, 4, 7, '118', '2023-07-21'),
('260800319', 'Neha Mehta', 'F', '7000000319', 'neha.260800319@muj.manipal.edu', 8, 1, 14, '735', '2026-07-21'),
('260400320', 'Yash Mittal', 'M', '7000000320', 'yash.260400320@muj.manipal.edu', 4, 1, 12, '712', '2026-07-17'),
('250100321', 'Kabir Das', 'M', '7000000321', 'kabir.250100321@muj.manipal.edu', 1, 2, 6, '319', '2025-07-30'),
('240100322', 'Parth Patel', 'M', '7000000322', 'parth.240100322@muj.manipal.edu', 1, 3, 1, '340', '2024-07-30'),
('230300323', 'Nikhil Goyal', 'M', '7000000323', 'nikhil.230300323@muj.manipal.edu', 3, 4, 9, '203', '2023-07-17'),
('250100324', 'Anika Gupta', 'F', '7000000324', 'anika.250100324@muj.manipal.edu', 1, 2, 15, '140', '2025-07-21'),
('251200325', 'Aditi Tiwari', 'F', '7000000325', 'aditi.251200325@muj.manipal.edu', 12, 2, 20, '209', '2025-07-22'),
('231000326', 'Manav Meena', 'M', '7000000326', 'manav.231000326@muj.manipal.edu', 10, 4, 11, '303', '2023-07-23'),
('261100327', 'Avni Patel', 'F', '7000000327', 'avni.261100327@muj.manipal.edu', 11, 1, 19, '234', '2026-07-18'),
('230100328', 'Shreya Patel', 'F', '7000000328', 'shreya.230100328@muj.manipal.edu', 1, 4, 13, '106', '2023-07-20'),
('230200329', 'Saanvi Mittal', 'F', '7000000329', 'saanvi.230200329@muj.manipal.edu', 2, 4, 14, '301', '2023-07-25'),
('260700330', 'Vivaan Rao', 'M', '7000000330', 'vivaan.260700330@muj.manipal.edu', 7, 1, 2, '527', '2026-07-26'),
('251100331', 'Arjun Shekhawat', 'M', '7000000331', 'arjun.251100331@muj.manipal.edu', 11, 2, 6, '317', '2025-07-17'),
('230100332', 'Neha Singh', 'F', '7000000332', 'neha.230100332@muj.manipal.edu', 1, 4, 15, '114', '2023-07-20'),
('260800333', 'Yash Das', 'M', '7000000333', 'yash.260800333@muj.manipal.edu', 8, 1, 11, '331', '2026-07-18'),
('250900334', 'Isha Shah', 'F', '7000000334', 'isha.250900334@muj.manipal.edu', 9, 2, 21, '607', '2025-07-16'),
('250100335', 'Shaurya Kulkarni', 'M', '7000000335', 'shaurya.250100335@muj.manipal.edu', 1, 2, 5, '511', '2025-07-18'),
('250800336', 'Dhruv Rathore', 'M', '7000000336', 'dhruv.250800336@muj.manipal.edu', 8, 2, 8, '810', '2025-07-18'),
('241000337', 'Neha Mishra', 'F', '7000000337', 'neha.241000337@muj.manipal.edu', 10, 3, 20, '708', '2024-07-25'),
('260200338', 'Naina Khanna', 'F', '7000000338', 'naina.260200338@muj.manipal.edu', 2, 1, 14, '208', '2026-07-28'),
('240600339', 'Krishna Bose', 'M', '7000000339', 'krishna.240600339@muj.manipal.edu', 6, 3, 1, '221', '2024-07-28'),
('260900340', 'Reyansh Sethi', 'M', '7000000340', 'reyansh.260900340@muj.manipal.edu', 9, 1, 2, '307', '2026-07-18'),
('240100341', 'Siddharth Bose', 'M', '7000000341', 'siddharth.240100341@muj.manipal.edu', 1, 3, 6, '917', '2024-07-17'),
('250400342', 'Dev Agarwal', 'M', '7000000342', 'dev.250400342@muj.manipal.edu', 4, 2, 5, '140', '2025-07-22'),
('230500343', 'Arjun Singh', 'M', '7000000343', 'arjun.230500343@muj.manipal.edu', 5, 4, 1, '217', '2023-07-30'),
('260600344', 'Ansh Deshpande', 'M', '7000000344', 'ansh.260600344@muj.manipal.edu', 6, 1, 5, '119', '2026-07-17'),
('260700345', 'Vivaan Bansal', 'M', '7000000345', 'vivaan.260700345@muj.manipal.edu', 7, 1, 6, '105', '2026-07-18'),
('260100346', 'Kunal Malhotra', 'M', '7000000346', 'kunal.260100346@muj.manipal.edu', 1, 1, 4, '526', '2026-07-31'),
('230200347', 'Aadhya Patel', 'F', '7000000347', 'aadhya.230200347@muj.manipal.edu', 2, 4, 19, '507', '2023-07-26'),
('260900348', 'Radhika Reddy', 'F', '7000000348', 'radhika.260900348@muj.manipal.edu', 9, 1, 18, '415', '2026-07-27'),
('260100349', 'Ira Agarwal', 'F', '7000000349', 'ira.260100349@muj.manipal.edu', 1, 1, 13, '929', '2026-07-25'),
('261100350', 'Aditya Rao', 'M', '7000000350', 'aditya.261100350@muj.manipal.edu', 11, 1, 12, '223', '2026-07-21'),
('250100351', 'Reyansh Sharma', 'M', '7000000351', 'reyansh.250100351@muj.manipal.edu', 1, 2, 8, '230', '2025-07-20'),
('250800352', 'Pooja Deshpande', 'F', '7000000352', 'pooja.250800352@muj.manipal.edu', 8, 2, 22, '118', '2025-07-26'),
('260800353', 'Avni Mehta', 'F', '7000000353', 'avni.260800353@muj.manipal.edu', 8, 1, 16, '101', '2026-07-19'),
('260600354', 'Ritvik Gupta', 'M', '7000000354', 'ritvik.260600354@muj.manipal.edu', 6, 1, 9, '739', '2026-07-25'),
('231000355', 'Siddharth Gupta', 'M', '7000000355', 'siddharth.231000355@muj.manipal.edu', 10, 4, 2, '412', '2023-07-23'),
('231000356', 'Kunal Bansal', 'M', '7000000356', 'kunal.231000356@muj.manipal.edu', 10, 4, 11, '837', '2023-07-26'),
('240100357', 'Nikhil Kulkarni', 'M', '7000000357', 'nikhil.240100357@muj.manipal.edu', 1, 3, 4, '308', '2024-07-16'),
('250700358', 'Nikhil Shekhawat', 'M', '7000000358', 'nikhil.250700358@muj.manipal.edu', 7, 2, 8, '624', '2025-07-16'),
('250100359', 'Aditya Bose', 'M', '7000000359', 'aditya.250100359@muj.manipal.edu', 1, 2, 5, '618', '2025-07-22'),
('261200360', 'Zoya Nair', 'F', '7000000360', 'zoya.261200360@muj.manipal.edu', 12, 1, 20, '829', '2026-07-21'),
('250800361', 'Ritvik Tiwari', 'M', '7000000361', 'ritvik.250800361@muj.manipal.edu', 8, 2, 2, '514', '2025-07-31'),
('260300362', 'Nisha Gupta', 'F', '7000000362', 'nisha.260300362@muj.manipal.edu', 3, 1, 15, '336', '2026-07-15'),
('260600363', 'Yash Sethi', 'M', '7000000363', 'yash.260600363@muj.manipal.edu', 6, 1, 4, '716', '2026-07-24'),
('240800364', 'Aniket Sethi', 'M', '7000000364', 'aniket.240800364@muj.manipal.edu', 8, 3, 7, '922', '2024-07-29'),
('230200365', 'Sara Agarwal', 'F', '7000000365', 'sara.230200365@muj.manipal.edu', 2, 4, 14, '730', '2023-07-27'),
('250700366', 'Aarav Khanna', 'M', '7000000366', 'aarav.250700366@muj.manipal.edu', 7, 2, 6, '229', '2025-07-16'),
('240700367', 'Ishita Kulkarni', 'F', '7000000367', 'ishita.240700367@muj.manipal.edu', 7, 3, 19, '613', '2024-07-31'),
('230100368', 'Neha Shekhawat', 'F', '7000000368', 'neha.230100368@muj.manipal.edu', 1, 4, 21, '635', '2023-07-21'),
('240200369', 'Myra Rao', 'F', '7000000369', 'myra.240200369@muj.manipal.edu', 2, 3, 19, '114', '2024-07-23'),
('250100370', 'Aditya Meena', 'M', '7000000370', 'aditya.250100370@muj.manipal.edu', 1, 2, 12, '705', '2025-07-22'),
('260600371', 'Aisha Malhotra', 'F', '7000000371', 'aisha.260600371@muj.manipal.edu', 6, 1, 13, '511', '2026-07-23'),
('240100372', 'Rudra Das', 'M', '7000000372', 'rudra.240100372@muj.manipal.edu', 1, 3, 6, '309', '2024-07-31'),
('250200373', 'Isha Khan', 'F', '7000000373', 'isha.250200373@muj.manipal.edu', 2, 2, 15, '325', '2025-07-21'),
('260100374', 'Zoya Khanna', 'F', '7000000374', 'zoya.260100374@muj.manipal.edu', 1, 1, 15, '832', '2026-07-26'),
('251000375', 'Ishaan Mehta', 'M', '7000000375', 'ishaan.251000375@muj.manipal.edu', 10, 2, 2, '517', '2025-07-28'),
('240700376', 'Nisha Shah', 'F', '7000000376', 'nisha.240700376@muj.manipal.edu', 7, 3, 22, '637', '2024-07-27'),
('260100377', 'Tara Bhatia', 'F', '7000000377', 'tara.260100377@muj.manipal.edu', 1, 1, 18, '618', '2026-07-25'),
('250100378', 'Lakshya Bhatia', 'M', '7000000378', 'lakshya.250100378@muj.manipal.edu', 1, 2, 3, '436', '2025-07-27'),
('230400379', 'Riya Khanna', 'F', '7000000379', 'riya.230400379@muj.manipal.edu', 4, 4, 19, '538', '2023-07-25'),
('250100380', 'Nikhil Jain', 'M', '7000000380', 'nikhil.250100380@muj.manipal.edu', 1, 2, 12, '537', '2025-07-22'),
('230100381', 'Aisha Arora', 'F', '7000000381', 'aisha.230100381@muj.manipal.edu', 1, 4, 21, '104', '2023-07-28'),
('240600382', 'Prisha Mishra', 'F', '7000000382', 'prisha.240600382@muj.manipal.edu', 6, 3, 22, '720', '2024-07-31'),
('260100383', 'Simran Banerjee', 'F', '7000000383', 'simran.260100383@muj.manipal.edu', 1, 1, 15, '128', '2026-07-23'),
('260800384', 'Vanya Mehta', 'F', '7000000384', 'vanya.260800384@muj.manipal.edu', 8, 1, 13, '121', '2026-07-19'),
('230100385', 'Ritvik Kulkarni', 'M', '7000000385', 'ritvik.230100385@muj.manipal.edu', 1, 4, 6, '217', '2023-07-19'),
('240100386', 'Vivaan Kulkarni', 'M', '7000000386', 'vivaan.240100386@muj.manipal.edu', 1, 3, 2, '136', '2024-07-15'),
('251100387', 'Kavya Saxena', 'F', '7000000387', 'kavya.251100387@muj.manipal.edu', 11, 2, 13, '806', '2025-07-27'),
('260800388', 'Prisha Das', 'F', '7000000388', 'prisha.260800388@muj.manipal.edu', 8, 1, 21, '524', '2026-07-22'),
('260200389', 'Reyansh Tiwari', 'M', '7000000389', 'reyansh.260200389@muj.manipal.edu', 2, 1, 3, '620', '2026-07-24'),
('250800390', 'Riya Mehta', 'F', '7000000390', 'riya.250800390@muj.manipal.edu', 8, 2, 17, '124', '2025-07-25'),
('260100391', 'Aisha Deshpande', 'F', '7000000391', 'aisha.260100391@muj.manipal.edu', 1, 1, 17, '303', '2026-07-23'),
('260600392', 'Dev Khan', 'M', '7000000392', 'dev.260600392@muj.manipal.edu', 6, 1, 12, '209', '2026-07-25'),
('251100393', 'Sneha Reddy', 'F', '7000000393', 'sneha.251100393@muj.manipal.edu', 11, 2, 22, '533', '2025-07-27'),
('250800394', 'Vihaan Yadav', 'M', '7000000394', 'vihaan.250800394@muj.manipal.edu', 8, 2, 2, '927', '2025-07-23'),
('251100395', 'Manav Banerjee', 'M', '7000000395', 'manav.251100395@muj.manipal.edu', 11, 2, 10, '738', '2025-07-15'),
('260400396', 'Prisha Tiwari', 'F', '7000000396', 'prisha.260400396@muj.manipal.edu', 4, 1, 22, '838', '2026-07-25'),
('240100397', 'Ananya Bansal', 'F', '7000000397', 'ananya.240100397@muj.manipal.edu', 1, 3, 22, '926', '2024-07-25'),
('240100398', 'Rohan Arora', 'M', '7000000398', 'rohan.240100398@muj.manipal.edu', 1, 3, 8, '417', '2024-07-31'),
('240400399', 'Ira Iyer', 'F', '7000000399', 'ira.240400399@muj.manipal.edu', 4, 3, 16, '908', '2024-07-20'),
('230300400', 'Dhruv Tiwari', 'M', '7000000400', 'dhruv.230300400@muj.manipal.edu', 3, 4, 1, '504', '2023-07-18'),
('260100401', 'Sai Yadav', 'M', '7000000401', 'sai.260100401@muj.manipal.edu', 1, 1, 6, '818', '2026-07-22'),
('230100402', 'Ansh Gupta', 'M', '7000000402', 'ansh.230100402@muj.manipal.edu', 1, 4, 1, '740', '2023-07-31'),
('250100403', 'Navya Ahmed', 'F', '7000000403', 'navya.250100403@muj.manipal.edu', 1, 2, 20, '238', '2025-07-19'),
('250900404', 'Kabir Joshi', 'M', '7000000404', 'kabir.250900404@muj.manipal.edu', 9, 2, 10, '940', '2025-07-27'),
('250300405', 'Om Bhatia', 'M', '7000000405', 'om.250300405@muj.manipal.edu', 3, 2, 11, '717', '2025-07-19'),
('240400406', 'Aditya Goyal', 'M', '7000000406', 'aditya.240400406@muj.manipal.edu', 4, 3, 6, '502', '2024-07-17'),
('251100407', 'Varun Khanna', 'M', '7000000407', 'varun.251100407@muj.manipal.edu', 11, 2, 4, '337', '2025-07-19'),
('260100408', 'Navya Rathore', 'F', '7000000408', 'navya.260100408@muj.manipal.edu', 1, 1, 20, '139', '2026-07-16'),
('240900409', 'Harsh Rao', 'M', '7000000409', 'harsh.240900409@muj.manipal.edu', 9, 3, 11, '807', '2024-07-28'),
('240100410', 'Veer Patel', 'M', '7000000410', 'veer.240100410@muj.manipal.edu', 1, 3, 1, '417', '2024-07-20'),
('240100411', 'Vivaan Saxena', 'M', '7000000411', 'vivaan.240100411@muj.manipal.edu', 1, 3, 5, '234', '2024-07-29'),
('250100412', 'Sai Meena', 'M', '7000000412', 'sai.250100412@muj.manipal.edu', 1, 2, 8, '838', '2025-07-20'),
('230100413', 'Aryan Agarwal', 'M', '7000000413', 'aryan.230100413@muj.manipal.edu', 1, 4, 8, '517', '2023-07-28'),
('240700414', 'Reyansh Meena', 'M', '7000000414', 'reyansh.240700414@muj.manipal.edu', 7, 3, 3, '632', '2024-07-16'),
('250900415', 'Nikhil Joshi', 'M', '7000000415', 'nikhil.250900415@muj.manipal.edu', 9, 2, 2, '917', '2025-07-18'),
('260700416', 'Manav Verma', 'M', '7000000416', 'manav.260700416@muj.manipal.edu', 7, 1, 11, '312', '2026-07-20'),
('241000417', 'Nisha Malhotra', 'F', '7000000417', 'nisha.241000417@muj.manipal.edu', 10, 3, 13, '617', '2024-07-22'),
('260200418', 'Rohan Choudhary', 'M', '7000000418', 'rohan.260200418@muj.manipal.edu', 2, 1, 3, '108', '2026-07-24'),
('250500419', 'Reyansh Choudhary', 'M', '7000000419', 'reyansh.250500419@muj.manipal.edu', 5, 2, 3, '219', '2025-07-23'),
('250100420', 'Muskan Khanna', 'F', '7000000420', 'muskan.250100420@muj.manipal.edu', 1, 2, 21, '314', '2025-07-20'),
('240300421', 'Advait Rao', 'M', '7000000421', 'advait.240300421@muj.manipal.edu', 3, 3, 1, '212', '2024-07-20'),
('230400422', 'Aniket Deshpande', 'M', '7000000422', 'aniket.230400422@muj.manipal.edu', 4, 4, 11, '402', '2023-07-23'),
('260100423', 'Karan Meena', 'M', '7000000423', 'karan.260100423@muj.manipal.edu', 1, 1, 4, '637', '2026-07-15'),
('240100424', 'Tanmay Deshpande', 'M', '7000000424', 'tanmay.240100424@muj.manipal.edu', 1, 3, 6, '516', '2024-07-21'),
('260500425', 'Dhruv Khan', 'M', '7000000425', 'dhruv.260500425@muj.manipal.edu', 5, 1, 9, '507', '2026-07-28'),
('260700426', 'Shreya Jain', 'F', '7000000426', 'shreya.260700426@muj.manipal.edu', 7, 1, 13, '828', '2026-07-26'),
('240200427', 'Kunal Pandey', 'M', '7000000427', 'kunal.240200427@muj.manipal.edu', 2, 3, 9, '937', '2024-07-28'),
('240900428', 'Sai Reddy', 'M', '7000000428', 'sai.240900428@muj.manipal.edu', 9, 3, 1, '506', '2024-07-24'),
('230100429', 'Khushi Goyal', 'F', '7000000429', 'khushi.230100429@muj.manipal.edu', 1, 4, 21, '232', '2023-07-21'),
('250800430', 'Anika Mittal', 'F', '7000000430', 'anika.250800430@muj.manipal.edu', 8, 2, 18, '208', '2025-07-25'),
('250100431', 'Ishita Verma', 'F', '7000000431', 'ishita.250100431@muj.manipal.edu', 1, 2, 16, '205', '2025-07-18'),
('240600432', 'Harsh Pandey', 'M', '7000000432', 'harsh.240600432@muj.manipal.edu', 6, 3, 6, '807', '2024-07-17'),
('230100433', 'Tanmay Shah', 'M', '7000000433', 'tanmay.230100433@muj.manipal.edu', 1, 4, 10, '514', '2023-07-20'),
('250600434', 'Kunal Khanna', 'M', '7000000434', 'kunal.250600434@muj.manipal.edu', 6, 2, 8, '122', '2025-07-15'),
('260900435', 'Simran Choudhary', 'F', '7000000435', 'simran.260900435@muj.manipal.edu', 9, 1, 14, '437', '2026-07-18'),
('240100436', 'Myra Mishra', 'F', '7000000436', 'myra.240100436@muj.manipal.edu', 1, 3, 13, '231', '2024-07-31'),
('250600437', 'Ira Mittal', 'F', '7000000437', 'ira.250600437@muj.manipal.edu', 6, 2, 16, '736', '2025-07-29'),
('240800438', 'Vihaan Reddy', 'M', '7000000438', 'vihaan.240800438@muj.manipal.edu', 8, 3, 12, '216', '2024-07-24'),
('251100439', 'Siya Nair', 'F', '7000000439', 'siya.251100439@muj.manipal.edu', 11, 2, 14, '723', '2025-07-25'),
('251200440', 'Lakshya Bansal', 'M', '7000000440', 'lakshya.251200440@muj.manipal.edu', 12, 2, 7, '732', '2025-07-29'),
('251100441', 'Meera Tiwari', 'F', '7000000441', 'meera.251100441@muj.manipal.edu', 11, 2, 21, '908', '2025-07-15'),
('250800442', 'Sara Kulkarni', 'F', '7000000442', 'sara.250800442@muj.manipal.edu', 8, 2, 14, '927', '2025-07-22'),
('240300443', 'Rohan Saxena', 'M', '7000000443', 'rohan.240300443@muj.manipal.edu', 3, 3, 4, '412', '2024-07-24'),
('240100444', 'Vivaan Mishra', 'M', '7000000444', 'vivaan.240100444@muj.manipal.edu', 1, 3, 2, '816', '2024-07-26'),
('261100445', 'Shaurya Sharma', 'M', '7000000445', 'shaurya.261100445@muj.manipal.edu', 11, 1, 1, '214', '2026-07-27'),
('250100446', 'Shaurya Rao', 'M', '7000000446', 'shaurya.250100446@muj.manipal.edu', 1, 2, 1, '525', '2025-07-17'),
('240300447', 'Om Sethi', 'M', '7000000447', 'om.240300447@muj.manipal.edu', 3, 3, 2, '623', '2024-07-21'),
('250200448', 'Rahul Patel', 'M', '7000000448', 'rahul.250200448@muj.manipal.edu', 2, 2, 7, '503', '2025-07-31'),
('240900449', 'Siddharth Meena', 'M', '7000000449', 'siddharth.240900449@muj.manipal.edu', 9, 3, 5, '831', '2024-07-18'),
('250700450', 'Krishna Rao', 'M', '7000000450', 'krishna.250700450@muj.manipal.edu', 7, 2, 7, '310', '2025-07-18'),
('250800451', 'Myra Khan', 'F', '7000000451', 'myra.250800451@muj.manipal.edu', 8, 2, 21, '934', '2025-07-26'),
('250100452', 'Mahira Mukherjee', 'F', '7000000452', 'mahira.250100452@muj.manipal.edu', 1, 2, 15, '637', '2025-07-23'),
('240100453', 'Rudra Ahmed', 'M', '7000000453', 'rudra.240100453@muj.manipal.edu', 1, 3, 5, '220', '2024-07-28'),
('250100454', 'Advik Yadav', 'M', '7000000454', 'advik.250100454@muj.manipal.edu', 1, 2, 7, '405', '2025-07-24'),
('240600455', 'Aryan Mittal', 'M', '7000000455', 'aryan.240600455@muj.manipal.edu', 6, 3, 3, '538', '2024-07-17'),
('240700456', 'Mahira Banerjee', 'F', '7000000456', 'mahira.240700456@muj.manipal.edu', 7, 3, 21, '240', '2024-07-15'),
('240700457', 'Siddharth Joshi', 'M', '7000000457', 'siddharth.240700457@muj.manipal.edu', 7, 3, 8, '206', '2024-07-29'),
('240200458', 'Shreya Choudhary', 'F', '7000000458', 'shreya.240200458@muj.manipal.edu', 2, 3, 22, '413', '2024-07-26'),
('230600459', 'Harsh Goyal', 'M', '7000000459', 'harsh.230600459@muj.manipal.edu', 6, 4, 3, '130', '2023-07-21'),
('250100460', 'Advik Nair', 'M', '7000000460', 'advik.250100460@muj.manipal.edu', 1, 2, 7, '109', '2025-07-22'),
('240100461', 'Yash Bose', 'M', '7000000461', 'yash.240100461@muj.manipal.edu', 1, 3, 2, '614', '2024-07-23'),
('230300462', 'Krishna Das', 'M', '7000000462', 'krishna.230300462@muj.manipal.edu', 3, 4, 5, '336', '2023-07-24'),
('250100463', 'Aisha Reddy', 'F', '7000000463', 'aisha.250100463@muj.manipal.edu', 1, 2, 21, '428', '2025-07-28'),
('250100464', 'Aadhya Meena', 'F', '7000000464', 'aadhya.250100464@muj.manipal.edu', 1, 2, 13, '110', '2025-07-30'),
('240100465', 'Sai Malhotra', 'M', '7000000465', 'sai.240100465@muj.manipal.edu', 1, 3, 1, '511', '2024-07-17'),
('240300466', 'Advik Iyer', 'M', '7000000466', 'advik.240300466@muj.manipal.edu', 3, 3, 10, '816', '2024-07-19'),
('260600467', 'Aditya Rathore', 'M', '7000000467', 'aditya.260600467@muj.manipal.edu', 6, 1, 6, '919', '2026-07-28'),
('260700468', 'Advik Bansal', 'M', '7000000468', 'advik.260700468@muj.manipal.edu', 7, 1, 5, '127', '2026-07-17'),
('240200469', 'Nikhil Choudhary', 'M', '7000000469', 'nikhil.240200469@muj.manipal.edu', 2, 3, 1, '735', '2024-07-28'),
('240400470', 'Aadhya Joshi', 'F', '7000000470', 'aadhya.240400470@muj.manipal.edu', 4, 3, 18, '436', '2024-07-17'),
('260800471', 'Divya Das', 'F', '7000000471', 'divya.260800471@muj.manipal.edu', 8, 1, 17, '232', '2026-07-16'),
('250300472', 'Aarohi Shah', 'F', '7000000472', 'aarohi.250300472@muj.manipal.edu', 3, 2, 17, '409', '2025-07-30'),
('240100473', 'Vivaan Patel', 'M', '7000000473', 'vivaan.240100473@muj.manipal.edu', 1, 3, 8, '715', '2024-07-21'),
('250300474', 'Rudra Deshpande', 'M', '7000000474', 'rudra.250300474@muj.manipal.edu', 3, 2, 9, '610', '2025-07-23'),
('250800475', 'Pranav Choudhary', 'M', '7000000475', 'pranav.250800475@muj.manipal.edu', 8, 2, 9, '420', '2025-07-16'),
('240100476', 'Krishna Kapoor', 'M', '7000000476', 'krishna.240100476@muj.manipal.edu', 1, 3, 7, '912', '2024-07-29'),
('260200477', 'Atharv Goyal', 'M', '7000000477', 'atharv.260200477@muj.manipal.edu', 2, 1, 6, '429', '2026-07-21'),
('260700478', 'Kabir Verma', 'M', '7000000478', 'kabir.260700478@muj.manipal.edu', 7, 1, 5, '139', '2026-07-24'),
('260100479', 'Vihaan Rao', 'M', '7000000479', 'vihaan.260100479@muj.manipal.edu', 1, 1, 4, '819', '2026-07-17'),
('261000480', 'Ananya Malhotra', 'F', '7000000480', 'ananya.261000480@muj.manipal.edu', 10, 1, 20, '220', '2026-07-18'),
('261200481', 'Rahul Khanna', 'M', '7000000481', 'rahul.261200481@muj.manipal.edu', 12, 1, 2, '517', '2026-07-24'),
('240700482', 'Tanvi Choudhary', 'F', '7000000482', 'tanvi.240700482@muj.manipal.edu', 7, 3, 19, '508', '2024-07-28'),
('250100483', 'Pranav Iyer', 'M', '7000000483', 'pranav.250100483@muj.manipal.edu', 1, 2, 10, '720', '2025-07-19'),
('240600484', 'Tanmay Yadav', 'M', '7000000484', 'tanmay.240600484@muj.manipal.edu', 6, 3, 9, '532', '2024-07-16'),
('250200485', 'Manav Khanna', 'M', '7000000485', 'manav.250200485@muj.manipal.edu', 2, 2, 5, '607', '2025-07-26'),
('230100486', 'Simran Agarwal', 'F', '7000000486', 'simran.230100486@muj.manipal.edu', 1, 4, 17, '332', '2023-07-29'),
('250700487', 'Arnav Reddy', 'M', '7000000487', 'arnav.250700487@muj.manipal.edu', 7, 2, 3, '830', '2025-07-31'),
('230100488', 'Divya Joshi', 'F', '7000000488', 'divya.230100488@muj.manipal.edu', 1, 4, 22, '608', '2023-07-22'),
('250400489', 'Kiara Joshi', 'F', '7000000489', 'kiara.250400489@muj.manipal.edu', 4, 2, 16, '623', '2025-07-22'),
('250700490', 'Navya Shekhawat', 'F', '7000000490', 'navya.250700490@muj.manipal.edu', 7, 2, 18, '112', '2025-07-19'),
('250700491', 'Siya Rao', 'F', '7000000491', 'siya.250700491@muj.manipal.edu', 7, 2, 22, '825', '2025-07-25'),
('250700492', 'Kiara Meena', 'F', '7000000492', 'kiara.250700492@muj.manipal.edu', 7, 2, 19, '809', '2025-07-17'),
('260900493', 'Om Rao', 'M', '7000000493', 'om.260900493@muj.manipal.edu', 9, 1, 3, '604', '2026-07-19'),
('240800494', 'Ansh Patel', 'M', '7000000494', 'ansh.240800494@muj.manipal.edu', 8, 3, 4, '607', '2024-07-29'),
('230100495', 'Rudra Nair', 'M', '7000000495', 'rudra.230100495@muj.manipal.edu', 1, 4, 6, '104', '2023-07-17'),
('260300496', 'Advik Deshpande', 'M', '7000000496', 'advik.260300496@muj.manipal.edu', 3, 1, 12, '237', '2026-07-17'),
('250300497', 'Arjun Yadav', 'M', '7000000497', 'arjun.250300497@muj.manipal.edu', 3, 2, 2, '616', '2025-07-18'),
('230200498', 'Pranav Gupta', 'M', '7000000498', 'pranav.230200498@muj.manipal.edu', 2, 4, 2, '835', '2023-07-28'),
('230100499', 'Muskan Rathore', 'F', '7000000499', 'muskan.230100499@muj.manipal.edu', 1, 4, 19, '313', '2023-07-22'),
('250100500', 'Karan Khanna', 'M', '7000000500', 'karan.250100500@muj.manipal.edu', 1, 2, 11, '811', '2025-07-16'),
('260800501', 'Myra Mishra', 'F', '7000000501', 'myra.260800501@muj.manipal.edu', 8, 1, 21, '819', '2026-07-15'),
('240400502', 'Aryan Yadav', 'M', '7000000502', 'aryan.240400502@muj.manipal.edu', 4, 3, 8, '314', '2024-07-30'),
('230100503', 'Pari Choudhary', 'F', '7000000503', 'pari.230100503@muj.manipal.edu', 1, 4, 13, '213', '2023-07-23'),
('230300504', 'Tanvi Rao', 'F', '7000000504', 'tanvi.230300504@muj.manipal.edu', 3, 4, 21, '924', '2023-07-23'),
('260400505', 'Vihaan Mittal', 'M', '7000000505', 'vihaan.260400505@muj.manipal.edu', 4, 1, 6, '826', '2026-07-23'),
('230100506', 'Diya Agarwal', 'F', '7000000506', 'diya.230100506@muj.manipal.edu', 1, 4, 19, '324', '2023-07-28'),
('240100507', 'Ayaan Bansal', 'M', '7000000507', 'ayaan.240100507@muj.manipal.edu', 1, 3, 1, '821', '2024-07-29'),
('230100508', 'Sara Reddy', 'F', '7000000508', 'sara.230100508@muj.manipal.edu', 1, 4, 20, '336', '2023-07-19'),
('230400509', 'Siya Meena', 'F', '7000000509', 'siya.230400509@muj.manipal.edu', 4, 4, 20, '701', '2023-07-21'),
('230300510', 'Kunal Patel', 'M', '7000000510', 'kunal.230300510@muj.manipal.edu', 3, 4, 8, '429', '2023-07-31'),
('250100511', 'Karan Shah', 'M', '7000000511', 'karan.250100511@muj.manipal.edu', 1, 2, 8, '810', '2025-07-16'),
('240800512', 'Atharv Shekhawat', 'M', '7000000512', 'atharv.240800512@muj.manipal.edu', 8, 3, 5, '201', '2024-07-21'),
('230200513', 'Rohan Patel', 'M', '7000000513', 'rohan.230200513@muj.manipal.edu', 2, 4, 9, '433', '2023-07-19'),
('260600514', 'Aadhya Jain', 'F', '7000000514', 'aadhya.260600514@muj.manipal.edu', 6, 1, 15, '603', '2026-07-15'),
('240700515', 'Harsh Mishra', 'M', '7000000515', 'harsh.240700515@muj.manipal.edu', 7, 3, 3, '901', '2024-07-31'),
('240100516', 'Aniket Shekhawat', 'M', '7000000516', 'aniket.240100516@muj.manipal.edu', 1, 3, 3, '716', '2024-07-25'),
('260800517', 'Dhruv Singh', 'M', '7000000517', 'dhruv.260800517@muj.manipal.edu', 8, 1, 7, '918', '2026-07-16'),
('230100518', 'Dev Tiwari', 'M', '7000000518', 'dev.230100518@muj.manipal.edu', 1, 4, 2, '827', '2023-07-28'),
('260100519', 'Parth Kulkarni', 'M', '7000000519', 'parth.260100519@muj.manipal.edu', 1, 1, 8, '718', '2026-07-17'),
('230400520', 'Pooja Reddy', 'F', '7000000520', 'pooja.230400520@muj.manipal.edu', 4, 4, 16, '208', '2023-07-26'),
('230900521', 'Anika Choudhary', 'F', '7000000521', 'anika.230900521@muj.manipal.edu', 9, 4, 15, '527', '2023-07-25'),
('240600522', 'Advait Mukherjee', 'M', '7000000522', 'advait.240600522@muj.manipal.edu', 6, 3, 3, '337', '2024-07-15'),
('230400523', 'Aryan Nair', 'M', '7000000523', 'aryan.230400523@muj.manipal.edu', 4, 4, 3, '933', '2023-07-23'),
('250100524', 'Muskan Meena', 'F', '7000000524', 'muskan.250100524@muj.manipal.edu', 1, 2, 17, '618', '2025-07-29'),
('250600525', 'Aarohi Rathore', 'F', '7000000525', 'aarohi.250600525@muj.manipal.edu', 6, 2, 18, '816', '2025-07-27'),
('261200526', 'Isha Bansal', 'F', '7000000526', 'isha.261200526@muj.manipal.edu', 12, 1, 14, '301', '2026-07-31'),
('250100527', 'Neha Shah', 'F', '7000000527', 'neha.250100527@muj.manipal.edu', 1, 2, 15, '405', '2025-07-27'),
('240600528', 'Aditya Reddy', 'M', '7000000528', 'aditya.240600528@muj.manipal.edu', 6, 3, 1, '235', '2024-07-30'),
('250400529', 'Karan Deshpande', 'M', '7000000529', 'karan.250400529@muj.manipal.edu', 4, 2, 12, '504', '2025-07-15'),
('240700530', 'Advait Bose', 'M', '7000000530', 'advait.240700530@muj.manipal.edu', 7, 3, 10, '930', '2024-07-28'),
('260100531', 'Advait Saxena', 'M', '7000000531', 'advait.260100531@muj.manipal.edu', 1, 1, 2, '718', '2026-07-29'),
('261000532', 'Krishna Banerjee', 'M', '7000000532', 'krishna.261000532@muj.manipal.edu', 10, 1, 1, '639', '2026-07-19'),
('240100533', 'Lakshya Goyal', 'M', '7000000533', 'lakshya.240100533@muj.manipal.edu', 1, 3, 12, '508', '2024-07-25'),
('250100534', 'Prisha Pandey', 'F', '7000000534', 'prisha.250100534@muj.manipal.edu', 1, 2, 20, '203', '2025-07-20'),
('230100535', 'Zoya Mishra', 'F', '7000000535', 'zoya.230100535@muj.manipal.edu', 1, 4, 14, '228', '2023-07-27'),
('230100536', 'Tara Iyer', 'F', '7000000536', 'tara.230100536@muj.manipal.edu', 1, 4, 13, '439', '2023-07-24'),
('260400537', 'Kunal Verma', 'M', '7000000537', 'kunal.260400537@muj.manipal.edu', 4, 1, 5, '237', '2026-07-22'),
('240400538', 'Mahira Shekhawat', 'F', '7000000538', 'mahira.240400538@muj.manipal.edu', 4, 3, 21, '217', '2024-07-30'),
('251200539', 'Om Joshi', 'M', '7000000539', 'om.251200539@muj.manipal.edu', 12, 2, 3, '625', '2025-07-29'),
('250200540', 'Kunal Kulkarni', 'M', '7000000540', 'kunal.250200540@muj.manipal.edu', 2, 2, 11, '603', '2025-07-21'),
('240700541', 'Aarohi Arora', 'F', '7000000541', 'aarohi.240700541@muj.manipal.edu', 7, 3, 14, '133', '2024-07-25'),
('260800542', 'Dev Banerjee', 'M', '7000000542', 'dev.260800542@muj.manipal.edu', 8, 1, 6, '924', '2026-07-28'),
('230200543', 'Riya Choudhary', 'F', '7000000543', 'riya.230200543@muj.manipal.edu', 2, 4, 13, '503', '2023-07-19'),
('240500544', 'Tara Pandey', 'F', '7000000544', 'tara.240500544@muj.manipal.edu', 5, 3, 17, '220', '2024-07-26'),
('261200545', 'Sneha Pandey', 'F', '7000000545', 'sneha.261200545@muj.manipal.edu', 12, 1, 13, '413', '2026-07-15'),
('251000546', 'Advik Meena', 'M', '7000000546', 'advik.251000546@muj.manipal.edu', 10, 2, 3, '726', '2025-07-29'),
('250400547', 'Nikhil Khan', 'M', '7000000547', 'nikhil.250400547@muj.manipal.edu', 4, 2, 8, '208', '2025-07-19'),
('230100548', 'Tanvi Choudhary', 'F', '7000000548', 'tanvi.230100548@muj.manipal.edu', 1, 4, 18, '717', '2023-07-24'),
('240100549', 'Kabir Kulkarni', 'M', '7000000549', 'kabir.240100549@muj.manipal.edu', 1, 3, 11, '926', '2024-07-17'),
('250800550', 'Neha Ahmed', 'F', '7000000550', 'neha.250800550@muj.manipal.edu', 8, 2, 18, '730', '2025-07-20'),
('250700551', 'Krishna Tiwari', 'M', '7000000551', 'krishna.250700551@muj.manipal.edu', 7, 2, 1, '807', '2025-07-31'),
('250100552', 'Pari Rathore', 'F', '7000000552', 'pari.250100552@muj.manipal.edu', 1, 2, 14, '219', '2025-07-16'),
('230600553', 'Ishita Rathore', 'F', '7000000553', 'ishita.230600553@muj.manipal.edu', 6, 4, 17, '530', '2023-07-17'),
('230600554', 'Riya Mishra', 'F', '7000000554', 'riya.230600554@muj.manipal.edu', 6, 4, 22, '531', '2023-07-23'),
('261000555', 'Siya Das', 'F', '7000000555', 'siya.261000555@muj.manipal.edu', 10, 1, 22, '526', '2026-07-20'),
('240100556', 'Nikhil Meena', 'M', '7000000556', 'nikhil.240100556@muj.manipal.edu', 1, 3, 4, '927', '2024-07-17'),
('250100557', 'Anvi Bhatia', 'F', '7000000557', 'anvi.250100557@muj.manipal.edu', 1, 2, 14, '538', '2025-07-28'),
('230100558', 'Parth Saxena', 'M', '7000000558', 'parth.230100558@muj.manipal.edu', 1, 4, 11, '307', '2023-07-18'),
('250100559', 'Harsh Deshpande', 'M', '7000000559', 'harsh.250100559@muj.manipal.edu', 1, 2, 9, '103', '2025-07-17'),
('251000560', 'Yash Mukherjee', 'M', '7000000560', 'yash.251000560@muj.manipal.edu', 10, 2, 5, '934', '2025-07-25'),
('250800561', 'Aadhya Das', 'F', '7000000561', 'aadhya.250800561@muj.manipal.edu', 8, 2, 15, '632', '2025-07-15'),
('230100562', 'Atharv Rathore', 'M', '7000000562', 'atharv.230100562@muj.manipal.edu', 1, 4, 11, '540', '2023-07-28'),
('230200563', 'Advait Malhotra', 'M', '7000000563', 'advait.230200563@muj.manipal.edu', 2, 4, 6, '919', '2023-07-27'),
('250800564', 'Saanvi Yadav', 'F', '7000000564', 'saanvi.250800564@muj.manipal.edu', 8, 2, 18, '533', '2025-07-28'),
('240100565', 'Dev Joshi', 'M', '7000000565', 'dev.240100565@muj.manipal.edu', 1, 3, 8, '623', '2024-07-22'),
('231000566', 'Diya Mukherjee', 'F', '7000000566', 'diya.231000566@muj.manipal.edu', 10, 4, 14, '306', '2023-07-17'),
('230100567', 'Ayaan Sethi', 'M', '7000000567', 'ayaan.230100567@muj.manipal.edu', 1, 4, 11, '907', '2023-07-21'),
('260100568', 'Advik Saxena', 'M', '7000000568', 'advik.260100568@muj.manipal.edu', 1, 1, 7, '501', '2026-07-26'),
('250600569', 'Aarohi Bhatia', 'F', '7000000569', 'aarohi.250600569@muj.manipal.edu', 6, 2, 18, '501', '2025-07-26'),
('240800570', 'Pooja Arora', 'F', '7000000570', 'pooja.240800570@muj.manipal.edu', 8, 3, 18, '503', '2024-07-25'),
('260800571', 'Prisha Bhatia', 'F', '7000000571', 'prisha.260800571@muj.manipal.edu', 8, 1, 16, '623', '2026-07-21'),
('240200572', 'Navya Gupta', 'F', '7000000572', 'navya.240200572@muj.manipal.edu', 2, 3, 18, '817', '2024-07-20'),
('230100573', 'Advait Shah', 'M', '7000000573', 'advait.230100573@muj.manipal.edu', 1, 4, 8, '204', '2023-07-23'),
('250100574', 'Sai Khan', 'M', '7000000574', 'sai.250100574@muj.manipal.edu', 1, 2, 8, '230', '2025-07-23'),
('260400575', 'Om Pandey', 'M', '7000000575', 'om.260400575@muj.manipal.edu', 4, 1, 12, '523', '2026-07-30'),
('250500576', 'Kunal Gupta', 'M', '7000000576', 'kunal.250500576@muj.manipal.edu', 5, 2, 11, '109', '2025-07-18'),
('260400577', 'Krishna Bhatia', 'M', '7000000577', 'krishna.260400577@muj.manipal.edu', 4, 1, 6, '336', '2026-07-16'),
('240300578', 'Kavya Shah', 'F', '7000000578', 'kavya.240300578@muj.manipal.edu', 3, 3, 17, '214', '2024-07-23'),
('240800579', 'Kabir Shah', 'M', '7000000579', 'kabir.240800579@muj.manipal.edu', 8, 3, 4, '533', '2024-07-19'),
('230100580', 'Shaurya Singh', 'M', '7000000580', 'shaurya.230100580@muj.manipal.edu', 1, 4, 12, '902', '2023-07-26'),
('240800581', 'Aarav Shah', 'M', '7000000581', 'aarav.240800581@muj.manipal.edu', 8, 3, 12, '807', '2024-07-16'),
('260100582', 'Parth Sharma', 'M', '7000000582', 'parth.260100582@muj.manipal.edu', 1, 1, 2, '127', '2026-07-22'),
('250100583', 'Jiya Joshi', 'F', '7000000583', 'jiya.250100583@muj.manipal.edu', 1, 2, 22, '517', '2025-07-20'),
('260100584', 'Aryan Khanna', 'M', '7000000584', 'aryan.260100584@muj.manipal.edu', 1, 1, 7, '231', '2026-07-17'),
('260100585', 'Reyansh Nair', 'M', '7000000585', 'reyansh.260100585@muj.manipal.edu', 1, 1, 5, '819', '2026-07-26'),
('260200586', 'Karan Agarwal', 'M', '7000000586', 'karan.260200586@muj.manipal.edu', 2, 1, 1, '906', '2026-07-31'),
('250600587', 'Sai Mukherjee', 'M', '7000000587', 'sai.250600587@muj.manipal.edu', 6, 2, 3, '326', '2025-07-26'),
('240700588', 'Tara Jain', 'F', '7000000588', 'tara.240700588@muj.manipal.edu', 7, 3, 22, '428', '2024-07-26'),
('231000589', 'Zoya Kapoor', 'F', '7000000589', 'zoya.231000589@muj.manipal.edu', 10, 4, 18, '940', '2023-07-18'),
('261100590', 'Kavya Mittal', 'F', '7000000590', 'kavya.261100590@muj.manipal.edu', 11, 1, 13, '713', '2026-07-28'),
('260100591', 'Vanya Sharma', 'F', '7000000591', 'vanya.260100591@muj.manipal.edu', 1, 1, 20, '338', '2026-07-27'),
('240800592', 'Radhika Bansal', 'F', '7000000592', 'radhika.240800592@muj.manipal.edu', 8, 3, 19, '129', '2024-07-15'),
('250800593', 'Aisha Singh', 'F', '7000000593', 'aisha.250800593@muj.manipal.edu', 8, 2, 22, '901', '2025-07-22'),
('230100594', 'Myra Goyal', 'F', '7000000594', 'myra.230100594@muj.manipal.edu', 1, 4, 18, '428', '2023-07-26'),
('250800595', 'Vihaan Rathore', 'M', '7000000595', 'vihaan.250800595@muj.manipal.edu', 8, 2, 2, '137', '2025-07-26'),
('260500596', 'Ansh Malhotra', 'M', '7000000596', 'ansh.260500596@muj.manipal.edu', 5, 1, 12, '510', '2026-07-25'),
('260500597', 'Vihaan Bansal', 'M', '7000000597', 'vihaan.260500597@muj.manipal.edu', 5, 1, 12, '513', '2026-07-21'),
('260700598', 'Tanmay Pandey', 'M', '7000000598', 'tanmay.260700598@muj.manipal.edu', 7, 1, 10, '935', '2026-07-22'),
('261200599', 'Kiara Yadav', 'F', '7000000599', 'kiara.261200599@muj.manipal.edu', 12, 1, 19, '332', '2026-07-23'),
('240800600', 'Vihaan Nair', 'M', '7000000600', 'vihaan.240800600@muj.manipal.edu', 8, 3, 12, '726', '2024-07-22'),
('230400601', 'Reyansh Banerjee', 'M', '7000000601', 'reyansh.230400601@muj.manipal.edu', 4, 4, 8, '237', '2023-07-15'),
('250300602', 'Anika Bhatia', 'F', '7000000602', 'anika.250300602@muj.manipal.edu', 3, 2, 14, '924', '2025-07-20'),
('230200603', 'Navya Joshi', 'F', '7000000603', 'navya.230200603@muj.manipal.edu', 2, 4, 18, '208', '2023-07-25'),
('250800604', 'Kabir Mukherjee', 'M', '7000000604', 'kabir.250800604@muj.manipal.edu', 8, 2, 1, '219', '2025-07-23'),
('250100605', 'Kavya Bose', 'F', '7000000605', 'kavya.250100605@muj.manipal.edu', 1, 2, 13, '134', '2025-07-28'),
('250800606', 'Avni Saxena', 'F', '7000000606', 'avni.250800606@muj.manipal.edu', 8, 2, 15, '737', '2025-07-22'),
('240100607', 'Pari Verma', 'F', '7000000607', 'pari.240100607@muj.manipal.edu', 1, 3, 20, '638', '2024-07-31'),
('251100608', 'Riya Das', 'F', '7000000608', 'riya.251100608@muj.manipal.edu', 11, 2, 14, '829', '2025-07-19'),
('261100609', 'Arjun Sharma', 'M', '7000000609', 'arjun.261100609@muj.manipal.edu', 11, 1, 10, '139', '2026-07-22'),
('250600610', 'Sai Deshpande', 'M', '7000000610', 'sai.250600610@muj.manipal.edu', 6, 2, 1, '502', '2025-07-29'),
('260900611', 'Pranav Sethi', 'M', '7000000611', 'pranav.260900611@muj.manipal.edu', 9, 1, 2, '440', '2026-07-19'),
('230200612', 'Advait Ahmed', 'M', '7000000612', 'advait.230200612@muj.manipal.edu', 2, 4, 8, '416', '2023-07-27'),
('250800613', 'Vanya Das', 'F', '7000000613', 'vanya.250800613@muj.manipal.edu', 8, 2, 20, '602', '2025-07-23'),
('230100614', 'Karan Shekhawat', 'M', '7000000614', 'karan.230100614@muj.manipal.edu', 1, 4, 6, '101', '2023-07-28'),
('260200615', 'Isha Rao', 'F', '7000000615', 'isha.260200615@muj.manipal.edu', 2, 1, 17, '636', '2026-07-19'),
('230600616', 'Zoya Bhatia', 'F', '7000000616', 'zoya.230600616@muj.manipal.edu', 6, 4, 16, '605', '2023-07-27'),
('250100617', 'Avni Deshpande', 'F', '7000000617', 'avni.250100617@muj.manipal.edu', 1, 2, 15, '322', '2025-07-16'),
('250800618', 'Myra Rao', 'F', '7000000618', 'myra.250800618@muj.manipal.edu', 8, 2, 16, '706', '2025-07-22'),
('240700619', 'Ansh Meena', 'M', '7000000619', 'ansh.240700619@muj.manipal.edu', 7, 3, 11, '229', '2024-07-21'),
('260200620', 'Ishita Meena', 'F', '7000000620', 'ishita.260200620@muj.manipal.edu', 2, 1, 13, '431', '2026-07-16'),
('261200621', 'Naina Gupta', 'F', '7000000621', 'naina.261200621@muj.manipal.edu', 12, 1, 13, '915', '2026-07-19'),
('230200622', 'Sneha Nair', 'F', '7000000622', 'sneha.230200622@muj.manipal.edu', 2, 4, 19, '640', '2023-07-31'),
('260400623', 'Ritvik Sharma', 'M', '7000000623', 'ritvik.260400623@muj.manipal.edu', 4, 1, 5, '104', '2026-07-31'),
('230100624', 'Tanmay Joshi', 'M', '7000000624', 'tanmay.230100624@muj.manipal.edu', 1, 4, 5, '930', '2023-07-23'),
('240800625', 'Vihaan Meena', 'M', '7000000625', 'vihaan.240800625@muj.manipal.edu', 8, 3, 5, '434', '2024-07-26'),
('250500626', 'Pooja Singh', 'F', '7000000626', 'pooja.250500626@muj.manipal.edu', 5, 2, 21, '328', '2025-07-18'),
('250100627', 'Kavya Reddy', 'F', '7000000627', 'kavya.250100627@muj.manipal.edu', 1, 2, 21, '130', '2025-07-15'),
('230100628', 'Kunal Shekhawat', 'M', '7000000628', 'kunal.230100628@muj.manipal.edu', 1, 4, 9, '435', '2023-07-28'),
('240300629', 'Vivaan Pandey', 'M', '7000000629', 'vivaan.240300629@muj.manipal.edu', 3, 3, 12, '427', '2024-07-15'),
('240500630', 'Radhika Pandey', 'F', '7000000630', 'radhika.240500630@muj.manipal.edu', 5, 3, 20, '629', '2024-07-24'),
('260800631', 'Aditya Sethi', 'M', '7000000631', 'aditya.260800631@muj.manipal.edu', 8, 1, 8, '622', '2026-07-22'),
('260500632', 'Pooja Joshi', 'F', '7000000632', 'pooja.260500632@muj.manipal.edu', 5, 1, 13, '521', '2026-07-29'),
('240400633', 'Muskan Verma', 'F', '7000000633', 'muskan.240400633@muj.manipal.edu', 4, 3, 17, '233', '2024-07-20'),
('240300634', 'Aarohi Choudhary', 'F', '7000000634', 'aarohi.240300634@muj.manipal.edu', 3, 3, 16, '619', '2024-07-24'),
('240700635', 'Muskan Mishra', 'F', '7000000635', 'muskan.240700635@muj.manipal.edu', 7, 3, 13, '212', '2024-07-25'),
('260700636', 'Vanya Meena', 'F', '7000000636', 'vanya.260700636@muj.manipal.edu', 7, 1, 18, '225', '2026-07-30'),
('261100637', 'Ansh Khan', 'M', '7000000637', 'ansh.261100637@muj.manipal.edu', 11, 1, 4, '722', '2026-07-16'),
('230100638', 'Advait Yadav', 'M', '7000000638', 'advait.230100638@muj.manipal.edu', 1, 4, 5, '229', '2023-07-21'),
('230200639', 'Pranav Jain', 'M', '7000000639', 'pranav.230200639@muj.manipal.edu', 2, 4, 3, '430', '2023-07-24'),
('251200640', 'Nikhil Arora', 'M', '7000000640', 'nikhil.251200640@muj.manipal.edu', 12, 2, 2, '512', '2025-07-21'),
('250400641', 'Aditya Bansal', 'M', '7000000641', 'aditya.250400641@muj.manipal.edu', 4, 2, 10, '737', '2025-07-27'),
('240900642', 'Meera Sethi', 'F', '7000000642', 'meera.240900642@muj.manipal.edu', 9, 3, 19, '131', '2024-07-16'),
('261000643', 'Vanya Saxena', 'F', '7000000643', 'vanya.261000643@muj.manipal.edu', 10, 1, 21, '424', '2026-07-15'),
('230300644', 'Vihaan Shekhawat', 'M', '7000000644', 'vihaan.230300644@muj.manipal.edu', 3, 4, 12, '329', '2023-07-24'),
('251200645', 'Aditya Kapoor', 'M', '7000000645', 'aditya.251200645@muj.manipal.edu', 12, 2, 6, '604', '2025-07-28'),
('250500646', 'Harsh Ahmed', 'M', '7000000646', 'harsh.250500646@muj.manipal.edu', 5, 2, 9, '610', '2025-07-25'),
('250200647', 'Ansh Khanna', 'M', '7000000647', 'ansh.250200647@muj.manipal.edu', 2, 2, 4, '222', '2025-07-19'),
('260700648', 'Mahira Patel', 'F', '7000000648', 'mahira.260700648@muj.manipal.edu', 7, 1, 18, '239', '2026-07-29'),
('261200649', 'Riya Yadav', 'F', '7000000649', 'riya.261200649@muj.manipal.edu', 12, 1, 13, '523', '2026-07-21'),
('250100650', 'Siddharth Shekhawat', 'M', '7000000650', 'siddharth.250100650@muj.manipal.edu', 1, 2, 1, '508', '2025-07-19'),
('261200651', 'Advait Sharma', 'M', '7000000651', 'advait.261200651@muj.manipal.edu', 12, 1, 6, '831', '2026-07-18'),
('230100652', 'Kunal Arora', 'M', '7000000652', 'kunal.230100652@muj.manipal.edu', 1, 4, 4, '401', '2023-07-20'),
('230600653', 'Anvi Rao', 'F', '7000000653', 'anvi.230600653@muj.manipal.edu', 6, 4, 13, '240', '2023-07-29'),
('260500654', 'Reyansh Deshpande', 'M', '7000000654', 'reyansh.260500654@muj.manipal.edu', 5, 1, 8, '508', '2026-07-29'),
('260700655', 'Rahul Choudhary', 'M', '7000000655', 'rahul.260700655@muj.manipal.edu', 7, 1, 7, '605', '2026-07-18'),
('230400656', 'Myra Bose', 'F', '7000000656', 'myra.230400656@muj.manipal.edu', 4, 4, 14, '940', '2023-07-15'),
('260700657', 'Ritvik Patel', 'M', '7000000657', 'ritvik.260700657@muj.manipal.edu', 7, 1, 6, '709', '2026-07-22'),
('260200658', 'Sara Choudhary', 'F', '7000000658', 'sara.260200658@muj.manipal.edu', 2, 1, 20, '724', '2026-07-30'),
('250200659', 'Meera Rathore', 'F', '7000000659', 'meera.250200659@muj.manipal.edu', 2, 2, 18, '609', '2025-07-23'),
('240200660', 'Neha Khan', 'F', '7000000660', 'neha.240200660@muj.manipal.edu', 2, 3, 18, '930', '2024-07-24'),
('261100661', 'Advait Jain', 'M', '7000000661', 'advait.261100661@muj.manipal.edu', 11, 1, 10, '818', '2026-07-20'),
('251200662', 'Pooja Bansal', 'F', '7000000662', 'pooja.251200662@muj.manipal.edu', 12, 2, 16, '839', '2025-07-24'),
('260100663', 'Aditya Nair', 'M', '7000000663', 'aditya.260100663@muj.manipal.edu', 1, 1, 11, '128', '2026-07-20'),
('250900664', 'Nisha Bhatia', 'F', '7000000664', 'nisha.250900664@muj.manipal.edu', 9, 2, 17, '433', '2025-07-29'),
('240600665', 'Aditi Verma', 'F', '7000000665', 'aditi.240600665@muj.manipal.edu', 6, 3, 14, '135', '2024-07-27'),
('250100666', 'Parth Arora', 'M', '7000000666', 'parth.250100666@muj.manipal.edu', 1, 2, 9, '718', '2025-07-15'),
('261100667', 'Vihaan Bhatia', 'M', '7000000667', 'vihaan.261100667@muj.manipal.edu', 11, 1, 6, '608', '2026-07-15'),
('250800668', 'Dev Kapoor', 'M', '7000000668', 'dev.250800668@muj.manipal.edu', 8, 2, 10, '337', '2025-07-29'),
('251200669', 'Parth Khanna', 'M', '7000000669', 'parth.251200669@muj.manipal.edu', 12, 2, 12, '636', '2025-07-28'),
('260100670', 'Saanvi Khanna', 'F', '7000000670', 'saanvi.260100670@muj.manipal.edu', 1, 1, 20, '505', '2026-07-17'),
('230100671', 'Ayaan Jain', 'M', '7000000671', 'ayaan.230100671@muj.manipal.edu', 1, 4, 3, '937', '2023-07-24'),
('250700672', 'Pranav Das', 'M', '7000000672', 'pranav.250700672@muj.manipal.edu', 7, 2, 11, '207', '2025-07-31'),
('230100673', 'Ritvik Das', 'M', '7000000673', 'ritvik.230100673@muj.manipal.edu', 1, 4, 7, '433', '2023-07-25'),
('251100674', 'Sara Goyal', 'F', '7000000674', 'sara.251100674@muj.manipal.edu', 11, 2, 16, '826', '2025-07-29'),
('250300675', 'Aniket Verma', 'M', '7000000675', 'aniket.250300675@muj.manipal.edu', 3, 2, 3, '306', '2025-07-22'),
('250100676', 'Varun Meena', 'M', '7000000676', 'varun.250100676@muj.manipal.edu', 1, 2, 10, '109', '2025-07-15'),
('251000677', 'Arjun Iyer', 'M', '7000000677', 'arjun.251000677@muj.manipal.edu', 10, 2, 3, '716', '2025-07-31'),
('240100678', 'Tanmay Choudhary', 'M', '7000000678', 'tanmay.240100678@muj.manipal.edu', 1, 3, 2, '415', '2024-07-19'),
('250400679', 'Nisha Patel', 'F', '7000000679', 'nisha.250400679@muj.manipal.edu', 4, 2, 14, '638', '2025-07-17'),
('240100680', 'Atharv Kapoor', 'M', '7000000680', 'atharv.240100680@muj.manipal.edu', 1, 3, 10, '413', '2024-07-21'),
('230100681', 'Nikhil Ahmed', 'M', '7000000681', 'nikhil.230100681@muj.manipal.edu', 1, 4, 7, '120', '2023-07-15'),
('240400682', 'Zoya Sethi', 'F', '7000000682', 'zoya.240400682@muj.manipal.edu', 4, 3, 16, '127', '2024-07-19'),
('230100683', 'Arjun Ahmed', 'M', '7000000683', 'arjun.230100683@muj.manipal.edu', 1, 4, 10, '224', '2023-07-18'),
('230200684', 'Naina Banerjee', 'F', '7000000684', 'naina.230200684@muj.manipal.edu', 2, 4, 21, '503', '2023-07-17'),
('250800685', 'Advait Iyer', 'M', '7000000685', 'advait.250800685@muj.manipal.edu', 8, 2, 10, '621', '2025-07-16'),
('241000686', 'Navya Verma', 'F', '7000000686', 'navya.241000686@muj.manipal.edu', 10, 3, 14, '517', '2024-07-21'),
('240600687', 'Aditi Bose', 'F', '7000000687', 'aditi.240600687@muj.manipal.edu', 6, 3, 18, '933', '2024-07-24'),
('250300688', 'Shreya Malhotra', 'F', '7000000688', 'shreya.250300688@muj.manipal.edu', 3, 2, 20, '421', '2025-07-29'),
('240100689', 'Pranav Kapoor', 'M', '7000000689', 'pranav.240100689@muj.manipal.edu', 1, 3, 11, '607', '2024-07-17'),
('230500690', 'Lakshya Rao', 'M', '7000000690', 'lakshya.230500690@muj.manipal.edu', 5, 4, 2, '511', '2023-07-15'),
('250300691', 'Rahul Shekhawat', 'M', '7000000691', 'rahul.250300691@muj.manipal.edu', 3, 2, 5, '516', '2025-07-26'),
('230100692', 'Tanvi Rathore', 'F', '7000000692', 'tanvi.230100692@muj.manipal.edu', 1, 4, 18, '112', '2023-07-27'),
('250100693', 'Ritvik Khan', 'M', '7000000693', 'ritvik.250100693@muj.manipal.edu', 1, 2, 1, '617', '2025-07-28'),
('260800694', 'Manav Mukherjee', 'M', '7000000694', 'manav.260800694@muj.manipal.edu', 8, 1, 4, '935', '2026-07-16'),
('260900695', 'Aisha Jain', 'F', '7000000695', 'aisha.260900695@muj.manipal.edu', 9, 1, 16, '424', '2026-07-27'),
('230300696', 'Kiara Bhatia', 'F', '7000000696', 'kiara.230300696@muj.manipal.edu', 3, 4, 16, '210', '2023-07-17'),
('260800697', 'Aarohi Kulkarni', 'F', '7000000697', 'aarohi.260800697@muj.manipal.edu', 8, 1, 22, '127', '2026-07-15'),
('240500698', 'Arjun Mehta', 'M', '7000000698', 'arjun.240500698@muj.manipal.edu', 5, 3, 5, '736', '2024-07-16'),
('230100699', 'Meera Bhatia', 'F', '7000000699', 'meera.230100699@muj.manipal.edu', 1, 4, 21, '536', '2023-07-20'),
('230100700', 'Varun Jain', 'M', '7000000700', 'varun.230100700@muj.manipal.edu', 1, 4, 8, '209', '2023-07-18'),
('240100701', 'Kiara Patel', 'F', '7000000701', 'kiara.240100701@muj.manipal.edu', 1, 3, 16, '319', '2024-07-28'),
('250200702', 'Tanvi Yadav', 'F', '7000000702', 'tanvi.250200702@muj.manipal.edu', 2, 2, 21, '614', '2025-07-27'),
('250800703', 'Reyansh Iyer', 'M', '7000000703', 'reyansh.250800703@muj.manipal.edu', 8, 2, 6, '422', '2025-07-23'),
('251100704', 'Reyansh Rathore', 'M', '7000000704', 'reyansh.251100704@muj.manipal.edu', 11, 2, 8, '207', '2025-07-18'),
('250800705', 'Mahira Shah', 'F', '7000000705', 'mahira.250800705@muj.manipal.edu', 8, 2, 15, '933', '2025-07-30'),
('260200706', 'Ritvik Singh', 'M', '7000000706', 'ritvik.260200706@muj.manipal.edu', 2, 1, 2, '539', '2026-07-28'),
('240700707', 'Sneha Ahmed', 'F', '7000000707', 'sneha.240700707@muj.manipal.edu', 7, 3, 13, '623', '2024-07-18'),
('251100708', 'Reyansh Khan', 'M', '7000000708', 'reyansh.251100708@muj.manipal.edu', 11, 2, 10, '428', '2025-07-18'),
('260700709', 'Manav Mehta', 'M', '7000000709', 'manav.260700709@muj.manipal.edu', 7, 1, 3, '919', '2026-07-31'),
('250800710', 'Vivaan Joshi', 'M', '7000000710', 'vivaan.250800710@muj.manipal.edu', 8, 2, 6, '215', '2025-07-24'),
('250200711', 'Dhruv Mittal', 'M', '7000000711', 'dhruv.250200711@muj.manipal.edu', 2, 2, 2, '301', '2025-07-22'),
('260200712', 'Tara Tiwari', 'F', '7000000712', 'tara.260200712@muj.manipal.edu', 2, 1, 14, '118', '2026-07-26'),
('251100713', 'Aarohi Shekhawat', 'F', '7000000713', 'aarohi.251100713@muj.manipal.edu', 11, 2, 21, '839', '2025-07-27'),
('260100714', 'Veer Rathore', 'M', '7000000714', 'veer.260100714@muj.manipal.edu', 1, 1, 11, '725', '2026-07-15'),
('240800715', 'Aisha Gupta', 'F', '7000000715', 'aisha.240800715@muj.manipal.edu', 8, 3, 14, '439', '2024-07-20'),
('260200716', 'Harsh Das', 'M', '7000000716', 'harsh.260200716@muj.manipal.edu', 2, 1, 7, '123', '2026-07-18'),
('250500717', 'Riya Saxena', 'F', '7000000717', 'riya.250500717@muj.manipal.edu', 5, 2, 13, '719', '2025-07-25'),
('240600718', 'Arjun Rathore', 'M', '7000000718', 'arjun.240600718@muj.manipal.edu', 6, 3, 8, '938', '2024-07-27'),
('251200719', 'Rohan Meena', 'M', '7000000719', 'rohan.251200719@muj.manipal.edu', 12, 2, 1, '715', '2025-07-30'),
('260100720', 'Jiya Khanna', 'F', '7000000720', 'jiya.260100720@muj.manipal.edu', 1, 1, 16, '706', '2026-07-20'),
('260700721', 'Kavya Goyal', 'F', '7000000721', 'kavya.260700721@muj.manipal.edu', 7, 1, 13, '923', '2026-07-21'),
('230100722', 'Kunal Shekhawat', 'M', '7000000722', 'kunal.230100722@muj.manipal.edu', 1, 4, 9, '222', '2023-07-16'),
('240100723', 'Saanvi Bose', 'F', '7000000723', 'saanvi.240100723@muj.manipal.edu', 1, 3, 22, '608', '2024-07-30'),
('250700724', 'Dev Rao', 'M', '7000000724', 'dev.250700724@muj.manipal.edu', 7, 2, 8, '627', '2025-07-24'),
('250100725', 'Aarohi Nair', 'F', '7000000725', 'aarohi.250100725@muj.manipal.edu', 1, 2, 21, '504', '2025-07-20'),
('250100726', 'Aditya Ahmed', 'M', '7000000726', 'aditya.250100726@muj.manipal.edu', 1, 2, 11, '718', '2025-07-20'),
('240900727', 'Aisha Kapoor', 'F', '7000000727', 'aisha.240900727@muj.manipal.edu', 9, 3, 21, '828', '2024-07-17'),
('260200728', 'Karan Pandey', 'M', '7000000728', 'karan.260200728@muj.manipal.edu', 2, 1, 8, '725', '2026-07-30'),
('240200729', 'Rudra Mehta', 'M', '7000000729', 'rudra.240200729@muj.manipal.edu', 2, 3, 6, '522', '2024-07-26'),
('230100730', 'Simran Shah', 'F', '7000000730', 'simran.230100730@muj.manipal.edu', 1, 4, 22, '301', '2023-07-27'),
('260100731', 'Ishaan Mukherjee', 'M', '7000000731', 'ishaan.260100731@muj.manipal.edu', 1, 1, 11, '502', '2026-07-16'),
('260100732', 'Arjun Goyal', 'M', '7000000732', 'arjun.260100732@muj.manipal.edu', 1, 1, 5, '733', '2026-07-15'),
('250200733', 'Reyansh Goyal', 'M', '7000000733', 'reyansh.250200733@muj.manipal.edu', 2, 2, 1, '819', '2025-07-25'),
('251100734', 'Simran Yadav', 'F', '7000000734', 'simran.251100734@muj.manipal.edu', 11, 2, 18, '318', '2025-07-16'),
('240800735', 'Divya Mehta', 'F', '7000000735', 'divya.240800735@muj.manipal.edu', 8, 3, 16, '125', '2024-07-18'),
('260100736', 'Ira Bhatia', 'F', '7000000736', 'ira.260100736@muj.manipal.edu', 1, 1, 15, '521', '2026-07-26'),
('230900737', 'Shaurya Khan', 'M', '7000000737', 'shaurya.230900737@muj.manipal.edu', 9, 4, 12, '622', '2023-07-29'),
('240200738', 'Krishna Jain', 'M', '7000000738', 'krishna.240200738@muj.manipal.edu', 2, 3, 5, '515', '2024-07-22'),
('230200739', 'Vivaan Malhotra', 'M', '7000000739', 'vivaan.230200739@muj.manipal.edu', 2, 4, 12, '326', '2023-07-28'),
('250300740', 'Ayaan Bose', 'M', '7000000740', 'ayaan.250300740@muj.manipal.edu', 3, 2, 2, '711', '2025-07-24'),
('230100741', 'Riya Bansal', 'F', '7000000741', 'riya.230100741@muj.manipal.edu', 1, 4, 16, '609', '2023-07-15'),
('230600742', 'Kiara Bose', 'F', '7000000742', 'kiara.230600742@muj.manipal.edu', 6, 4, 20, '909', '2023-07-17'),
('250100743', 'Muskan Deshpande', 'F', '7000000743', 'muskan.250100743@muj.manipal.edu', 1, 2, 18, '824', '2025-07-16'),
('250200744', 'Jiya Sharma', 'F', '7000000744', 'jiya.250200744@muj.manipal.edu', 2, 2, 13, '313', '2025-07-19'),
('240800745', 'Anika Reddy', 'F', '7000000745', 'anika.240800745@muj.manipal.edu', 8, 3, 13, '110', '2024-07-16'),
('230100746', 'Manav Sharma', 'M', '7000000746', 'manav.230100746@muj.manipal.edu', 1, 4, 6, '337', '2023-07-20'),
('240300747', 'Reyansh Bhatia', 'M', '7000000747', 'reyansh.240300747@muj.manipal.edu', 3, 3, 9, '407', '2024-07-20'),
('240100748', 'Myra Deshpande', 'F', '7000000748', 'myra.240100748@muj.manipal.edu', 1, 3, 13, '824', '2024-07-27'),
('230100749', 'Rohan Shekhawat', 'M', '7000000749', 'rohan.230100749@muj.manipal.edu', 1, 4, 9, '308', '2023-07-16'),
('240100750', 'Aarav Mukherjee', 'M', '7000000750', 'aarav.240100750@muj.manipal.edu', 1, 3, 2, '623', '2024-07-22'),
('240100751', 'Muskan Jain', 'F', '7000000751', 'muskan.240100751@muj.manipal.edu', 1, 3, 13, '623', '2024-07-23'),
('230200752', 'Ayaan Kulkarni', 'M', '7000000752', 'ayaan.230200752@muj.manipal.edu', 2, 4, 6, '829', '2023-07-20'),
('250200753', 'Manav Kulkarni', 'M', '7000000753', 'manav.250200753@muj.manipal.edu', 2, 2, 5, '925', '2025-07-30'),
('230100754', 'Shreya Mehta', 'F', '7000000754', 'shreya.230100754@muj.manipal.edu', 1, 4, 16, '732', '2023-07-19'),
('260100755', 'Aisha Sethi', 'F', '7000000755', 'aisha.260100755@muj.manipal.edu', 1, 1, 18, '833', '2026-07-23'),
('260300756', 'Anika Banerjee', 'F', '7000000756', 'anika.260300756@muj.manipal.edu', 3, 1, 15, '531', '2026-07-20'),
('230200757', 'Pranav Shekhawat', 'M', '7000000757', 'pranav.230200757@muj.manipal.edu', 2, 4, 9, '540', '2023-07-23'),
('250300758', 'Harsh Jain', 'M', '7000000758', 'harsh.250300758@muj.manipal.edu', 3, 2, 11, '117', '2025-07-28'),
('240300759', 'Dhruv Gupta', 'M', '7000000759', 'dhruv.240300759@muj.manipal.edu', 3, 3, 11, '522', '2024-07-16'),
('240400760', 'Riya Kapoor', 'F', '7000000760', 'riya.240400760@muj.manipal.edu', 4, 3, 17, '630', '2024-07-29'),
('250100761', 'Atharv Sharma', 'M', '7000000761', 'atharv.250100761@muj.manipal.edu', 1, 2, 12, '811', '2025-07-25'),
('240100762', 'Yash Deshpande', 'M', '7000000762', 'yash.240100762@muj.manipal.edu', 1, 3, 4, '917', '2024-07-15'),
('250500763', 'Atharv Saxena', 'M', '7000000763', 'atharv.250500763@muj.manipal.edu', 5, 2, 11, '240', '2025-07-21'),
('240800764', 'Kunal Saxena', 'M', '7000000764', 'kunal.240800764@muj.manipal.edu', 8, 3, 11, '116', '2024-07-21'),
('230300765', 'Ira Patel', 'F', '7000000765', 'ira.230300765@muj.manipal.edu', 3, 4, 19, '914', '2023-07-21'),
('240100766', 'Pari Ahmed', 'F', '7000000766', 'pari.240100766@muj.manipal.edu', 1, 3, 19, '929', '2024-07-18'),
('260100767', 'Shaurya Reddy', 'M', '7000000767', 'shaurya.260100767@muj.manipal.edu', 1, 1, 12, '515', '2026-07-16'),
('250100768', 'Riya Choudhary', 'F', '7000000768', 'riya.250100768@muj.manipal.edu', 1, 2, 13, '224', '2025-07-24'),
('240200769', 'Pooja Gupta', 'F', '7000000769', 'pooja.240200769@muj.manipal.edu', 2, 3, 18, '103', '2024-07-20'),
('240700770', 'Om Choudhary', 'M', '7000000770', 'om.240700770@muj.manipal.edu', 7, 3, 9, '711', '2024-07-25'),
('231000771', 'Aditi Choudhary', 'F', '7000000771', 'aditi.231000771@muj.manipal.edu', 10, 4, 22, '901', '2023-07-22'),
('240100772', 'Divya Agarwal', 'F', '7000000772', 'divya.240100772@muj.manipal.edu', 1, 3, 14, '519', '2024-07-26'),
('261100773', 'Varun Mehta', 'M', '7000000773', 'varun.261100773@muj.manipal.edu', 11, 1, 10, '137', '2026-07-24'),
('230100774', 'Vihaan Deshpande', 'M', '7000000774', 'vihaan.230100774@muj.manipal.edu', 1, 4, 5, '208', '2023-07-18'),
('230500775', 'Shreya Saxena', 'F', '7000000775', 'shreya.230500775@muj.manipal.edu', 5, 4, 18, '402', '2023-07-25'),
('250100776', 'Isha Rathore', 'F', '7000000776', 'isha.250100776@muj.manipal.edu', 1, 2, 14, '501', '2025-07-21'),
('240200777', 'Ishaan Saxena', 'M', '7000000777', 'ishaan.240200777@muj.manipal.edu', 2, 3, 8, '303', '2024-07-30'),
('250800778', 'Khushi Gupta', 'F', '7000000778', 'khushi.250800778@muj.manipal.edu', 8, 2, 14, '114', '2025-07-22'),
('251100779', 'Parth Yadav', 'M', '7000000779', 'parth.251100779@muj.manipal.edu', 11, 2, 8, '210', '2025-07-17'),
('261100780', 'Tanmay Choudhary', 'M', '7000000780', 'tanmay.261100780@muj.manipal.edu', 11, 1, 7, '112', '2026-07-27'),
('230100781', 'Parth Mishra', 'M', '7000000781', 'parth.230100781@muj.manipal.edu', 1, 4, 7, '132', '2023-07-27'),
('250100782', 'Advait Patel', 'M', '7000000782', 'advait.250100782@muj.manipal.edu', 1, 2, 8, '504', '2025-07-28'),
('230400783', 'Sara Mukherjee', 'F', '7000000783', 'sara.230400783@muj.manipal.edu', 4, 4, 19, '936', '2023-07-24'),
('261100784', 'Kiara Yadav', 'F', '7000000784', 'kiara.261100784@muj.manipal.edu', 11, 1, 19, '901', '2026-07-29'),
('260300785', 'Pooja Kapoor', 'F', '7000000785', 'pooja.260300785@muj.manipal.edu', 3, 1, 15, '512', '2026-07-29'),
('240200786', 'Vihaan Arora', 'M', '7000000786', 'vihaan.240200786@muj.manipal.edu', 2, 3, 12, '833', '2024-07-24'),
('240500787', 'Aniket Bansal', 'M', '7000000787', 'aniket.240500787@muj.manipal.edu', 5, 3, 6, '729', '2024-07-17'),
('240200788', 'Aditya Patel', 'M', '7000000788', 'aditya.240200788@muj.manipal.edu', 2, 3, 7, '303', '2024-07-27'),
('260100789', 'Vanya Shekhawat', 'F', '7000000789', 'vanya.260100789@muj.manipal.edu', 1, 1, 14, '705', '2026-07-21'),
('250100790', 'Khushi Rathore', 'F', '7000000790', 'khushi.250100790@muj.manipal.edu', 1, 2, 15, '329', '2025-07-28'),
('240100791', 'Shaurya Das', 'M', '7000000791', 'shaurya.240100791@muj.manipal.edu', 1, 3, 5, '635', '2024-07-16'),
('250500792', 'Reyansh Mittal', 'M', '7000000792', 'reyansh.250500792@muj.manipal.edu', 5, 2, 10, '616', '2025-07-28'),
('260400793', 'Jiya Bhatia', 'F', '7000000793', 'jiya.260400793@muj.manipal.edu', 4, 1, 13, '518', '2026-07-22'),
('250400794', 'Mihir Reddy', 'M', '7000000794', 'mihir.250400794@muj.manipal.edu', 4, 2, 9, '739', '2025-07-21'),
('230300795', 'Pooja Patel', 'F', '7000000795', 'pooja.230300795@muj.manipal.edu', 3, 4, 14, '336', '2023-07-22'),
('230100796', 'Zoya Jain', 'F', '7000000796', 'zoya.230100796@muj.manipal.edu', 1, 4, 18, '903', '2023-07-16'),
('250600797', 'Aisha Rao', 'F', '7000000797', 'aisha.250600797@muj.manipal.edu', 6, 2, 21, '733', '2025-07-31'),
('261100798', 'Sai Pandey', 'M', '7000000798', 'sai.261100798@muj.manipal.edu', 11, 1, 5, '907', '2026-07-15'),
('240800799', 'Aryan Verma', 'M', '7000000799', 'aryan.240800799@muj.manipal.edu', 8, 3, 7, '124', '2024-07-24'),
('240700800', 'Krishna Sharma', 'M', '7000000800', 'krishna.240700800@muj.manipal.edu', 7, 3, 3, '110', '2024-07-16'),
('230100801', 'Kiara Pandey', 'F', '7000000801', 'kiara.230100801@muj.manipal.edu', 1, 4, 18, '329', '2023-07-30'),
('230200802', 'Parth Rao', 'M', '7000000802', 'parth.230200802@muj.manipal.edu', 2, 4, 10, '526', '2023-07-29'),
('260200803', 'Avni Rathore', 'F', '7000000803', 'avni.260200803@muj.manipal.edu', 2, 1, 16, '421', '2026-07-20'),
('260100804', 'Dev Rao', 'M', '7000000804', 'dev.260100804@muj.manipal.edu', 1, 1, 5, '140', '2026-07-27'),
('260800805', 'Kabir Jain', 'M', '7000000805', 'kabir.260800805@muj.manipal.edu', 8, 1, 10, '416', '2026-07-27'),
('261000806', 'Harsh Shah', 'M', '7000000806', 'harsh.261000806@muj.manipal.edu', 10, 1, 9, '637', '2026-07-17'),
('260700807', 'Parth Banerjee', 'M', '7000000807', 'parth.260700807@muj.manipal.edu', 7, 1, 2, '906', '2026-07-26'),
('260900808', 'Arjun Mittal', 'M', '7000000808', 'arjun.260900808@muj.manipal.edu', 9, 1, 10, '530', '2026-07-15'),
('250800809', 'Ira Sharma', 'F', '7000000809', 'ira.250800809@muj.manipal.edu', 8, 2, 22, '716', '2025-07-22'),
('230600810', 'Navya Goyal', 'F', '7000000810', 'navya.230600810@muj.manipal.edu', 6, 4, 22, '125', '2023-07-26'),
('261200811', 'Ritvik Joshi', 'M', '7000000811', 'ritvik.261200811@muj.manipal.edu', 12, 1, 1, '140', '2026-07-26'),
('250300812', 'Vanya Yadav', 'F', '7000000812', 'vanya.250300812@muj.manipal.edu', 3, 2, 20, '825', '2025-07-28'),
('260400813', 'Pranav Bose', 'M', '7000000813', 'pranav.260400813@muj.manipal.edu', 4, 1, 4, '632', '2026-07-15'),
('260100814', 'Om Khan', 'M', '7000000814', 'om.260100814@muj.manipal.edu', 1, 1, 6, '938', '2026-07-17'),
('260200815', 'Yash Khanna', 'M', '7000000815', 'yash.260200815@muj.manipal.edu', 2, 1, 5, '238', '2026-07-19'),
('250800816', 'Ishita Saxena', 'F', '7000000816', 'ishita.250800816@muj.manipal.edu', 8, 2, 13, '120', '2025-07-26'),
('260200817', 'Pranav Nair', 'M', '7000000817', 'pranav.260200817@muj.manipal.edu', 2, 1, 4, '414', '2026-07-31'),
('240100818', 'Ritvik Saxena', 'M', '7000000818', 'ritvik.240100818@muj.manipal.edu', 1, 3, 9, '506', '2024-07-25'),
('251100819', 'Veer Das', 'M', '7000000819', 'veer.251100819@muj.manipal.edu', 11, 2, 8, '736', '2025-07-15'),
('230100820', 'Ira Shah', 'F', '7000000820', 'ira.230100820@muj.manipal.edu', 1, 4, 22, '523', '2023-07-28'),
('250100821', 'Advait Mittal', 'M', '7000000821', 'advait.250100821@muj.manipal.edu', 1, 2, 6, '816', '2025-07-31'),
('240900822', 'Om Tiwari', 'M', '7000000822', 'om.240900822@muj.manipal.edu', 9, 3, 8, '219', '2024-07-30'),
('260700823', 'Arjun Rao', 'M', '7000000823', 'arjun.260700823@muj.manipal.edu', 7, 1, 8, '621', '2026-07-30'),
('260800824', 'Shaurya Bhatia', 'M', '7000000824', 'shaurya.260800824@muj.manipal.edu', 8, 1, 2, '206', '2026-07-25'),
('260100825', 'Zoya Patel', 'F', '7000000825', 'zoya.260100825@muj.manipal.edu', 1, 1, 22, '633', '2026-07-24'),
('240500826', 'Diya Arora', 'F', '7000000826', 'diya.240500826@muj.manipal.edu', 5, 3, 19, '817', '2024-07-30'),
('260800827', 'Naina Saxena', 'F', '7000000827', 'naina.260800827@muj.manipal.edu', 8, 1, 20, '434', '2026-07-26'),
('230200828', 'Krishna Nair', 'M', '7000000828', 'krishna.230200828@muj.manipal.edu', 2, 4, 11, '429', '2023-07-23'),
('260800829', 'Simran Rathore', 'F', '7000000829', 'simran.260800829@muj.manipal.edu', 8, 1, 14, '138', '2026-07-19'),
('240800830', 'Advik Tiwari', 'M', '7000000830', 'advik.240800830@muj.manipal.edu', 8, 3, 7, '318', '2024-07-27'),
('260100831', 'Dhruv Deshpande', 'M', '7000000831', 'dhruv.260100831@muj.manipal.edu', 1, 1, 8, '814', '2026-07-26'),
('260500832', 'Om Bhatia', 'M', '7000000832', 'om.260500832@muj.manipal.edu', 5, 1, 6, '226', '2026-07-16'),
('250100833', 'Sara Kapoor', 'F', '7000000833', 'sara.250100833@muj.manipal.edu', 1, 2, 21, '719', '2025-07-31'),
('240100834', 'Pooja Arora', 'F', '7000000834', 'pooja.240100834@muj.manipal.edu', 1, 3, 14, '217', '2024-07-16'),
('260300835', 'Ananya Deshpande', 'F', '7000000835', 'ananya.260300835@muj.manipal.edu', 3, 1, 21, '438', '2026-07-30'),
('230400836', 'Dev Iyer', 'M', '7000000836', 'dev.230400836@muj.manipal.edu', 4, 4, 1, '326', '2023-07-28'),
('250100837', 'Karan Singh', 'M', '7000000837', 'karan.250100837@muj.manipal.edu', 1, 2, 2, '232', '2025-07-23'),
('230100838', 'Saanvi Tiwari', 'F', '7000000838', 'saanvi.230100838@muj.manipal.edu', 1, 4, 18, '414', '2023-07-29'),
('250800839', 'Aarav Choudhary', 'M', '7000000839', 'aarav.250800839@muj.manipal.edu', 8, 2, 5, '220', '2025-07-21'),
('260100840', 'Kavya Nair', 'F', '7000000840', 'kavya.260100840@muj.manipal.edu', 1, 1, 19, '637', '2026-07-20'),
('260800841', 'Reyansh Saxena', 'M', '7000000841', 'reyansh.260800841@muj.manipal.edu', 8, 1, 8, '836', '2026-07-27'),
('230100842', 'Kunal Mittal', 'M', '7000000842', 'kunal.230100842@muj.manipal.edu', 1, 4, 7, '926', '2023-07-23'),
('250600843', 'Muskan Kulkarni', 'F', '7000000843', 'muskan.250600843@muj.manipal.edu', 6, 2, 20, '706', '2025-07-18'),
('250700844', 'Rudra Yadav', 'M', '7000000844', 'rudra.250700844@muj.manipal.edu', 7, 2, 3, '118', '2025-07-16'),
('250700845', 'Anika Patel', 'F', '7000000845', 'anika.250700845@muj.manipal.edu', 7, 2, 13, '606', '2025-07-23'),
('230100846', 'Arjun Bose', 'M', '7000000846', 'arjun.230100846@muj.manipal.edu', 1, 4, 7, '633', '2023-07-30'),
('261100847', 'Ishaan Sharma', 'M', '7000000847', 'ishaan.261100847@muj.manipal.edu', 11, 1, 8, '703', '2026-07-25'),
('231000848', 'Tanmay Reddy', 'M', '7000000848', 'tanmay.231000848@muj.manipal.edu', 10, 4, 8, '839', '2023-07-29'),
('230400849', 'Avni Choudhary', 'F', '7000000849', 'avni.230400849@muj.manipal.edu', 4, 4, 20, '301', '2023-07-20'),
('230500850', 'Aditi Banerjee', 'F', '7000000850', 'aditi.230500850@muj.manipal.edu', 5, 4, 18, '309', '2023-07-23'),
('250800851', 'Harsh Nair', 'M', '7000000851', 'harsh.250800851@muj.manipal.edu', 8, 2, 10, '515', '2025-07-31'),
('260100852', 'Navya Joshi', 'F', '7000000852', 'navya.260100852@muj.manipal.edu', 1, 1, 21, '328', '2026-07-15'),
('251000853', 'Saanvi Khan', 'F', '7000000853', 'saanvi.251000853@muj.manipal.edu', 10, 2, 14, '216', '2025-07-17'),
('230300854', 'Atharv Bose', 'M', '7000000854', 'atharv.230300854@muj.manipal.edu', 3, 4, 4, '613', '2023-07-27'),
('240100855', 'Avni Shekhawat', 'F', '7000000855', 'avni.240100855@muj.manipal.edu', 1, 3, 13, '304', '2024-07-30'),
('240400856', 'Sara Meena', 'F', '7000000856', 'sara.240400856@muj.manipal.edu', 4, 3, 19, '521', '2024-07-17'),
('230600857', 'Shreya Nair', 'F', '7000000857', 'shreya.230600857@muj.manipal.edu', 6, 4, 13, '212', '2023-07-22'),
('260900858', 'Advait Rathore', 'M', '7000000858', 'advait.260900858@muj.manipal.edu', 9, 1, 11, '814', '2026-07-28'),
('240200859', 'Advik Kulkarni', 'M', '7000000859', 'advik.240200859@muj.manipal.edu', 2, 3, 12, '923', '2024-07-21'),
('240700860', 'Dhruv Pandey', 'M', '7000000860', 'dhruv.240700860@muj.manipal.edu', 7, 3, 1, '512', '2024-07-18'),
('240200861', 'Vivaan Shekhawat', 'M', '7000000861', 'vivaan.240200861@muj.manipal.edu', 2, 3, 11, '333', '2024-07-21'),
('260100862', 'Dhruv Joshi', 'M', '7000000862', 'dhruv.260100862@muj.manipal.edu', 1, 1, 7, '625', '2026-07-17'),
('260500863', 'Ayaan Patel', 'M', '7000000863', 'ayaan.260500863@muj.manipal.edu', 5, 1, 3, '727', '2026-07-27'),
('241000864', 'Tara Arora', 'F', '7000000864', 'tara.241000864@muj.manipal.edu', 10, 3, 17, '410', '2024-07-22'),
('241000865', 'Jiya Saxena', 'F', '7000000865', 'jiya.241000865@muj.manipal.edu', 10, 3, 22, '210', '2024-07-26'),
('230100866', 'Veer Gupta', 'M', '7000000866', 'veer.230100866@muj.manipal.edu', 1, 4, 10, '515', '2023-07-23'),
('230300867', 'Ananya Deshpande', 'F', '7000000867', 'ananya.230300867@muj.manipal.edu', 3, 4, 17, '722', '2023-07-23'),
('250100868', 'Sara Bose', 'F', '7000000868', 'sara.250100868@muj.manipal.edu', 1, 2, 13, '818', '2025-07-28'),
('240100869', 'Kunal Banerjee', 'M', '7000000869', 'kunal.240100869@muj.manipal.edu', 1, 3, 11, '436', '2024-07-26'),
('250800870', 'Advik Das', 'M', '7000000870', 'advik.250800870@muj.manipal.edu', 8, 2, 8, '435', '2025-07-23'),
('230100871', 'Karan Rao', 'M', '7000000871', 'karan.230100871@muj.manipal.edu', 1, 4, 1, '518', '2023-07-25'),
('250700872', 'Riya Pandey', 'F', '7000000872', 'riya.250700872@muj.manipal.edu', 7, 2, 20, '408', '2025-07-29'),
('240200873', 'Sai Ahmed', 'M', '7000000873', 'sai.240200873@muj.manipal.edu', 2, 3, 4, '911', '2024-07-18'),
('230200874', 'Rohan Mishra', 'M', '7000000874', 'rohan.230200874@muj.manipal.edu', 2, 4, 12, '524', '2023-07-17'),
('250900875', 'Navya Verma', 'F', '7000000875', 'navya.250900875@muj.manipal.edu', 9, 2, 19, '238', '2025-07-25'),
('260800876', 'Pooja Verma', 'F', '7000000876', 'pooja.260800876@muj.manipal.edu', 8, 1, 14, '803', '2026-07-20'),
('250100877', 'Arjun Tiwari', 'M', '7000000877', 'arjun.250100877@muj.manipal.edu', 1, 2, 6, '715', '2025-07-22'),
('250700878', 'Siya Bose', 'F', '7000000878', 'siya.250700878@muj.manipal.edu', 7, 2, 19, '721', '2025-07-26'),
('230200879', 'Prisha Banerjee', 'F', '7000000879', 'prisha.230200879@muj.manipal.edu', 2, 4, 14, '720', '2023-07-16'),
('260100880', 'Diya Sethi', 'F', '7000000880', 'diya.260100880@muj.manipal.edu', 1, 1, 19, '833', '2026-07-15'),
('261100881', 'Varun Shah', 'M', '7000000881', 'varun.261100881@muj.manipal.edu', 11, 1, 3, '531', '2026-07-29'),
('230200882', 'Simran Sethi', 'F', '7000000882', 'simran.230200882@muj.manipal.edu', 2, 4, 13, '205', '2023-07-17'),
('260700883', 'Aryan Agarwal', 'M', '7000000883', 'aryan.260700883@muj.manipal.edu', 7, 1, 8, '640', '2026-07-18'),
('260700884', 'Jiya Iyer', 'F', '7000000884', 'jiya.260700884@muj.manipal.edu', 7, 1, 13, '224', '2026-07-20'),
('260400885', 'Vanya Agarwal', 'F', '7000000885', 'vanya.260400885@muj.manipal.edu', 4, 1, 19, '706', '2026-07-27'),
('240200886', 'Karan Bose', 'M', '7000000886', 'karan.240200886@muj.manipal.edu', 2, 3, 4, '807', '2024-07-26'),
('251200887', 'Parth Kapoor', 'M', '7000000887', 'parth.251200887@muj.manipal.edu', 12, 2, 2, '311', '2025-07-30'),
('250800888', 'Rahul Jain', 'M', '7000000888', 'rahul.250800888@muj.manipal.edu', 8, 2, 7, '614', '2025-07-18'),
('230100889', 'Harsh Iyer', 'M', '7000000889', 'harsh.230100889@muj.manipal.edu', 1, 4, 9, '207', '2023-07-24'),
('260100890', 'Divya Bose', 'F', '7000000890', 'divya.260100890@muj.manipal.edu', 1, 1, 13, '113', '2026-07-24'),
('230200891', 'Rudra Banerjee', 'M', '7000000891', 'rudra.230200891@muj.manipal.edu', 2, 4, 2, '922', '2023-07-22'),
('250400892', 'Kabir Yadav', 'M', '7000000892', 'kabir.250400892@muj.manipal.edu', 4, 2, 3, '420', '2025-07-24'),
('240800893', 'Naina Arora', 'F', '7000000893', 'naina.240800893@muj.manipal.edu', 8, 3, 21, '419', '2024-07-18'),
('230500894', 'Ritvik Shekhawat', 'M', '7000000894', 'ritvik.230500894@muj.manipal.edu', 5, 4, 11, '405', '2023-07-15'),
('240600895', 'Siya Yadav', 'F', '7000000895', 'siya.240600895@muj.manipal.edu', 6, 3, 14, '130', '2024-07-30'),
('230100896', 'Kunal Meena', 'M', '7000000896', 'kunal.230100896@muj.manipal.edu', 1, 4, 11, '511', '2023-07-17'),
('250800897', 'Rudra Gupta', 'M', '7000000897', 'rudra.250800897@muj.manipal.edu', 8, 2, 11, '922', '2025-07-23'),
('250700898', 'Aniket Singh', 'M', '7000000898', 'aniket.250700898@muj.manipal.edu', 7, 2, 10, '209', '2025-07-22'),
('231000899', 'Mihir Agarwal', 'M', '7000000899', 'mihir.231000899@muj.manipal.edu', 10, 4, 11, '939', '2023-07-31'),
('260300900', 'Manav Mishra', 'M', '7000000900', 'manav.260300900@muj.manipal.edu', 3, 1, 3, '539', '2026-07-24'),
('240100901', 'Varun Patel', 'M', '7000000901', 'varun.240100901@muj.manipal.edu', 1, 3, 3, '826', '2024-07-24'),
('240300902', 'Rudra Mittal', 'M', '7000000902', 'rudra.240300902@muj.manipal.edu', 3, 3, 9, '935', '2024-07-31'),
('260400903', 'Navya Mishra', 'F', '7000000903', 'navya.260400903@muj.manipal.edu', 4, 1, 13, '927', '2026-07-20'),
('250600904', 'Zoya Kulkarni', 'F', '7000000904', 'zoya.250600904@muj.manipal.edu', 6, 2, 14, '235', '2025-07-21'),
('240100905', 'Lakshya Khan', 'M', '7000000905', 'lakshya.240100905@muj.manipal.edu', 1, 3, 11, '220', '2024-07-30'),
('230100906', 'Prisha Joshi', 'F', '7000000906', 'prisha.230100906@muj.manipal.edu', 1, 4, 18, '603', '2023-07-22'),
('230300907', 'Ayaan Goyal', 'M', '7000000907', 'ayaan.230300907@muj.manipal.edu', 3, 4, 9, '224', '2023-07-29'),
('250300908', 'Advait Das', 'M', '7000000908', 'advait.250300908@muj.manipal.edu', 3, 2, 1, '828', '2025-07-18'),
('250300909', 'Kabir Mittal', 'M', '7000000909', 'kabir.250300909@muj.manipal.edu', 3, 2, 7, '403', '2025-07-23'),
('250100910', 'Rudra Kapoor', 'M', '7000000910', 'rudra.250100910@muj.manipal.edu', 1, 2, 4, '304', '2025-07-26'),
('251100911', 'Shaurya Mehta', 'M', '7000000911', 'shaurya.251100911@muj.manipal.edu', 11, 2, 9, '419', '2025-07-22'),
('231000912', 'Sara Pandey', 'F', '7000000912', 'sara.231000912@muj.manipal.edu', 10, 4, 18, '404', '2023-07-16'),
('230200913', 'Varun Kapoor', 'M', '7000000913', 'varun.230200913@muj.manipal.edu', 2, 4, 11, '603', '2023-07-29'),
('250400914', 'Sai Kulkarni', 'M', '7000000914', 'sai.250400914@muj.manipal.edu', 4, 2, 8, '740', '2025-07-19'),
('260100915', 'Mihir Khanna', 'M', '7000000915', 'mihir.260100915@muj.manipal.edu', 1, 1, 8, '812', '2026-07-17'),
('250600916', 'Divya Goyal', 'F', '7000000916', 'divya.250600916@muj.manipal.edu', 6, 2, 18, '512', '2025-07-18'),
('240100917', 'Nikhil Banerjee', 'M', '7000000917', 'nikhil.240100917@muj.manipal.edu', 1, 3, 10, '518', '2024-07-24'),
('240100918', 'Ananya Iyer', 'F', '7000000918', 'ananya.240100918@muj.manipal.edu', 1, 3, 13, '914', '2024-07-21'),
('250800919', 'Reyansh Mukherjee', 'M', '7000000919', 'reyansh.250800919@muj.manipal.edu', 8, 2, 9, '422', '2025-07-22'),
('240100920', 'Mihir Pandey', 'M', '7000000920', 'mihir.240100920@muj.manipal.edu', 1, 3, 2, '311', '2024-07-23'),
('240800921', 'Naina Tiwari', 'F', '7000000921', 'naina.240800921@muj.manipal.edu', 8, 3, 18, '840', '2024-07-18'),
('240400922', 'Jiya Shekhawat', 'F', '7000000922', 'jiya.240400922@muj.manipal.edu', 4, 3, 13, '534', '2024-07-27'),
('230100923', 'Rohan Nair', 'M', '7000000923', 'rohan.230100923@muj.manipal.edu', 1, 4, 7, '736', '2023-07-27'),
('230100924', 'Ishita Mukherjee', 'F', '7000000924', 'ishita.230100924@muj.manipal.edu', 1, 4, 13, '128', '2023-07-27'),
('260800925', 'Diya Rathore', 'F', '7000000925', 'diya.260800925@muj.manipal.edu', 8, 1, 17, '423', '2026-07-24'),
('260600926', 'Veer Bose', 'M', '7000000926', 'veer.260600926@muj.manipal.edu', 6, 1, 8, '116', '2026-07-28'),
('251200927', 'Ayaan Sharma', 'M', '7000000927', 'ayaan.251200927@muj.manipal.edu', 12, 2, 4, '215', '2025-07-20'),
('250100928', 'Rudra Rao', 'M', '7000000928', 'rudra.250100928@muj.manipal.edu', 1, 2, 10, '802', '2025-07-21'),
('250800929', 'Kabir Khan', 'M', '7000000929', 'kabir.250800929@muj.manipal.edu', 8, 2, 2, '640', '2025-07-22'),
('250100930', 'Ananya Sethi', 'F', '7000000930', 'ananya.250100930@muj.manipal.edu', 1, 2, 18, '128', '2025-07-19'),
('260400931', 'Tanmay Bansal', 'M', '7000000931', 'tanmay.260400931@muj.manipal.edu', 4, 1, 10, '406', '2026-07-15'),
('230300932', 'Kabir Arora', 'M', '7000000932', 'kabir.230300932@muj.manipal.edu', 3, 4, 2, '137', '2023-07-22'),
('260100933', 'Simran Mukherjee', 'F', '7000000933', 'simran.260100933@muj.manipal.edu', 1, 1, 20, '101', '2026-07-17'),
('251100934', 'Advik Banerjee', 'M', '7000000934', 'advik.251100934@muj.manipal.edu', 11, 2, 1, '105', '2025-07-15'),
('261100935', 'Lakshya Choudhary', 'M', '7000000935', 'lakshya.261100935@muj.manipal.edu', 11, 1, 9, '419', '2026-07-15'),
('250600936', 'Avni Tiwari', 'F', '7000000936', 'avni.250600936@muj.manipal.edu', 6, 2, 13, '504', '2025-07-18'),
('230500937', 'Atharv Kulkarni', 'M', '7000000937', 'atharv.230500937@muj.manipal.edu', 5, 4, 5, '216', '2023-07-29'),
('230100938', 'Rohan Mehta', 'M', '7000000938', 'rohan.230100938@muj.manipal.edu', 1, 4, 12, '902', '2023-07-19'),
('260300939', 'Manav Choudhary', 'M', '7000000939', 'manav.260300939@muj.manipal.edu', 3, 1, 2, '120', '2026-07-21'),
('230100940', 'Veer Ahmed', 'M', '7000000940', 'veer.230100940@muj.manipal.edu', 1, 4, 1, '526', '2023-07-21'),
('240100941', 'Radhika Agarwal', 'F', '7000000941', 'radhika.240100941@muj.manipal.edu', 1, 3, 15, '505', '2024-07-31'),
('260100942', 'Anika Sethi', 'F', '7000000942', 'anika.260100942@muj.manipal.edu', 1, 1, 17, '108', '2026-07-18'),
('260100943', 'Shreya Bose', 'F', '7000000943', 'shreya.260100943@muj.manipal.edu', 1, 1, 20, '717', '2026-07-28'),
('240700944', 'Ayaan Khanna', 'M', '7000000944', 'ayaan.240700944@muj.manipal.edu', 7, 3, 5, '236', '2024-07-30'),
('260100945', 'Shreya Ahmed', 'F', '7000000945', 'shreya.260100945@muj.manipal.edu', 1, 1, 18, '140', '2026-07-25'),
('230100946', 'Aryan Kulkarni', 'M', '7000000946', 'aryan.230100946@muj.manipal.edu', 1, 4, 4, '510', '2023-07-21'),
('260100947', 'Dev Das', 'M', '7000000947', 'dev.260100947@muj.manipal.edu', 1, 1, 12, '808', '2026-07-19'),
('261100948', 'Vihaan Bose', 'M', '7000000948', 'vihaan.261100948@muj.manipal.edu', 11, 1, 7, '739', '2026-07-19'),
('260100949', 'Lakshya Ahmed', 'M', '7000000949', 'lakshya.260100949@muj.manipal.edu', 1, 1, 11, '519', '2026-07-24'),
('250400950', 'Reyansh Yadav', 'M', '7000000950', 'reyansh.250400950@muj.manipal.edu', 4, 2, 7, '131', '2025-07-23'),
('250300951', 'Aditya Khanna', 'M', '7000000951', 'aditya.250300951@muj.manipal.edu', 3, 2, 1, '820', '2025-07-23'),
('250500952', 'Myra Pandey', 'F', '7000000952', 'myra.250500952@muj.manipal.edu', 5, 2, 14, '912', '2025-07-31'),
('240500953', 'Anika Iyer', 'F', '7000000953', 'anika.240500953@muj.manipal.edu', 5, 3, 18, '226', '2024-07-30'),
('250700954', 'Mahira Kulkarni', 'F', '7000000954', 'mahira.250700954@muj.manipal.edu', 7, 2, 14, '426', '2025-07-17'),
('250100955', 'Krishna Yadav', 'M', '7000000955', 'krishna.250100955@muj.manipal.edu', 1, 2, 4, '621', '2025-07-17'),
('250400956', 'Siddharth Mishra', 'M', '7000000956', 'siddharth.250400956@muj.manipal.edu', 4, 2, 8, '406', '2025-07-28'),
('250800957', 'Ayaan Rao', 'M', '7000000957', 'ayaan.250800957@muj.manipal.edu', 8, 2, 6, '217', '2025-07-22'),
('250400958', 'Siddharth Mittal', 'M', '7000000958', 'siddharth.250400958@muj.manipal.edu', 4, 2, 7, '415', '2025-07-29'),
('261100959', 'Anika Bose', 'F', '7000000959', 'anika.261100959@muj.manipal.edu', 11, 1, 17, '611', '2026-07-16'),
('250600960', 'Siddharth Patel', 'M', '7000000960', 'siddharth.250600960@muj.manipal.edu', 6, 2, 7, '423', '2025-07-29'),
('260800961', 'Karan Khan', 'M', '7000000961', 'karan.260800961@muj.manipal.edu', 8, 1, 9, '508', '2026-07-22'),
('240600962', 'Sneha Saxena', 'F', '7000000962', 'sneha.240600962@muj.manipal.edu', 6, 3, 22, '123', '2024-07-20'),
('231000963', 'Harsh Bhatia', 'M', '7000000963', 'harsh.231000963@muj.manipal.edu', 10, 4, 4, '521', '2023-07-16'),
('261200964', 'Arnav Kapoor', 'M', '7000000964', 'arnav.261200964@muj.manipal.edu', 12, 1, 1, '210', '2026-07-27'),
('250400965', 'Sai Jain', 'M', '7000000965', 'sai.250400965@muj.manipal.edu', 4, 2, 6, '911', '2025-07-26'),
('240500966', 'Ishaan Meena', 'M', '7000000966', 'ishaan.240500966@muj.manipal.edu', 5, 3, 1, '903', '2024-07-20'),
('240100967', 'Khushi Jain', 'F', '7000000967', 'khushi.240100967@muj.manipal.edu', 1, 3, 15, '405', '2024-07-29'),
('250300968', 'Yash Patel', 'M', '7000000968', 'yash.250300968@muj.manipal.edu', 3, 2, 4, '431', '2025-07-23'),
('230100969', 'Kiara Ahmed', 'F', '7000000969', 'kiara.230100969@muj.manipal.edu', 1, 4, 21, '130', '2023-07-24'),
('250800970', 'Avni Kulkarni', 'F', '7000000970', 'avni.250800970@muj.manipal.edu', 8, 2, 13, '230', '2025-07-30'),
('250800971', 'Muskan Gupta', 'F', '7000000971', 'muskan.250800971@muj.manipal.edu', 8, 2, 14, '322', '2025-07-20'),
('260800972', 'Siddharth Yadav', 'M', '7000000972', 'siddharth.260800972@muj.manipal.edu', 8, 1, 11, '914', '2026-07-23'),
('250700973', 'Advik Agarwal', 'M', '7000000973', 'advik.250700973@muj.manipal.edu', 7, 2, 11, '816', '2025-07-28'),
('251100974', 'Reyansh Pandey', 'M', '7000000974', 'reyansh.251100974@muj.manipal.edu', 11, 2, 12, '630', '2025-07-28'),
('260800975', 'Rudra Bose', 'M', '7000000975', 'rudra.260800975@muj.manipal.edu', 8, 1, 5, '435', '2026-07-19'),
('261100976', 'Khushi Khanna', 'F', '7000000976', 'khushi.261100976@muj.manipal.edu', 11, 1, 17, '712', '2026-07-19'),
('240100977', 'Aniket Goyal', 'M', '7000000977', 'aniket.240100977@muj.manipal.edu', 1, 3, 12, '401', '2024-07-20'),
('260100978', 'Manav Bhatia', 'M', '7000000978', 'manav.260100978@muj.manipal.edu', 1, 1, 12, '736', '2026-07-21'),
('260600979', 'Kunal Bose', 'M', '7000000979', 'kunal.260600979@muj.manipal.edu', 6, 1, 6, '622', '2026-07-16'),
('250700980', 'Pooja Jain', 'F', '7000000980', 'pooja.250700980@muj.manipal.edu', 7, 2, 15, '238', '2025-07-28'),
('250200981', 'Ananya Saxena', 'F', '7000000981', 'ananya.250200981@muj.manipal.edu', 2, 2, 22, '706', '2025-07-23'),
('230500982', 'Mahira Rao', 'F', '7000000982', 'mahira.230500982@muj.manipal.edu', 5, 4, 18, '224', '2023-07-25'),
('240100983', 'Reyansh Rathore', 'M', '7000000983', 'reyansh.240100983@muj.manipal.edu', 1, 3, 5, '339', '2024-07-17'),
('230100984', 'Advait Khanna', 'M', '7000000984', 'advait.230100984@muj.manipal.edu', 1, 4, 10, '624', '2023-07-22'),
('260100985', 'Tanmay Kapoor', 'M', '7000000985', 'tanmay.260100985@muj.manipal.edu', 1, 1, 11, '802', '2026-07-20'),
('240700986', 'Khushi Sharma', 'F', '7000000986', 'khushi.240700986@muj.manipal.edu', 7, 3, 13, '338', '2024-07-27'),
('260700987', 'Shreya Verma', 'F', '7000000987', 'shreya.260700987@muj.manipal.edu', 7, 1, 13, '302', '2026-07-26'),
('240600988', 'Pooja Ahmed', 'F', '7000000988', 'pooja.240600988@muj.manipal.edu', 6, 3, 16, '515', '2024-07-21'),
('250500989', 'Manav Singh', 'M', '7000000989', 'manav.250500989@muj.manipal.edu', 5, 2, 5, '218', '2025-07-27'),
('240400990', 'Avni Sharma', 'F', '7000000990', 'avni.240400990@muj.manipal.edu', 4, 3, 21, '337', '2024-07-17'),
('260100991', 'Tara Meena', 'F', '7000000991', 'tara.260100991@muj.manipal.edu', 1, 1, 13, '407', '2026-07-20'),
('250500992', 'Advik Choudhary', 'M', '7000000992', 'advik.250500992@muj.manipal.edu', 5, 2, 1, '417', '2025-07-19'),
('251100993', 'Mihir Iyer', 'M', '7000000993', 'mihir.251100993@muj.manipal.edu', 11, 2, 7, '802', '2025-07-23'),
('250400994', 'Rohan Mukherjee', 'M', '7000000994', 'rohan.250400994@muj.manipal.edu', 4, 2, 11, '824', '2025-07-28'),
('260100995', 'Yash Nair', 'M', '7000000995', 'yash.260100995@muj.manipal.edu', 1, 1, 3, '113', '2026-07-29'),
('251200996', 'Isha Sharma', 'F', '7000000996', 'isha.251200996@muj.manipal.edu', 12, 2, 14, '618', '2025-07-20'),
('260300997', 'Isha Choudhary', 'F', '7000000997', 'isha.260300997@muj.manipal.edu', 3, 1, 14, '823', '2026-07-23'),
('230100998', 'Sai Choudhary', 'M', '7000000998', 'sai.230100998@muj.manipal.edu', 1, 4, 6, '914', '2023-07-19'),
('250700999', 'Ritvik Kapoor', 'M', '7000000999', 'ritvik.250700999@muj.manipal.edu', 7, 2, 11, '533', '2025-07-25'),
('230101000', 'Kiara Arora', 'F', '7000001000', 'kiara.230101000@muj.manipal.edu', 1, 4, 14, '606', '2023-07-25'),
('250301001', 'Veer Yadav', 'M', '7000001001', 'veer.250301001@muj.manipal.edu', 3, 2, 1, '530', '2025-07-26'),
('260701002', 'Advait Yadav', 'M', '7000001002', 'advait.260701002@muj.manipal.edu', 7, 1, 9, '807', '2026-07-27'),
('261201003', 'Tara Sethi', 'F', '7000001003', 'tara.261201003@muj.manipal.edu', 12, 1, 21, '137', '2026-07-31'),
('260801004', 'Vivaan Shah', 'M', '7000001004', 'vivaan.260801004@muj.manipal.edu', 8, 1, 8, '840', '2026-07-31'),
('250201005', 'Myra Mishra', 'F', '7000001005', 'myra.250201005@muj.manipal.edu', 2, 2, 13, '831', '2025-07-16'),
('250801006', 'Ishita Tiwari', 'F', '7000001006', 'ishita.250801006@muj.manipal.edu', 8, 2, 13, '120', '2025-07-31'),
('260801007', 'Shaurya Tiwari', 'M', '7000001007', 'shaurya.260801007@muj.manipal.edu', 8, 1, 1, '822', '2026-07-18'),
('240101008', 'Shreya Ahmed', 'F', '7000001008', 'shreya.240101008@muj.manipal.edu', 1, 3, 18, '815', '2024-07-27'),
('260901009', 'Arnav Das', 'M', '7000001009', 'arnav.260901009@muj.manipal.edu', 9, 1, 6, '406', '2026-07-21'),
('250301010', 'Kavya Banerjee', 'F', '7000001010', 'kavya.250301010@muj.manipal.edu', 3, 2, 21, '929', '2025-07-29'),
('260101011', 'Ishita Bhatia', 'F', '7000001011', 'ishita.260101011@muj.manipal.edu', 1, 1, 15, '903', '2026-07-20'),
('260401012', 'Krishna Agarwal', 'M', '7000001012', 'krishna.260401012@muj.manipal.edu', 4, 1, 10, '326', '2026-07-26'),
('260301013', 'Ritvik Banerjee', 'M', '7000001013', 'ritvik.260301013@muj.manipal.edu', 3, 1, 8, '608', '2026-07-26'),
('260401014', 'Mihir Shekhawat', 'M', '7000001014', 'mihir.260401014@muj.manipal.edu', 4, 1, 3, '336', '2026-07-23'),
('240101015', 'Pranav Khan', 'M', '7000001015', 'pranav.240101015@muj.manipal.edu', 1, 3, 10, '137', '2024-07-15'),
('250601016', 'Krishna Goyal', 'M', '7000001016', 'krishna.250601016@muj.manipal.edu', 6, 2, 6, '732', '2025-07-25'),
('240101017', 'Yash Jain', 'M', '7000001017', 'yash.240101017@muj.manipal.edu', 1, 3, 2, '607', '2024-07-19'),
('240101018', 'Neha Joshi', 'F', '7000001018', 'neha.240101018@muj.manipal.edu', 1, 3, 21, '605', '2024-07-26'),
('251101019', 'Nikhil Verma', 'M', '7000001019', 'nikhil.251101019@muj.manipal.edu', 11, 2, 9, '218', '2025-07-15'),
('240701020', 'Sneha Shah', 'F', '7000001020', 'sneha.240701020@muj.manipal.edu', 7, 3, 13, '227', '2024-07-21'),
('250101021', 'Meera Choudhary', 'F', '7000001021', 'meera.250101021@muj.manipal.edu', 1, 2, 19, '438', '2025-07-31'),
('230101022', 'Aryan Khan', 'M', '7000001022', 'aryan.230101022@muj.manipal.edu', 1, 4, 8, '933', '2023-07-21'),
('260101023', 'Pranav Mukherjee', 'M', '7000001023', 'pranav.260101023@muj.manipal.edu', 1, 1, 11, '940', '2026-07-23'),
('260101024', 'Aisha Pandey', 'F', '7000001024', 'aisha.260101024@muj.manipal.edu', 1, 1, 15, '817', '2026-07-28'),
('251001025', 'Ira Malhotra', 'F', '7000001025', 'ira.251001025@muj.manipal.edu', 10, 2, 13, '519', '2025-07-31'),
('240701026', 'Ananya Patel', 'F', '7000001026', 'ananya.240701026@muj.manipal.edu', 7, 3, 17, '133', '2024-07-25'),
('231001027', 'Kabir Das', 'M', '7000001027', 'kabir.231001027@muj.manipal.edu', 10, 4, 2, '713', '2023-07-24'),
('230501028', 'Vihaan Khanna', 'M', '7000001028', 'vihaan.230501028@muj.manipal.edu', 5, 4, 1, '339', '2023-07-19'),
('260601029', 'Neha Mishra', 'F', '7000001029', 'neha.260601029@muj.manipal.edu', 6, 1, 21, '836', '2026-07-24'),
('240201030', 'Riya Tiwari', 'F', '7000001030', 'riya.240201030@muj.manipal.edu', 2, 3, 22, '429', '2024-07-21'),
('220901031', 'Aniket Yadav', 'M', '7000001031', 'aniket.220901031@muj.manipal.edu', 9, 5, 7, '107', '2022-07-19'),
('260401032', 'Nikhil Rathore', 'M', '7000001032', 'nikhil.260401032@muj.manipal.edu', 4, 1, 10, '502', '2026-07-18'),
('230301033', 'Rudra Sethi', 'M', '7000001033', 'rudra.230301033@muj.manipal.edu', 3, 4, 8, '512', '2023-07-23'),
('260401034', 'Atharv Shah', 'M', '7000001034', 'atharv.260401034@muj.manipal.edu', 4, 1, 2, '939', '2026-07-15'),
('260701035', 'Kabir Goyal', 'M', '7000001035', 'kabir.260701035@muj.manipal.edu', 7, 1, 8, '527', '2026-07-23'),
('250101036', 'Sai Singh', 'M', '7000001036', 'sai.250101036@muj.manipal.edu', 1, 2, 5, '403', '2025-07-20'),
('260401037', 'Navya Bose', 'F', '7000001037', 'navya.260401037@muj.manipal.edu', 4, 1, 20, '314', '2026-07-31'),
('250501038', 'Riya Reddy', 'F', '7000001038', 'riya.250501038@muj.manipal.edu', 5, 2, 17, '823', '2025-07-18'),
('240101039', 'Advik Ahmed', 'M', '7000001039', 'advik.240101039@muj.manipal.edu', 1, 3, 10, '419', '2024-07-28'),
('260701040', 'Lakshya Patel', 'M', '7000001040', 'lakshya.260701040@muj.manipal.edu', 7, 1, 5, '335', '2026-07-27'),
('240101041', 'Kunal Das', 'M', '7000001041', 'kunal.240101041@muj.manipal.edu', 1, 3, 2, '415', '2024-07-27'),
('230401042', 'Khushi Shekhawat', 'F', '7000001042', 'khushi.230401042@muj.manipal.edu', 4, 4, 19, '432', '2023-07-30'),
('240201043', 'Siya Mukherjee', 'F', '7000001043', 'siya.240201043@muj.manipal.edu', 2, 3, 21, '135', '2024-07-25'),
('251201044', 'Ishita Agarwal', 'F', '7000001044', 'ishita.251201044@muj.manipal.edu', 12, 2, 16, '333', '2025-07-25'),
('240101045', 'Sara Banerjee', 'F', '7000001045', 'sara.240101045@muj.manipal.edu', 1, 3, 14, '522', '2024-07-26'),
('230101046', 'Aditi Arora', 'F', '7000001046', 'aditi.230101046@muj.manipal.edu', 1, 4, 20, '820', '2023-07-17'),
('250101047', 'Myra Shekhawat', 'F', '7000001047', 'myra.250101047@muj.manipal.edu', 1, 2, 17, '707', '2025-07-26'),
('250601048', 'Nisha Choudhary', 'F', '7000001048', 'nisha.250601048@muj.manipal.edu', 6, 2, 16, '505', '2025-07-16'),
('250101049', 'Ansh Choudhary', 'M', '7000001049', 'ansh.250101049@muj.manipal.edu', 1, 2, 1, '215', '2025-07-29'),
('250901050', 'Shreya Mittal', 'F', '7000001050', 'shreya.250901050@muj.manipal.edu', 9, 2, 13, '634', '2025-07-28'),
('240801051', 'Khushi Yadav', 'F', '7000001051', 'khushi.240801051@muj.manipal.edu', 8, 3, 14, '332', '2024-07-31'),
('240201052', 'Kunal Kapoor', 'M', '7000001052', 'kunal.240201052@muj.manipal.edu', 2, 3, 4, '111', '2024-07-18'),
('261101053', 'Veer Nair', 'M', '7000001053', 'veer.261101053@muj.manipal.edu', 11, 1, 6, '131', '2026-07-25'),
('260701054', 'Pranav Ahmed', 'M', '7000001054', 'pranav.260701054@muj.manipal.edu', 7, 1, 12, '540', '2026-07-17'),
('240101055', 'Advik Verma', 'M', '7000001055', 'advik.240101055@muj.manipal.edu', 1, 3, 8, '640', '2024-07-17'),
('260101056', 'Aarohi Goyal', 'F', '7000001056', 'aarohi.260101056@muj.manipal.edu', 1, 1, 22, '506', '2026-07-30'),
('250301057', 'Sara Malhotra', 'F', '7000001057', 'sara.250301057@muj.manipal.edu', 3, 2, 17, '535', '2025-07-27'),
('240101058', 'Pranav Sharma', 'M', '7000001058', 'pranav.240101058@muj.manipal.edu', 1, 3, 3, '713', '2024-07-18'),
('230101059', 'Mihir Meena', 'M', '7000001059', 'mihir.230101059@muj.manipal.edu', 1, 4, 12, '724', '2023-07-29'),
('260101060', 'Ansh Rathore', 'M', '7000001060', 'ansh.260101060@muj.manipal.edu', 1, 1, 5, '421', '2026-07-23'),
('260301061', 'Atharv Jain', 'M', '7000001061', 'atharv.260301061@muj.manipal.edu', 3, 1, 8, '104', '2026-07-29'),
('260701062', 'Aditya Bhatia', 'M', '7000001062', 'aditya.260701062@muj.manipal.edu', 7, 1, 10, '927', '2026-07-27'),
('260201063', 'Aryan Ahmed', 'M', '7000001063', 'aryan.260201063@muj.manipal.edu', 2, 1, 4, '930', '2026-07-28'),
('240701064', 'Aarav Kapoor', 'M', '7000001064', 'aarav.240701064@muj.manipal.edu', 7, 3, 2, '804', '2024-07-20'),
('240801065', 'Mihir Patel', 'M', '7000001065', 'mihir.240801065@muj.manipal.edu', 8, 3, 4, '439', '2024-07-25'),
('230101066', 'Sara Saxena', 'F', '7000001066', 'sara.230101066@muj.manipal.edu', 1, 4, 22, '838', '2023-07-18'),
('251101067', 'Aditya Mishra', 'M', '7000001067', 'aditya.251101067@muj.manipal.edu', 11, 2, 5, '715', '2025-07-24'),
('230501068', 'Kabir Verma', 'M', '7000001068', 'kabir.230501068@muj.manipal.edu', 5, 4, 3, '307', '2023-07-30'),
('260701069', 'Avni Bose', 'F', '7000001069', 'avni.260701069@muj.manipal.edu', 7, 1, 16, '410', '2026-07-20'),
('240401070', 'Ishaan Khan', 'M', '7000001070', 'ishaan.240401070@muj.manipal.edu', 4, 3, 7, '613', '2024-07-15'),
('230201071', 'Om Patel', 'M', '7000001071', 'om.230201071@muj.manipal.edu', 2, 4, 1, '310', '2023-07-15'),
('260501072', 'Rahul Shah', 'M', '7000001072', 'rahul.260501072@muj.manipal.edu', 5, 1, 11, '329', '2026-07-15'),
('250901073', 'Vivaan Verma', 'M', '7000001073', 'vivaan.250901073@muj.manipal.edu', 9, 2, 12, '823', '2025-07-18'),
('250801074', 'Siya Rathore', 'F', '7000001074', 'siya.250801074@muj.manipal.edu', 8, 2, 15, '512', '2025-07-30'),
('260201075', 'Navya Mehta', 'F', '7000001075', 'navya.260201075@muj.manipal.edu', 2, 1, 19, '335', '2026-07-27'),
('250101076', 'Rohan Singh', 'M', '7000001076', 'rohan.250101076@muj.manipal.edu', 1, 2, 4, '404', '2025-07-17'),
('250101077', 'Avni Mittal', 'F', '7000001077', 'avni.250101077@muj.manipal.edu', 1, 2, 16, '610', '2025-07-30'),
('240301078', 'Ira Bansal', 'F', '7000001078', 'ira.240301078@muj.manipal.edu', 3, 3, 14, '223', '2024-07-27'),
('260101079', 'Tara Verma', 'F', '7000001079', 'tara.260101079@muj.manipal.edu', 1, 1, 22, '430', '2026-07-20'),
('260201080', 'Aniket Mishra', 'M', '7000001080', 'aniket.260201080@muj.manipal.edu', 2, 1, 3, '410', '2026-07-20'),
('230301081', 'Pranav Agarwal', 'M', '7000001081', 'pranav.230301081@muj.manipal.edu', 3, 4, 9, '621', '2023-07-25'),
('260701082', 'Sara Rao', 'F', '7000001082', 'sara.260701082@muj.manipal.edu', 7, 1, 18, '533', '2026-07-30'),
('250701083', 'Ishita Banerjee', 'F', '7000001083', 'ishita.250701083@muj.manipal.edu', 7, 2, 16, '729', '2025-07-26'),
('260101084', 'Tanmay Shekhawat', 'M', '7000001084', 'tanmay.260101084@muj.manipal.edu', 1, 1, 3, '301', '2026-07-15'),
('230101085', 'Dhruv Kulkarni', 'M', '7000001085', 'dhruv.230101085@muj.manipal.edu', 1, 4, 4, '738', '2023-07-29'),
('260201086', 'Aditya Mukherjee', 'M', '7000001086', 'aditya.260201086@muj.manipal.edu', 2, 1, 10, '138', '2026-07-27'),
('260101087', 'Lakshya Malhotra', 'M', '7000001087', 'lakshya.260101087@muj.manipal.edu', 1, 1, 1, '739', '2026-07-25'),
('230101088', 'Pari Mehta', 'F', '7000001088', 'pari.230101088@muj.manipal.edu', 1, 4, 14, '635', '2023-07-16'),
('251001089', 'Rahul Banerjee', 'M', '7000001089', 'rahul.251001089@muj.manipal.edu', 10, 2, 9, '907', '2025-07-28'),
('251201090', 'Sara Mishra', 'F', '7000001090', 'sara.251201090@muj.manipal.edu', 12, 2, 18, '411', '2025-07-20'),
('240801091', 'Aryan Bansal', 'M', '7000001091', 'aryan.240801091@muj.manipal.edu', 8, 3, 12, '423', '2024-07-23'),
('230101092', 'Mihir Malhotra', 'M', '7000001092', 'mihir.230101092@muj.manipal.edu', 1, 4, 12, '523', '2023-07-18'),
('261101093', 'Om Mukherjee', 'M', '7000001093', 'om.261101093@muj.manipal.edu', 11, 1, 6, '536', '2026-07-31'),
('250201094', 'Navya Jain', 'F', '7000001094', 'navya.250201094@muj.manipal.edu', 2, 2, 17, '735', '2025-07-30'),
('250101095', 'Kunal Malhotra', 'M', '7000001095', 'kunal.250101095@muj.manipal.edu', 1, 2, 7, '326', '2025-07-28'),
('240601096', 'Pari Jain', 'F', '7000001096', 'pari.240601096@muj.manipal.edu', 6, 3, 20, '316', '2024-07-21'),
('260101097', 'Siddharth Tiwari', 'M', '7000001097', 'siddharth.260101097@muj.manipal.edu', 1, 1, 4, '204', '2026-07-16'),
('260701098', 'Naina Kulkarni', 'F', '7000001098', 'naina.260701098@muj.manipal.edu', 7, 1, 14, '310', '2026-07-19'),
('260201099', 'Siddharth Khan', 'M', '7000001099', 'siddharth.260201099@muj.manipal.edu', 2, 1, 8, '418', '2026-07-25'),
('250901100', 'Kabir Mishra', 'M', '7000001100', 'kabir.250901100@muj.manipal.edu', 9, 2, 5, '322', '2025-07-19'),
('250101101', 'Dev Banerjee', 'M', '7000001101', 'dev.250101101@muj.manipal.edu', 1, 2, 9, '934', '2025-07-28'),
('260501102', 'Mahira Rathore', 'F', '7000001102', 'mahira.260501102@muj.manipal.edu', 5, 1, 22, '326', '2026-07-17'),
('250101103', 'Divya Deshpande', 'F', '7000001103', 'divya.250101103@muj.manipal.edu', 1, 2, 18, '515', '2025-07-30'),
('260701104', 'Atharv Das', 'M', '7000001104', 'atharv.260701104@muj.manipal.edu', 7, 1, 1, '236', '2026-07-15'),
('250801105', 'Ishita Shekhawat', 'F', '7000001105', 'ishita.250801105@muj.manipal.edu', 8, 2, 17, '430', '2025-07-26'),
('240201106', 'Ishita Khan', 'F', '7000001106', 'ishita.240201106@muj.manipal.edu', 2, 3, 21, '725', '2024-07-24'),
('250601107', 'Varun Kulkarni', 'M', '7000001107', 'varun.250601107@muj.manipal.edu', 6, 2, 11, '625', '2025-07-27'),
('230101108', 'Ira Kapoor', 'F', '7000001108', 'ira.230101108@muj.manipal.edu', 1, 4, 21, '606', '2023-07-29'),
('260101109', 'Rahul Rao', 'M', '7000001109', 'rahul.260101109@muj.manipal.edu', 1, 1, 9, '804', '2026-07-15'),
('251001110', 'Tanmay Rao', 'M', '7000001110', 'tanmay.251001110@muj.manipal.edu', 10, 2, 4, '733', '2025-07-16'),
('250201111', 'Shaurya Shekhawat', 'M', '7000001111', 'shaurya.250201111@muj.manipal.edu', 2, 2, 11, '907', '2025-07-20'),
('230101112', 'Jiya Bansal', 'F', '7000001112', 'jiya.230101112@muj.manipal.edu', 1, 4, 16, '117', '2023-07-27'),
('230101113', 'Dev Gupta', 'M', '7000001113', 'dev.230101113@muj.manipal.edu', 1, 4, 11, '537', '2023-07-23'),
('250701114', 'Advait Choudhary', 'M', '7000001114', 'advait.250701114@muj.manipal.edu', 7, 2, 4, '732', '2025-07-28'),
('240801115', 'Pari Pandey', 'F', '7000001115', 'pari.240801115@muj.manipal.edu', 8, 3, 19, '802', '2024-07-19'),
('250101116', 'Harsh Khan', 'M', '7000001116', 'harsh.250101116@muj.manipal.edu', 1, 2, 6, '540', '2025-07-16'),
('260201117', 'Varun Nair', 'M', '7000001117', 'varun.260201117@muj.manipal.edu', 2, 1, 2, '428', '2026-07-19'),
('260601118', 'Ishita Sharma', 'F', '7000001118', 'ishita.260601118@muj.manipal.edu', 6, 1, 18, '817', '2026-07-17'),
('230101119', 'Krishna Khan', 'M', '7000001119', 'krishna.230101119@muj.manipal.edu', 1, 4, 3, '512', '2023-07-27'),
('261101120', 'Harsh Joshi', 'M', '7000001120', 'harsh.261101120@muj.manipal.edu', 11, 1, 11, '103', '2026-07-26'),
('251201121', 'Rahul Iyer', 'M', '7000001121', 'rahul.251201121@muj.manipal.edu', 12, 2, 8, '815', '2025-07-22'),
('240901122', 'Khushi Deshpande', 'F', '7000001122', 'khushi.240901122@muj.manipal.edu', 9, 3, 14, '512', '2024-07-26'),
('260101123', 'Dhruv Deshpande', 'M', '7000001123', 'dhruv.260101123@muj.manipal.edu', 1, 1, 11, '505', '2026-07-20'),
('260801124', 'Ansh Bhatia', 'M', '7000001124', 'ansh.260801124@muj.manipal.edu', 8, 1, 8, '526', '2026-07-28'),
('250101125', 'Navya Reddy', 'F', '7000001125', 'navya.250101125@muj.manipal.edu', 1, 2, 19, '834', '2025-07-31'),
('230401126', 'Shreya Bhatia', 'F', '7000001126', 'shreya.230401126@muj.manipal.edu', 4, 4, 20, '613', '2023-07-21'),
('260601127', 'Manav Nair', 'M', '7000001127', 'manav.260601127@muj.manipal.edu', 6, 1, 2, '527', '2026-07-21'),
('250101128', 'Vanya Khan', 'F', '7000001128', 'vanya.250101128@muj.manipal.edu', 1, 2, 22, '633', '2025-07-18'),
('230101129', 'Parth Khan', 'M', '7000001129', 'parth.230101129@muj.manipal.edu', 1, 4, 6, '616', '2023-07-30'),
('240701130', 'Krishna Verma', 'M', '7000001130', 'krishna.240701130@muj.manipal.edu', 7, 3, 3, '232', '2024-07-22'),
('230101131', 'Siddharth Iyer', 'M', '7000001131', 'siddharth.230101131@muj.manipal.edu', 1, 4, 9, '528', '2023-07-17'),
('250101132', 'Anvi Bose', 'F', '7000001132', 'anvi.250101132@muj.manipal.edu', 1, 2, 14, '713', '2025-07-27'),
('261001133', 'Aditya Verma', 'M', '7000001133', 'aditya.261001133@muj.manipal.edu', 10, 1, 7, '906', '2026-07-31'),
('250701134', 'Kavya Khanna', 'F', '7000001134', 'kavya.250701134@muj.manipal.edu', 7, 2, 18, '201', '2025-07-16'),
('250201135', 'Pranav Shah', 'M', '7000001135', 'pranav.250201135@muj.manipal.edu', 2, 2, 9, '536', '2025-07-15'),
('261101136', 'Arnav Joshi', 'M', '7000001136', 'arnav.261101136@muj.manipal.edu', 11, 1, 9, '233', '2026-07-22'),
('260401137', 'Mihir Mehta', 'M', '7000001137', 'mihir.260401137@muj.manipal.edu', 4, 1, 4, '532', '2026-07-26'),
('230101138', 'Rohan Rathore', 'M', '7000001138', 'rohan.230101138@muj.manipal.edu', 1, 4, 9, '831', '2023-07-24'),
('230101139', 'Nisha Mukherjee', 'F', '7000001139', 'nisha.230101139@muj.manipal.edu', 1, 4, 16, '303', '2023-07-21'),
('240201140', 'Shreya Bansal', 'F', '7000001140', 'shreya.240201140@muj.manipal.edu', 2, 3, 21, '829', '2024-07-26'),
('240401141', 'Krishna Singh', 'M', '7000001141', 'krishna.240401141@muj.manipal.edu', 4, 3, 11, '601', '2024-07-27'),
('250101142', 'Tanvi Patel', 'F', '7000001142', 'tanvi.250101142@muj.manipal.edu', 1, 2, 22, '108', '2025-07-22'),
('260101143', 'Rahul Sethi', 'M', '7000001143', 'rahul.260101143@muj.manipal.edu', 1, 1, 8, '414', '2026-07-23'),
('261201144', 'Anvi Banerjee', 'F', '7000001144', 'anvi.261201144@muj.manipal.edu', 12, 1, 19, '120', '2026-07-18'),
('230101145', 'Ansh Singh', 'M', '7000001145', 'ansh.230101145@muj.manipal.edu', 1, 4, 4, '924', '2023-07-17'),
('260101146', 'Sai Mehta', 'M', '7000001146', 'sai.260101146@muj.manipal.edu', 1, 1, 10, '339', '2026-07-27'),
('230101147', 'Vanya Malhotra', 'F', '7000001147', 'vanya.230101147@muj.manipal.edu', 1, 4, 14, '533', '2023-07-16'),
('261001148', 'Myra Mehta', 'F', '7000001148', 'myra.261001148@muj.manipal.edu', 10, 1, 17, '614', '2026-07-19'),
('251101149', 'Krishna Mehta', 'M', '7000001149', 'krishna.251101149@muj.manipal.edu', 11, 2, 10, '437', '2025-07-21'),
('250201150', 'Aarohi Khanna', 'F', '7000001150', 'aarohi.250201150@muj.manipal.edu', 2, 2, 13, '501', '2025-07-17'),
('250301151', 'Kavya Jain', 'F', '7000001151', 'kavya.250301151@muj.manipal.edu', 3, 2, 13, '927', '2025-07-17'),
('240701152', 'Manav Joshi', 'M', '7000001152', 'manav.240701152@muj.manipal.edu', 7, 3, 5, '922', '2024-07-24'),
('250401153', 'Aarav Bhatia', 'M', '7000001153', 'aarav.250401153@muj.manipal.edu', 4, 2, 1, '316', '2025-07-18'),
('250201154', 'Mihir Mukherjee', 'M', '7000001154', 'mihir.250201154@muj.manipal.edu', 2, 2, 3, '533', '2025-07-31'),
('240101155', 'Tanmay Singh', 'M', '7000001155', 'tanmay.240101155@muj.manipal.edu', 1, 3, 11, '211', '2024-07-23'),
('231001156', 'Vivaan Singh', 'M', '7000001156', 'vivaan.231001156@muj.manipal.edu', 10, 4, 3, '912', '2023-07-26'),
('230101157', 'Prisha Bansal', 'F', '7000001157', 'prisha.230101157@muj.manipal.edu', 1, 4, 14, '438', '2023-07-29'),
('240101158', 'Myra Jain', 'F', '7000001158', 'myra.240101158@muj.manipal.edu', 1, 3, 15, '815', '2024-07-27'),
('260501159', 'Advait Kulkarni', 'M', '7000001159', 'advait.260501159@muj.manipal.edu', 5, 1, 12, '926', '2026-07-26'),
('260701160', 'Meera Reddy', 'F', '7000001160', 'meera.260701160@muj.manipal.edu', 7, 1, 20, '223', '2026-07-20'),
('250501161', 'Jiya Kulkarni', 'F', '7000001161', 'jiya.250501161@muj.manipal.edu', 5, 2, 17, '803', '2025-07-24'),
('230301162', 'Khushi Mehta', 'F', '7000001162', 'khushi.230301162@muj.manipal.edu', 3, 4, 21, '237', '2023-07-24'),
('230101163', 'Rahul Reddy', 'M', '7000001163', 'rahul.230101163@muj.manipal.edu', 1, 4, 10, '726', '2023-07-18'),
('241001164', 'Rohan Kapoor', 'M', '7000001164', 'rohan.241001164@muj.manipal.edu', 10, 3, 7, '724', '2024-07-17'),
('260501165', 'Sneha Mishra', 'F', '7000001165', 'sneha.260501165@muj.manipal.edu', 5, 1, 16, '618', '2026-07-30'),
('250801166', 'Yash Iyer', 'M', '7000001166', 'yash.250801166@muj.manipal.edu', 8, 2, 7, '522', '2025-07-16'),
('230101167', 'Aisha Yadav', 'F', '7000001167', 'aisha.230101167@muj.manipal.edu', 1, 4, 13, '910', '2023-07-28'),
('250701168', 'Rohan Jain', 'M', '7000001168', 'rohan.250701168@muj.manipal.edu', 7, 2, 6, '422', '2025-07-27'),
('250701169', 'Shaurya Khanna', 'M', '7000001169', 'shaurya.250701169@muj.manipal.edu', 7, 2, 10, '527', '2025-07-26'),
('230101170', 'Mihir Gupta', 'M', '7000001170', 'mihir.230101170@muj.manipal.edu', 1, 4, 2, '224', '2023-07-22'),
('260201171', 'Vihaan Pandey', 'M', '7000001171', 'vihaan.260201171@muj.manipal.edu', 2, 1, 3, '708', '2026-07-24'),
('251001172', 'Isha Agarwal', 'F', '7000001172', 'isha.251001172@muj.manipal.edu', 10, 2, 19, '215', '2025-07-19'),
('240101173', 'Navya Sethi', 'F', '7000001173', 'navya.240101173@muj.manipal.edu', 1, 3, 16, '839', '2024-07-26'),
('240401174', 'Aryan Banerjee', 'M', '7000001174', 'aryan.240401174@muj.manipal.edu', 4, 3, 6, '922', '2024-07-15'),
('260801175', 'Zoya Pandey', 'F', '7000001175', 'zoya.260801175@muj.manipal.edu', 8, 1, 20, '124', '2026-07-28'),
('240701176', 'Karan Joshi', 'M', '7000001176', 'karan.240701176@muj.manipal.edu', 7, 3, 2, '927', '2024-07-15'),
('250201177', 'Aarav Kapoor', 'M', '7000001177', 'aarav.250201177@muj.manipal.edu', 2, 2, 1, '434', '2025-07-30'),
('250501178', 'Lakshya Kulkarni', 'M', '7000001178', 'lakshya.250501178@muj.manipal.edu', 5, 2, 4, '124', '2025-07-15'),
('260101179', 'Ira Das', 'F', '7000001179', 'ira.260101179@muj.manipal.edu', 1, 1, 19, '606', '2026-07-27'),
('231001180', 'Khushi Bansal', 'F', '7000001180', 'khushi.231001180@muj.manipal.edu', 10, 4, 13, '438', '2023-07-28'),
('230101181', 'Tara Shah', 'F', '7000001181', 'tara.230101181@muj.manipal.edu', 1, 4, 19, '720', '2023-07-30'),
('241001182', 'Khushi Shah', 'F', '7000001182', 'khushi.241001182@muj.manipal.edu', 10, 3, 20, '810', '2024-07-16'),
('250401183', 'Lakshya Arora', 'M', '7000001183', 'lakshya.250401183@muj.manipal.edu', 4, 2, 2, '409', '2025-07-23'),
('240401184', 'Radhika Saxena', 'F', '7000001184', 'radhika.240401184@muj.manipal.edu', 4, 3, 13, '140', '2024-07-18'),
('240101185', 'Avni Khanna', 'F', '7000001185', 'avni.240101185@muj.manipal.edu', 1, 3, 18, '820', '2024-07-28'),
('260601186', 'Aditya Deshpande', 'M', '7000001186', 'aditya.260601186@muj.manipal.edu', 6, 1, 7, '818', '2026-07-18'),
('260701187', 'Siddharth Bhatia', 'M', '7000001187', 'siddharth.260701187@muj.manipal.edu', 7, 1, 6, '138', '2026-07-31'),
('250101188', 'Kabir Patel', 'M', '7000001188', 'kabir.250101188@muj.manipal.edu', 1, 2, 7, '701', '2025-07-20'),
('230101189', 'Sara Reddy', 'F', '7000001189', 'sara.230101189@muj.manipal.edu', 1, 4, 13, '840', '2023-07-26'),
('230101190', 'Sneha Malhotra', 'F', '7000001190', 'sneha.230101190@muj.manipal.edu', 1, 4, 17, '221', '2023-07-25'),
('250701191', 'Rohan Khanna', 'M', '7000001191', 'rohan.250701191@muj.manipal.edu', 7, 2, 8, '333', '2025-07-21'),
('240801192', 'Atharv Joshi', 'M', '7000001192', 'atharv.240801192@muj.manipal.edu', 8, 3, 12, '136', '2024-07-23'),
('240301193', 'Rudra Rathore', 'M', '7000001193', 'rudra.240301193@muj.manipal.edu', 3, 3, 3, '619', '2024-07-31'),
('240801194', 'Sai Goyal', 'M', '7000001194', 'sai.240801194@muj.manipal.edu', 8, 3, 5, '412', '2024-07-28'),
('260801195', 'Kavya Pandey', 'F', '7000001195', 'kavya.260801195@muj.manipal.edu', 8, 1, 16, '337', '2026-07-28'),
('240701196', 'Ansh Kulkarni', 'M', '7000001196', 'ansh.240701196@muj.manipal.edu', 7, 3, 3, '539', '2024-07-31'),
('250101197', 'Avni Ahmed', 'F', '7000001197', 'avni.250101197@muj.manipal.edu', 1, 2, 22, '514', '2025-07-22'),
('260301198', 'Avni Malhotra', 'F', '7000001198', 'avni.260301198@muj.manipal.edu', 3, 1, 15, '539', '2026-07-26'),
('230101199', 'Reyansh Das', 'M', '7000001199', 'reyansh.230101199@muj.manipal.edu', 1, 4, 8, '405', '2023-07-22'),
('260101200', 'Aisha Khanna', 'F', '7000001200', 'aisha.260101200@muj.manipal.edu', 1, 1, 19, '130', '2026-07-21');

TRUNCATE activity_log;  -- start the live feed clean

-- A demo week: 6 days served and closed, plus today's bookings
CALL sp_demo_week();

SELECT 'Done. Refresh the Schemas panel (circular arrows) to see the mess database.' AS status;
