local source = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
local dir = source:match("^@(.*)/[^/]*$")
if dir then
  package.path = dir .. "/?.lua;" .. package.path
end

local S = require("rextina_status")

local M = {}

local TERMINAL = "com.superlogical.terminal"

function M.collect(api, host)
  local items = {}
  local listed = api.call("session.list")
  if type(listed) ~= "table" then
    return items
  end
  for _, session in ipairs(listed.sessions or {}) do
    local view = api.call("session.view", { session_id = session.session_id })
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
  end
  return items
end

function M.find_next(apis, current_block_id, last_block_id)
  local all, seen = {}, {}
  for _, entry in ipairs(apis) do
    for _, item in ipairs(M.collect(entry.api, entry.host)) do
      if not seen[item.block_id] then
        seen[item.block_id] = true
        all[#all + 1] = item
      end
    end
  end
  local ordered = S.order(all)
  local from = last_block_id
  for _, item in ipairs(ordered) do
    if item.block_id == current_block_id then
      from = current_block_id
    end
  end
  return S.next(ordered, from)
end

function M.go(item, apis, queue)
  for _, entry in ipairs(apis) do
    if entry.host == item.host then
      entry.api.call("session.focus_block", { session_id = item.session_id, block_id = item.block_id })
      break
    end
  end
  pcall(queue, "session.select", { session_id = item.session_id, window_id = item.window_id })
end

local function apis()
  local list = { { api = { call = rex.call } } }
  for _, label in ipairs(rex.servers() or {}) do
    local ok, server = pcall(rex.server, label)
    if ok and server then
      list[#list + 1] = { host = label, api = { call = server.call } }
    end
  end
  return list
end

local memory = {}

if rex and rex.action then
  rex.action({
    name = "rextina_next",
    title = "Go to Next Agent Needing Attention",
    category = "Rextina",
    keywords = "agent claude blocked done attention jump next",
    run = function(ctx)
      local servers = apis()
      local item = M.find_next(servers, ctx.block_id, memory.last)
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
