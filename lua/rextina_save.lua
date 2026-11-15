local Restore = require("rextina_restore")
local Store = require("rextina_store")

local M = {}

function M.store(lib, opts)
  return Store.new(lib, opts and opts.dir or Store.default_dir(os.getenv))
end

function M.deps(lib, opts, attached)
  attached = attached or {}
  local home = opts and opts.home or os.getenv("HOME") or ""
  local host = lib.exec({ "hostname", "-s" })
  return {
    host = host and host.ok and (host.stdout:gsub("%s+$", "")) or "",
    status = function()
      return (lib.call("server.status"))
    end,
    sessions = function()
      local listed = lib.call("session.list")
      return type(listed) == "table" and listed.sessions or {}
    end,
    view = function(session_id)
      local view = lib.call("session.view", { session_id = session_id })
      if view == nil and lib.call("session.attach", { session_id = session_id }) then
        attached[#attached + 1] = session_id
        view = lib.call("session.view", { session_id = session_id })
      end
      return view
    end,
    process = function(session_id, block_id)
      return (lib.call("block.method", { session_id = session_id, block_id = block_id, method = "process" }))
    end,
    claude = function(pid)
      if type(pid) ~= "number" then
        return nil
      end
      local f = io.open(string.format("%s/.claude/sessions/%d.json", home, pid), "r")
      if not f then
        return nil
      end
      local text = f:read("*a")
      f:close()
      return (lib.json.decode(text))
    end,
    now = function()
      return os.date("!%Y-%m-%dT%H:%M:%SZ")
    end,
  }
end

function M.run(lib, opts)
  local attached = {}
  local save = Restore.build(M.deps(lib, opts, attached))
  for _, session_id in ipairs(attached) do
    lib.call("session.detach", { session_id = session_id })
  end
  if not save then
    return nil, nil, "no server"
  end
  local store = M.store(lib, opts)
  if #save.sessions == 0 and store:read(save.instance_id) then
    return nil, nil, "empty"
  end
  local path, err = store:write(save)
  if not path then
    return nil, nil, err
  end
  store:prune(5)
  return save, path
end

return M
