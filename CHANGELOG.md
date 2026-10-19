# Changelog

Versions follow [Semantic Versioning](https://semver.org). Release builds are attached to the
[GitHub releases](https://github.com/agungkristd/Kueri/releases) with their SHA-256 checksum.

## 1.1.3

- Delete rows from a table: one, or several picked with ⌘- or ⇧-click (Delete key or context menu),
  after a confirmation.
- Foreign-key cells show an arrow that opens the referenced table filtered to that value.
- Click a column header to sort ascending, again for descending; the query is rewritten to match.
- Results of a hand-written single-table `SELECT *` can be edited like a browsed table.
- Choose the grid and editor font (any monospaced family) in Settings, with a live preview.
- Settings is a native preferences window: switching panes no longer redraws or shifts the toolbar.
- ⌘T opens a tab directly; tabs are named after their connection.
- Connections can be reordered by dragging; New Connection sits at the bottom of the list.
- The database switcher (⌘K) opens without delay on servers with many databases.
- The workspace no longer repeats the connection name next to the connection bar; rename from the
  connection list (⇧⌘R).
- A zoomed-out diagram stays centred in the view.
- One sidebar toggle in the workspace toolbar instead of two.
- Faster diagram drawing and lower memory use for large results.

## 1.1.2

- Open source under the MIT License; the DMG now includes the license texts of the libraries it
  bundles (THIRD_PARTY_NOTICES.md).
- Filter the rows of a result (⌘F) without running a new query; edits still go to the right row.
- Syntax colours in the SQL editor.
- Database, table and history search by words in any order ("shop local" finds `shop_local`).
- Alternating rows in the connection list.
- Builds are signed with a stable identity when available, so macOS keeps the Local Network
  permission across updates; LAN connections refused right after launch are retried, and the
  error says what to allow when macOS blocks them.

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
