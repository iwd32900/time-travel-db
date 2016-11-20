# Time-Travel DB

Like Git for your data.

## Motivation

Relational databases are designed to be mutable -- to allow adding, removing, and altering rows.
However, sometimes one needs a record of the data's history.
This might be an audit log to comply with legal requirements, or something like a version control system.

This article demonstrates how to construct a relational database such that it can be queried as it existed at any point in the past (or even as it is predicted to exist in the future!).
The code here is for [SQLite](http://sqlite.org), but with some adjustment to the syntax should work with most popular relational databases, including MySQL and PostgreSQL.

## A simple example table

We'll start with a trivial table of people's names (which may change over time), and unique integer identiers for those people (which will not).  Foreign key relationships in other tables would be declared against the unique `id`.

```
CREATE TABLE people (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    full_name TEXT
);
```

## Adding fields to track history

In order to track history, we will augment this table with 4 additional fields.
As we'll see later, we will not touch this table directly in normal use, so I've named it with a leading underscore.

```
CREATE TABLE _hist_people (
    rev INTEGER PRIMARY KEY AUTOINCREMENT,
    id INTEGER,
    added DATETIME NOT NULL DEFAULT (STRFTIME('%Y-%m-%d %H:%M:%f', 'now')),
    removed DATETIME,
    full_name TEXT,
    CHECK (id <= rev),
    CHECK (added <= removed)
);
CREATE INDEX _idx_people_id ON _hist_people (id); -- this is critical for inserts
CREATE INDEX _idx_people_removed ON _hist_people (removed); -- this makes the view more efficient
```

This table will be append-only:  we will never remove rows, and the only field we will ever update is `removed`.
The `id` column will serve the same purpose as before -- the target for foreign key relationships -- but
since it is no longer unique, we add a new field `rev` to uniquely identify records.
Rows with the same `id` but different `rev` represent different versions in the history of a single row in our original table.
We also introduce timestamps for when each version takes effect (`added`) and when it is superceded or deleted (`removed`).
We allow `added = removed` in case of rapid-fire updates, because SQLite only offers millisecond resolution.
Finally, we add some indexes that will be important for performance later.

## Viewing the current state

Given the structure above, we can query for the records that were present (active) at any particular point in time.
To make life easier, we can remove the original definition of `people`,
and replace it with a view that returns the current records.
We can use a similar query to reconstruct the `people` table at any other arbitrary point in time.

```
CREATE VIEW people AS
    SELECT id, full_name
    FROM _hist_people
    WHERE added <= STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
    AND (removed is NULL OR removed > STRFTIME('%Y-%m-%d %H:%M:%f', 'now'));
```

## Maintaining the timestamps

Inserting rows into `_hist_people`, is a little awkward still, in two main ways.
First, while `added` gets set automatically, we still have to update `removed` on any rows that have been superceded.
If you want to introduce rows out of chronological order, such as "scheduling" a future change by adding a row with an `added` date in the future, then juggling the dates becomes even more complex.
Second, when adding new data items rather than updating existing ones, we also have to assign a new `id`.
In Postgres we could use a sequence, but that's not an option in most other databases.
We can safely use the auto-assigned value of `rev` for `id` too, because there are never more revisions than items.
But it's a two-step process, and we have to remember to do it.

Fortunately, we can automate both steps with a trigger -- a bit of SQL that's executed every time we add a row to _hist_people.
The timestamp update was tricky to make both correct and performant.
A simpler one is possible if you only ever add rows in chronological order and never mark them as removed at a future date;  you can eliminate the first subquery entirely.
However, in my testing it's only about twice as fast, so you don't gain much for the loss of flexibility.

```
CREATE TRIGGER _trig_people_id AFTER INSERT ON _hist_people
FOR EACH ROW BEGIN
    UPDATE _hist_people SET id = IFNULL(id, NEW.rev) WHERE rev = NEW.rev;
    UPDATE _hist_people SET removed = (
        SELECT MIN(hp2.added) FROM _hist_people hp2
        WHERE hp2.id = _hist_people.id AND (
            hp2.added > _hist_people.added
            OR (hp2.added = _hist_people.added AND hp2.rev > _hist_people.rev)
        )
    ) WHERE (removed IS NULL OR removed > NEW.added)
    AND added <= NEW.added AND id = (
        SELECT hp3.id FROM _hist_people hp3 WHERE hp3.rev = NEW.rev
    );
END;
```

## Simplifying INSERTs, UPDATEs, and DELETEs.

At this point, the system is pretty easy to use.
Still, we're reading data from `people` but have to write data to `_hist_people`.
It turns out we can also use `INSTEAD OF` triggers to make the `people` view behave almost like a real table.
We just have to define what happens during an attempted `INSERT`, `UPDATE`, or `DELETE` operation on `people`.

INSERT is pretty easy.
The one slight weirdness is that it has `INSERT OR REPLACE` semantics with respect to `id`.
If for some reason you manually specify an `id` *and* it's a duplicate, you'll get a logical `UPDATE` instead of an error.

```
CREATE TRIGGER _trig_people_insert INSTEAD OF INSERT ON people
FOR EACH ROW BEGIN
    INSERT INTO _hist_people (id, full_name)
        VALUES (NEW.id, NEW.full_name);
END;
```

DELETE is also pretty easy.
We just need to mark any currently visible rows as invisible, as of this moment:

```
CREATE TRIGGER _trig_people_delete INSTEAD OF DELETE ON people
FOR EACH ROW BEGIN
    UPDATE _hist_people SET removed = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        WHERE id = OLD.id
        AND added <= STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        AND (removed is NULL OR removed > STRFTIME('%Y-%m-%d %H:%M:%f', 'now'));
END;
```

UPDATE looks a lot like INSERT.
They would be identical, in fact, except for that an UPDATE could change a row's `id`.
I can't think of a good reason to do this, given the typical semantics of a database.
But if that happens for some reason, we would need to both obsolete the old record
and add a new one.
If the `id` stays the same, it's sufficient just to add the new record -- the first trigger will fix the dates for us.

```
CREATE TRIGGER _trig_people_update INSTEAD OF UPDATE ON people
FOR EACH ROW BEGIN
    UPDATE _hist_people SET removed = STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        WHERE id = OLD.id AND id != NEW.id
        AND added <= STRFTIME('%Y-%m-%d %H:%M:%f', 'now')
        AND (removed is NULL OR removed > STRFTIME('%Y-%m-%d %H:%M:%f', 'now'));
    INSERT INTO _hist_people (id, full_name)
        VALUES (NEW.id, NEW.full_name);
END;
```

## Whodunit

Of course, a proper audit log would record *who* made the changes in addition to *when* they were made.
Conceptually, this is easy to add to our scheme.
The `_hist_people` table needs `added_by` and `removed_by` columns, and the triggers need to update them when the corresponding dates are set.
However, I couldn't find a way to do it easily in SQLite.
SQLite does not feature @variables like MySQL does, and it doesn't allow access to temporary tables from inside triggers.
I finally came up with a scheme that requires each database connection to create a `TEMPORARY TRIGGER ... AFTER UPDATE ON _hist_people`.
It introduces a performance hit, but it may be tolerable if you need this function.
If you're going to perform a whole lot of modifications, it will be much faster to update `added_by` and `removed_by` just once, after the everything is finished, rather than after every row with a trigger.

## Performance and alternatives

This scheme works well for smallish data sets, but it is less performant than a simple unversioned table.
On my laptop, loading 100 items with 500 versions each (50,000 total INSERTs) takes about 60 seconds.
In contrast, running the same 50,000 `INSERT OR REPLACE` commands against a simple unversioned table takes about half a second!
Peformance scales with number of versions, however -- 10,000 items with 5 edits each takes only 8 seconds.

With very minor modifications, you can use a real table for `people` instead of a view.
The triggers become `AFTER` triggers rather than `INSTEAD OF`, but are otherwise pretty much identical.
In my testing, there was no performance benefit when loading data -- in fact, it was slightly slower.
It also keeps a second copy of current data, which could up to double the size of the database.
Finally, it eliminates the ability to "schedule" future updates to the database by inserting post-dated records.

However, there are some potential upsides.
It may allow more efficient indexing and querying, particularly when there are many more items in the history than are current.
It also allows you to explictly declare (and the database to enforce) foreign key relationships.
And it restores normal semantics to `INSERT`, rather than the `INSERT OR REPLACE` behavior the view exhibits.
