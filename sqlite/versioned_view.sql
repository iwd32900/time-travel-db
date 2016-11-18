.header on
.mode tabs
.null NULL

-- Append only table [EXPLAIN MORE]
CREATE TABLE hist_people (
    -- These columns are essential metadata for all tables
    -- TODO: find a way to track user IDs too
    rev INTEGER PRIMARY KEY AUTOINCREMENT,
    id INTEGER,
    -- This gives millisecond precision, instead of seconds only for DATETIME('now')
    added DATETIME NOT NULL DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f', 'now')),
    -- added_by TEXT,
    removed DATETIME,
    -- removed_by TEXT,
    -- Remaining columns are for "application data"
    full_name TEXT,
    -- To ensure our hack for auto-assigning IDs works, assuming no one manually overrides rev.
    CHECK (id <= rev),
    -- Logical consistency.  We allow added = removed to permit rapid-fire updates, but these records will never be selected in a view.
    CHECK (added <= removed)
);
CREATE INDEX idx_people_id ON hist_people (id); -- takes 100 x 100 insert time from ~10 min to ~40 sec.
-- CREATE INDEX idx_people_removed ON hist_people (removed); -- this actually slows things down a bit
-- CREATE INDEX idx_people_added ON hist_people (added); -- this actually slows things down a bit

CREATE TRIGGER trig_people_id AFTER INSERT ON hist_people
FOR EACH ROW BEGIN
    -- Ensures that id is auto-assigned when missing, to simulate auto-increment
    UPDATE hist_people SET id = NEW.rev WHERE rev = NEW.rev AND id IS NULL;
    -- Any existing row with the same ID should be marked as removed iff it predates the new row.
    -- Getting this logic right is tricky, because many rows added in quick succession appear simultaneous
    -- (millisecond resolution only), but we also want even the new row to have its removed value set
    -- if a previously entered row has a future date.
    -- If a row is marked removed already, we also don't want to move that date forward any, hence the MIN/IFNULL construct.
    -- If we promise not to add rows out of chronological order, we can probably make this simpler.
    UPDATE hist_people SET removed = MIN(
        IFNULL(hist_people.removed, DATETIME('9999-12-31')),
        (
            SELECT MIN(hp2.added) FROM hist_people hp2
            WHERE hp2.id = hist_people.id AND (
                hp2.added > hist_people.added
                OR (hp2.added = hist_people.added AND hp2.rev > hist_people.rev)
            )
        )
    ) WHERE id = (
        SELECT hp3.id FROM hist_people hp3 WHERE hp3.rev = NEW.rev
    );
    -- ... refine this WHERE clause to make the updates touch fewer rows ...
END;

-- Test data on underlying table
INSERT INTO hist_people (full_name) VALUES ('George Washington');
INSERT INTO hist_people (full_name) VALUES ('John Kenedy');
INSERT INTO hist_people (full_name) VALUES ('Thomas Jefferson');
INSERT INTO hist_people (id, full_name) VALUES (2, 'John F. Kenedy');

SELECT * FROM hist_people;

-- View of data as of this moment in time
CREATE VIEW people AS
    SELECT id, full_name
    FROM hist_people
    WHERE added <= STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
    AND (removed is NULL OR removed > STRFTIME('%Y-%m-%d %H:%M:%f', 'now'));

SELECT * FROM people;

-- Simulate destructive operations on the View
CREATE TRIGGER trig_people_insert INSTEAD OF INSERT ON people
FOR EACH ROW BEGIN
    INSERT INTO hist_people (id, full_name)
        VALUES (NEW.id, NEW.full_name);
END;

INSERT INTO people (id, full_name) VALUES (2, 'JFK');
INSERT INTO people (full_name) VALUES ('Franklin Roosevelt');
SELECT * FROM people;

-- UPDATE is simply an INSERT, *unless* the id changes.  Then we have to explicitly mark the old row removed.
-- I would argue that an UPDATE should never change `id`, but maybe you have a reason.
CREATE TRIGGER trig_people_update INSTEAD OF UPDATE ON people
FOR EACH ROW BEGIN
    UPDATE hist_people SET removed = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        WHERE id = OLD.id AND id != NEW.id
        AND added <= STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        AND (removed is NULL OR removed > STRFTIME('%Y-%m-%d %H:%M:%f', 'now'));
    INSERT INTO hist_people (id, full_name)
        VALUES (NEW.id, NEW.full_name);
END;

UPDATE people SET full_name = 'FDR' WHERE full_name = 'Franklin Roosevelt';
SELECT * FROM people;

-- The proper semantics of DELETE are a little unclear.
-- This takes a row that is currently visible and makes it invisible as of the present moment.
CREATE TRIGGER trig_people_delete INSTEAD OF DELETE ON people
FOR EACH ROW BEGIN
    UPDATE hist_people SET removed = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        WHERE id = OLD.id
        AND added <= STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        AND (removed is NULL OR removed > STRFTIME('%Y-%m-%d %H:%M:%f', 'now'));
END;

DELETE FROM people WHERE full_name = 'FDR';
SELECT * FROM people;

-- .mode csv
-- .import prez_names.csv people;
.read prez_names.sql
select count(*) from hist_people;
select count(*) from people;
select min(added), max(added) from hist_people;
-- about 10 minutes to do 100 items x 100 updates with no indexes

.timer on
UPDATE people SET full_name = 'Abraham Lincoln' WHERE id = 1;
-- 0.2 sec for one update without indexes
-- 0.015 sec for one update with index on `id` after 100 x 100 (40 sec to load)
-- 0.055 sec for one update with index on `id` after 100 x 200 (6 min to load)
-- 0.001 sec for one update with index on `id` after 10000 x 10 (20 sec to load)
