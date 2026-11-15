local dir = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path

local args = rex.args or {}
local _, _, reason = require("rextina_save").run(rex, { dir = args.dir })
if reason and reason ~= "empty" and reason ~= "no server" then
  rex.log("warn", "rextina save failed: " .. tostring(reason))
end
rex.stop(0)
