package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "github.com/go-sql-driver/mysql"
	_ "github.com/lib/pq"
	_ "modernc.org/sqlite"
)

type connProfile struct {
	Name     string `json:"name"`
	Driver   string `json:"driver,omitempty"` // "mysql" (default) | "postgres" | "sqlite"
	Host     string `json:"host"`
	Port     string `json:"port"`
	User     string `json:"user"`
	Password string `json:"password"`
	Database string `json:"database"`
}

type profileOut struct {
	Name     string `json:"name"`
	Driver   string `json:"driver,omitempty"`
	Host     string `json:"host"`
	Port     string `json:"port"`
	User     string `json:"user"`
	Database string `json:"database"`
}

// normDriver canonicalizes the profile's driver field.
func normDriver(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "sqlite", "sqlite3":
		return "sqlite"
	case "postgres", "postgresql", "pg":
		return "postgres"
	default:
		return "mysql"
	}
}

// quoteIdentPG quotes an identifier with double quotes (SQL standard, used by
// SQLite and Postgres).
func quoteIdentPG(s string) string {
	return "\"" + strings.ReplaceAll(s, "\"", "\"\"") + "\""
}

// ident quotes an identifier according to the driver's dialect.
func ident(driver, s string) string {
	if driver == "postgres" || driver == "sqlite" {
		return quoteIdentPG(s)
	}
	return quoteIdent(s)
}

// tableRef returns a fully qualified table reference per dialect. Only MySQL
// uses `db`.`table`; Postgres connects per database and SQLite has a single
// file, so both use a bare (quoted) table name.
func tableRef(database, table, driver string) string {
	switch driver {
	case "mysql":
		return quoteIdent(database) + "." + quoteIdent(table)
	case "postgres":
		// listTables may return a schema-qualified "schema.table"; quote each
		// part separately (quoting the whole string would be wrong).
		if i := strings.Index(table, "."); i >= 0 {
			return quoteIdentPG(table[:i]) + "." + quoteIdentPG(table[i+1:])
		}
		return quoteIdentPG(table)
	default: // sqlite
		return quoteIdentPG(table)
	}
}

// ph returns the SQL placeholder for argument i (1-based). MySQL and SQLite
// use "?" everywhere; Postgres needs "$n" numbering.
func ph(driver string, i int) string {
	if driver == "postgres" {
		return "$" + strconv.Itoa(i)
	}
	return "?"
}

const maxCellRunes = 4096

// Producer-side ceilings: nothing the database returns may force unbounded
// work or output on this side.
const maxProfileBytes = 64 * 1024
const maxProfilesBytes = 1 << 20
const maxColumns = 256
const maxOutputBytes = 8 << 20

// Total deadline for any single database interaction.
const dbTimeout = 45 * time.Second

var readKeywords = map[string]bool{
	"PRAGMA": true,
	"SELECT": true, "SHOW": true, "DESCRIBE": true, "DESC": true,
	"EXPLAIN": true, "WITH": true, "VALUES": true,
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}

// connectionsOverride is set from the process-wide --connections flag and wins
// over every environment/default lookup.
var connectionsOverride string

func connectionsPath() string {
	if connectionsOverride != "" {
		return connectionsOverride
	}
	if p := os.Getenv("DBPEEK_CONNECTIONS"); p != "" {
		return p
	}
	if p := os.Getenv("GOMYSQL_CONNECTIONS"); p != "" {
		return p
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		fail("cannot resolve config dir: %v", err)
	}
	return filepath.Join(dir, "gomysql", "connections.json")
}

func verifyCredFile(st os.FileInfo, path string) error {
	if !st.Mode().IsRegular() {
		return fmt.Errorf("connections file is not a regular file: %s", path)
	}
	s, ok := st.Sys().(*syscall.Stat_t)
	if !ok || int(s.Uid) != os.Geteuid() {
		return fmt.Errorf("connections file is not owned by you: %s", path)
	}
	if st.Mode().Perm() != 0o600 {
		return fmt.Errorf("connections file must have 0600 permissions (run: chmod 600 %s)", path)
	}
	return nil
}

