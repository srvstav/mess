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
  (1, 3, 'Jalebi'), (1, 3, 'Samosa'), (1, 3, 'Masala Chai'),
  (1, 4, 'Farmhouse Pizza'), (1, 4, 'Veg Burger'), (1, 4, 'Garlic Bread'), (1, 4, 'Gulab Jamun'),
  -- BluSpring
  (2, 1, 'Berry Pancakes'), (2, 1, 'Boiled Eggs'), (2, 1, 'Bread Butter Jam'), (2, 1, 'Cold Coffee'),
  (2, 2, 'Chole'), (2, 2, 'Bhature'), (2, 2, 'Veg Pulao'), (2, 2, 'Lassi'),
  (2, 3, 'Fresh Fruit Tart'), (2, 3, 'Veg Sandwich'), (2, 3, 'Lemon Tea'),
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
