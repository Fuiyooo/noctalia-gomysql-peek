# DB Peek — Noctalia plugin

A database browser overlay for [Noctalia](https://noctalia.dev) v5: pick a
connection, browse databases, tables and rows, filter/search every column, and
run read-only SQL — all from a keyboard-first overlay.

Supports **MySQL / MariaDB, PostgreSQL and SQLite**. The UI is a Noctalia
declarative `ui.*` panel; the data layer is a small headless **Go** engine
(`dbpeek-engine`) that speaks JSON on stdout.

```
┌──────────────────────────────────────────────────────────┐
│ employees                                 / search · q … │
│ sample › sampledb › employees                            │
├──────────────────────────────────────────────────────────┤
│ id  first_name  last_name  email      salary  hire_date  │
│ 1   John         Doe        john.doe@…  75000   2021-03… │
├──────────────────────────────────────────────────────────┤
│ 1–5 of 5                              ◀ Prev    Next ▶   │
└──────────────────────────────────────────────────────────┘
```

## Layout

```
dbpeek/                 the Noctalia plugin (plugin.toml + .luau + engine + demo/)
omarchy/                the original Omarchy/Quickshell plugin (kept for reference)
catalog.toml            plugin index for the Noctalia source
```

## Install

Requirements: Noctalia v5+, [Go](https://go.dev) to build the engine, and a
reachable database.

```sh
# 1. Build the engine (the one step the plugin manager can't do for you)
dbpeek/install.sh

# 2. Add this repo as a plugin source and enable it
noctalia msg plugins source add dbpeek-dev path "$PWD"
noctalia msg plugins enable fuiyooo/dbpeek
```

Then open the panel:

```sh
noctalia msg panel-toggle fuiyooo/dbpeek:peek
```

Bind it to a key from your **compositor** (Noctalia's own `[keybinds]` only
handles shell actions and rejects `Super`). On Hyprland, add to your keybinds —
in this example **Super+Ctrl+M**:

```conf
bind = SUPER CTRL, M, exec, noctalia msg panel-toggle fuiyooo/dbpeek:peek
```

If your Hyprland config uses the Lua DSL (`hl.bind`):

```lua
hl.bind(mainMod .. " + CTRL + M", hl.dsp.exec_cmd("noctalia msg panel-toggle fuiyooo/dbpeek:peek"))
```

The **DB Peek** bar widget (a database glyph) can be added from
Settings → Bar; clicking it toggles the panel.

## Demo database

A ready-to-use **SQLite** dataset ships in `dbpeek/demo/` (`demo.db`, rebuilt
with `sqlite3 demo.db < dbpeek/demo/schema.sql`) with `departments`, `employees`
(60 rows) and `products`. With no connections configured, press **Enter** on the
empty connections list to add a `demo` SQLite connection pointing at it — one
keypress and you can test the whole flow.

The same dataset is provided for **MySQL/MariaDB** and **PostgreSQL** as SQL
scripts (DB Peek can't bundle a running server):

```sh
# MySQL / MariaDB (creates database dbpeek_demo)
mysql -u root -p < dbpeek/demo/mysql.sql

# PostgreSQL (creates database dbpeek_demo)
psql -h 127.0.0.1 -U postgres -f dbpeek/demo/postgres.sql
```

Then add a connection with driver MySQL/PostgreSQL, host `127.0.0.1`, the
matching port and database `dbpeek_demo`.

## Keys

| Key | Action |
| --- | --- |
| ↑ / ↓ | Move selection (PgUp/PgDn ±8, Home/End ends) |
| ⏎ | Open the selection (lists) / open the field-value view (rows) |
| → ← | Next / previous page (in the field-value view: next/previous row) |
| `/` | Search all columns of the open table (in a list: filter it) |
| `w` | Filter rows by a raw SQL `WHERE` expression (read-only) |
| `q` | Run a read-only SQL query |
| `r` | Refresh what you are viewing |
| ⇧R | Reload the table fresh (drops query + search + where) |
| `y` | In the field-value view: copy the focused value to the clipboard |
| `Ctrl+B` | Back one level (also closes the current input / cancels the delete prompt) |
| `n` / `e` / `d` | New / edit / delete a connection (connections view) |
| `←` / `→` | In the connection form: MySQL / PostgreSQL / SQLite |
| `↑` / `↓`, `→` | In the SQL box: move through autosuggestions, then insert the highlighted one |

The overlay is **keyboard-only** — no mouse. On-screen chips only show the keys
for the current actions.

The SQL box **autosuggests**: SQL keywords plus table/column names parsed from
the bundled demo SQL files (`dbpeek/demo/*.sql`).

> **Esc** is owned by Noctalia and closes the panel. Back navigation uses
> **Ctrl+B**, which still reaches the plugin while a text field is focused.

## Connection profiles

Profiles are stored in this plugin's Noctalia data directory by default:

```
$XDG_STATE_HOME/noctalia/plugins/data/fuiyooo/dbpeek/connections.json
```

Override the location with the **Connections file** plugin setting. Passwords
are stored in plaintext in a `0600` file owned by you; the engine refuses to
read a file that is not a regular, `0600`, user-owned file.

## Engine

The plugin drives `~/.local/bin/dbpeek-engine` (configurable via the **Engine
binary** setting). You can use it directly:

```sh
dbpeek-engine [--connections PATH] profiles
dbpeek-engine --connections PATH dbs           --profile sample
dbpeek-engine --connections PATH tables        --profile sample --db shop
dbpeek-engine --connections PATH rows          --profile sample --db shop --table items --limit 50 --offset 0 --search pen
dbpeek-engine --connections PATH rows          --profile sample --db shop --table items --where "price > 100"
dbpeek-engine --connections PATH query         --profile sample --db shop --sql "SELECT id, name FROM items LIMIT 10"
dbpeek-engine --connections PATH schema        --profile sample --db shop
```

All commands print JSON on stdout and errors on stderr. `--profile` matches a
`name` in the connections file. Read-only statements only (`SELECT`, `SHOW`,
`DESCRIBE`, `EXPLAIN`, `WITH`, `VALUES`, plus `PRAGMA` for SQLite), single
statement, executed inside a `READ ONLY` transaction (PostgreSQL/MySQL) or an
`?mode=ro` connection (SQLite).

## Security model

- **Credentials**: `profile save` input is read from a private `0600` file
  (`--from-file`), never from the process command line. The connections file is
  opened with `O_NOFOLLOW`, verified to be a regular, user-owned `0600` file,
  and updated atomically.
- **Read-only SQL**: keyword allowlist plus a `READ ONLY` transaction, so the
  server itself rejects anything that would modify data. The table view's `w`
  expression is embedded in the plugin's own `SELECT` and rejects `;`, SQL
  comments and `INTO OUTFILE/DUMPFILE`.
- **Resource bounds**: cells truncate at 4096 characters, result sets cap at 256
  columns / 8 MB, and database calls have a 45 s deadline.

## Development

The `dbpeek/` directory is a standard Noctalia plugin. Point a `path` source at
this repo and edit the `.luau` files — Noctalia hot-reloads them. Rebuild the
engine with `dbpeek/install.sh` after changing Go code.

```
dbpeek/plugin.toml      manifest (panel, widget, settings)
dbpeek/panel.luau       the overlay UI
dbpeek/widget.luau      the bar widget + IPC entry point
dbpeek/lib/engine.luau  runAsync wrapper around dbpeek-engine
dbpeek/lib/format.luau  table formatting helpers
dbpeek/engine/          the Go data engine
dbpeek/demo/            the bundled SQLite demo dataset
```

## License

[MIT](LICENSE)