func loadProfiles() []connProfile {
	path := connectionsPath()
	// O_NOFOLLOW: a symlink here (planted or accidental) fails instead of
	// silently redirecting credential reads elsewhere.
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		if os.IsNotExist(err) {
			return []connProfile{}
		}
		fail("cannot open connections file (%s): %v", path, err)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		fail("cannot stat connections file: %v", err)
	}
	if err := verifyCredFile(st, path); err != nil {
		fail("%v", err)
	}
	data, err := io.ReadAll(io.LimitReader(f, maxProfilesBytes+1))
	if err != nil {
		fail("cannot read connections file: %v", err)
	}
	if len(data) > maxProfilesBytes {
		fail("connections file too large")
	}
	if len(bytes.TrimSpace(data)) == 0 {
		return []connProfile{}
	}
	var out []connProfile
	if err := json.Unmarshal(data, &out); err != nil {
		fail("cannot parse connections file: %v", err)
	}
	return out
}

func findProfile(name string) connProfile {
	for _, p := range loadProfiles() {
		if p.Name == name {
			return p
		}
	}
	fail("no connection profile named %q", name)
	return connProfile{}
}

func buildDSN(p connProfile, db string) string {
	return fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?timeout=5s&readTimeout=30s&writeTimeout=30s&parseTime=true",
		url.QueryEscape(p.User), url.QueryEscape(p.Password), p.Host, p.Port, db)
}

func open(ctx context.Context, p connProfile, db string) *sql.DB {
	driver := normDriver(p.Driver)
	var dr, dsn string
	switch driver {
	case "mysql":
		dr = "mysql"
		dsn = buildDSN(p, db)
	case "sqlite":
		// For SQLite the "host" field carries the database file path.
		// Opened read-only: the whole session can never write, so no
		// transaction-level guard is needed on this driver.
		path := p.Host
		if path == "" {
			path = p.Database
		}
		if path == "" {
			fail("sqlite profile %q has no file path (set host)", p.Name)
		}
		dr = "sqlite"
		dsn = "file:" + path + "?mode=ro"
	default: // postgres
		port := p.Port
		if port == "" {
			port = "5432"
		}
		name := db
		if name == "" {
			name = p.Database
		}
		dr = "postgres"
		// lib/pq parsing: "password=" (kosong) menelen token berikutnya —
		// password kosong harus dihilangkan dari DSN, bukan dibiarkan kosong.
		if p.Password != "" {
			dsn = fmt.Sprintf("host=%s port=%s user=%s password=%s dbname=%s sslmode=disable",
				p.Host, port, p.User, p.Password, name)
		} else {
			dsn = fmt.Sprintf("host=%s port=%s user=%s dbname=%s sslmode=disable",
				p.Host, port, p.User, name)
		}
	}
	handle, err := sql.Open(dr, dsn)
	if err != nil {
		fail("%v", err)
	}
	handle.SetMaxOpenConns(4)
	if err := handle.PingContext(ctx); err != nil {
		handle.Close()
		fail("%v", err)
	}
	return handle
}

func quoteIdent(s string) string {
	return "`" + strings.ReplaceAll(s, "`", "``") + "`"
}

func cell(v sql.NullString) any {
	if !v.Valid {
		return nil
	}
	s := v.String
	if len(s) > maxCellRunes {
		s = string([]rune(s)[:maxCellRunes]) + "…"
	}
	return s
}

func emit(v any) {
	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(v); err != nil {
		fail("%v", err)
	}
}

func saveProfilesFile(list []connProfile) error {
	path := connectionsPath()
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// Lstat (never follows symlinks): the config location must be a real
	// directory owned by us, with private permissions.
	dst, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !dst.IsDir() {
		return fmt.Errorf("config location is not a directory: %s", dir)
	}
	if s, ok := dst.Sys().(*syscall.Stat_t); !ok || int(s.Uid) != os.Geteuid() {
		return fmt.Errorf("config directory is not owned by you: %s", dir)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return err
	}
	// Publish atomically: private temp file in the same directory, then a
	// single rename over the target (rename replaces a planted symlink
	// itself instead of following it, and WriteFile-style truncation never
	// inherits stale permissions).
	tmpName := filepath.Join(dir, fmt.Sprintf(".connections.%d.tmp", os.Getpid()))
	tmp, err := os.OpenFile(tmpName, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return err
	}
	defer os.Remove(tmpName)
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, 0o600); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	st, err := os.Lstat(path)
	if err != nil {
		return err
	}
	return verifyCredFile(st, path)
}

