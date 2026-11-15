local source = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
local dir = source:match("^@(.*)/[^/]*$")
if dir then
  package.path = dir .. "/?.lua;" .. package.path
end

local S = require("rextina_status")

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

return M
