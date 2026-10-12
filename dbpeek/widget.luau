-- widget.luau — bar widget for DB Peek: a database glyph that toggles the panel.
--
-- It also hosts the IPC entry point for deep links: the widget is always loaded
-- (unlike the panel), so `summon` stores the request in the shared state channel
-- and opens the panel, which picks it up in onOpen().

local PANEL_ID = "fuiyooo/dbpeek:peek"

local function paint()
  barWidget.setGlyph("database")
  barWidget.setTooltip("DB Peek — browse database data")
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function onIpc(event, payload)
  if event == "summon" then
    -- payload is a JSON string: {"profile":"name","database":"db","table":"t"}
    noctalia.state.set("summon", payload or "")
    noctalia.togglePanel(PANEL_ID)
  elseif event == "toggle" or event == "open" or event == "refresh" then
    noctalia.togglePanel(PANEL_ID)
  end
end

function onExit(_signal, reason)
  noctalia.state.set("summon", "")
end

paint()
