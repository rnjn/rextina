local Store = require("rextina_store")
local Save = require("rextina_save")

local function tmpdir()
  local made = rex.exec({ "mktemp", "-d" })
  return (made.stdout:gsub("%s+$", ""))
end

local function cleanup(dir)
  rex.exec({ "chmod", "-R", "u+rwx", dir })
  rex.exec({ "rm", "-rf", dir })
end

local function sample(id, saved_at)
  return {
    version = 1,
    instance_id = id,
    saved_at = saved_at or "2026-11-15T08:00:00Z",
    host = "spode",
    sessions = { { label = "infra", tabs = { { active = true, layout = { pane = { cwd = "/work/a" } } } } } },
  }
end

local function put(dir, name, text)
  local f = assert(io.open(dir .. "/" .. name, "w"))
  f:write(text)
  f:close()
end

local function ids(list)
  local out = {}
  for i, save in ipairs(list) do
    out[i] = save.instance_id
  end
  table.sort(out)
  return out
end

test("write then read_all round trips a save", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir .. "/saves")
  local path = store:write(sample("run-1"))
  eq(dir .. "/saves/run-1.json", path)
  eq({ sample("run-1") }, store:read_all())
  eq(sample("run-1"), store:read("run-1"))
  eq(nil, store:read("run-9"))
  cleanup(dir)
end)

test("write creates the directory and sets mode 600", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir .. "/deep/saves")
  local path = store:write(sample("run-1"))
  local mode = rex.exec({ "stat", "-f", "%Lp", path })
  if not mode.ok then
    mode = rex.exec({ "stat", "-c", "%a", path })
  end
  eq("600", (mode.stdout:gsub("%s+$", "")))
  cleanup(dir)
end)

test("write leaves no .tmp file behind", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  store:write(sample("run-1"))
  eq("run-1.json", (rex.exec({ "ls", dir }).stdout:gsub("%s+$", "")))
  cleanup(dir)
end)

test("write refuses an instance id with a slash", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  local path, err = store:write(sample("../evil"))
  eq(nil, path)
  eq(true, err ~= nil)
  eq("", rex.exec({ "ls", dir }).stdout)
  cleanup(dir)
end)

test("read_all skips invalid JSON, a wrong version, and a mismatched file name", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  store:write(sample("run-1"))
  put(dir, "broken.json", "{ not json")
  put(dir, "empty.json", "")
  put(dir, "future.json", rex.json.encode({ version = 2, instance_id = "future", sessions = {} }))
  put(dir, "renamed.json", rex.json.encode(sample("someone-else")))
  put(dir, "notes.txt", "hello")
  eq({ "run-1" }, ids(store:read_all()))
  cleanup(dir)
end)

test("read_all returns {} for a missing directory", function()
  eq({}, Store.new(rex, "/nonexistent/rextina/saves"):read_all())
end)

test("prune keeps the five newest by saved_at", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  for i = 1, 7 do
    store:write(sample("run-" .. i, "2026-11-15T08:0" .. i .. ":00Z"))
  end
  store:prune(5)
  eq({ "run-3", "run-4", "run-5", "run-6", "run-7" }, ids(store:read_all()))
  cleanup(dir)
end)

test("default_dir honours REXTINA_STATE_DIR, then XDG_STATE_HOME, then HOME", function()
  local function env(vars)
    return function(name)
      return vars[name]
    end
  end
  eq("/x", Store.default_dir(env({ REXTINA_STATE_DIR = "/x", XDG_STATE_HOME = "/s", HOME = "/h" })))
  eq("/s/rextina/saves", Store.default_dir(env({ REXTINA_STATE_DIR = "", XDG_STATE_HOME = "/s", HOME = "/h" })))
  eq("/h/.local/state/rextina/saves", Store.default_dir(env({ HOME = "/h" })))
end)

test("write returns nil and an error when the directory cannot be created", function()
  local path, err = Store.new(rex, "/dev/null/saves"):write(sample("run-1"))
  eq(nil, path)
  eq(true, err ~= nil)
end)

