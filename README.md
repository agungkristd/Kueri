# Kueri

A small, native macOS database client for PostgreSQL, MySQL/MariaDB, SQLite and Redis.
Written in Swift with AppKit and SwiftUI. No Electron, no bundled runtimes: the app is about 3 MB
and idles at roughly 60–85 MB of memory.

## Features

- **Connections:** PostgreSQL, MySQL/MariaDB, SQLite, Redis. Saved connections, one connection per
  window tab (⌘T), and tabs reconnect after a restart.
- **Browsing:** sidebar of tables with expandable columns (type and primary key), database switcher (⌘K),
  Postgres schema picker, 300-row pages.
- **Table tabs:** open tables, structure views and diagrams side by side within a connection.
- **Grid:** fast native grid (hundreds of columns, thousands of rows), inline editing with double-click,
  row details panel with JSON formatting and search, edits saved by primary key (⌘S).
- **SQL editor:** inline autocomplete for keywords, tables and columns (Tab to accept, ⌥Esc for the list).
  Can be hidden with ⇧⌘E.
- **Structure and diagrams:** column structure per table, and a foreign-key diagram of a table and its
  related tables.
- **Table actions:** open in new tab, copy name, clone, truncate, delete. Destructive actions require
  typing the table name.
- **Templates:** create table, view, materialized view, function/procedure and schema.
- **Query history:** kept per connection and database (⌘Y).

## Requirements

- macOS 14.4 or later
- Xcode Command Line Tools (Swift 5.9+)
- `libpq` from Homebrew: `brew install libpq`

MySQL/MariaDB and Redis use built-in protocol implementations, so they need no client libraries.

## Build

```sh
./build.sh                       # builds Kueri.app in this folder
cp -R Kueri.app /Applications/   # optional
```

## Checks

```sh
swift build -Xcc -I"$(brew --prefix libpq)/include" -Xlinker -L"$(brew --prefix libpq)/lib"
.build/debug/Kueri --selftest    # driver and logic checks (debug build: they are asserts)
Kueri.app/Contents/MacOS/Kueri --bench   # grid performance and UI behaviour checks
```

`--probe <sqlite|postgres|mysql|redis> host port user password database "query"` runs a query
against a server from the command line, which is handy when working on a driver.

## Limitations

- Saved passwords are stored unencrypted in the app's preferences file (readable only by your user
  account). The app is ad-hoc signed, and Keychain re-prompts on every rebuild of such apps.
- MySQL and Redis connections don't use TLS yet; use them on local or trusted networks.
  For MySQL 8 servers that require full `caching_sha2_password` authentication, enable
  "Allow public key retrieval" on the connection (off by default, because without TLS the server's
  key could be replaced by someone on the network).
- PostgreSQL refuses servers that ask for the password in clear text (`require_auth=!password`);
  scram, md5 and trust work as usual. Enable "Allow cleartext password" only for servers that use the
  `password` auth method on a trusted network.
- Redis passwords are only sent to localhost by default, because Redis connections aren't encrypted
  yet. For a server elsewhere on a trusted network, enable "Allow cleartext password".
- Queries that mention passwords or authentication (`password`, `AUTH`, `IDENTIFIED BY`, …) are
  not saved to the query history.
- Result sets are capped at 10,000 rows in memory. Postgres streams rows, so large results don't
  exhaust memory.
- Redis values are read-only.
