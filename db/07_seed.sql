TRUNCATE TABLE
    watchlist, audit_log, notifications, transactions, bids, auctions, items, categories, users
    RESTART IDENTITY CASCADE;

INSERT INTO users (full_name, email, password_hash, role) VALUES
    ('Ada Admin',            'admin@bidhub.local',              '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'ADMIN'),

    ('Sam Electronics',      'seller-electronics@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'SELLER'),
    ('Amara Fine Arts',      'seller-art@bidhub.local',          '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'SELLER'),
    ('Victor Motors',        'seller-vehicles@bidhub.local',     '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'SELLER'),
    ('Melody Strings',       'seller-instruments@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'SELLER'),
    ('Beatrice Rare Books',  'seller-books@bidhub.local',        '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'SELLER'),

    ('Liam Chen',      'buyer1@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Olivia Brooks',  'buyer2@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Noah Patel',     'buyer3@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Emma Garcia',    'buyer4@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Ethan Kim',      'buyer5@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Ava Johnson',    'buyer6@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Mason Lee',      'buyer7@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Sophia Rossi',   'buyer8@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Lucas Muller',   'buyer9@bidhub.local',  '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Isabella Novak', 'buyer10@bidhub.local', '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Jackson Wright', 'buyer11@bidhub.local', '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Mia Torres',     'buyer12@bidhub.local', '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Benjamin Osei',  'buyer13@bidhub.local', '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER'),
    ('Charlotte Dias', 'buyer14@bidhub.local', '$2b$12$u4PI.JE0GJbfTAzSws/nS.6VtElHg.V3VRNh6Q4gQheYczoQm777m', 'BUYER');









INSERT INTO categories (name, slug, parent_id) VALUES ('Electronics', 'electronics', NULL);
INSERT INTO categories (name, slug, parent_id) SELECT 'Computers', 'computers', category_id FROM categories WHERE slug = 'electronics';
INSERT INTO categories (name, slug, parent_id) SELECT 'Laptops', 'laptops', category_id FROM categories WHERE slug = 'computers';
INSERT INTO categories (name, slug, parent_id) SELECT 'Gaming Laptops', 'gaming-laptops', category_id FROM categories WHERE slug = 'laptops';


INSERT INTO categories (name, slug, parent_id) VALUES ('Art & Collectibles', 'art-collectibles', NULL);
INSERT INTO categories (name, slug, parent_id) SELECT 'Paintings', 'paintings', category_id FROM categories WHERE slug = 'art-collectibles';
INSERT INTO categories (name, slug, parent_id) SELECT 'Oil Paintings', 'oil-paintings', category_id FROM categories WHERE slug = 'paintings';
INSERT INTO categories (name, slug, parent_id) SELECT 'Landscape Oil Paintings', 'landscape-oil-paintings', category_id FROM categories WHERE slug = 'oil-paintings';


INSERT INTO categories (name, slug, parent_id) VALUES ('Vehicles', 'vehicles', NULL);
INSERT INTO categories (name, slug, parent_id) SELECT 'Cars', 'cars', category_id FROM categories WHERE slug = 'vehicles';
INSERT INTO categories (name, slug, parent_id) SELECT 'Classic Cars', 'classic-cars', category_id FROM categories WHERE slug = 'cars';
INSERT INTO categories (name, slug, parent_id) SELECT 'Muscle Cars', 'muscle-cars', category_id FROM categories WHERE slug = 'classic-cars';


INSERT INTO categories (name, slug, parent_id) VALUES ('Musical Instruments', 'musical-instruments', NULL);
INSERT INTO categories (name, slug, parent_id) SELECT 'String Instruments', 'string-instruments', category_id FROM categories WHERE slug = 'musical-instruments';
INSERT INTO categories (name, slug, parent_id) SELECT 'Guitars', 'guitars', category_id FROM categories WHERE slug = 'string-instruments';
INSERT INTO categories (name, slug, parent_id) SELECT 'Electric Guitars', 'electric-guitars', category_id FROM categories WHERE slug = 'guitars';


INSERT INTO categories (name, slug, parent_id) VALUES ('Books', 'books', NULL);
INSERT INTO categories (name, slug, parent_id) SELECT 'Rare Books', 'rare-books', category_id FROM categories WHERE slug = 'books';
INSERT INTO categories (name, slug, parent_id) SELECT 'First Editions', 'first-editions', category_id FROM categories WHERE slug = 'rare-books';
INSERT INTO categories (name, slug, parent_id) SELECT 'Signed First Editions', 'signed-first-editions', category_id FROM categories WHERE slug = 'first-editions';









WITH item_data (title, condition, attrs) AS (
    VALUES
    ('Vortex X15 Gaming Laptop',      'NEW',         '{"ram":"32GB","cpu":"Intel Core i9-13900H","gpu":"RTX 4080","storage":"2TB NVMe SSD","screen_size":"15.6in"}'::jsonb),
    ('Titan Ryzen Edition 17',        'NEW',         '{"ram":"16GB","cpu":"AMD Ryzen 9 7945HX","gpu":"RTX 4070","storage":"1TB NVMe SSD","screen_size":"17.3in"}'::jsonb),
    ('Nova Strike G5',                'LIKE_NEW',    '{"ram":"16GB","cpu":"Intel Core i7-12700H","gpu":"RTX 3070 Ti","storage":"1TB SSD","screen_size":"15.6in"}'::jsonb),
    ('Phantom Blade Pro',             'USED',        '{"ram":"32GB","cpu":"AMD Ryzen 7 6800H","gpu":"RTX 3060","storage":"512GB SSD","screen_size":"14in"}'::jsonb),
    ('Eclipse Raider 16',             'REFURBISHED', '{"ram":"16GB","cpu":"Intel Core i5-12500H","gpu":"RTX 3050","storage":"512GB SSD","screen_size":"16in"}'::jsonb),
    ('Aurora Gaming Ultra',           'NEW',         '{"ram":"64GB","cpu":"Intel Core i9-14900HX","gpu":"RTX 4090","storage":"4TB NVMe SSD","screen_size":"18in"}'::jsonb),
    ('Cobalt Strike Lite',            'USED',        '{"ram":"8GB","cpu":"Intel Core i5-11400H","gpu":"GTX 1650","storage":"256GB SSD","screen_size":"15.6in"}'::jsonb),
    ('Redline Predator X',            'LIKE_NEW',    '{"ram":"32GB","cpu":"AMD Ryzen 9 6900HX","gpu":"RTX 3080","storage":"1TB SSD","screen_size":"17.3in"}'::jsonb),
    ('Zenith Voyager 14',             'NEW',         '{"ram":"16GB","cpu":"Intel Core i7-13700H","gpu":"RTX 4060","storage":"1TB NVMe SSD","screen_size":"14in"}'::jsonb),
    ('Ironclad Battlestation',        'USED',        '{"ram":"16GB","cpu":"AMD Ryzen 5 5600H","gpu":"GTX 1660 Ti","storage":"512GB SSD","screen_size":"15.6in"}'::jsonb),
    ('Solstice Extreme 15',           'REFURBISHED', '{"ram":"16GB","cpu":"Intel Core i7-11800H","gpu":"RTX 3060","storage":"512GB SSD","screen_size":"15.6in"}'::jsonb),
    ('Quantum Fury 17',               'NEW',         '{"ram":"32GB","cpu":"AMD Ryzen 9 7940HS","gpu":"RTX 4070","storage":"2TB NVMe SSD","screen_size":"17in"}'::jsonb)
)
INSERT INTO items (seller_id, category_id, title, description, condition, attributes)
SELECT
    (SELECT user_id FROM users WHERE email = 'seller-electronics@bidhub.local'),
    (SELECT category_id FROM categories WHERE slug = 'gaming-laptops'),
    d.title,
    format('%s — %s condition, tested and ready to ship.', d.title, d.condition),
    d.condition::item_condition,
    d.attrs
FROM item_data d;


WITH item_data (title, condition, attrs) AS (
    VALUES
    ('Sunset Over the Highlands',     'USED',        '{"artist":"Margaret Hale","medium":"oil on canvas","dimensions":"24x36in","year":"1998"}'::jsonb),
    ('Autumn Valley at Dusk',         'USED',        '{"artist":"Thomas Everly","medium":"oil on canvas","dimensions":"30x40in","year":"2005"}'::jsonb),
    ('Coastal Cliffs in Morning Light','LIKE_NEW',   '{"artist":"Priya Anand","medium":"oil on linen","dimensions":"20x30in","year":"2019"}'::jsonb),
    ('The Old Mill Pond',             'USED',        '{"artist":"Henrik Solberg","medium":"oil on canvas","dimensions":"18x24in","year":"1987"}'::jsonb),
    ('Wheat Fields Under Storm Clouds','NEW',        '{"artist":"Elena Voss","medium":"oil on canvas","dimensions":"36x48in","year":"2023"}'::jsonb),
    ('Mountain Lake Reflections',     'USED',        '{"artist":"Marcus Idowu","medium":"oil on board","dimensions":"16x20in","year":"2001"}'::jsonb),
    ('Vineyard in Late Summer',       'LIKE_NEW',    '{"artist":"Sofia Bianchi","medium":"oil on canvas","dimensions":"24x30in","year":"2016"}'::jsonb),
    ('Winter Forest Path',            'USED',        '{"artist":"Anders Lindqvist","medium":"oil on canvas","dimensions":"20x24in","year":"1993"}'::jsonb),
    ('Desert Mesa at Twilight',       'NEW',         '{"artist":"Rosa Delgado","medium":"oil on canvas","dimensions":"30x40in","year":"2022"}'::jsonb),
    ('The Fishermans Cove',           'USED',        '{"artist":"Owen Kavanagh","medium":"oil on canvas","dimensions":"22x28in","year":"1979"}'::jsonb),
    ('Highland Loch in Fog',          'REFURBISHED', '{"artist":"Isla MacRae","medium":"oil on canvas","dimensions":"24x36in","year":"1965"}'::jsonb),
    ('Rolling Hills of Provence',     'LIKE_NEW',    '{"artist":"Claire Dubois","medium":"oil on canvas","dimensions":"28x36in","year":"2014"}'::jsonb)
)
INSERT INTO items (seller_id, category_id, title, description, condition, attributes)
SELECT
    (SELECT user_id FROM users WHERE email = 'seller-art@bidhub.local'),
    (SELECT category_id FROM categories WHERE slug = 'landscape-oil-paintings'),
    d.title,
    format('%s — %s condition, professionally appraised.', d.title, d.condition),
    d.condition::item_condition,
    d.attrs
FROM item_data d;


WITH item_data (title, condition, attrs) AS (
    VALUES
    ('1969 Chevrolet Camaro SS',      'USED',        '{"make":"Chevrolet","model":"Camaro SS","year":"1969","mileage":"82000","transmission":"Manual","engine":"396 V8"}'::jsonb),
    ('1970 Dodge Challenger R/T',     'USED',        '{"make":"Dodge","model":"Challenger R/T","year":"1970","mileage":"91000","transmission":"Manual","engine":"440 V8"}'::jsonb),
    ('1967 Ford Mustang Fastback',    'USED',        '{"make":"Ford","model":"Mustang Fastback","year":"1967","mileage":"104000","transmission":"Manual","engine":"289 V8"}'::jsonb),
    ('1971 Plymouth Barracuda',       'REFURBISHED', '{"make":"Plymouth","model":"Barracuda","year":"1971","mileage":"76000","transmission":"Automatic","engine":"340 V8"}'::jsonb),
    ('1968 Pontiac GTO',              'USED',        '{"make":"Pontiac","model":"GTO","year":"1968","mileage":"88000","transmission":"Manual","engine":"400 V8"}'::jsonb),
    ('1966 Shelby GT350',             'USED',        '{"make":"Shelby","model":"GT350","year":"1966","mileage":"63000","transmission":"Manual","engine":"289 V8 HiPo"}'::jsonb),
    ('1972 Buick GSX',                'USED',        '{"make":"Buick","model":"GSX","year":"1972","mileage":"99000","transmission":"Automatic","engine":"455 V8"}'::jsonb),
    ('1969 AMC Javelin SST',          'LIKE_NEW',    '{"make":"AMC","model":"Javelin SST","year":"1969","mileage":"41000","transmission":"Manual","engine":"390 V8"}'::jsonb),
    ('1973 Oldsmobile 442',           'USED',        '{"make":"Oldsmobile","model":"442","year":"1973","mileage":"113000","transmission":"Automatic","engine":"455 V8"}'::jsonb),
    ('1970 Chevrolet Chevelle SS',    'USED',        '{"make":"Chevrolet","model":"Chevelle SS","year":"1970","mileage":"97000","transmission":"Manual","engine":"454 V8"}'::jsonb),
    ('1965 Ford Mustang GT',          'REFURBISHED', '{"make":"Ford","model":"Mustang GT","year":"1965","mileage":"120000","transmission":"Manual","engine":"289 V8"}'::jsonb),
    ('1968 Dodge Charger R/T',        'USED',        '{"make":"Dodge","model":"Charger R/T","year":"1968","mileage":"85000","transmission":"Automatic","engine":"440 V8"}'::jsonb)
)
INSERT INTO items (seller_id, category_id, title, description, condition, attributes)
SELECT
    (SELECT user_id FROM users WHERE email = 'seller-vehicles@bidhub.local'),
    (SELECT category_id FROM categories WHERE slug = 'muscle-cars'),
    d.title,
    format('%s — %s condition, clean title, records available.', d.title, d.condition),
    d.condition::item_condition,
    d.attrs
FROM item_data d;


WITH item_data (title, condition, attrs) AS (
    VALUES
    ('Fender Stratocaster American Pro II', 'NEW',         '{"brand":"Fender","model":"Stratocaster American Pro II","body_type":"Solid","pickups":"V-Mod II Single-Coil","year":"2023"}'::jsonb),
    ('Gibson Les Paul Standard 60s',        'NEW',         '{"brand":"Gibson","model":"Les Paul Standard 60s","body_type":"Solid","pickups":"Burstbucker","year":"2022"}'::jsonb),
    ('PRS Custom 24',                       'LIKE_NEW',    '{"brand":"PRS","model":"Custom 24","body_type":"Solid","pickups":"85/15 Humbucker","year":"2020"}'::jsonb),
    ('Ibanez RG550 Genesis',                'USED',        '{"brand":"Ibanez","model":"RG550","body_type":"Solid","pickups":"V7/S1/V8","year":"2015"}'::jsonb),
    ('Gretsch G6120 Nashville',             'USED',        '{"brand":"Gretsch","model":"G6120 Nashville","body_type":"Hollow","pickups":"FilterTron","year":"2011"}'::jsonb),
    ('Epiphone Casino',                     'USED',        '{"brand":"Epiphone","model":"Casino","body_type":"Hollow","pickups":"P-90 Single-Coil","year":"2009"}'::jsonb),
    ('Fender Telecaster Player',            'LIKE_NEW',    '{"brand":"Fender","model":"Telecaster Player","body_type":"Solid","pickups":"Alnico V Single-Coil","year":"2021"}'::jsonb),
    ('Jackson Soloist SL1',                 'USED',        '{"brand":"Jackson","model":"Soloist SL1","body_type":"Solid","pickups":"Seymour Duncan Humbucker","year":"2017"}'::jsonb),
    ('Gibson SG Standard',                  'USED',        '{"brand":"Gibson","model":"SG Standard","body_type":"Solid","pickups":"Burstbucker","year":"2013"}'::jsonb),
    ('Rickenbacker 330',                    'REFURBISHED', '{"brand":"Rickenbacker","model":"330","body_type":"Semi-Hollow","pickups":"Hi-Gain Single-Coil","year":"1998"}'::jsonb),
    ('ESP LTD EC-1000',                     'NEW',         '{"brand":"ESP","model":"LTD EC-1000","body_type":"Solid","pickups":"EMG 81/60 Active Humbucker","year":"2023"}'::jsonb),
    ('Squier Classic Vibe 70s Strat',       'USED',        '{"brand":"Squier","model":"Classic Vibe 70s Stratocaster","body_type":"Solid","pickups":"Ceramic Single-Coil","year":"2019"}'::jsonb)
)
INSERT INTO items (seller_id, category_id, title, description, condition, attributes)
SELECT
    (SELECT user_id FROM users WHERE email = 'seller-instruments@bidhub.local'),
    (SELECT category_id FROM categories WHERE slug = 'electric-guitars'),
    d.title,
    format('%s — %s condition, plays great, includes hard case.', d.title, d.condition),
    d.condition::item_condition,
    d.attrs
FROM item_data d;


WITH item_data (title, condition, attrs) AS (
    VALUES
    ('The Hobbit, First Edition',                    'USED',        '{"author":"J.R.R. Tolkien","publisher":"George Allen & Unwin","year":"1937","edition":"First","signed_by":"J.R.R. Tolkien"}'::jsonb),
    ('To Kill a Mockingbird, First Edition',          'USED',        '{"author":"Harper Lee","publisher":"J.B. Lippincott & Co.","year":"1960","edition":"First","signed_by":"Harper Lee"}'::jsonb),
    ('One Hundred Years of Solitude',                 'USED',        '{"author":"Gabriel Garcia Marquez","publisher":"Harper & Row","year":"1970","edition":"First US","signed_by":"Gabriel Garcia Marquez"}'::jsonb),
    ('The Old Man and the Sea',                       'USED',        '{"author":"Ernest Hemingway","publisher":"Charles Scribners Sons","year":"1952","edition":"First","signed_by":"Ernest Hemingway"}'::jsonb),
    ('Beloved, First Edition',                        'LIKE_NEW',    '{"author":"Toni Morrison","publisher":"Alfred A. Knopf","year":"1987","edition":"First","signed_by":"Toni Morrison"}'::jsonb),
    ('A Game of Thrones, First Edition',               'LIKE_NEW',   '{"author":"George R.R. Martin","publisher":"Bantam Spectra","year":"1996","edition":"First","signed_by":"George R.R. Martin"}'::jsonb),
    ('Harry Potter and the Philosophers Stone',       'USED',        '{"author":"J.K. Rowling","publisher":"Bloomsbury","year":"1997","edition":"First","signed_by":"J.K. Rowling"}'::jsonb),
    ('The Grapes of Wrath, First Edition',            'USED',        '{"author":"John Steinbeck","publisher":"The Viking Press","year":"1939","edition":"First","signed_by":"John Steinbeck"}'::jsonb),
    ('Slaughterhouse-Five, First Edition',            'USED',        '{"author":"Kurt Vonnegut","publisher":"Delacorte Press","year":"1969","edition":"First","signed_by":"Kurt Vonnegut"}'::jsonb),
    ('American Gods, First Edition',                  'NEW',         '{"author":"Neil Gaiman","publisher":"William Morrow","year":"2001","edition":"First","signed_by":"Neil Gaiman"}'::jsonb),
    ('The Shining, First Edition',                    'USED',        '{"author":"Stephen King","publisher":"Doubleday","year":"1977","edition":"First","signed_by":"Stephen King"}'::jsonb),
    ('Norwegian Wood, First Edition',                 'REFURBISHED', '{"author":"Haruki Murakami","publisher":"Kodansha","year":"1987","edition":"First Japanese","signed_by":"Haruki Murakami"}'::jsonb)
)
INSERT INTO items (seller_id, category_id, title, description, condition, attributes)
SELECT
    (SELECT user_id FROM users WHERE email = 'seller-books@bidhub.local'),
    (SELECT category_id FROM categories WHERE slug = 'signed-first-editions'),
    d.title,
    format('%s — %s condition, signature authenticated.', d.title, d.condition),
    d.condition::item_condition,
    d.attrs
FROM item_data d;















WITH auction_data (item_title, starting_price, bid_increment, start_offset, end_offset, status, reserve_price) AS (
    VALUES
    
    ('Vortex X15 Gaming Laptop',   1200.00, 50.00,  '-3 days',  '3 minutes',  'ACTIVE',    NULL::numeric),
    ('Titan Ryzen Edition 17',      900.00, 25.00,  '-2 days',  '6 hours',    'ACTIVE',    NULL),
    ('Nova Strike G5',              700.00, 25.00,  '-1 day',   '3 days',     'ACTIVE',    NULL),
    ('Phantom Blade Pro',           500.00, 20.00,  '1 day',    '9 days',     'SCHEDULED', NULL),
    ('Eclipse Raider 16',           400.00, 20.00,  '-9 days',  '-2 days',    'ACTIVE',    NULL),
    ('Aurora Gaming Ultra',        2500.00, 100.00, '-17 days', '-10 days',   'ACTIVE',    NULL),
    ('Cobalt Strike Lite',          250.00, 10.00,  '-25 days', '-18 days',   'ACTIVE',    NULL),
    ('Redline Predator X',         1000.00, 50.00,  '-12 days', '-5 days',    'ACTIVE',    6000.00),

    
    ('Sunset Over the Highlands',        600.00,  25.00, '-3 days',  '8 minutes', 'ACTIVE',    NULL),
    ('Autumn Valley at Dusk',            800.00,  25.00, '-2 days',  '8 hours',   'ACTIVE',    NULL),
    ('Coastal Cliffs in Morning Light', 1200.00,  50.00, '-1 day',   '4 days',    'ACTIVE',    NULL),
    ('The Old Mill Pond',                350.00,  20.00, '1 day',    '10 days',   'SCHEDULED', NULL),
    ('Wheat Fields Under Storm Clouds', 1500.00,  50.00, '-9 days',  '-3 days',   'ACTIVE',    NULL),
    ('Mountain Lake Reflections',        300.00,  15.00, '-16 days', '-9 days',   'ACTIVE',    NULL),
    ('Vineyard in Late Summer',          700.00,  25.00, '-24 days', '-17 days',  'ACTIVE',    NULL),
    ('Winter Forest Path',               400.00,  20.00, '-11 days', '-4 days',   'ACTIVE',    5500.00),

    
    ('1969 Chevrolet Camaro SS',       28000.00, 500.00, '-3 days',  '5 minutes', 'ACTIVE',    NULL),
    ('1970 Dodge Challenger R/T',      32000.00, 500.00, '-2 days',  '10 hours',  'ACTIVE',    NULL),
    ('1967 Ford Mustang Fastback',     24000.00, 500.00, '-1 day',   '5 days',    'ACTIVE',    NULL),
    ('1971 Plymouth Barracuda',        26000.00, 500.00, '2 days',   '11 days',   'SCHEDULED', NULL),
    ('1968 Pontiac GTO',               22000.00, 500.00, '-10 days', '-3 days',   'ACTIVE',    NULL),
    ('1966 Shelby GT350',              45000.00, 1000.00,'-18 days', '-11 days',  'ACTIVE',    NULL),
    ('1972 Buick GSX',                 19000.00, 500.00, '-26 days', '-19 days',  'ACTIVE',    NULL),
    ('1969 AMC Javelin SST',           21000.00, 500.00, '-13 days', '-6 days',   'ACTIVE',    90000.00),

    
    ('Fender Stratocaster American Pro II', 1400.00, 50.00, '-3 days',  '12 minutes', 'ACTIVE',    NULL),
    ('Gibson Les Paul Standard 60s',        2200.00, 75.00, '-2 days',  '9 hours',    'ACTIVE',    NULL),
    ('PRS Custom 24',                       2600.00, 75.00, '-1 day',   '6 days',     'ACTIVE',    NULL),
    ('Ibanez RG550 Genesis',                 600.00, 25.00, '3 days',   '12 days',    'SCHEDULED', NULL),
    ('Gretsch G6120 Nashville',              900.00, 25.00, '-8 days',  '-1 day',     'ACTIVE',    NULL),
    ('Epiphone Casino',                      500.00, 20.00, '-15 days', '-8 days',    'ACTIVE',    NULL),
    ('Fender Telecaster Player',             700.00, 25.00, '-23 days', '-16 days',   'ACTIVE',    NULL),
    ('Jackson Soloist SL1',                  800.00, 25.00, '-14 days', '-7 days',    'ACTIVE',    6000.00),

    
    ('The Hobbit, First Edition',                2500.00, 100.00, '-3 days',  '15 minutes', 'ACTIVE',    NULL),
    ('To Kill a Mockingbird, First Edition',     3200.00, 100.00, '-2 days',  '11 hours',   'ACTIVE',    NULL),
    ('One Hundred Years of Solitude',            1800.00, 75.00,  '-1 day',   '7 days',     'ACTIVE',    NULL),
    ('The Old Man and the Sea',                  1200.00, 50.00,  '4 days',   '13 days',    'SCHEDULED', NULL),
    ('Beloved, First Edition',                    900.00, 50.00,  '-7 days',  '-1 day',     'ACTIVE',    NULL),
    ('A Game of Thrones, First Edition',         1600.00, 75.00,  '-14 days', '-7 days',    'ACTIVE',    NULL),
    ('Harry Potter and the Philosophers Stone',  4000.00, 150.00, '-22 days', '-15 days',   'ACTIVE',    NULL),
    ('The Grapes of Wrath, First Edition',       1100.00, 50.00,  '-15 days', '-8 days',    'ACTIVE',    9000.00)
)
INSERT INTO auctions (item_id, starting_price, bid_increment, start_time, end_time, status, reserve_price)
SELECT
    i.item_id,
    d.starting_price,
    d.bid_increment,
    now() + d.start_offset::interval,
    now() + d.end_offset::interval,
    d.status::auction_status,
    d.reserve_price
FROM auction_data d
JOIN items i ON i.title = d.item_title;










DO $$
DECLARE
    auc            RECORD;
    all_buyers     INT[];
    eligible       INT[];
    num_bids       INT;
    bid_amount     NUMERIC(12,2);
    i              INT;
    chosen_bidder  INT;
    use_procedure  BOOLEAN;
BEGIN
    SELECT array_agg(user_id) INTO all_buyers FROM users WHERE role = 'BUYER';

    FOR auc IN
        SELECT a.auction_id, a.starting_price, a.bid_increment, a.end_time, i.seller_id
        FROM auctions a
        JOIN items i ON i.item_id = a.item_id
        WHERE a.status = 'ACTIVE'   
        ORDER BY a.auction_id
    LOOP
        eligible := ARRAY(SELECT unnest(all_buyers) EXCEPT SELECT auc.seller_id);
        use_procedure := auc.end_time > now();
        num_bids := 5 + floor(random() * 16)::INT;   
        bid_amount := auc.starting_price;

        FOR i IN 1..num_bids LOOP
            bid_amount := bid_amount + auc.bid_increment * (1 + floor(random() * 2)::INT);
            chosen_bidder := eligible[1 + floor(random() * array_length(eligible, 1))::INT];

            IF use_procedure THEN
                
                
                
                BEGIN
                    CALL place_bid(chosen_bidder, auc.auction_id, bid_amount);
                EXCEPTION WHEN OTHERS THEN
                    NULL; 
                END;
            ELSE
                
                
                
                
                INSERT INTO bids (auction_id, bidder_id, amount, placed_at)
                VALUES (
                    auc.auction_id, chosen_bidder, bid_amount,
                    auc.end_time - (num_bids - i + 1) * interval '20 minutes'
                );
            END IF;
        END LOOP;
    END LOOP;
END $$;













CALL close_expired_auctions();

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'mv_leaderboard') THEN
        REFRESH MATERIALIZED VIEW mv_leaderboard;
    ELSE
        RAISE NOTICE 'mv_leaderboard does not exist yet (P2-05 not merged) -- skipping refresh.';
    END IF;
END $$;

ANALYZE;




SELECT 'users' AS table_name, count(*) AS row_count FROM users
UNION ALL SELECT 'categories',    count(*) FROM categories
UNION ALL SELECT 'items',         count(*) FROM items
UNION ALL SELECT 'auctions',      count(*) FROM auctions
UNION ALL SELECT 'bids',          count(*) FROM bids
UNION ALL SELECT 'transactions',  count(*) FROM transactions
UNION ALL SELECT 'notifications', count(*) FROM notifications
UNION ALL SELECT 'audit_log',     count(*) FROM audit_log
UNION ALL SELECT 'watchlist',     count(*) FROM watchlist
ORDER BY table_name;