# Changelog

Versions follow [Semantic Versioning](https://semver.org). Release builds are attached to the
[GitHub releases](https://github.com/agungkristd/Kueri/releases) with their SHA-256 checksum.

## 1.1.1

- The connection form fills the window: header on top, fields below, actions along the bottom edge.
- README: limitations for the release build, diagrams, index and SQLite column editing.

## 1.1.0

First release with a downloadable, self-contained DMG.

- Settings (⌘,): theme, grid and editor font sizes, rows per page, result row limit, server-side
  query timeout, startup tabs, history privacy, editable keymap. View › Appearance switches theme.
- TLS for all server types, SSH tunnels, production mode.
- Export / import in every pg_dump format across PostgreSQL versions, TimescaleDB restore mode,
  MySQL/MariaDB dumper, SQLite dump and backup.
- Whole-database diagram with drag, pan and zoom; table details with inline editing of columns and
  indexes, saved together after the SQL is shown.
- Server processes with cancel query and kill connection; create database; connection bar;
  database dropdown; history in the sidebar; Test Connection.
- Fixed: a crash when a query finished while table names were being read; the app opening behind
  other windows; a Redis password sent over unverified TLS.

## 1.0

- Native client for PostgreSQL, MySQL/MariaDB, SQLite and Redis: grid with inline editing, row
  details with JSON, SQL editor with completion, structure view, foreign-key diagram, table actions,
  templates, per-database query history, connection tabs.
