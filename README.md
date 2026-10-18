# Kueri

A small, native macOS database client for PostgreSQL, MySQL/MariaDB, SQLite and Redis.
Written in Swift with AppKit and SwiftUI. No Electron, no bundled runtimes: the app is about 3 MB
and idles at roughly 60–85 MB of memory.

## Features

- **Connections:** PostgreSQL, MySQL/MariaDB, SQLite, Redis. Saved connections, one connection per
  window tab (⌘T), and tabs reconnect after a restart.
- **Browsing:** sidebar of tables with expandable columns (type and primary key), "Open database"
  dialog (⌘K), Postgres schema picker, 300-row pages. A bar in the toolbar shows server version,
  connection, database and table (red for production connections).
- **Table tabs:** open tables, structure views and diagrams side by side within a connection.
- **Grid:** fast native grid (hundreds of columns, thousands of rows), inline editing with double-click,
  row details panel with JSON formatting and search, edits saved by primary key (⌘S).
- **SQL editor:** inline autocomplete for keywords, tables and columns (Tab to accept, ⌥Esc for the list).
  Can be hidden with ⇧⌘E.
- **Structure and diagrams:** column structure per table, and a foreign-key diagram of a table and its
  related tables, or of the whole database (current schema, up to 150 tables) from the sidebar's
  Diagram tab. Click to select a table, drag it to move it, double-click or right-click for its details,
  where columns can be edited (name, type, NULL, default) or deleted. Drag empty space to scroll;
  zoom with ⌃-scroll, pinch or ⌘= / ⌘− / ⌘0; ⇧-scroll scrolls sideways.
- **Server processes (⇧⌘P):** client connections on PostgreSQL, MySQL/MariaDB and Redis, refreshed
  every 2 seconds; cancel a running query or kill a connection (Kueri's own one is protected).
- **Table actions:** open in new tab, copy name, clone, truncate, delete. Destructive actions require
  typing the table name.
- **Templates:** create database, table, view, materialized view, function/procedure and schema.
- **Query history:** a sidebar tab per connection and database, grouped by day (⌘Y).
- **Security:** TLS for all server types (Off / Prefer / Required / Verify), SSH tunnels through the
  system `ssh` (keys and ssh-agent; no password login), and a production mode that asks before
  queries without WHERE, DROP, TRUNCATE, saves and imports.
- **Export / import:** whole database, schema only or data only:
  - PostgreSQL uses `pg_dump` / `psql` / `pg_restore`, in every pg_dump format: SQL (`.sql`),
    custom (`.dump`, `.bak`), tar (`.tar`) and directory (a folder). Imports read the format from the
    file itself, so a `.backup` or a renamed archive works too. Dumps move between server versions
    in both directions (tested 12 ↔ 17); settings an older server doesn't know are skipped.
    TimescaleDB dumps are restored in TimescaleDB's restore mode when the target has the extension,
    and refused before any change when it doesn't.
  - MySQL/MariaDB uses a built-in dumper (tested MySQL 8.4 → MariaDB 11).
  - SQLite uses `sqlite3` (`.dump`, or `.backup` for `.bak`).
  - An import that has failed statements reports them, grouped, instead of reporting success.

## Requirements

- macOS 14.4 or later
- Xcode Command Line Tools (Swift 5.9+)
- `libpq` and `openssl@3` from Homebrew: `brew install libpq openssl@3`
- Optional: a full PostgreSQL client (for example Postgres.app) to import dumps compressed with
  zstd or lz4; Homebrew's libpq only reads gzip-compressed archives.

MySQL/MariaDB and Redis use built-in protocol implementations, so they need no client libraries.

## Build

```sh
./build.sh                       # builds Kueri.app in this folder
cp -R Kueri.app /Applications/   # optional
```

## Checks

```sh
swift build -Xcc -I"$(brew --prefix libpq)/include" -Xlinker -L"$(brew --prefix libpq)/lib" \
  -Xcc -I"$(brew --prefix openssl@3)/include" -Xlinker -L"$(brew --prefix openssl@3)/lib"
.build/debug/Kueri --selftest    # driver and logic checks (debug build: they are asserts)
Kueri.app/Contents/MacOS/Kueri --bench   # grid performance and UI behaviour checks
```

`--probe <sqlite|postgres|mysql|redis> host port user password database "query"` runs a query
against a server from the command line, which is handy when working on a driver.

## Limitations

- Saved passwords are stored unencrypted in the app's preferences file (readable only by your user
  account). The app is ad-hoc signed, and Keychain re-prompts on every rebuild of such apps.
- For MySQL 8 servers that require full `caching_sha2_password` authentication, use TLS "Verify", or
  enable "Allow public key retrieval" on the connection. It is off by default, because without a
  verified certificate the password or the server's key could be intercepted on the network.
- SQL files are imported with `psql` in restricted mode and `sqlite3 -safe`, so meta-commands in a
  file (`\!`, `.shell`, …) are refused and reported as errors.
- PostgreSQL refuses servers that ask for the password in clear text (`require_auth=!password`);
  scram, md5 and trust work as usual. Enable "Allow cleartext password" only for servers that use the
  `password` auth method on a trusted network.
- Without TLS or an SSH tunnel, Redis passwords are only sent to localhost. For a server elsewhere on
  a trusted network, enable "Allow cleartext password".
- TimescaleDB restores need the same TimescaleDB version on the target as on the source server.
- Queries that mention passwords or authentication (`password`, `AUTH`, `IDENTIFIED BY`, …) are
  not saved to the query history.
- Result sets are capped at 10,000 rows in memory. Postgres streams rows, so large results don't
  exhaust memory.
- Redis values are read-only.
