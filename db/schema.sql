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