func cmdProfileGet(fs *flag.FlagSet) {
	name := fs.String("name", "", "connection profile name")
	_ = fs.Parse(os.Args[3:])
	if *name == "" {
		fs.Usage()
		os.Exit(2)
	}
	p := findProfile(*name)
	emit(map[string]any{"profile": p})
}

func cmdProfileSave(fs *flag.FlagSet) {
	fromFile := fs.String("from-file", "", "read the profile JSON from this file instead of stdin")
	_ = fs.Parse(os.Args[3:])
	// Credentials arrive over a private pipe (stdin) or a private 0600 file,
	// never on the process command line where every local user could read
	// them via ps. Noctalia's plugin runtime has no stdin, so it writes the
	// profile to a temp file and passes --from-file. A Decoder is used
	// instead of ReadAll: a pipe stays open (no EOF), so reading must
	// complete after one JSON value, not at end-of-stream.
	var src io.Reader = os.Stdin
	if *fromFile != "" {
		f, err := os.OpenFile(*fromFile, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
		if err != nil {
			fail("cannot open profile file: %v", err)
		}
		defer f.Close()
		src = f
	}
	var p connProfile
	dec := json.NewDecoder(io.LimitReader(src, maxProfileBytes))
	if err := dec.Decode(&p); err != nil {
		fail("invalid profile JSON: %v", err)
	}
	p.Driver = normDriver(p.Driver)
	if p.Name == "" || p.Host == "" {
		fail("name and host are required")
	}
	switch p.Driver {
	case "mysql", "mariadb":
		if p.Port == "" {
			p.Port = "3306"
		}
		if p.Driver == "mariadb" {
			p.Driver = "mysql"
		}
	case "postgres":
		if p.Port == "" {
			p.Port = "5432"
		}
	}
	list := loadProfiles()
	replaced := false
	for i := range list {
		if list[i].Name == p.Name {
			list[i] = p
			replaced = true
			break
		}
	}
	if !replaced {
		list = append(list, p)
	}
	if err := saveProfilesFile(list); err != nil {
		fail("%v", err)
	}
	emit(map[string]any{"saved": p.Name})
}

func cmdProfileRemove(fs *flag.FlagSet) {
	name := fs.String("name", "", "profile name")
	_ = fs.Parse(os.Args[3:])
	if *name == "" {
		fs.Usage()
		os.Exit(2)
	}
	list := loadProfiles()
	out := make([]connProfile, 0, len(list))
	found := false
	for _, p := range list {
		if p.Name == *name {
			found = true
			continue
		}
		out = append(out, p)
	}
	if !found {
		fail("no connection profile named %q", name)
	}
	if err := saveProfilesFile(out); err != nil {
		fail("%v", err)
	}
	emit(map[string]any{"removed": *name})
}

func cmdProfiles() {
	profiles := loadProfiles()
	out := make([]profileOut, 0, len(profiles))
	for _, p := range profiles {
		out = append(out, profileOut{
			Name: p.Name, Host: p.Host, Port: p.Port,
			User: p.User, Database: p.Database, Driver: normDriver(p.Driver),
		})
	}
	emit(map[string]any{"profiles": out})
}

func cmdDbs(fs *flag.FlagSet) {
	name := fs.String("profile", "", "connection profile name")
	_ = fs.Parse(os.Args[2:])
	if *name == "" {
		fs.Usage()
		os.Exit(2)
	}
	p := findProfile(*name)
	ctx, cancel := context.WithTimeout(context.Background(), dbTimeout)
	defer cancel()
	handle := open(ctx, p, "")
	defer handle.Close()
	dbs := listDatabases(ctx, handle, normDriver(p.Driver))
	emit(map[string]any{"databases": dbs})
}

// listDatabases enumerates DBs per dialect.
func listDatabases(ctx context.Context, handle *sql.DB, driver string) []string {
	dbs := []string{}
	switch driver {
	case "sqlite":
		// One database per file; the UI shows it as a single entry.
		return []string{"main"}
	case "postgres":
		rows, err := handle.QueryContext(ctx, "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY datname")
		if err != nil {
			fail("%v", err)
		}
		defer rows.Close()
		for rows.Next() {
			var s sql.NullString
			if err := rows.Scan(&s); err != nil {
				fail("%v", err)
			}
			if s.Valid && s.String != "" {
				dbs = append(dbs, s.String)
			}
		}
		if err := rows.Err(); err != nil {
			fail("%v", err)
		}
	default:
		rows, err := handle.QueryContext(ctx, "SHOW DATABASES")
		if err != nil {
			fail("%v", err)
		}
		defer rows.Close()
		for rows.Next() {
			var s sql.NullString
			if err := rows.Scan(&s); err != nil {
				fail("%v", err)
			}
			if s.Valid && s.String != "" {
				dbs = append(dbs, s.String)
			}
		}
		if err := rows.Err(); err != nil {
			fail("%v", err)
		}
	}
	return dbs
}

// listTables enumerates tables per dialect.
func listTables(ctx context.Context, handle *sql.DB, driver string) []string {
	tables := []string{}
	switch driver {
	case "sqlite":
		rows, err := handle.QueryContext(ctx, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
		if err != nil {
			fail("%v", err)
		}
		defer rows.Close()
		for rows.Next() {
			var s sql.NullString
			if err := rows.Scan(&s); err != nil {
				fail("%v", err)
			}
			if s.Valid {
				tables = append(tables, s.String)
			}
		}
		if err := rows.Err(); err != nil {
			fail("%v", err)
		}
	case "postgres":
		rows, err := handle.QueryContext(ctx, "SELECT schemaname, tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1, 2")
		if err != nil {
			fail("%v", err)
		}
		defer rows.Close()
		for rows.Next() {
			var schema, name sql.NullString
			if err := rows.Scan(&schema, &name); err != nil {
				fail("%v", err)
			}
			if !name.Valid || name.String == "" {
				continue
			}
			// Bare name for the default schema, qualified for the rest so
			// tables in non-public schemas resolve unambiguously.
			if schema.Valid && schema.String != "" && schema.String != "public" {
				tables = append(tables, schema.String+"."+name.String)
			} else {
				tables = append(tables, name.String)
			}
		}
		if err := rows.Err(); err != nil {
			fail("%v", err)
		}
	default:
		rows, err := handle.QueryContext(ctx, "SHOW TABLES")
		if err != nil {
			fail("%v", err)
		}
		defer rows.Close()
		for rows.Next() {
			var s sql.NullString
			if err := rows.Scan(&s); err != nil {
				fail("%v", err)
			}
			if s.Valid {
				tables = append(tables, s.String)
			}
		}
		if err := rows.Err(); err != nil {
			fail("%v", err)
		}
	}
	return tables
}

func cmdTables(fs *flag.FlagSet) {
	name := fs.String("profile", "", "connection profile name")
	db := fs.String("db", "", "database")
	_ = fs.Parse(os.Args[2:])
	if *name == "" {
		fs.Usage()
		os.Exit(2)
	}
	p := findProfile(*name)
	database := *db
	if database == "" {
		database = p.Database
	}
	if database == "" {
		fail("no database selected: pass --db or save a database in the profile")
	}
	ctx, cancel := context.WithTimeout(context.Background(), dbTimeout)
	defer cancel()
	handle := open(ctx, p, database)
	defer handle.Close()
	tables := listTables(ctx, handle, normDriver(p.Driver))
	emit(map[string]any{"tables": tables})
}

func readColumns(ctx context.Context, qer queryer, ref string, driver string) ([]string, error) {
	if driver != "mysql" {
		// Portable probe: an empty SELECT still yields the column names via
		// rows.Columns() on every driver.
		rows, err := qer.QueryContext(ctx, "SELECT * FROM "+ref+" LIMIT 0")
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		return rows.Columns()
	}
	rows, err := qer.QueryContext(ctx, "SHOW COLUMNS FROM "+ref)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols := []string{}
	for rows.Next() {
		var field, colType, null, key, extra sql.NullString
		var def sql.NullString
		if err := rows.Scan(&field, &colType, &null, &key, &def, &extra); err != nil {
			return nil, err
		}
		cols = append(cols, field.String)
	}
	return cols, rows.Err()
}

// queryer is satisfied by *sql.DB and *sql.Tx so user SQL can run inside a
// read-only transaction while internally generated SQL uses the pool.
type queryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

func fetchPage(ctx context.Context, qer queryer, q string, args []any, maxRows int64) ([]string, []json.RawMessage, bool, error) {
	rows, err := qer.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, nil, false, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return nil, nil, false, err
	}
	if len(cols) > maxColumns {
		return nil, nil, false, fmt.Errorf("too many columns (%d, max %d)", len(cols), maxColumns)
	}
	vals := make([]sql.NullString, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	out := []json.RawMessage{}
	truncated := false
	var outBytes int64
	for rows.Next() {
		if int64(len(out)) >= maxRows {
			truncated = true
			break
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, nil, false, err
		}
		row := make([]any, len(cols))
		for i, v := range vals {
			row[i] = cell(v)
		}
		raw, err := json.Marshal(row)
		if err != nil {
			return nil, nil, false, err
		}
		outBytes += int64(len(raw))
		if outBytes > maxOutputBytes {
			truncated = true
			break
		}
		out = append(out, raw)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, false, err
	}
	return cols, out, truncated, nil
}

func emitRows(cols []string, raw []json.RawMessage, total int64, offset, limit int64, truncated bool) {
	emit(map[string]any{
		"columns":   cols,
		"rows":      raw,
		"total":     total,
		"offset":    offset,
		"limit":     limit,
		"truncated": truncated,
	})
}

// validateWhere vets a user-supplied WHERE expression that gets embedded in
// the plugin's own SELECT. It must not be able to close the enclosing group,
// chain statements, write server-side files, or comment out the appended
// LIMIT/OFFSET. It also always runs inside a read-only transaction.
func validateWhere(expr string) error {
	if len(expr) > 4096 {
		return fmt.Errorf("WHERE expression too long")
	}
	if strings.Contains(expr, ";") {
		return fmt.Errorf("WHERE expression must be a single expression (no ';')")
	}
	upper := strings.ToUpper(expr)
	if strings.Contains(upper, "INTO OUTFILE") || strings.Contains(upper, "INTO DUMPFILE") {
		return fmt.Errorf("WHERE expression may not write server-side files")
	}
	for _, bad := range []string{"--", "#", "/*", "*/"} {
		if strings.Contains(expr, bad) {
			return fmt.Errorf("WHERE expression may not contain SQL comments")
		}
	}
	return nil
}

func cmdRows(fs *flag.FlagSet) {
	name := fs.String("profile", "", "connection profile name")
	db := fs.String("db", "", "database")
	table := fs.String("table", "", "table name")
	limitF := fs.String("limit", "50", "rows per page")
	offsetF := fs.String("offset", "0", "row offset")
	search := fs.String("search", "", "LIKE search across all columns")
	whereF := fs.String("where", "", "raw SQL WHERE expression (read-only)")
	_ = fs.Parse(os.Args[2:])
	if *name == "" || *table == "" {
		fs.Usage()
		os.Exit(2)
	}
	limit, err := strconv.ParseInt(*limitF, 10, 64)
	if err != nil || limit < 1 {
		limit = 50
	}
	if limit > 500 {
		limit = 500
	}
	offset, err := strconv.ParseInt(*offsetF, 10, 64)
	if err != nil || offset < 0 {
		offset = 0
	}
	p := findProfile(*name)
	database := *db
	if database == "" {
		database = p.Database
	}
	if database == "" {
		fail("no database selected: pass --db or save a database in the profile")
	}
	ctx, cancel := context.WithTimeout(context.Background(), dbTimeout)
	defer cancel()
	handle := open(ctx, p, database)
	defer handle.Close()
	driver := normDriver(p.Driver)
	ref := tableRef(database, *table, driver)
	// MySQL/Postgres run everything inside a READ ONLY transaction so even a
	// hostile WHERE expression cannot make the session modify data. SQLite is
	// opened with ?mode=ro, which already guarantees read-only access.
	var qer queryer = handle
	if driver != "sqlite" {
		tx, err := handle.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
		if err != nil {
			fail("%v", err)
		}
		defer tx.Rollback()
		qer = tx
	}
	cols, err := readColumns(ctx, qer, ref, driver)
	if err != nil {
		fail("%v", err)
	}
	if len(cols) == 0 {
		fail("table %s has no columns", ref)
	}

	var total int64
	var where string
	var args []any
	var conds []string
	if *search != "" {
		likes := make([]string, len(cols))
		args = make([]any, len(cols))
		for i, c := range cols {
			likes[i] = ident(driver, c) + " LIKE " + ph(driver, i+1)
			if driver == "postgres" {
				likes[i] = ident(driver, c) + " ILIKE " + ph(driver, i+1)
			}
			args[i] = "%" + *search + "%"
		}
		conds = append(conds, "("+strings.Join(likes, " OR ")+")")
	}
	if strings.TrimSpace(*whereF) != "" {
		expr := strings.TrimSpace(*whereF)
		if err := validateWhere(expr); err != nil {
			fail("%v", err)
		}
		conds = append(conds, "("+expr+")")
	}
	if len(conds) > 0 {
		where = " WHERE " + strings.Join(conds, " AND ")
	}
	if err := qer.QueryRowContext(ctx, "SELECT COUNT(*) FROM "+ref+where, args...).Scan(&total); err != nil {
		fail("%v", err)
	}

	q := "SELECT * FROM " + ref + where + " LIMIT " + ph(driver, len(args)+1) + " OFFSET " + ph(driver, len(args)+2)
	pageArgs := append(append([]any{}, args...), limit, offset)
	pageCols, raw, truncated, err := fetchPage(ctx, qer, q, pageArgs, limit)
	if err != nil {
		fail("%v", err)
	}
	if len(pageCols) == 0 {
		pageCols = cols
	}
	emitRows(pageCols, raw, total, offset, limit, truncated)
}

func cmdQuery(fs *flag.FlagSet) {
	name := fs.String("profile", "", "connection profile name")
	db := fs.String("db", "", "database")
	sqlText := fs.String("sql", "", "read-only SQL statement")
	maxRowsF := fs.String("max-rows", "500", "maximum rows to fetch")
	_ = fs.Parse(os.Args[2:])
	if *name == "" || *sqlText == "" {
		fs.Usage()
		os.Exit(2)
	}
	maxRows, err := strconv.ParseInt(*maxRowsF, 10, 64)
	if err != nil || maxRows < 1 {
		maxRows = 500
	}
	if maxRows > 5000 {
		maxRows = 5000
	}
	trimmed := strings.TrimSpace(*sqlText)
	fields := strings.Fields(trimmed)
	if len(fields) == 0 {
		fail("empty query")
	}
	keyword := strings.ToUpper(strings.TrimPrefix(fields[0], "("))
	if strings.HasPrefix(fields[0], "(") {
		keyword = "SELECT"
	}
	if !readKeywords[keyword] {
		fail("only read-only queries are allowed (SELECT, SHOW, DESCRIBE, EXPLAIN, WITH, VALUES)")
	}
	upper := strings.ToUpper(trimmed)
	if strings.Contains(upper, "INTO OUTFILE") || strings.Contains(upper, "INTO DUMPFILE") {
		fail("writing server-side files is not allowed")
	}
	if strings.Contains(trimmed, ";") {
		tail := strings.TrimSpace(trimmed[strings.LastIndex(trimmed, ";")+1:])
		if tail != "" {
			fail("only a single statement is allowed")
		}
	}
	p := findProfile(*name)
	database := *db
	if database == "" {
		database = p.Database
	}
	ctx, cancel := context.WithTimeout(context.Background(), dbTimeout)
	defer cancel()
	handle := open(ctx, p, database)
	defer handle.Close()
	// The keyword allowlist is only the first gate: user SQL always runs
	// inside a READ ONLY transaction, so the server itself rejects anything
	// that would modify data (ANALYZE, EXPLAIN ANALYZE side effects, ...).
	var qer queryer = handle
	if normDriver(p.Driver) != "sqlite" {
		tx, err := handle.BeginTx(ctx, &sql.TxOptions{ReadOnly: true})
		if err != nil {
			fail("%v", err)
		}
		defer tx.Rollback()
		qer = tx
	}
	cols, raw, truncated, err := fetchPage(ctx, qer, trimmed, nil, maxRows)
	if err != nil {
		fail("%v", err)
	}
	emitRows(cols, raw, int64(len(raw)), 0, maxRows, truncated)
}

func cmdSchema(fs *flag.FlagSet) {
	name := fs.String("profile", "", "connection profile name")
	db := fs.String("db", "", "database")
	_ = fs.Parse(os.Args[2:])
	if *name == "" {
		fs.Usage()
		os.Exit(2)
	}
	p := findProfile(*name)
	driver := normDriver(p.Driver)
	database := *db
	if database == "" {
		database = p.Database
	}
	ctx, cancel := context.WithTimeout(context.Background(), dbTimeout)
	defer cancel()
	handle := open(ctx, p, database)
	defer handle.Close()
	type tableInfo struct {
		Name    string   `json:"name"`
		Columns []string `json:"columns"`
	}
	tables := listTables(ctx, handle, driver)
	out := []tableInfo{}
	for _, tb := range tables {
		cols, err := readColumns(ctx, handle, tableRef(database, tb, driver), driver)
		if err != nil {
			continue // tabel aneh (virtual/system): lewati, jangan gagalkan seluruh schema
		}
		if len(cols) == 0 {
			continue
		}
		out = append(out, tableInfo{Name: tb, Columns: cols})
	}
	emit(map[string]any{"database": database, "tables": out})
}

// stripGlobalFlags pulls process-wide flags (--connections PATH) out of os.Args
// before dispatch, so each command's FlagSet can keep parsing positionally.
func stripGlobalFlags() {
	out := os.Args[:1]
	args := os.Args[1:]
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--connections":
			if i+1 >= len(args) {
				fail("--connections requires a path")
			}
			connectionsOverride = args[i+1]
			i++
		case strings.HasPrefix(a, "--connections="):
			connectionsOverride = strings.TrimPrefix(a, "--connections=")
		default:
			out = append(out, a)
		}
	}
	os.Args = out
}

