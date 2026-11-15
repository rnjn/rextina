local R = require("rextina_restore")

local function view()
  return rex.json.decode(fixture("view-split.json"))
end

local function proc(name, pid, cwd)
  return { foreground = { name = name, pid = pid, cwd = cwd } }
end

local function deps(opts)
  opts = opts or {}
  local v = opts.view or view()
  local processes = opts.processes or {
    ["block:b1"] = proc("fish", 11, "/work/a"),
    ["block:b2"] = proc("claude", 12, "/work/a"),
    ["block:b3"] = proc("nvim", 13, "/work/b"),
    ["block:b4"] = proc("fish", 14, "/work/c"),
  }
  local records = opts.records or {
    [12] = { sessionId = "ab12-cd", kind = "interactive", cwd = "/work/a" },
  }
  return {
    host = "spode",
    status = function()
      if opts.no_server then
        return nil
      end
      return { instance_id = "run-2" }
    end,
    sessions = function()
      return opts.sessions or { { session_id = "session:s1", label = "infra" } }
    end,
    view = function(session_id)
      if opts.no_view and opts.no_view[session_id] then
        return nil
      end
      return v
    end,
    process = function(_, block_id)
      return processes[block_id]
    end,
    claude = function(pid)
      return records[pid]
    end,
    now = function()
      return "2026-11-15T08:00:00Z"
    end,
  }
end

test("claude_id accepts a matching interactive record", function()
  eq("ab12-cd", R.claude_id(proc("claude", 7, "/work/a"), { sessionId = "ab12-cd", kind = "interactive", cwd = "/work/a" }))
end)

test("claude_id rejects another program, a missing record, a different cwd, a non-interactive kind", function()
  local record = { sessionId = "ab12-cd", kind = "interactive", cwd = "/work/a" }
  eq(nil, R.claude_id(proc("fish", 7, "/work/a"), record))
  eq(nil, R.claude_id(proc("claude", 7, "/work/a"), nil))
  eq(nil, R.claude_id(proc("claude", 7, "/work/b"), record))
  eq(nil, R.claude_id(proc("claude", 7, "/work/a"), { sessionId = "ab12-cd", kind = "bg", cwd = "/work/a" }))
  eq(nil, R.claude_id({}, record))
  eq(nil, R.claude_id(nil, record))
end)

test("claude_id rejects an id with shell characters", function()
  eq(nil, R.claude_id(proc("claude", 7, "/work/a"), { sessionId = "x; rm -rf ~", kind = "interactive", cwd = "/work/a" }))
  eq(nil, R.claude_id(proc("claude", 7, "/work/a"), { sessionId = "", kind = "interactive", cwd = "/work/a" }))
  eq(nil, R.claude_id(proc("claude", 7, "/work/a"), { sessionId = 42, kind = "interactive", cwd = "/work/a" }))
end)