local function fake_lib(opts)
  opts = opts or {}
  local view = rex.json.decode(fixture("view-split.json"))
  return {
    json = rex.json,
    exec = rex.exec,
    call = function(method, args)
      if method == "server.status" then
        if opts.no_server then
          return nil, "no server"
        end
        return { instance_id = opts.instance or "run-2" }
      end
      if method == "session.list" then
        return { sessions = opts.sessions or { { session_id = "session:s1", label = "infra" } } }
      end
      if method == "session.view" then
        return view
      end
      if method == "block.method" and args.method == "process" then
        return { foreground = { name = "fish", pid = 1, cwd = "/work/a" } }
      end
      return nil, "unexpected"
    end,
  }
end

test("save run writes nothing when there is no server", function()
  local dir = tmpdir()
  local save, path, reason = Save.run(fake_lib({ no_server = true }), { dir = dir })
  eq(nil, save)
  eq(nil, path)
  eq("no server", reason)
  eq("", rex.exec({ "ls", dir }).stdout)
  cleanup(dir)
end)

test("save run does not overwrite a save from this run with an empty one", function()
  local dir = tmpdir()
  Save.run(fake_lib(), { dir = dir })
  local _, _, reason = Save.run(fake_lib({ sessions = {} }), { dir = dir })
  eq("empty", reason)
  eq(1, #Store.new(rex, dir):read("run-2").sessions)
  cleanup(dir)
end)

test("save run writes an empty save when none exists for this run", function()
  local dir = tmpdir()
  local save = Save.run(fake_lib({ sessions = {} }), { dir = dir })
  eq(0, #save.sessions)
  eq({ "run-2" }, ids(Store.new(rex, dir):read_all()))
  cleanup(dir)
end)

test("save run writes and prunes", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  for i = 1, 6 do
    store:write(sample("old-" .. i, "2026-11-01T00:0" .. i .. ":00Z"))
  end
  local save, path = Save.run(fake_lib(), { dir = dir })
  eq("run-2", save.instance_id)
  eq(dir .. "/run-2.json", path)
  eq({ "old-2", "old-3", "old-4", "old-5", "old-6", "run-2" }, ids(store:read_all()))
  cleanup(dir)
end)

test("save run reads the conversation id from claude's process file", function()
  local dir = tmpdir()
  rex.exec({ "mkdir", "-p", dir .. "/home/.claude/sessions" })
  put(dir .. "/home/.claude/sessions", "1.json",
    rex.json.encode({ sessionId = "ab12-cd", kind = "interactive", cwd = "/work/a" }))
  local lib = fake_lib()
  local call = lib.call
  lib.call = function(method, args)
    if method == "block.method" then
      return { foreground = { name = "claude", pid = 1, cwd = "/work/a" } }
    end
    return call(method, args)
  end
  local save = Save.run(lib, { dir = dir .. "/saves", home = dir .. "/home" })
  eq("ab12-cd", save.sessions[1].tabs[1].layout.pane.claude)
  cleanup(dir)
end)

test("save run attaches to sessions that refuse unattached reads, then detaches", function()
  local dir = tmpdir()
  local lib = fake_lib({ sessions = { { session_id = "session:s1", label = "infra" }, { session_id = "session:s2", label = "web" } } })
  local call = lib.call
  local attached, log = {}, {}
  lib.call = function(method, args)
    if method == "session.attach" then
      attached[args.session_id] = true
      log[#log + 1] = "attach " .. args.session_id
      return {}
    end
    if method == "session.detach" then
      attached[args.session_id] = nil
      log[#log + 1] = "detach " .. args.session_id
      return {}
    end
    if (method == "session.view" or method == "block.method") and not attached[args.session_id] then
      return nil, "stream is not attached to session"
    end
    return call(method, args)
  end
  local save = Save.run(lib, { dir = dir })
  eq(2, #save.sessions)
  eq("fish", save.sessions[2].tabs[1].layout.pane.program)
  eq({}, attached)
  eq({ "attach session:s1", "attach session:s2", "detach session:s1", "detach session:s2" }, log)
  cleanup(dir)
end)

test("save run does not attach when reads already work", function()
  local dir = tmpdir()
  local lib = fake_lib()
  local call = lib.call
  local attaches = { count = 0 }
  lib.call = function(method, args)
    if method == "session.attach" or method == "session.detach" then
      attaches.count = attaches.count + 1
      return {}
    end
    return call(method, args)
  end
  Save.run(lib, { dir = dir })
  eq(0, attaches.count)
  cleanup(dir)
end)

test("read_all skips a save whose structure is wrong and keeps the good one", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  store:write(sample("good"))
  put(dir, "bad1.json", rex.json.encode({ version = 1, instance_id = "bad1", saved_at = "t", sessions = { 5 } }))
  put(dir, "bad2.json", rex.json.encode({ version = 1, instance_id = "bad2", saved_at = 5, sessions = {} }))
  put(dir, "bad3.json", [[{"version":1,"instance_id":"bad3","saved_at":"t","sessions":[{"label":"x","tabs":[{"layout":{"split":true}}]}]}]])
  eq({ "good" }, ids(store:read_all()))
  cleanup(dir)
end)

local function trivial_sample(id, at)
  local s = sample(id, at)
  return s
end

local function real_sample(id, at)
  local s = sample(id, at)
  s.sessions[1].tabs[2] = { active = false, layout = { pane = { cwd = "/work/b" } } }
  return s
end

test("prune never lets trivial saves push out a real one", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  store:write(real_sample("real", "2026-11-15T08:00:00Z"))
  for i = 1, 7 do
    store:write(trivial_sample("crash-" .. i, "2026-11-15T09:0" .. i .. ":00Z"))
  end
  store:prune(5)
  local left = ids(store:read_all())
  eq(true, left[#left] == "real")
  eq(6, #left)
  cleanup(dir)
end)

test("prune keeps the five newest real saves", function()
  local dir = tmpdir()
  local store = Store.new(rex, dir)
  for i = 1, 7 do
    store:write(real_sample("run-" .. i, "2026-11-15T08:0" .. i .. ":00Z"))
  end
  store:prune(5)
  eq({ "run-3", "run-4", "run-5", "run-6", "run-7" }, ids(store:read_all()))
  cleanup(dir)
end)

test("an incomplete save does not replace a recent complete one from the same run", function()
  local dir = tmpdir()
  Save.run(fake_lib(), { dir = dir })
  local lib = fake_lib()
  local call = lib.call
  lib.call = function(method, args)
    if method == "block.method" then
      return nil, "shutting down"
    end
    return call(method, args)
  end
  local _, _, reason = Save.run(lib, { dir = dir })
  eq("incomplete", reason)
  eq("/work/a", Store.new(rex, dir):read("run-2").sessions[1].tabs[1].layout.pane.cwd)
  cleanup(dir)
end)

test("an incomplete save is written when there is nothing better", function()
  local dir = tmpdir()
  local lib = fake_lib()
  local call = lib.call
  lib.call = function(method, args)
    if method == "block.method" then
      return nil, "gone"
    end
    return call(method, args)
  end
  local save = Save.run(lib, { dir = dir })
  eq(true, save ~= nil)
  eq(true, Store.new(rex, dir):read("run-2") ~= nil)
  cleanup(dir)
end)

test("an incomplete save replaces a complete one that is more than ten minutes old", function()
  local dir = tmpdir()
  local old = sample("run-2", "2020-01-01T00:00:00Z")
  Store.new(rex, dir):write(old)
  local lib = fake_lib()
  local call = lib.call
  lib.call = function(method, args)
    if method == "block.method" then
      return nil, "gone"
    end
    return call(method, args)
  end
  local save = Save.run(lib, { dir = dir })
  eq(true, save ~= nil)
  eq(true, Store.new(rex, dir):read("run-2").saved_at > "2026")
  cleanup(dir)
end)
