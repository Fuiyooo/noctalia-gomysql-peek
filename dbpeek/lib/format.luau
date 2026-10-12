-- format.luau — parsing/format helpers ported from the omarchy plugin's Peek.js,
-- plus a width-fitting routine for the declarative table view.

local M = {}

function M.cell(v)
  if v == nil then
    return "NULL"
  end
  return tostring(v)
end

function M.isNull(v)
  return v == nil
end

-- Case-insensitive substring filter over a list of strings.
function M.filter(list, needle)
  if needle == nil or needle == "" then
    return list
  end
  local n = string.lower(needle)
  local out = {}
  for _, item in ipairs(list) do
    if string.find(string.lower(tostring(item)), n, 1, true) then
      out[#out + 1] = item
    end
  end
  return out
end

-- Column widths in pixels, fitted to the available width so wide tables clip
-- gracefully instead of overflowing (ui.scroll only scrolls vertically).
-- `gap` is the per-cell gap the row renders with, reserved up front so the
-- computed widths plus gaps still fit the available width.
function M.fitWidths(cols, rows, avail, charW, gap)
  charW = charW or 7
  gap = gap or 0
  local n = #cols
  if n == 0 then
    return {}
  end
  local usable = avail - gap * (n - 1)
  if usable < 1 then
    usable = 1
  end
  local mins, maxs = {}, {}
  for c = 1, n do
    local head = #tostring(cols[c])
    local mx = head
    local sample = math.min(#rows, 60)
    for r = 1, sample do
      local row = rows[r]
      local v = row and row[c]
      local len = (v == nil) and 4 or #tostring(v)
      if len > mx then
        mx = len
      end
    end
    mins[c] = math.max(54, math.floor(head * charW) + 18)
    maxs[c] = math.max(mins[c], math.min(math.floor(mx * charW) + 18, 300))
  end

  local total = 0
  for c = 1, n do
    total = total + maxs[c]
  end
  if total <= usable then
    return maxs
  end

  local widths = {}
  local factor = usable / total
  for c = 1, n do
    local w = math.floor(maxs[c] * factor)
    if w < mins[c] then
      w = mins[c]
    end
    widths[c] = w
  end
  return widths
end

function M.rangeLabel(offset, shown, total, truncated)
  if shown == 0 then
    return "no rows"
  end
  local from = offset + 1
  local to = offset + shown
  if truncated then
    return from .. "\u{2013}" .. to .. " (capped)"
  end
  return from .. "\u{2013}" .. to .. " of " .. tostring(total)
end

return M
