#!/usr/bin/env python3
# Usage:  python3 make_prez_names.py > prez_names.sql
import random

ITEMS = 100
EDITS = 500

names = [
    "George Washington",
    "Thomas Jefferson",
    "Abraham Lincoln",
    "Franklin Roosevelt",
    "John Kenedy",
]
names = [n.split() for n in names]

print('BEGIN;')
for edit in range(EDITS):
    for item in range(ITEMS):
        full_name = "%s %s" % (random.choice(names)[0], random.choice(names)[1])
        print('INSERT OR REPLACE INTO people VALUES (%i, "%s");' % (item, full_name))
print('COMMIT;')