test("build records sessions, tabs and nested splits from the fixture", function()
  local save = R.build(deps())
  eq(1, save.version)
  eq("run-2", save.instance_id)
  eq("2026-11-15T08:00:00Z", save.saved_at)
  eq("spode", save.host)
  eq(1, #save.sessions)
  eq("infra", save.sessions[1].label)
  eq(2, #save.sessions[1].tabs)
  eq({ pane = { cwd = "/work/a", program = "fish" } }, save.sessions[1].tabs[1].layout)
  eq({
    split = {
      direction = "horizontal",
      ratio = 0.5,
      before = {
        split = {
          direction = "vertical",
          ratio = 0.5,
          before = { pane = { cwd = "/work/a", program = "claude", claude = "ab12-cd" } },
          after = { pane = { cwd = "/work/b", program = "nvim" } },
        },
      },
      after = { pane = { cwd = "/work/c", program = "fish" } },
    },
  }, save.sessions[1].tabs[2].layout)
end)

test("build drops generated labels and keeps chosen ones", function()
  local v = view()
  v.windows[2].layers[1].blocks[3].label = "logs"
  local save = R.build(deps({ view = v }))
  eq(nil, save.sessions[1].tabs[1].label)
  eq("deploy", save.sessions[1].tabs[2].label)
  eq("logs", save.sessions[1].tabs[2].layout.split.after.pane.label)
  eq(nil, save.sessions[1].tabs[2].layout.split.before.split.before.pane.label)
end)

test("build marks the active tab", function()
  local save = R.build(deps())
  eq(true, save.sessions[1].tabs[1].active)
  eq(false, save.sessions[1].tabs[2].active)
end)

test("build leaves out a session whose view fails", function()
  local save = R.build(deps({
    sessions = { { session_id = "session:gone", label = "gone" }, { session_id = "session:s1", label = "infra" } },
    no_view = { ["session:gone"] = true },
  }))
  eq(1, #save.sessions)
  eq("infra", save.sessions[1].label)
end)

test("build returns nil when the server status fails", function()
  eq(nil, R.build(deps({ no_server = true })))
end)

test("build saves a non-terminal block as a bare pane", function()
  local v = view()
  v.windows[1].layers[1].blocks[1].creator_name = "com.example.other"
  local save = R.build(deps({ view = v }))
  eq({ pane = {} }, save.sessions[1].tabs[1].layout)
end)

test("build saves a pane whose process cannot be read as a bare pane", function()
  local save = R.build(deps({ processes = {} }))
  eq({ pane = {} }, save.sessions[1].tabs[1].layout)
end)

test("build ignores floating layers", function()
  local v = view()
  table.insert(v.windows[1].layers, 1, {
    kind = "floating",
    layout = { block_id = "block:b9" },
    blocks = { { block_id = "block:b9", label = "float", creator_name = "com.superlogical.terminal" } },
  })
  local save = R.build(deps({ view = v }))
  eq({ pane = { cwd = "/work/a", program = "fish" } }, save.sessions[1].tabs[1].layout)
end)

local function single(pane)
  return { sessions = { { label = "s", tabs = { { layout = { pane = pane } } } } } }
end

test("is_trivial", function()
  eq(true, R.is_trivial(single({ cwd = "/Users/x", program = "fish" })))
  eq(true, R.is_trivial({ sessions = {} }))
  eq(false, R.is_trivial(single({ claude = "ab12-cd" })))
  eq(false, R.is_trivial(R.build(deps())))
  local two_tabs = single({})
  two_tabs.sessions[1].tabs[2] = { layout = { pane = {} } }
  eq(false, R.is_trivial(two_tabs))
  local split = { sessions = { { tabs = { { layout = { split = { before = { pane = {} }, after = { pane = {} } } } } } } } }
  eq(false, R.is_trivial(split))
  local two_sessions = single({})
  two_sessions.sessions[2] = two_sessions.sessions[1]
  eq(false, R.is_trivial(two_sessions))
end)

test("counts", function()
  eq({ tabs = 2, panes = 4, resumed = 1 }, R.counts(R.build(deps()).sessions[1]))
end)

local function saved(id, at, extra)
  local save = {
    version = 1,
    instance_id = id,
    saved_at = at,
    host = "spode",
    sessions = {
      { label = "infra", tabs = {
        { active = false, layout = { pane = { cwd = "/work/a" } } },
        { label = "deploy", active = true, layout = { split = {
          direction = "horizontal",
          ratio = 0.5,
          before = { pane = { cwd = "/work/a", program = "claude", claude = "ab12-cd" } },
          after = { pane = { cwd = "/work/b", label = "logs" } },
        } } },
      } },
      { label = "web", tabs = { { active = true, layout = { pane = { cwd = "/work/c" } } }, { active = false, layout = { pane = {} } } } },
    },
  }
  for k, v in pairs(extra or {}) do
    save[k] = v
  end
  return save
end

local function trivial(id, at)
  return { version = 1, instance_id = id, saved_at = at, sessions = { { label = "fresh", tabs = { { active = true, layout = { pane = { cwd = "/Users/x" } } } } } } }
end

test("choose skips the running server's save", function()
  local chosen = R.choose({ saved("now", "t3"), saved("before", "t1") }, "now")
  eq("before", chosen.instance_id)
end)

test("choose skips a trivial save and finds the real one behind it", function()
  local chosen = R.choose({ trivial("crash", "t2"), saved("real", "t1"), saved("now", "t3") }, "now")
  eq("real", chosen.instance_id)
end)

test("choose takes the newest of several real saves", function()
  local chosen = R.choose({ saved("older", "t1"), saved("newer", "t2") }, "now")
  eq("newer", chosen.instance_id)
end)

test("choose returns closed, not an older save, after a completed restore", function()
  local chosen, reason = R.choose({ saved("older", "t1"), saved("newer", "t2", { closed_at = "t4" }) }, "now")
  eq(nil, chosen)
  eq("closed", reason)
end)

test("choose returns none when there are no saves", function()
  local chosen, reason = R.choose({}, "now")
  eq(nil, chosen)
  eq("none", reason)
  local only_running, why = R.choose({ saved("now", "t1") }, "now")
  eq(nil, only_running)
  eq("none", why)
end)

test("choose by id returns a closed save", function()
  local chosen = R.choose({ saved("older", "t1", { closed_at = "t4" }), saved("newer", "t2") }, "now", "older")
  eq("older", chosen.instance_id)
end)

test("choose by id refuses the running server's save and an unknown id", function()
  local running, why = R.choose({ saved("now", "t1") }, "now", "now")
  eq(nil, running)
  eq("running", why)
  local unknown, reason = R.choose({ saved("a", "t1") }, "now", "zzz")
  eq(nil, unknown)
  eq("unknown", reason)
end)

local function exists(known)
  return function(path)
    return known[path] == true
  end
end

test("window_spec turns a nested split into the api layout", function()
  local spec = R.window_spec(saved("a", "t").sessions[1].tabs[2], { dir_exists = exists({ ["/work/a"] = true, ["/work/b"] = true }) })
  eq({
    window_label = "deploy",
    layout = { split = {
      direction = "horizontal",
      ratio = 0.5,
      before = { block = { flavor = "com.superlogical.terminal.shell", options = { cwd = "/work/a", initial_input = "claude --resume ab12-cd\n" } } },
      after = { block = { flavor = "com.superlogical.terminal.shell", label = "logs", options = { cwd = "/work/b" } } },
    } },
  }, spec)
end)

test("window_spec passes an existing cwd and omits a missing one", function()
  local tab = { layout = { pane = { cwd = "/gone" } } }
  eq({ layout = { block = { flavor = "com.superlogical.terminal.shell" } } }, R.window_spec(tab, { dir_exists = exists({}) }))
end)

test("window_spec keeps a cwd with spaces, quotes and non-ASCII as an option", function()
  local odd = [[/work/my "odd" dir é; rm -rf ~]]
  local spec = R.window_spec({ layout = { pane = { cwd = odd, claude = "ab12-cd" } } }, { dir_exists = exists({ [odd] = true }) })
  eq(odd, spec.layout.block.options.cwd)
  eq("claude --resume ab12-cd\n", spec.layout.block.options.initial_input)
end)

test("window_spec drops a conversation id with shell characters", function()
  local spec = R.window_spec({ layout = { pane = { claude = "x; rm -rf ~" } } }, { dir_exists = exists({}) })
  eq({ layout = { block = { flavor = "com.superlogical.terminal.shell" } } }, spec)
end)

test("window_spec ignores a non-string cwd or label from a damaged save", function()
  local spec = R.window_spec({ label = 7, layout = { pane = { cwd = { "x" }, label = false } } }, { dir_exists = exists({}) })
  eq({ layout = { block = { flavor = "com.superlogical.terminal.shell" } } }, spec)
end)

local function restorer(opts)
  opts = opts or {}
  local r = { created = {}, focused = {}, persisted = 0, clock = 0 }
  r.deps = {
    dir_exists = function()
      return true
    end,
    now = function()
      r.clock = r.clock + 1
      return "now-" .. r.clock
    end,
    persist = function()
      r.persisted = r.persisted + 1
    end,
    focus_window = function(session_id, window_id)
      r.focused[#r.focused + 1] = { session_id, window_id }
    end,
    create = function(args)
      r.created[#r.created + 1] = args
      if opts.fail and opts.fail[args.label] then
        return nil, "boom"
      end
      return rex.json.decode(fixture("create-result.json"))
    end,
  }
  return r
end

test("restore creates every session and closes the save", function()
  local r, save = restorer(), saved("a", "t1")
  local report = R.restore(save, r.deps)
  eq(2, #r.created)
  eq("infra", r.created[1].label)
  eq(2, #r.created[1].initial_windows)
  eq("deploy", r.created[1].initial_windows[2].window_label)
  eq(true, report.complete)
  eq(true, save.closed_at ~= nil)
  eq(true, save.sessions[1].restored_at ~= nil)
end)

test("restore focuses the saved active tab", function()
  local r = restorer()
  R.restore(saved("a", "t1"), r.deps)
  eq({ { "session:ns1", "window:nw2" }, { "session:ns1", "window:nw1" } }, r.focused)
end)

test("restore continues after one session fails and leaves the save open", function()
  local r, save = restorer({ fail = { infra = true } }), saved("a", "t1")
  local report = R.restore(save, r.deps)
  eq(2, #r.created)
  eq(false, report.complete)
  eq("boom", report.sessions[1].error)
  eq(nil, report.sessions[2].error)
  eq(nil, save.closed_at)
  eq(nil, save.sessions[1].restored_at)
  eq(true, save.sessions[2].restored_at ~= nil)
end)

test("a second restore rebuilds only the session that failed", function()
  local save = saved("a", "t1")
  R.restore(save, restorer({ fail = { infra = true } }).deps)
  local r = restorer()
  local report = R.restore(save, r.deps)
  eq(1, #r.created)
  eq("infra", r.created[1].label)
  eq(1, #report.sessions)
  eq(true, report.complete)
  eq(true, save.closed_at ~= nil)
end)

test("restore persists after each session and once on closing", function()
  local r = restorer()
  R.restore(saved("a", "t1"), r.deps)
  eq(3, r.persisted)
end)

test("restore with all=true rebuilds sessions already marked", function()
  local save = saved("a", "t1")
  R.restore(save, restorer().deps)
  local r = restorer()
  R.restore(save, r.deps, true)
  eq(2, #r.created)
end)

test("report counts tabs, panes and resumed conversations", function()
  local report = R.restore(saved("a", "t1"), restorer().deps)
  eq("t1", report.saved_at)
  eq("spode", report.host)
  eq({ label = "infra", tabs = 2, panes = 3, resumed = 1 }, report.sessions[1])
  eq({ label = "web", tabs = 2, panes = 2, resumed = 0 }, report.sessions[2])
end)

test("restore of a session with no tabs is skipped, not sent to the server", function()
  local save = saved("a", "t1")
  save.sessions[2].tabs = {}
  local r = restorer()
  local report = R.restore(save, r.deps)
  eq(1, #r.created)
  eq(true, report.complete)
end)

test("an id that starts with a hyphen is not a conversation id", function()
  eq(false, R.valid_id("--dangerously-skip-permissions"))
  eq(false, R.valid_id("-x"))
  eq(true, R.valid_id("af241ec7-0933-4996-b79d-41ada75b95bf"))
  local spec = R.window_spec({ layout = { pane = { claude = "--dangerously-skip-permissions" } } }, { dir_exists = exists({}) })
  eq(nil, spec.layout.block.options)
end)

test("build reports a save as incomplete when a view or a process read fails", function()
  local _, complete_flag = R.build(deps())
  eq(false, complete_flag)
  local _, missing_view = R.build(deps({
    sessions = { { session_id = "session:gone", label = "gone" }, { session_id = "session:s1", label = "infra" } },
    no_view = { ["session:gone"] = true },
  }))
  eq(true, missing_view)
  local _, missing_process = R.build(deps({ processes = {} }))
  eq(true, missing_process)
end)

test("valid_save accepts what build produces", function()
  eq(true, R.valid_save(R.build(deps())))
  eq(true, R.valid_save(saved("a", "t1")))
  eq(true, R.valid_save({ version = 1, instance_id = "a", saved_at = "t", sessions = {} }))
end)

test("valid_save rejects wrong types anywhere in the tree", function()
  local function with(change)
    local s = saved("a", "t1")
    change(s)
    return R.valid_save(s)
  end
  eq(false, with(function(s) s.saved_at = 5 end))
  eq(false, with(function(s) s.instance_id = 5 end))
  eq(false, with(function(s) s.sessions = "x" end))
  eq(false, with(function(s) s.sessions[1] = 5 end))
  eq(false, with(function(s) s.sessions[1].tabs = "x" end))
  eq(false, with(function(s) s.sessions[1].tabs[1] = 5 end))
  eq(false, with(function(s) s.sessions[1].tabs[1].layout = 5 end))
  eq(false, with(function(s) s.sessions[1].tabs[2].layout.split = true end))
  eq(false, with(function(s) s.sessions[1].tabs[2].layout.split.before = nil end))
  eq(false, with(function(s) s.sessions[1].tabs[2].layout.split.ratio = "half" end))
  eq(false, with(function(s) s.sessions[1].tabs[1].layout.pane = "x" end))
  eq(false, R.valid_save(nil))
  eq(false, R.valid_save("x"))
end)

test("valid_save rejects absurdly deep nesting", function()
  local node = { pane = {} }
  for _ = 1, 300 do
    node = { split = { direction = "horizontal", ratio = 0.5, before = node, after = { pane = {} } } }
  end
  local s = saved("a", "t1")
  s.sessions[1].tabs[1].layout = node
  eq(false, R.valid_save(s))
end)