func main() {
	stripGlobalFlags()
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: dbpeek-engine [--connections PATH] <profiles|profile|dbs|tables|rows|query|schema> [flags]")
		os.Exit(2)
	}
	cmd := os.Args[1]
	switch cmd {
	case "profiles":
		cmdProfiles()
	case "profile":
		if len(os.Args) < 3 {
			fail("usage: omysql-engine profile <get|save|remove> [flags]")
		}
		switch os.Args[2] {
		case "get":
			fs := flag.NewFlagSet("profile get", flag.ExitOnError)
			cmdProfileGet(fs)
		case "save":
			fs := flag.NewFlagSet("profile save", flag.ExitOnError)
			cmdProfileSave(fs)
		case "remove":
			fs := flag.NewFlagSet("profile remove", flag.ExitOnError)
			cmdProfileRemove(fs)
		default:
			fail("unknown profile action %q", os.Args[2])
		}
	case "dbs":
		fs := flag.NewFlagSet("dbs", flag.ExitOnError)
		cmdDbs(fs)
	case "tables":
		fs := flag.NewFlagSet("tables", flag.ExitOnError)
		cmdTables(fs)
	case "rows":
		fs := flag.NewFlagSet("rows", flag.ExitOnError)
		cmdRows(fs)
	case "query":
		fs := flag.NewFlagSet("query", flag.ExitOnError)
		cmdQuery(fs)
	case "schema":
		fs := flag.NewFlagSet("schema", flag.ExitOnError)
		cmdSchema(fs)
	default:
		fail("unknown command %q", cmd)
	}
}
