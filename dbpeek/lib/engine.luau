-- engine.luau — thin async wrapper around the dbpeek Go engine.
--
-- Everything goes through noctalia.runAsync with an argv array (no shell), so
-- profile names, SQL and paths are passed as literal arguments. Credentials are
-- never sent on the command line: the engine reads `profile save` input from a
-- private 0600 file (--from-file), because the Noctalia plugin runtime has no
-- stdin.

local M = {}

local bin = "~/.local/bin/dbpeek-engine"
local connfile = ""
local ready = false

-- Only one engine process at a time; extra requests queue behind it.
local busy = false
local queued = nil

function M.configure(opts)
  if opts.bin and opts.bin ~= "" then
    bin = opts.bin
  end
  if opts.connfile and opts.connfile ~= "" then
    connfile = opts.connfile
  end
  ready = true
end

local function trim(s)
  s = tostring(s or "")
  s = string.gsub(s, "%s+", " ")
  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  return s
end

local function argv(args)
  local a = { bin }
  if connfile ~= "" then
    a[#a + 1] = "--connections"
    a[#a + 1] = connfile
  end
  for i = 1, #args do
    a[#a + 1] = args[i]
  end
  return a
end

local function drain()
  if queued == nil then
    return
  end
  local q = queued
  queued = nil
  M.run(q.args, q.cb)
end

local function execute(args, cb)
  busy = true
  local accepted = noctalia.runAsync(argv(args), function(result)
    busy = false
    if result == nil then
      cb(false, "engine produced no result")
    elseif result.exitCode ~= 0 then
      local msg = trim(result.stderr)
      cb(false, msg ~= "" and msg or ("engine failed (exit " .. tostring(result.exitCode) .. ")"))
    else
      local data, err = noctalia.json.decode(result.stdout or "")
      if data == nil then
        cb(false, "bad engine output: " .. tostring(err))
      else
        cb(true, data)
      end
    end
    drain()
  end, 60000)
  if not accepted then
    busy = false
    cb(false, "could not start engine — check engine_path in the plugin settings")
  end
end

-- run(args, cb): args is the engine argv after the binary (e.g. {"profiles"}).
-- cb(ok, dataOrError).
function M.run(args, cb)
  if not ready then
    cb(false, "engine not configured")
    return
  end
  if busy then
    queued = { args = args, cb = cb }
    return
  end
  execute(args, cb)
end

-- saveProfile(profileTable, cb): publishes the profile via a private temp file
-- so the password never reaches argv.
function M.saveProfile(profile, cb)
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    cb(false, "plugin data dir unavailable")
    return
  end
  local tmp = dir .. "/profile.tmp.json"
  local encoded, encErr = noctalia.json.encode(profile)
  if encoded == nil then
    cb(false, "cannot encode profile: " .. tostring(encErr))
    return
  end
  local ok, werr = noctalia.writeFile(tmp, encoded)
  if ok == false then
    cb(false, "cannot write profile file: " .. tostring(werr))
    return
  end
  M.run({ "profile", "save", "--from-file", tmp }, function(success, data)
    noctalia.removeFile(tmp)
    cb(success, data)
  end)
end

return M
