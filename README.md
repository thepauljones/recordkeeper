# Record Keeper - JAI

AI slop playing with claude code after getting red-pilled by geohot with his multiple agents

![Screenshot](doc/img/screen.png "Home Screen")

## About

A desktop vinyl/CD collection manager built in Jai. Search, sort, add, edit, and delete records. Artwork lookup via iTunes API. Uses SQLite for storage and GetRect for the immediate-mode UI.

## Build

```
jai first.jai
```

Produces a `records` binary in the project root.

## Run

```
./records                                        # default database at data/records.db
./records --db path/to/other.db                  # custom database path
```

## Tests

The test suite is a frame-driven state machine that runs inside the normal app loop. It creates records, searches, edits, deletes, and verifies keyboard navigation, sort modes, and collection stats -- 20 steps, 61 assertions. The DB is cleaned on startup so no manual `rm` is needed between runs.

```
jai test.jai && ./test                # build and run tests (fast, 5 frames between steps)
jai test.jai && ./test --watchable    # build and run tests (slow, ~600ms between steps)
```

The test build (`test.jai`) produces a `test` binary with test mode and the test database (`data/test_records.db`) baked in -- no flags needed. `--watchable` slows things down so you can watch records appear, get edited, sorted, and deleted in real time.

You can also run tests from the normal build with explicit flags:

```
./records --test --db data/test_records.db
```
