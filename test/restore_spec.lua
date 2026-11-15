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
