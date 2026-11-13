local M = {}

local PRIORITY = { blocked = 1, error = 2, done = 3 }

local TITLES = {
  permission = "Claude needs approval",
  question = "Claude has a question",
  auth = "Claude needs sign-in",
}

function M.transition(entry, record, now, min_working)
  if not record then
    return nil, nil
  end
  local previous = entry and entry.state
  local since = entry and entry.working_since
  local state = record.state
  if state == previous then
    return entry, nil
  end
  local event
  if state == "working" then
    if previous ~= "working" and previous ~= "blocked" then
      since = now
    end
  elseif state == "blocked" then
    event = "blocked"
  elseif state == "error" then
    event = "error"
    since = nil
  elseif state == "done" then
    if since and now - since >= min_working then
      event = "done"
    end
    since = nil
  else
    since = nil
  end
  return { state = state, working_since = since }, event
end

function M.worked(entry, now)
  if entry and entry.working_since then
    return now - entry.working_since
  end
  return nil
end

function M.duration(seconds)
  seconds = math.floor(seconds)
  if seconds < 60 then
    return seconds .. "s"
  end
  if seconds < 3600 then
    return math.floor(seconds / 60) .. "m " .. (seconds % 60) .. "s"
  end
  return math.floor(seconds / 3600) .. "h " .. math.floor((seconds % 3600) / 60) .. "m"
end

function M.text(info)
  local title
  if info.event == "blocked" then
    title = TITLES[info.kind] or "Claude is blocked"
  elseif info.event == "done" then
    title = "Claude finished"
  else
    title = "Claude failed"
  end
  local parts = {}
  for _, part in ipairs({ info.host or "", info.session or "", info.window or "" }) do
    if part ~= "" then
      parts[#parts + 1] = part
    end
  end
  local body = info.msg or ""
  if info.event == "done" then
    body = info.worked and ("Worked for " .. M.duration(info.worked)) or ""
  end
  return title, table.concat(parts, " › "), body
end

local function quote(text)
  text = tostring(text or ""):gsub("%c", " ")
  text = text:gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. text .. '"'
end

function M.applescript(title, subtitle, body)
  return "display notification " .. quote(body) .. " with title " .. quote(title) .. " subtitle " .. quote(subtitle)
end

function M.locate(view, block_id)
  if type(view) ~= "table" then
    return nil
  end
  for _, window in ipairs(view.windows or {}) do
    for _, layer in ipairs(window.layers or {}) do
      for _, block in ipairs(layer.blocks or {}) do
        if block.block_id == block_id then
          return {
            session_label = view.label,
            window_id = window.window_id,
            window_label = window.label,
            focused = window.window_id == view.active_window_id and window.focused_block_id == block_id,
          }
        end
      end
    end
  end
  return nil
end

function M.order(items)
  local kept = {}
  for _, item in ipairs(items) do
    if PRIORITY[item.state] then
      kept[#kept + 1] = item
    end
  end
  table.sort(kept, function(a, b)
    if PRIORITY[a.state] ~= PRIORITY[b.state] then
      return PRIORITY[a.state] < PRIORITY[b.state]
    end
    local at, bt = a.updated_at or "", b.updated_at or ""
    if at ~= bt then
      return at < bt
    end
    return (a.block_id or "") < (b.block_id or "")
  end)
  return kept
end

function M.next(ordered, current_block_id)
  if #ordered == 0 then
    return nil
  end
  for i, item in ipairs(ordered) do
    if item.block_id == current_block_id then
      return ordered[i % #ordered + 1]
    end
  end
  return ordered[1]
end

function M.root(records)
  for _, record in ipairs(records or {}) do
    if record.id == nil or record.id == "" then
      return record
    end
  end
  return nil
end

function M.is_rex(info)
  return type(info) == "string" and info:find('bundleID="com.superlogical.rex"', 1, true) ~= nil
end

function M.handle(deps, state, ctx, ev)
  local record
  if ev.ids then
    local root_removed = false
    for _, id in ipairs(ev.ids) do
      if id == "" then
        root_removed = true
      end
    end
    if not root_removed then
      return
    end
  else
    if ev.id and ev.id ~= "" then
      return
    end
    record = ev.record
    if type(record) ~= "table" then
      return
    end
  end

  local block_id = ctx.block_id
  local now = deps.now()
  local slot = state[block_id] or {}
  state[block_id] = slot
  local worked = M.worked(slot.entry, now)
  local entry, event = M.transition(slot.entry, record, now, deps.min_working or 30)
  slot.entry = entry
  if not event then
    return
  end
  if slot.notified_at and now - slot.notified_at < 5 then
    return
  end
  local where = M.locate(deps.view(ctx.session_id), block_id)
  if where and where.focused and deps.frontmost() then
    return
  end
  slot.notified_at = now
  deps.notify(M.text({
    event = event,
    kind = record.kind,
    msg = record.msg,
    host = deps.host,
    session = where and where.session_label,
    window = where and where.window_label,
    worked = worked,
  }))
end

return M
