# TODO

## Engine — optional TLS/SSL support (requested, deferred)

Today the engine is hard-wired to cleartext; it cannot connect to a server that
*requires* TLS.

- [ ] PostgreSQL: add an optional `sslmode` to the profile and append it to the
      DSN. Currently hardcoded `sslmode=disable` in
      `dbpeek/engine/main.go` (`open()`, Postgres branch).
      Values to support: `disable` (default), `allow`, `prefer`, `require`,
      `verify-ca`, `verify-full`, plus `sslrootcert` for the `verify-*` modes.
      Caution: the DSN is keyword/value, so every emitted field must be
      non-empty — an unquoted empty value (`sslmode=`) makes lib/pq swallow the
      next token (this is what caused the empty-`dbname` bug fixed in Testing).
- [ ] MySQL/MariaDB: expose go-sql-driver's `tls=` DSN parameter. The DSN built
      by `buildDSN()` (`dbpeek/engine/main.go`) currently has no `tls=`, so TLS
      is always off.
- [ ] Add `sslmode` (and optional `sslrootcert`) to the `connProfile` struct.
- [ ] Surface the field in the connection form (`dbpeek/panel.luau`, `formBody`)
      and add the label/description to `dbpeek/translations/en.json`.
- [ ] Keep `disable` as the default so existing profiles are unchanged.
- [ ] Tests: connect to a TLS-only Postgres (`ssl=on`, `pg_hba` `hostssl`) and a
      plaintext Postgres; assert both succeed with the right `sslmode`.

Notes from the SSL investigation (context for whoever picks this up):
- A Postgres container with `SHOW ssl;` = `off` reports
  `server does not support SSL, but SSL was required` to any client using
  `sslmode=require`; the engine's `disable` is correct for such a server.
- `password authentication failed ... (28P01)` is auth, not SSL — the engine
  omits `password=` from the DSN entirely when the profile password is empty.
- The misleading `pq: SSL is not enabled on the server` was **not** a TLS
  problem: an empty default `database` produced `dbname= ` in the DSN, and
  lib/pq's keyword/value parser then swallowed the following `sslmode=disable`,
  falling back to `sslmode=require`. Fixed — see Testing.

## Porting gaps (omarchy -> noctalia)

Identified while assessing the port; the Noctalia plugin is otherwise at parity.

- [ ] Mouse interaction for lists and table rows. `dbpeek/panel.luau` line ~8
      claims "every list row is also clickable" but no click handlers exist
      (only the bar widget has `onClick`). Either implement it or fix the
      comment.
- [ ] Horizontal scrolling for wide tables. The port fits column widths
      (`lib/format.luau` `fitWidths`) and only scrolls vertically, so tables
      with many columns get squeezed. The Omarchy plugin had a horizontal
      `Flickable`.
- [ ] Contextual empty states. Omarchy showed "No databases visible for this
      user", "No tables in <db>", "No matches for <filter>"; the port shows a
      generic "No entries".
- [ ] Engine watchdog: Omarchy escalated SIGTERM -> SIGKILL after 60 s; the port
      relies solely on `noctalia.runAsync(..., 60000)`.
- [ ] IPC: add an explicit `close` verb (`dbpeek/panel.luau` / `widget.luau`);
      the engine's `schema` command is not surfaced in the UI.
- [ ] Docs: the README's `[keybinds] cancel = ["ctrl+q"]` note does not match
      Noctalia v5.2.1, whose `settings.json` has no top-level global `cancel`
      keybind (only per-component keybinds). Verify and update.

## Engine robustness

- [ ] `rows` paging has no `ORDER BY`, so `--offset` pages can repeat or skip
      rows between requests when the backend returns rows in a different order
      (notably Postgres). Consider a stable tie-breaker (primary key) or at least
      document the limitation.

## Testing

- [x] Engine builds (`CGO_ENABLED=0 go build`, `go vet` clean) and runs all
      commands against the bundled SQLite `dbpeek/demo/demo.db`.
- [x] Live PostgreSQL against `192.168.9.78:5432` (PostgreSQL 18.6, user
      `postgres`): `profiles`, `dbs`, `tables`, `schema`, `rows` (paging,
      `--search`, `--where`), `query` (`SELECT`/`WITH`/`EXPLAIN`) all pass, and
      the read-only guards reject `DELETE`, `;`, SQL comments and
      `INTO OUTFILE`. **Note:** `192.168.9.78` is this host's own `wlan0`
      address; the server is the local `postgres-server` podman container.
- [x] **Bug found and fixed:** Postgres `--search` failed on any table with a
      non-text column (`pq: operator does not exist: integer ~~* unknown`);
      columns are now `CAST(... AS TEXT)` before the `ILIKE` match
      (`dbpeek/engine/main.go`). Re-verified on `employees`/`products`/
      `departments` plus a numeric search and a search+`where` combination;
      SQLite regression-checked.
- [x] **Bug found and fixed:** with an *empty* default `database`, every command
      that opens the connection (`dbs`, `tables`, ...) failed with the
      misleading `pq: SSL is not enabled on the server`. Cause: the DSN
      contained an unquoted empty `dbname=`; lib/pq's keyword/value parser then
      swallowed the following `sslmode=disable` and fell back to its default
      `sslmode=require`. Fix in `open()`: build the Postgres DSN from only
      non-empty fields and single-quote values containing spaces/quotes/
      backslashes (new `pgDQValue` helper). Verified with an empty-`database`
      profile (`dbs`/`tables`/`rows --search`), an explicit-database profile,
      and passwords containing a space and a single quote (now fail with a
      clean auth error, proving the DSN parses correctly). SQLite
      regression-checked. This very likely explains the original "engine
      rejects for lack of SSL" report — the test profile had no default
      database.
- [ ] Live MySQL/MariaDB test (no `mysql` client on the current machine).
- [ ] Noctalia plugin smoke test (panel + bar widget) on the target desktop.
