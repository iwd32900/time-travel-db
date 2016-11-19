.header on
.mode tabs
.null NULL

-- Append only table [EXPLAIN MORE]
CREATE TABLE _hist_people (
    -- These columns are essential metadata for all tables
    -- TODO: find a way to track user IDs too
    rev INTEGER PRIMARY KEY AUTOINCREMENT,
    id INTEGER,
    -- This gives millisecond precision, instead of seconds only for DATETIME('now')
    added DATETIME NOT NULL DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f', 'now')),
    removed DATETIME,
    -- In another database, this would be relatively straightforward using variables.
    -- But SQLite doesn't have them, and doesn't let you access a temporary table from a trigger.
    -- added_by TEXT,
    -- removed_by TEXT,
    -- Remaining columns are for "application data"
    full_name TEXT,
    -- To ensure our hack for auto-assigning IDs works, assuming no one manually overrides rev.
    CHECK (id <= rev),
    -- Logical consistency.  We allow added = removed to permit rapid-fire updates, but these records will never be selected in a view.
    CHECK (added <= removed)
);
CREATE INDEX _idx_people_id ON _hist_people (id); -- this is critical for inserts
CREATE INDEX _idx_people_removed ON _hist_people (removed); -- this makes the view more efficient

CREATE TRIGGER _trig_people_id AFTER INSERT ON _hist_people
FOR EACH ROW BEGIN
    -- Ensures that id is auto-assigned when missing, to simulate auto-increment
    UPDATE _hist_people SET id = IFNULL(id, NEW.rev)
    -- , added_by = (SELECT username from _variables LIMIT 1)
    WHERE rev = NEW.rev;
    -- Any existing row with the same ID should be marked as removed iff it predates the new row.
    -- If it's already removed, that date can move back, but not forward.
    -- Times may be tied because we only get millisecond resolution;  we break ties by `rev`.
    -- Getting this logic right is tricky, because many rows added in quick succession appear simultaneous
    -- (millisecond resolution only), but we also want even the new row to have its removed value set
    -- if a previously entered row has a future date.
    UPDATE _hist_people SET removed = (
        SELECT MIN(hp2.added) FROM _hist_people hp2
        WHERE hp2.id = _hist_people.id AND (
            hp2.added > _hist_people.added
            OR (hp2.added = _hist_people.added AND hp2.rev > _hist_people.rev)
        )
    ) --, removed_by = (SELECT username from _variables LIMIT 1)
    WHERE (removed IS NULL OR removed > NEW.added)
    AND added <= NEW.added AND id = (
        SELECT hp3.id FROM _hist_people hp3 WHERE hp3.rev = NEW.rev
    );
    -- If we promise not to add rows out of chronological order, we can use this version.
    -- This version doesn't update NEW.removed if there are future-dated records,
    -- but is ~2.5x more efficient after 500 updates per item.
    -- UPDATE _hist_people SET removed = IFNULL(MIN(_hist_people.removed, NEW.added), NEW.added)
    -- WHERE (removed IS NULL OR removed > NEW.added)
    -- AND added <= NEW.added AND rev != NEW.rev AND id = (
    --     SELECT hp3.id FROM _hist_people hp3 WHERE hp3.rev = NEW.rev
    -- );
END;

-- Test data on underlying table
INSERT INTO _hist_people (full_name) VALUES ('George Washington');
INSERT INTO _hist_people (full_name) VALUES ('John Kenedy');
INSERT INTO _hist_people (full_name) VALUES ('Thomas Jefferson');
INSERT INTO _hist_people (id, full_name) VALUES (2, 'John F. Kenedy');

SELECT * FROM _hist_people;

-- View of data as of this moment in time
CREATE VIEW people AS
    SELECT id, full_name
    FROM _hist_people
    WHERE added <= STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
    AND (removed is NULL OR removed > STRFTIME('%Y-%m-%d %H:%M:%f', 'now'));

SELECT * FROM people;

-- Simulate destructive operations on the View
-- This actually has INSERT OR REPLACE semantics if `id` is specified -- not sure how to avoid that.
CREATE TRIGGER _trig_people_insert INSTEAD OF INSERT ON people
FOR EACH ROW BEGIN
    INSERT INTO _hist_people (id, full_name)
        VALUES (NEW.id, NEW.full_name);
END;

INSERT INTO people (id, full_name) VALUES (2, 'JFK');
INSERT INTO people (full_name) VALUES ('Franklin Roosevelt');
SELECT * FROM people;

-- UPDATE is simply an INSERT, *unless* the id changes.  Then we have to explicitly mark the old row removed.
-- I would argue that an UPDATE should never change `id`, but maybe you have a reason.
CREATE TRIGGER _trig_people_update INSTEAD OF UPDATE ON people
FOR EACH ROW BEGIN
    UPDATE _hist_people SET removed = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        -- , removed_by = (SELECT username from _variables LIMIT 1)
        WHERE id = OLD.id AND id != NEW.id
        AND added <= STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        AND (removed is NULL OR removed > STRFTIME('%Y-%m-%d %H:%M:%f', 'now'));
    INSERT INTO _hist_people (id, full_name)
        VALUES (NEW.id, NEW.full_name);
END;

UPDATE people SET full_name = 'FDR' WHERE full_name = 'Franklin Roosevelt';
SELECT * FROM people;

-- The proper semantics of DELETE are a little unclear.
-- This takes a row that is currently visible and makes it invisible as of the present moment.
CREATE TRIGGER _trig_people_delete INSTEAD OF DELETE ON people
FOR EACH ROW BEGIN
    UPDATE _hist_people SET removed = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        -- , removed_by = (SELECT username from _variables LIMIT 1)
        WHERE id = OLD.id
        AND added <= STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        AND (removed is NULL OR removed > STRFTIME('%Y-%m-%d %H:%M:%f', 'now'));
END;

DELETE FROM people WHERE full_name = 'FDR';
SELECT * FROM people;

-- .mode csv
-- .import prez_names.csv people;
.read prez_names.sql
select count(*) from _hist_people;
select count(*) from people;
select min(added), max(added) from _hist_people;

.timer on
UPDATE people SET full_name = 'Abraham Lincoln' WHERE id = 1;
-- 100 items x 500 updates = 50 sec (0.006 sec insert, 0.001 select * from people)
