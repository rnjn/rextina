local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path

local S = require("rextina_status")

local args = rex.args or {}
local dry = args.dry == true or args.dry == "true"
local state = {}

local function frontmost()
  local front = rex.exec({ "lsappinfo", "front" }, { timeout = 2 })
  if not front or not front.ok then
    return false
  end
  local asn = front.stdout:gsub("%s+$", "")
  local info = rex.exec({ "lsappinfo", "info", "-only", "bundleid", asn }, { timeout = 2 })
  return info ~= nil and info.ok and S.is_rex(info.stdout)
end

local function notify(title, subtitle, body)
  if dry then
    rex.log(title .. " | " .. subtitle .. " | " .. body)
    return
  end
  local result, err = rex.exec({ "osascript", "-e", S.applescript(title, subtitle, body) }, { timeout = 5 })
  if not result or not result.ok then
    rex.log("warn", "notification failed: " .. tostring(err or (result and result.stderr)))
  end
end

local deps = {
  host = args.host ~= nil and tostring(args.host) or "",
  min_working = tonumber(args.min_working) or 30,
  now = os.time,
  view = function(session_id)
    return (rex.session.view({ session_id = session_id }))
  end,
  frontmost = frontmost,
  notify = notify,
}

local function on_status(ctx, ev)
  S.handle(deps, state, ctx, ev)
end

rex.on("terminal.program_status_changed", on_status)
rex.on("terminal.program_status_removed", on_status)
rex.on("block_closed", function(_, ev)
  state[ev.block_id] = nil
end)
