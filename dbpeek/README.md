# DB Peek

Noctalia plugin: a fullscreen database browser (MySQL / PostgreSQL / SQLite)
with a Go engine behind it.

- Entry points: `peek` panel (fullscreen overlay) and `peek` bar widget.
- Settings: **engine_path**, **connections_file**, **page_size**.
- Plugin data (default connections file):
  `$XDG_STATE_HOME/noctalia/plugins/data/fuiyooo/dbpeek/connections.json`.

## Usage

```sh
noctalia msg panel-toggle fuiyooo/dbpeek:peek          # open / close
noctalia msg plugin fuiyooo/dbpeek:peek all refresh    # re-run the current view
```

Deep link to a table (requires the bar widget to be placed, since it hosts the
IPC handler):

```sh
noctalia msg plugin fuiyooo/dbpeek:bar focused summon '{"profile":"sample","database":"shop","table":"items"}'
```

Build the engine first: `./install.sh`. Keys and details are in the repository
root README.
