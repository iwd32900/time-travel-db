.header on
.mode tabs
.null NULL

CREATE TABLE people (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name TEXT
);

SELECT STRFTIME('%Y-%m-%d %H:%M:%f', 'now');
.read prez_names.sql
SELECT STRFTIME('%Y-%m-%d %H:%M:%f', 'now');

select count(*) from people;

.timer on
UPDATE people SET full_name = 'Abraham Lincoln' WHERE id = 1;
