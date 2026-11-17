local source = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
local dir = source:match("^@(.*)/[^/]*$")
if dir then
  package.path = dir .. "/?.lua;" .. package.path
end

local S = require("rextina_status")
local Restore = require("rextina_restore")
local Save = require("rextina_save")

local M = {}

local TERMINAL = "com.superlogical.terminal"

local function attached(api, session_id, method, args)
  local result, err = api.call(method, args)
  if result ~= nil then
    return result, err, false
  end
  if not api.call("session.attach", { session_id = session_id }) then
    return nil, err, false
  end
  result, err = api.call(method, args)
  return result, err, true
end

function M.collect(api, host)
  local items = {}
  local listed = api.call("session.list")
  if type(listed) ~= "table" then
    return items
  end
  for _, session in ipairs(listed.sessions or {}) do
    local view, _, did_attach = attached(api, session.session_id, "session.view", { session_id = session.session_id })
    for _, window in ipairs(type(view) == "table" and view.windows or {}) do
      for _, layer in ipairs(window.layers or {}) do
        for _, block in ipairs(layer.blocks or {}) do
          if block.creator_name == TERMINAL then
            local status = api.call("block.method", {
              session_id = session.session_id,
              block_id = block.block_id,
              method = "program_status",
            })
            local record = type(status) == "table" and S.root(status.records)
            if record then
              items[#items + 1] = {
                host = host,
                session_id = session.session_id,
                window_id = window.window_id,
                block_id = block.block_id,
                state = record.state,
                updated_at = record.updated_at,
              }
            end
          end
        end
      end
    end
    if did_attach then
      api.call("session.detach", { session_id = session.session_id })
    end
  end
  return items
end

function M.find_next(apis, current_block_id, last_block_id, seen)
  seen = seen or {}
  local candidates, known, still_seen = {}, {}, {}
  for _, entry in ipairs(apis) do
    for _, item in ipairs(M.collect(entry.api, entry.host)) do
      if not known[item.block_id] then
        known[item.block_id] = true
        local stamp = item.updated_at or ""
        if item.state == "done" and item.block_id == current_block_id then
          seen[item.block_id] = stamp
        end
        if item.state == "done" and seen[item.block_id] == stamp then
          still_seen[item.block_id] = true
        else
          candidates[#candidates + 1] = item
        end
      end
    end
  end
  for block_id in pairs(seen) do
    if not still_seen[block_id] then
      seen[block_id] = nil
    end
  end
  local ordered = S.order(candidates)
  local from = last_block_id
  for _, item in ipairs(ordered) do
    if item.block_id == current_block_id then
      from = current_block_id
    end
  end
  local target = S.next(ordered, from)
  if target and target.state == "done" then
    seen[target.block_id] = target.updated_at or ""
  end
  return target
end

function M.go(item, apis, queue)
  for _, entry in ipairs(apis) do
    if entry.host == item.host then
      local _, _, did_attach = attached(entry.api, item.session_id, "session.focus_block",
        { session_id = item.session_id, block_id = item.block_id })
      if did_attach then
        entry.api.call("session.detach", { session_id = item.session_id })
      end
      break
    end
  end
  pcall(queue, "session.select", { session_id = item.session_id, window_id = item.window_id })
end

function M.local_apis(lib)
  return { { api = { call = lib.call } } }
end

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.restore_action(lib, args)
  args = args or {}
  local status = lib.call("server.status")
  if type(status) ~= "table" or not status.instance_id then
    return { restored = false, reason = "no server" }
  end
  local store = Save.store(lib, { dir = args.dir })
  local save, reason = Restore.choose(store:read_all(), status.instance_id, args.save)
  if not save then
    return { restored = false, reason = reason }
  end
  if not Restore.from_here(save, status) then
    return { restored = false, reason = "other machine", host = save.host }
  end
  local joined = {}
  local report = Restore.restore(save, {
    live = function()
      local current = Restore.build(Save.deps(lib, nil, joined), true)
      return current and current.sessions or {}
    end,
    write = function(session_id, block_id, text)
      return lib.call("block.method", {
        session_id = session_id,
        block_id = block_id,
        method = "write",
        args = { data = text },
      }) ~= nil
    end,
    create = function(create_args)
      return lib.call("session.create", create_args)
    end,
    focus_window = function(session_id, window_id)
      lib.call("session.focus_window", { session_id = session_id, window_id = window_id })
    end,
    dir_exists = function(path)
      local found = lib.exec({ "test", "-d", path })
      return found ~= nil and found.ok == true
    end,
    now = now,
    persist = function(changed)
      store:write(changed)
    end,
  }, args.save ~= nil)
  for _, session_id in ipairs(joined) do
    lib.call("session.detach", { session_id = session_id })
  end
  report.restored = true
  report.instance_id = save.instance_id
  return report
end

function M.saves_action(lib, args)
  args = args or {}
  local status = lib.call("server.status")
  local running = type(status) == "table" and status.instance_id or nil
  local saves = Save.store(lib, { dir = args.dir }):read_all()
  table.sort(saves, function(a, b)
    return (a.saved_at or "") > (b.saved_at or "")
  end)
  local list = {}
  for i, save in ipairs(saves) do
    local state = "open"
    if save.instance_id == running then
      state = "running"
    elseif Restore.is_trivial(save) then
      state = "trivial"
    elseif save.closed_at then
      state = "closed"
    end
    list[i] = {
      instance_id = save.instance_id,
      saved_at = save.saved_at,
      host = save.host,
      sessions = #save.sessions,
      state = state,
    }
  end
  return list
end

function M.save_restart_action(lib, args, queue)
  args = args or {}
  local save, _, reason = Save.run(lib, { dir = args.dir })
  if not save and reason ~= "empty" and reason ~= "incomplete" then
    return { restarting = false, reason = reason }
  end
  queue("client.server.restart")
  return { restarting = true }
end

local memory = { seen = {} }

if rex and rex.action then
  rex.action({
    name = "rextina_next",
    title = "Go to Next Agent Needing Attention",
    category = "Rextina",
    keywords = "agent claude blocked done attention jump next",
    run = function(ctx)
      local servers = M.local_apis(rex)
      local item = M.find_next(servers, ctx.block_id, memory.last, memory.seen)
      memory.last = item and item.block_id
      if not item then
        return { none = true }
      end
      M.go(item, servers, rex.client.queue)
      return {
        host = item.host,
        session_id = item.session_id,
        window_id = item.window_id,
        block_id = item.block_id,
        state = item.state,
      }
    end,
  })
end

if rex and rex.action then
  rex.action({
    name = "rextina_restore",
    title = "Restore Sessions",
    category = "Rextina",
    keywords = "restore sessions tabs layout restart resume claude",
    args = { save = "string?" },
    run = function(_, args)
      return M.restore_action(rex, { save = args and args.save })
    end,
  })
  rex.action({
    name = "rextina_saves",
    title = "List Session Saves",
    category = "Rextina",
    keywords = "restore sessions saves list",
    run = function()
      return M.saves_action(rex)
    end,
  })
  rex.action({
    name = "rextina_save_restart",
    title = "Save Sessions and Restart Server…",
    category = "Rextina",
    keywords = "save restart server upgrade restore",
    run = function()
      return M.save_restart_action(rex, nil, rex.client.queue)
    end,
  })
end

return M
