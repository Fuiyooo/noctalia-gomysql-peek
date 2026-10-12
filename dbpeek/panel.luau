-- panel.luau — DB Peek fullscreen overlay.
--
-- A declarative ui.* UI driven by the dbpeek Go engine. Ported from the omarchy
-- DbPeek.qml overlay: connections -> databases -> tables -> rows, with search,
-- a read-only SQL box, a WHERE filter and a per-row field/value detail view.
--
-- Keyboard is delivered through the panel's capture_keys + onKey; every list
-- row is also clickable. Escape is owned by the host (it dismisses the panel),
-- so "back" is BackSpace / the Back button / a row click.

local format = require("./lib/format.luau")
local engine = require("./lib/engine.luau")

local PANEL_ID = "fuiyooo/dbpeek:peek"
local ENGINE_DEFAULT = "~/.local/bin/dbpeek-engine"

local function confStr(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil or v == "" then
    return fallback
  end
  if type(v) == "boolean" then
    return v and "true" or "false"
  end
  if type(v) == "number" then
    return tostring(v)
  end
  return v
end

local binPath = noctalia.expandPath(confStr("engine_path", ENGINE_DEFAULT))
local connFile = confStr("connections_file", "")
if connFile == "" then
  local dd = noctalia.pluginDataDir()
  connFile = (dd or noctalia.expandPath("~/.local/share/noctalia")) .. "/connections.json"
else
  connFile = noctalia.expandPath(connFile)
end
engine.configure({ bin = binPath, connfile = connFile })

local PAGE = tonumber(confStr("page_size", "50")) or 50

-- Gap between table cells/columns (kept identical on the header so columns align).
local CELL_GAP = 14

-- ── state ───────────────────────────────────────────────────────────────────
local S = {
  open = false,
  view = "profiles",          -- profiles | databases | tables | rows | form
  profiles = {}, databases = {}, tables = {},
  active = nil, database = "", table = "",
  columns = {}, rows = {}, total = 0, offset = 0, limit = PAGE, truncated = false,
  sel = 1, detail = false, detailPairs = {}, detailRow = 1,
  filter = "",
  inputMode = "",             -- "" | search | where | sql
  inputToken = 0,
  searchTerm = "", whereClause = "", sqlText = "",
  suggest = {},
  schemaCache = nil,          -- { db = name, tables = { {name=,columns=} } }
  isQuery = false, lastSql = "",
  form = nil, formToken = 0, formError = "",
  confirm = nil,
  error = "", status = "", busy = false,
}

local render -- forward declaration
local runSql -- forward declaration (refresh() runs a query before runSql is defined)

-- ── engine requests ─────────────────────────────────────────────────────────
local function req(args, cb)
  S.busy = true
  S.error = ""
  render()
  engine.run(args, function(ok, data)
    S.busy = false
    if not ok then
      S.error = tostring(data)
      render()
      return
    end
    if cb then
      cb(data)
    end
    render()
  end)
end

-- ── data operations ─────────────────────────────────────────────────────────
local function fetchProfiles(cb)
  req({ "profiles" }, function(data)
    if data then
      S.profiles = data.profiles or {}
      if S.sel > #S.profiles then
        S.sel = 1
      end
    end
    if cb then
      cb()
    end
  end)
end

local function fetchDatabases()
  req({ "dbs", "--profile", S.active.name }, function(data)
    if data then
      S.databases = data.databases or {}
      if S.sel > #S.databases then
        S.sel = 1
      end
    end
  end)
end

local function fetchTables()
  req({ "tables", "--profile", S.active.name, "--db", S.database }, function(data)
    if data then
      S.tables = data.tables or {}
      if S.sel > #S.tables then
        S.sel = 1
      end
    end
  end)
end

local function buildDetail()
  local pairsOut = {}
  if S.detailRow < 1 then
    S.detailRow = 1
  end
  if S.detailRow > #S.rows then
    S.detailRow = #S.rows
  end
  local row = S.rows[S.detailRow] or {}
  for c = 1, #S.columns do
    pairsOut[#pairsOut + 1] = { field = S.columns[c], value = row[c] }
  end
  S.detailPairs = pairsOut
  if S.sel > #S.detailPairs then
    S.sel = 1
  end
end

local function detailShiftRow(delta)
  local n = #S.rows
  if n == 0 then
    return
  end
  local r = S.detailRow + delta
  if r < 1 then
    r = 1
  elseif r > n then
    r = n
  end
  S.detailRow = r
  buildDetail()
  render()
end

local function fetchRows()
  local args = {
    "rows", "--profile", S.active.name, "--db", S.database,
    "--table", S.table, "--limit", tostring(S.limit), "--offset", tostring(S.offset),
  }
  if S.searchTerm ~= "" then
    args[#args + 1] = "--search"
    args[#args + 1] = S.searchTerm
  end
  if S.whereClause ~= "" then
    args[#args + 1] = "--where"
    args[#args + 1] = S.whereClause
  end
  req(args, function(data)
    if data then
      S.columns = data.columns or {}
      S.rows = data.rows or {}
      S.total = data.total or 0
      S.offset = data.offset or 0
      S.truncated = data.truncated == true
      if S.sel > #S.rows then
        S.sel = 1
      end
      if S.detail then
        buildDetail()
      end
    end
  end)
end

-- ── navigation / actions ────────────────────────────────────────────────────
local function resetInputs()
  S.inputMode = ""
  S.searchTerm = ""
  S.whereClause = ""
  S.isQuery = false
  S.lastSql = ""
end

local function openProfile(profile)
  S.active = profile
  S.database = profile.database or ""
  S.table = ""
  S.filter = ""
  S.sel = 1
  S.detail = false
  S.view = "databases"
  fetchDatabases()
end

local function openDatabase(db)
  S.database = db
  S.table = ""
  S.filter = ""
  S.sel = 1
  S.detail = false
  S.view = "tables"
  fetchTables()
end

local function openTable(t)
  S.table = t
  S.filter = ""
  S.sel = 1
  S.detail = false
  S.offset = 0
  resetInputs()
  S.view = "rows"
  fetchRows()
end

local function items()
  if S.view == "profiles" then
    local out = {}
    local needle = string.lower(S.filter)
    for _, p in ipairs(S.profiles) do
      local hay = string.lower(tostring(p.name) .. " " .. tostring(p.host) .. " " .. tostring(p.user) .. " " .. tostring(p.driver or ""))
      if needle == "" or string.find(hay, needle, 1, true) then
        out[#out + 1] = p
      end
    end
    return out
  elseif S.view == "databases" then
    return format.filter(S.databases, S.filter)
  elseif S.view == "tables" then
    return format.filter(S.tables, S.filter)
  end
  return {}
end

local function count()
  if S.view == "rows" then
    return #S.rows
  end
  return #items()
end

-- In the row-detail view the arrows walk fields, not rows.
local function navCount()
  if S.view == "rows" and S.detail then
    return #S.detailPairs
  end
  return count()
end

local function move(delta)
  local n = navCount()
  if n == 0 then
    return
  end
  local v = S.sel + delta
  if v < 1 then
    v = 1
  elseif v > n then
    v = n
  end
  S.sel = v
  render()
end

local function activate()
  if S.view == "form" or S.busy then
    return
  end
  if S.view == "rows" then
    if S.detail then
      S.detail = false
    else
      S.detailRow = S.sel
      buildDetail()
      S.sel = 1
      S.detail = true
    end
    render()
    return
  end
  local list = items()
  local it = list[S.sel]
  if it == nil then
    return
  end
  if S.view == "profiles" then
    openProfile(it)
  elseif S.view == "databases" then
    openDatabase(it)
  elseif S.view == "tables" then
    openTable(it)
  end
end

local function goBack()
  if S.busy then
    return
  end
  if S.inputMode ~= "" then
    S.inputMode = ""
    render()
    return
  end
  if S.view == "form" then
    S.view = "profiles"
    S.error = ""
    render()
    return
  end
  if S.view == "rows" then
    if S.detail then
      S.detail = false
      render()
      return
    end
    S.view = "tables"
    S.sel = 1
    if #S.tables == 0 then
      fetchTables()
    else
      render()
    end
    return
  end
  if S.view == "tables" then
    S.view = "databases"
    S.sel = 1
    if #S.databases == 0 then
      fetchDatabases()
    else
      render()
    end
    return
  end
  if S.view == "databases" then
    S.view = "profiles"
    S.sel = 1
    render()
    return
  end
  panel.close()
end

local function refresh()
  if S.busy then
    return
  end
  if S.view == "profiles" then
    fetchProfiles()
  elseif S.view == "databases" then
    fetchDatabases()
  elseif S.view == "tables" then
    fetchTables()
  elseif S.view == "rows" then
    if S.isQuery and S.lastSql ~= "" then
      runSql(S.lastSql)
    else
      fetchRows()
    end
  end
end

local function reloadFresh()
  if S.view ~= "rows" or S.busy then
    return
  end
  S.isQuery = false
  S.lastSql = ""
  S.filter = ""
  resetInputs()
  S.offset = 0
  S.sel = 1
  S.detail = false
  fetchRows()
end

local function prevPage()
  if S.isQuery or S.busy or S.offset <= 0 then
    return
  end
  S.offset = math.max(0, S.offset - S.limit)
  S.sel = 1
  fetchRows()
end

local function nextPage()
  if S.isQuery or S.busy then
    return
  end
  if S.offset + #S.rows < S.total then
    S.offset = S.offset + S.limit
    S.sel = 1
    fetchRows()
  end
end

-- ── SQL autosuggestion ──────────────────────────────────────────────────────
local SQL_KEYWORDS = {
  "SELECT", "FROM", "WHERE", "ORDER BY", "GROUP BY", "HAVING", "LIMIT", "OFFSET",
  "JOIN", "LEFT JOIN", "INNER JOIN", "RIGHT JOIN", "ON", "AS", "AND", "OR", "NOT",
  "IN", "IS NULL", "IS NOT NULL", "LIKE", "ILIKE", "DISTINCT", "CASE", "WHEN",
  "THEN", "ELSE", "END", "COUNT(*)", "SUM(", "AVG(", "MIN(", "MAX(", "DESC", "ASC",
  "UNION", "UNION ALL", "SHOW", "DESCRIBE", "EXPLAIN", "WITH", "VALUES",
}

local function currentToken(text)
  return string.match(text or "", "([%w_]*)$") or ""
end

local computeSuggestions -- forward declaration (ensureSchema calls it)

-- Loads table/column names once per database for the suggestion list.
local function ensureSchema()
  if S.active == nil then
    return
  end
  if S.schemaCache ~= nil and S.schemaCache.db == S.database then
    return
  end
  S.schemaCache = { db = S.database, tables = {} }
  engine.run({ "schema", "--profile", S.active.name, "--db", S.database }, function(ok, data)
    local tables = {}
    if ok and data and data.tables ~= nil then
      tables = data.tables
    end
    S.schemaCache = { db = S.database, tables = tables }
    computeSuggestions()
    render()
  end)
end

computeSuggestions = function()
  local tok = currentToken(S.sqlText)
  if tok == "" then
    S.suggest = {}
    return
  end
  local low = string.lower(tok)
  local seen, out = {}, {}
  local function add(v)
    if v ~= nil and v ~= "" and seen[v] == nil then
      seen[v] = true
      out[#out + 1] = v
    end
  end
  for _, k in ipairs(SQL_KEYWORDS) do
    if string.sub(string.lower(k), 1, #low) == low then
      add(k)
    end
  end
  if S.schemaCache ~= nil then
    for _, t in ipairs(S.schemaCache.tables or {}) do
      add(t.name)
      for _, c in ipairs(t.columns or {}) do
        add(c)
      end
    end
  end
  local capped = {}
  for i = 1, math.min(#out, 6) do
    capped[i] = out[i]
  end
  S.suggest = capped
end

local function insertSuggestion(value)
  local text = S.sqlText or ""
  local n = #currentToken(text)
  local head = string.sub(text, 1, #text - n)
  S.sqlText = head .. value
  S.lastSql = S.sqlText
  S.inputToken = S.inputToken + 1
  S.suggest = {}
  render()
end

local function openInput(mode)
  if S.view ~= "rows" then
    return
  end
  if mode == "search" and S.isQuery then
    return
  end
  S.inputToken = S.inputToken + 1
  S.inputMode = mode
  if mode == "sql" then
    S.sqlText = S.lastSql or ""
    S.suggest = {}
    ensureSchema()
  end
  render()
end

local function applySearch(text)
  S.searchTerm = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  S.offset = 0
  S.sel = 1
  S.inputMode = ""
  fetchRows()
end

local function applyWhere(text)
  S.whereClause = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  S.offset = 0
  S.sel = 1
  S.inputMode = ""
  fetchRows()
end

runSql = function(text)
  local sql = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if sql == "" then
    return
  end
  req({ "query", "--profile", S.active.name, "--db", S.database, "--sql", sql }, function(data)
    if data then
      S.columns = data.columns or {}
      S.rows = data.rows or {}
      S.total = data.total or 0
      S.offset = 0
      S.truncated = data.truncated == true
      S.isQuery = true
      S.lastSql = sql
      S.sqlText = sql
      S.suggest = {}
      S.sel = 1
      S.detail = false
      S.inputMode = ""
      S.status = ""
    end
  end)
end

local function yank()
  if not S.detail then
    return
  end
  local pair = S.detailPairs[S.sel]
  if pair == nil then
    return
  end
  local shown = format.cell(pair.value)
  noctalia.copyToClipboard(shown, "text/plain")
  S.status = "copied: " .. shown
  render()
end

-- ── connection form ─────────────────────────────────────────────────────────
local function emptyForm()
  return { driver = "mysql", name = "", host = "", port = "", user = "", password = "", database = "" }
end

local function openNewForm()
  if S.busy then
    return
  end
  S.form = emptyForm()
  S.formToken = S.formToken + 1
  S.formError = ""
  S.view = "form"
  render()
end

local function openEditForm()
  if S.busy then
    return
  end
  local it = items()[S.sel]
  if it == nil then
    return
  end
  req({ "profile", "get", "--name", it.name }, function(data)
    local p = (data and data.profile) or it
    S.form = {
      driver = p.driver or "mysql",
      name = p.name or "",
      host = p.host or "",
      port = p.port or "",
      user = p.user or "",
      password = p.password or "",
      database = p.database or "",
    }
    S.formToken = S.formToken + 1
    S.formError = ""
    S.view = "form"
  end)
end

local function saveForm()
  local f = S.form
  if f == nil or S.busy then
    return
  end
  if f.name == "" or f.host == "" then
    S.formError = "name and host are required"
    render()
    return
  end
  local payload = {
    name = f.name, driver = f.driver, host = f.host, port = f.port,
    user = f.user, password = f.password, database = f.database,
  }
  S.busy = true
  S.formError = ""
  render()
  engine.saveProfile(payload, function(ok, data)
    S.busy = false
    if not ok then
      S.formError = tostring(data)
      render()
      return
    end
    S.active = payload
    S.view = "profiles"
    S.sel = 1
    fetchProfiles()
  end)
end

local function requestDelete()
  local it = items()[S.sel]
  if it == nil then
    return
  end
  S.confirm = { name = it.name }
  render()
end

local function deleteSelected()
  local name = S.confirm and S.confirm.name
  S.confirm = nil
  if name == nil then
    return
  end
  req({ "profile", "remove", "--name", name }, function()
    S.sel = 1
    fetchProfiles()
  end)
end

-- Creates a SQLite connection pointing at the bundled demo database.
local function addDemoConnection()
  if S.busy then
    return
  end
  local dir = noctalia.pluginDir()
  if dir == nil then
    S.error = "plugin directory unavailable"
    render()
    return
  end
  local profile = { name = "demo", driver = "sqlite", host = dir .. "/demo/demo.db" }
  S.busy = true
  S.error = ""
  render()
  engine.saveProfile(profile, function(ok, data)
    S.busy = false
    if not ok then
      S.error = tostring(data)
      render()
      return
    end
    fetchProfiles()
  end)
end

-- ── keyboard ────────────────────────────────────────────────────────────────
function onKey(chord, pressed)
  if not pressed then
    return
  end
  if S.confirm ~= nil then
    if chord == "Return" then
      deleteSelected()
    elseif chord == "BackSpace" then
      S.confirm = nil
      render()
    end
    return
  end
  -- While a text input is open the host gives it the keys it consumes. If a
  -- Backspace reaches us the input did not take it, so close the input.
  if S.inputMode ~= "" then
    if chord == "BackSpace" then
      S.inputMode = ""
      render()
    end
    return
  end
  if S.view == "form" then
    if chord == "BackSpace" then
      goBack()
    end
    return
  end

  if chord == "Up" then
    move(-1)
  elseif chord == "Down" then
    move(1)
  elseif chord == "Prior" then
    move(-8)
  elseif chord == "Next" then
    move(8)
  elseif chord == "Home" then
    S.sel = 1
    render()
  elseif chord == "End" then
    local n = navCount()
    if n > 0 then
      S.sel = n
      render()
    end
  elseif chord == "Left" then
    if S.view == "rows" then
      if S.detail then
        detailShiftRow(-1)
      else
        prevPage()
      end
    end
  elseif chord == "Right" then
    if S.view == "rows" then
      if S.detail then
        detailShiftRow(1)
      else
        nextPage()
      end
    end
  elseif chord == "Return" then
    activate()
  elseif chord == "BackSpace" then
    goBack()
  elseif chord == "n" then
    if S.view == "profiles" then
      openNewForm()
    end
  elseif chord == "e" then
    if S.view == "profiles" then
      openEditForm()
    end
  elseif chord == "d" then
    if S.view == "profiles" then
      requestDelete()
    end
  elseif chord == "q" then
    if S.view == "rows" then
      openInput("sql")
    end
  elseif chord == "w" then
    if S.view == "rows" and not S.isQuery then
      openInput("where")
    end
  elseif chord == "slash" then
    if S.view == "rows" and not S.isQuery then
      openInput("search")
    end
  elseif chord == "r" then
    refresh()
  elseif chord == "shift+R" then
    reloadFresh()
  elseif chord == "y" then
    if S.view == "rows" and S.detail then
      yank()
    end
  end
end

-- ── rendering ───────────────────────────────────────────────────────────────
local function screen()
  local outs = noctalia.outputs()
  if outs ~= nil then
    for _, o in ipairs(outs) do
      if o.focused then
        return o.width, o.height
      end
    end
    if outs[1] ~= nil then
      return outs[1].width, outs[1].height
    end
  end
  return 1600, 900
end

local function title()
  if S.view == "profiles" then
    return "Connections"
  elseif S.view == "databases" then
    return "Databases"
  elseif S.view == "tables" then
    return "Tables"
  elseif S.view == "form" then
    return S.form and S.form.name ~= "" and S.form.name or "New connection"
  end
  if S.isQuery then
    return "Query result"
  end
  return S.table
end

local function breadcrumb()
  local parts = {}
  if S.active ~= nil then
    parts[#parts + 1] = S.active.name
  end
  if S.database ~= "" then
    parts[#parts + 1] = S.database
  end
  if S.view == "rows" and not S.isQuery and S.table ~= "" then
    parts[#parts + 1] = S.table
  end
  return table.concat(parts, "  ›  ")
end

local function hint()
  if S.view == "profiles" then
    return "↑ ↓ move · ⏎ open · n new · e edit · d delete · backspace back"
  elseif S.view == "databases" or S.view == "tables" then
    return "type to filter · ⏎ open · r refresh · backspace back"
  elseif S.view == "rows" then
    if S.detail then
      return "↑ ↓ field · y copy · ⏎ back to data · backspace back"
    end
    return "↑ ↓ row · ⏎ detail · / search · w where · q sql · ← → page · r refresh"
  elseif S.view == "form" then
    return "fill the fields · Save / Cancel"
  end
  return ""
end

local function header()
  local bc = breadcrumb()
  return ui.row({ key = "header", align = "center", gap = 12 }, {
    ui.column({ key = "ht", gap = 2, flexGrow = 1 }, {
      ui.label({ key = "t", text = title(), fontSize = 18, fontWeight = "bold", color = "on_surface", maxLines = 1 }),
      ui.label({ key = "b", text = bc, fontSize = 11, color = "on_surface_variant", visible = bc ~= "", maxLines = 1 }),
    }),
    ui.label({ key = "meta", text = S.busy and "loading…" or hint(), fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
  })
end

local function notice()
  local text = S.error ~= "" and S.error or S.status
  if text == "" then
    return nil
  end
  return ui.label({
    key = "notice",
    text = text,
    fontSize = 12,
    color = S.error ~= "" and "error" or "on_surface_variant",
    maxLines = 2,
  })
end

local function filterInput(availW)
  return ui.input({
    key = "filter-" .. S.view,
    value = S.filter,
    placeholder = "Filter…",
    controlSize = "sm",
    fontSize = 12,
    width = availW,
    onChange = function(v)
      S.filter = v
      S.sel = 1
      render()
    end,
  })
end

local function listRow(props, children)
  return ui.row(props, children)
end

local function listBody(availW, sub)
  local itemsList = items()
  if #itemsList == 0 then
    if S.view == "profiles" and not S.busy then
      return ui.column({ key = "empty", flexGrow = 1, align = "center", justify = "center", gap = 10 }, {
        ui.label({ key = "e1", text = "No connections yet", fontSize = 13, color = "on_surface_variant" }),
        ui.button({
          key = "demo",
          text = "Add demo connection (SQLite)",
          variant = "primary",
          onClick = function()
            addDemoConnection()
          end,
        }),
        ui.label({ key = "e2", text = "or press n to add your own", fontSize = 11, color = "on_surface_variant" }),
      })
    end
    return ui.column({ key = "empty", flexGrow = 1, align = "center", justify = "center" }, {
      ui.label({ key = "e", text = S.busy and "loading…" or "No entries", fontSize = 13, color = "on_surface_variant" }),
    })
  end
  local nodes = {}
  for i, it in ipairs(itemsList) do
    local idx = i
    local name, detail
    if S.view == "profiles" then
      name = it.name
      detail = tostring(it.user or "") .. "@" .. tostring(it.host or "") .. (it.port ~= nil and it.port ~= "" and (":" .. tostring(it.port)) or "") ..
        (it.database ~= nil and it.database ~= "" and ("  ·  " .. it.database) or "")
    else
      name = tostring(it)
      detail = ""
    end
    local props = {
      key = "row-" .. tostring(idx) .. "-" .. name,
      align = "center",
      height = 34,
      radius = 6,
      paddingH = 8,
      onClick = function()
        S.sel = idx
        activate()
      end,
      onHover = function(state)
        if state == "true" then
          S.sel = idx
          render()
        end
      end,
    }
    if idx == S.sel then
      props.fill = "hover"
    end
    local selected = idx == S.sel
    local cells = {
      ui.label({ key = "n", text = name, fontSize = 13, fontWeight = "bold", color = selected and "on_hover" or "on_surface", width = math.floor(availW * 0.34), maxLines = 1 }),
    }
    if S.view == "profiles" then
      cells[#cells + 1] = ui.label({ key = "d", text = detail, fontSize = 11, color = selected and "on_hover" or "on_surface_variant", flexGrow = 1, maxLines = 1 })
      cells[#cells + 1] = ui.label({ key = "dr", text = tostring(it.driver or "mysql"), fontSize = 10, color = "primary" })
    end
    nodes[#nodes + 1] = listRow(props, cells)
  end
  return ui.scroll({ key = "list-scroll", flexGrow = 1, paddingV = 4 }, nodes)
end

local function tableBody(availW)
  local cols = S.columns
  if #cols == 0 then
    return ui.column({ key = "empty", flexGrow = 1, align = "center", justify = "center" }, {
      ui.label({ key = "e", text = S.busy and "loading…" or "No rows", fontSize = 13, color = "on_surface_variant" }),
    })
  end
  local widths = format.fitWidths(cols, S.rows, availW - 16, 7, CELL_GAP)
  local headCells = {}
  for c = 1, #cols do
    headCells[#headCells + 1] = ui.label({
      key = "h" .. c, text = tostring(cols[c]), fontSize = 12, fontWeight = "bold",
      color = "on_surface", width = widths[c], maxLines = 1,
    })
  end
  local headerRow = ui.row({
    key = "thead", align = "center", height = 30, paddingH = 10, gap = CELL_GAP,
    fill = "surface_variant", radius = 6,
  }, headCells)

  local nodes = {}
  for r, row in ipairs(S.rows) do
    local idx = r
    local selected = idx == S.sel
    local cells = {}
    for c = 1, #cols do
      local v = row[c]
      local color = "on_surface"
      if format.isNull(v) then
        color = selected and "on_hover" or "on_surface_variant"
      elseif selected then
        color = "on_hover"
      end
      cells[#cells + 1] = ui.label({
        key = "c" .. c,
        text = format.cell(v),
        fontSize = 12,
        width = widths[c],
        maxLines = 1,
        color = color,
      })
    end
    local props = {
      key = "r-" .. tostring(idx),
      align = "center",
      height = 30,
      paddingH = 10,
      gap = CELL_GAP,
      radius = 6,
      onClick = function()
        S.sel = idx
        render()
      end,
      onHover = function(state)
        if state == "true" then
          S.sel = idx
          render()
        end
      end,
    }
    if selected then
      props.fill = "hover"
    elseif idx % 2 == 0 then
      props.fill = "surface_variant/0.35"
    end
    nodes[#nodes + 1] = ui.row(props, cells)
  end
  return ui.column({ key = "table", flexGrow = 1, gap = 2 }, {
    headerRow,
    ui.separator({ key = "trule", color = "outline/0.5" }),
    ui.scroll({ key = "rows-scroll", flexGrow = 1, gap = 1 }, nodes),
  })
end

local function detailBody(availW)
  local fw = math.min(math.max(120, math.floor(availW * 0.3)), 320)
  local head = ui.row({ key = "dhead", align = "center", height = 30, paddingH = 10, gap = CELL_GAP, fill = "surface_variant", radius = 6 }, {
    ui.label({ key = "f", text = "Field", fontSize = 12, fontWeight = "bold", width = fw, maxLines = 1 }),
    ui.label({ key = "v", text = "Value", fontSize = 12, fontWeight = "bold", color = "on_surface", flexGrow = 1, maxLines = 1 }),
  })
  local nodes = {}
  for i, pair in ipairs(S.detailPairs) do
    local idx = i
    local selected = idx == S.sel
    local props = {
      key = "dp-" .. tostring(idx),
      align = "center",
      height = 30,
      paddingH = 10,
      gap = CELL_GAP,
      radius = 6,
      onClick = function()
        S.sel = idx
        render()
      end,
      onHover = function(state)
        if state == "true" then
          S.sel = idx
          render()
        end
      end,
    }
    if selected then
      props.fill = "hover"
    elseif idx % 2 == 0 then
      props.fill = "surface_variant/0.35"
    end
    nodes[#nodes + 1] = ui.row(props, {
      ui.label({ key = "f", text = tostring(pair.field), fontSize = 12, fontWeight = "bold", width = fw, maxLines = 1, color = selected and "on_hover" or "on_surface" }),
      ui.label({
        key = "v", text = format.cell(pair.value), fontSize = 12, flexGrow = 1, maxLines = 1,
        color = format.isNull(pair.value) and (selected and "on_hover" or "on_surface_variant") or (selected and "on_hover" or "on_surface"),
      }),
    })
  end
  return ui.column({ key = "detail", flexGrow = 1, gap = 2 }, {
    head,
    ui.separator({ key = "drule", color = "outline/0.5" }),
    ui.scroll({ key = "detail-scroll", flexGrow = 1, gap = 1 }, nodes),
  })
end

local function formField(key, label, value, placeholder, password, onChange, grow)
  local colProps = { key = "ff-" .. key, gap = 3 }
  if grow then
    colProps.flexGrow = 1
  end
  return ui.column(colProps, {
    ui.label({ key = "l-" .. key, text = label, fontSize = 11, color = "on_surface_variant" }),
    ui.input({
      key = "f-" .. tostring(S.formToken) .. "-" .. key,
      value = value,
      placeholder = placeholder,
      fontSize = 13,
      password = password == true,
      onChange = onChange,
    }),
  })
end

local function formBody(availW)
  local f = S.form
  if f == nil then
    return ui.column({ key = "empty", flexGrow = 1 })
  end
  local W = math.min(availW, 560)

  local function driverBtn(driver, label)
    return ui.button({
      key = "drv-" .. driver,
      text = label,
      variant = f.driver == driver and "primary" or "outline",
      selected = f.driver == driver,
      controlSize = "sm",
      onClick = function()
        f.driver = driver
        render()
      end,
    })
  end

  local fields = {
    ui.column({ key = "ff-driver", gap = 3 }, {
      ui.label({ key = "l-driver", text = "Driver", fontSize = 11, color = "on_surface_variant" }),
      ui.row({ key = "drivers", gap = 6 }, {
        driverBtn("mysql", "MySQL"),
        driverBtn("postgres", "PostgreSQL"),
        driverBtn("sqlite", "SQLite"),
      }),
    }),
  }

  fields[#fields + 1] = formField("name", "Name", f.name, "e.g. local", false, function(v) f.name = v end)
  fields[#fields + 1] = formField(
    "host",
    f.driver == "sqlite" and "SQLite file" or "Host",
    f.host,
    f.driver == "sqlite" and "/path/to/db.sqlite" or "127.0.0.1",
    false,
    function(v) f.host = v end
  )

  if f.driver ~= "sqlite" then
    fields[#fields + 1] = ui.row({ key = "row-port-user", gap = 10, align = "start" }, {
      formField("port", "Port", f.port, f.driver == "postgres" and "5432" or "3306", false, function(v) f.port = v end, true),
      formField("user", "User", f.user, "user", false, function(v) f.user = v end, true),
    })
    fields[#fields + 1] = formField("password", "Password", f.password, "••••••", true, function(v) f.password = v end)
  end
  fields[#fields + 1] = formField("database", "Default database (optional)", f.database, "", false, function(v) f.database = v end)

  if S.formError ~= "" then
    fields[#fields + 1] = ui.label({ key = "ferr", text = S.formError, fontSize = 12, color = "error", maxLines = 2 })
  end
  fields[#fields + 1] = ui.row({ key = "factions", gap = 8, justify = "end" }, {
    ui.button({ key = "cancel", text = "Cancel", variant = "outline", onClick = function() goBack() end }),
    ui.button({ key = "save", text = "Save", variant = "primary", onClick = function() saveForm() end }),
  })

  return ui.column({ key = "form", flexGrow = 1, gap = 10, align = "start" }, {
    ui.label({
      key = "ftitle",
      text = f.name ~= "" and ("Edit connection — " .. f.name) or "New connection",
      fontSize = 15,
      fontWeight = "bold",
      color = "on_surface",
    }),
    ui.scroll({ key = "formscroll", flexGrow = 1 }, {
      ui.column({ key = "formcol", gap = 10, width = W }, fields),
    }),
  })
end

local function inputBar(availW)
  if S.inputMode == "" then
    return nil
  end
  local placeholder = "Search all columns… (⏎ apply)"
  if S.inputMode == "where" then
    placeholder = "WHERE … (⏎ apply · empty clears)"
  elseif S.inputMode == "sql" then
    placeholder = "Read-only SQL… (⏎ run)"
  end
  local seed = ""
  if S.inputMode == "search" then
    seed = S.searchTerm
  elseif S.inputMode == "where" then
    seed = S.whereClause
  elseif S.inputMode == "sql" then
    seed = S.sqlText
  end

  local row = ui.row({ key = "inputbar", gap = 8, align = "center" }, {
    ui.input({
      key = "in-" .. S.inputMode .. "-" .. tostring(S.inputToken),
      value = seed,
      placeholder = placeholder,
      fontSize = 13,
      flexGrow = 1,
      focus = true,
      submitOnEnter = true,
      onChange = function(v)
        if S.inputMode == "sql" then
          S.sqlText = v
          S.lastSql = v
          computeSuggestions()
          render()
        elseif S.inputMode == "search" then
          S.searchTerm = v
        else
          S.whereClause = v
        end
      end,
      onSubmit = function()
        if S.inputMode == "search" then
          applySearch(S.searchTerm)
        elseif S.inputMode == "where" then
          applyWhere(S.whereClause)
        else
          runSql(S.sqlText)
        end
      end,
    }),
    ui.button({ key = "iclose", text = "Close", variant = "ghost", controlSize = "sm", onClick = function()
      S.inputMode = ""
      S.suggest = {}
      render()
    end }),
  })

  local children = { row }
  if S.inputMode == "sql" and #S.suggest > 0 then
    local btns = {}
    for _, s in ipairs(S.suggest) do
      btns[#btns + 1] = ui.button({
        key = "sg-" .. s,
        text = s,
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          insertSuggestion(s)
        end,
      })
    end
    children[#children + 1] = ui.row({ key = "suggest", gap = 6, align = "center" }, btns)
  end
  return ui.column({ key = "inputwrap", gap = 6 }, children)
end

local function footer(availW)
  local left
  local buttons = {}
  if S.view == "rows" then
    if S.detail then
      left = "row " .. tostring(S.detailRow) .. " / " .. tostring(#S.rows) .. "  ·  field " .. tostring(S.sel) .. " / " .. tostring(#S.detailPairs)
    else
      left = format.rangeLabel(S.offset, #S.rows, S.total, S.truncated)
    end
    buttons[#buttons + 1] = ui.button({
      key = "prev", text = "◀ Prev", variant = "ghost", controlSize = "sm",
      enabled = not S.isQuery and S.offset > 0,
      onClick = function() prevPage() end,
    })
    buttons[#buttons + 1] = ui.button({
      key = "next", text = "Next ▶", variant = "ghost", controlSize = "sm",
      enabled = not S.isQuery and (S.offset + #S.rows) < S.total,
      onClick = function() nextPage() end,
    })
  elseif S.view == "profiles" then
    left = "n new · e edit · d delete"
    buttons[#buttons + 1] = ui.button({ key = "new", text = "New", variant = "primary", controlSize = "sm", onClick = function() openNewForm() end })
    buttons[#buttons + 1] = ui.button({ key = "edit", text = "Edit", variant = "outline", controlSize = "sm", onClick = function() openEditForm() end })
    buttons[#buttons + 1] = ui.button({ key = "del", text = "Delete", variant = "destructive", controlSize = "sm", onClick = function() requestDelete() end })
  else
    left = hint()
  end
  if S.isQuery and S.lastSql ~= "" then
    left = (left or "") .. "  ·  " .. S.lastSql
  end
  return ui.row({ key = "footer", align = "center", gap = 8 }, {
    ui.label({ key = "left", text = left or "", fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
    ui.row({ key = "btns", gap = 6 }, buttons),
  })
end

local function confirmBar()
  if S.confirm == nil then
    return nil
  end
  return ui.row({ key = "confirm", gap = 8, align = "center", fill = "error/0.15", radius = 8, paddingH = 10, paddingV = 6 }, {
    ui.label({ key = "msg", text = 'Remove connection "' .. tostring(S.confirm.name) .. '"?', fontSize = 12, color = "on_surface", flexGrow = 1 }),
    ui.button({ key = "rm", text = "Remove", variant = "destructive", controlSize = "sm", onClick = function() deleteSelected() end }),
    ui.button({ key = "cx", text = "Cancel", variant = "outline", controlSize = "sm", onClick = function()
      S.confirm = nil
      render()
    end }),
  })
end

local function body(availW)
  if S.view == "form" then
    return formBody(availW)
  elseif S.view == "rows" then
    if S.detail then
      return detailBody(availW)
    end
    return tableBody(availW)
  end
  return listBody(availW)
end

-- Fixed panel size (mirrors plugin.toml); the host still clamps it to the output.
local PANEL_W = 1180
local PANEL_PAD = 18

render = function()
  if not S.open then
    return
  end
  local sw = screen()
  local inner = math.max(500, math.min(PANEL_W, sw) - 2 * PANEL_PAD)

  local children = { header() }
  local n = notice()
  if n ~= nil then
    children[#children + 1] = n
  end
  children[#children + 1] = ui.separator({ key = "sep", color = "outline/0.5" })

  if S.view == "profiles" or S.view == "databases" or S.view == "tables" then
    children[#children + 1] = filterInput(inner)
  end
  local ib = inputBar(inner)
  if ib ~= nil then
    children[#children + 1] = ib
  end

  children[#children + 1] = body(inner)
  children[#children + 1] = confirmBar()
  children[#children + 1] = footer(inner)

  panel.render(ui.column({ key = "root", flexGrow = 1, padding = PANEL_PAD, gap = 10 }, children))
end

-- ── lifecycle ───────────────────────────────────────────────────────────────
local function jumpToSummon()
  local raw = noctalia.state.get("summon")
  noctalia.state.set("summon", "")
  if raw == nil or raw == "" then
    return false
  end
  local data = noctalia.json.decode(raw)
  if type(data) ~= "table" or data.profile == nil or data.profile == "" then
    return false
  end
  S.active = { name = data.profile }
  S.database = data.database or ""
  S.table = data.table or ""
  S.isQuery = false
  S.offset = 0
  S.sel = 1
  if data.table ~= nil and data.table ~= "" then
    S.view = "rows"
    fetchRows()
  elseif S.database ~= "" then
    S.view = "tables"
    fetchTables()
  else
    S.view = "databases"
    fetchDatabases()
  end
  return true
end

function onOpen(_context)
  S.open = true
  S.error = ""
  S.status = ""
  S.confirm = nil
  S.inputMode = ""
  S.detail = false
  if jumpToSummon() then
    return
  end
  if #S.profiles == 0 then
    S.view = "profiles"
    S.sel = 1
    fetchProfiles()
  else
    render()
  end
end

function onClose()
  S.open = false
  S.busy = false
end

function onIpc(event, _payload)
  if event == "refresh" then
    refresh()
  elseif event == "toggle" or event == "open" then
    noctalia.togglePanel(PANEL_ID)
  end
end
