local N = require("rextina")
local Store = require("rextina_store")

local function tmpdir()
  return (rex.exec({ "mktemp", "-d" }).stdout:gsub("%s+$", ""))
end

local function cleanup(dir)
  rex.exec({ "rm", "-rf", dir })
end

local function save(id, at, cwd, extra)
  local s = {
    version = 1,
    instance_id = id,
    saved_at = at,
    host = "spode",
    sessions = {
      { label = "infra", tabs = {
        { active = true, layout = { pane = { cwd = cwd or "/tmp" } } },
        { label = "deploy", active = false, layout = { pane = { cwd = cwd or "/tmp", claude = "ab12-cd" } } },
      } },
    },
  }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

local function lib(opts)
  opts = opts or {}
  local l = { json = rex.json, exec = rex.exec, calls = {} }
  function l.call(method, args)
    l.calls[#l.calls + 1] = { method, args }
    if method == "server.status" then
      if opts.no_server then
        return nil, "no server"
      end
      return { instance_id = "now", host_id = opts.host_id or "here" }
    end
    if method == "session.create" then
      return rex.json.decode(fixture("create-result.json"))
    end
    if method == "session.list" then
      return { sessions = opts.live and { { session_id = "session:live", label = "infra" } } or {} }
    end
    if method == "session.view" then
      if opts.unattached and not l.attached then
        return nil, "stream is not attached to session"
      end
      return { active_window_id = "window:l1", windows = {
        { window_id = "window:l1", label = "Window 0a1b2c3d", layers = { { kind = "tiled",
          layout = { block_id = "block:l1" },
          blocks = { { block_id = "block:l1", label = "shell", creator_name = "com.superlogical.terminal" } } } } },
        { window_id = "window:l2", label = "deploy", layers = { { kind = "tiled",
          layout = { block_id = "block:l2" },
          blocks = { { block_id = "block:l2", label = "shell", creator_name = "com.superlogical.terminal" } } } } },
      } }
    end
    if method == "session.attach" then
      l.attached = true
      return {}
    end
    if method == "block.method" and args.method == "process" then
      return { foreground = { name = "fish", pid = 1, cwd = opts.live } }
    end
    return {}
  end
  function l.created()
    local out = {}
    for _, call in ipairs(l.calls) do
      if call[1] == "session.create" then
        out[#out + 1] = call[2]
      end
    end
    return out
  end
  return l
end

test("restore_action reports none when there is nothing to restore", function()
  local dir = tmpdir()
  local l = lib()
  eq({ restored = false, reason = "none" }, N.restore_action(l, { dir = dir }))
  eq(0, #l.created())
  cleanup(dir)
end)

test("restore_action restores the chosen save and marks it closed on disk", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  store:write(save("before", "t1", dir))
  store:write(save("now", "t2", dir))
  local l = lib()
  local report = N.restore_action(l, { dir = dir })
  eq(true, report.restored)
  eq(true, report.complete)
  eq("before", report.instance_id)
  eq(1, #l.created())
  eq(dir, l.created()[1].initial_windows[1].layout.block.options.cwd)
  eq("claude --resume ab12-cd\n", l.created()[1].initial_windows[2].layout.block.options.initial_input)
  eq(true, store:read("before").closed_at ~= nil)
  eq({ restored = false, reason = "closed" }, N.restore_action(lib(), { dir = dir }))
  cleanup(dir)
end)

test("restore_action resumes inside a session Rex already brought back", function()
  for _, unattached in ipairs({ false, true }) do
    local dir = tmpdir()
    local store = Store.new(rex, dir)
    store:write(save("before", "t1", dir))
    local l = lib({ live = dir, unattached = unattached })
    local report = N.restore_action(l, { dir = dir })
    eq(0, #l.created())
    eq({ label = "infra", tabs = 2, panes = 2, resumed = 1, in_place = true }, report.sessions[1])
    local wrote, detached = {}, 0
    for _, call in ipairs(l.calls) do
      if call[1] == "block.method" and call[2].method == "write" then
        wrote[#wrote + 1] = call[2]
      end
      if call[1] == "session.detach" then
        detached = detached + 1
      end
    end
    eq({ { session_id = "session:live", block_id = "block:l2", method = "write",
      args = { data = "claude --resume ab12-cd\n" } } }, wrote)
    eq(unattached and 1 or 0, detached)
    eq(true, store:read("before").closed_at ~= nil)
    cleanup(dir)
  end
end)

test("restore_action refuses a save when it is talking to another machine's server", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  store:write(save("before", "t1", dir, { host_id = "here" }))
  local l = lib({ host_id = "fred" })
  eq({ restored = false, reason = "other machine", host = "spode" }, N.restore_action(l, { dir = dir }))
  eq({ restored = false, reason = "other machine", host = "spode" }, N.restore_action(l, { dir = dir, save = "before" }))
  eq(0, #l.created())
  eq(nil, store:read("before").closed_at)
  eq(true, N.restore_action(lib(), { dir = dir }).restored)
  cleanup(dir)
end)

test("restore_action by id restores a closed save in full", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  local closed = save("before", "t1", dir, { closed_at = "t3" })
  closed.sessions[1].restored_at = "t3"
  store:write(closed)
  local l = lib()
  local report = N.restore_action(l, { dir = dir, save = "before" })
  eq(true, report.restored)
  eq(1, #l.created())
  cleanup(dir)
end)

test("restore_action falls back to home for a directory that is gone", function()
  local dir = tmpdir()
  Store.new(rex, dir):write(save("before", "t1", dir .. "/gone"))
  local l = lib()
  N.restore_action(l, { dir = dir })
  eq(nil, l.created()[1].initial_windows[1].layout.block.options)
  cleanup(dir)
end)

test("restore_action focuses the saved active tab", function()
  local dir = tmpdir()
  Store.new(rex, dir):write(save("before", "t1", dir))
  local l = lib()
  N.restore_action(l, { dir = dir })
  local focused
  for _, call in ipairs(l.calls) do
    if call[1] == "session.focus_window" then
      focused = call[2]
    end
  end
  eq({ session_id = "session:ns1", window_id = "window:nw1" }, focused)
  cleanup(dir)
end)

test("restore_action reports no server", function()
  local dir = tmpdir()
  eq({ restored = false, reason = "no server" }, N.restore_action(lib({ no_server = true }), { dir = dir }))
  cleanup(dir)
end)

test("saves_action labels running, trivial, open and closed saves, newest first", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  store:write(save("now", "t4", dir))
  store:write(save("open", "t2", dir))
  store:write(save("closed", "t1", dir, { closed_at = "t9" }))
  store:write({ version = 1, instance_id = "fresh", saved_at = "t3", host = "spode",
    sessions = { { label = "x", tabs = { { active = true, layout = { pane = {} } } } } } })
  eq({
    { instance_id = "now", saved_at = "t4", host = "spode", sessions = 1, state = "running" },
    { instance_id = "fresh", saved_at = "t3", host = "spode", sessions = 1, state = "trivial" },
    { instance_id = "open", saved_at = "t2", host = "spode", sessions = 1, state = "open" },
    { instance_id = "closed", saved_at = "t1", host = "spode", sessions = 1, state = "closed" },
  }, N.saves_action(lib(), { dir = dir }))
  cleanup(dir)
end)

test("save_restart does not restart when the save fails", function()
  local queued = {}
  local result = N.save_restart_action(lib({ no_server = true }), { dir = "/dev/null/saves" }, function(name)
    queued[#queued + 1] = name
  end)
  eq({}, queued)
  eq(false, result.restarting)
  eq("no server", result.reason)
end)

test("save_restart saves then asks the app to restart", function()
  local dir = tmpdir()
  local queued = {}
  local result = N.save_restart_action(lib(), { dir = dir }, function(name)
    queued[#queued + 1] = name
  end)
  eq({ "client.server.restart" }, queued)
  eq(true, result.restarting)
  eq(true, Store.new(rex, dir):read("now") ~= nil)
  cleanup(dir)
end)
