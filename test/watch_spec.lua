local S = require("rextina_status")

local function harness(opts)
  opts = opts or {}
  local h = { clock = 100, notes = {}, state = {} }
  h.deps = {
    host = opts.host or "fred",
    min_working = 30,
    now = function()
      return h.clock
    end,
    view = function()
      if opts.no_view then
        return nil
      end
      return rex.json.decode(fixture("view.json"))
    end,
    frontmost = function()
      return opts.frontmost or false
    end,
    notify = function(title, subtitle, body)
      h.notes[#h.notes + 1] = { title, subtitle, body }
    end,
  }
  h.ctx = { session_id = "session:s1", block_id = opts.block or "block:b1" }
  function h.report(state, at, extra)
    h.clock = at
    local record = { state = state }
    for k, v in pairs(extra or {}) do
      record[k] = v
    end
    S.handle(h.deps, h.state, h.ctx, { name = "program_status_changed", id = "", record = record })
  end
  return h
end

test("blocked event notifies with labels from the view", function()
  local h = harness()
  h.report("blocked", 100, { kind = "permission", msg = "Needs approval" })
  eq({ { "Claude needs approval", "fred › infra › deploy", "Needs approval" } }, h.notes)
end)

test("child record is ignored", function()
  local h = harness()
  S.handle(h.deps, h.state, h.ctx,
    { name = "program_status_changed", id = "build/test", record = { id = "build/test", state = "blocked" } })
  eq({}, h.notes)
end)

test("focused block with Rex frontmost is silent", function()
  local h = harness({ block = "block:b3", frontmost = true })
  h.report("blocked", 100)
  eq({}, h.notes)
end)

test("focused block with another app frontmost notifies", function()
  local h = harness({ block = "block:b3", frontmost = false })
  h.report("blocked", 100)
  eq(1, #h.notes)
end)

test("unfocused block with Rex frontmost notifies", function()
  local h = harness({ block = "block:b1", frontmost = true })
  h.report("blocked", 100)
  eq(1, #h.notes)
end)

test("view failure still notifies", function()
  local h = harness({ no_view = true })
  h.report("error", 100, { msg = "boom" })
  eq({ { "Claude failed", "fred", "boom" } }, h.notes)
end)

test("repeat within 5 seconds is dropped", function()
  local h = harness()
  h.report("blocked", 100)
  h.report("working", 101)
  h.report("blocked", 102)
  eq(1, #h.notes)
  h.report("working", 103)
  h.report("blocked", 110)
  eq(2, #h.notes)
end)

test("done after a long turn reports the duration", function()
  local h = harness()
  h.report("working", 100)
  h.report("done", 160)
  eq({ { "Claude finished", "fred › infra › deploy", "Worked for 1m 0s" } }, h.notes)
end)

test("short turn is silent", function()
  local h = harness()
  h.report("working", 100)
  h.report("done", 110)
  eq({}, h.notes)
end)

test("removed root record then done is silent", function()
  local h = harness()
  h.report("working", 100)
  S.handle(h.deps, h.state, h.ctx, { name = "program_status_removed", ids = { "", "build/test" }, reason = "clear" })
  h.report("done", 200)
  eq({}, h.notes)
end)

test("removed child record keeps the root entry", function()
  local h = harness()
  h.report("working", 100)
  S.handle(h.deps, h.state, h.ctx, { name = "program_status_removed", ids = { "build/test" }, reason = "clear" })
  h.report("done", 200)
  eq(1, #h.notes)
end)

test("blocks are tracked separately", function()
  local h = harness()
  h.report("working", 100)
  h.ctx = { session_id = "session:s1", block_id = "block:b2" }
  h.report("done", 200)
  eq({}, h.notes)
end)

test("recorded events from a live server are handled", function()
  local h = harness()
  for line in fixture("events.jsonl"):gmatch("[^\n]+") do
    local block_event = rex.json.decode(line).payload.event.payload
    local ev = block_event.payload
    ev.name = block_event.name
    S.handle(h.deps, h.state, { session_id = "session:s1", block_id = block_event.block_id }, ev)
  end
  eq({ { "Claude needs approval", "fred › infra › deploy", "hi" } }, h.notes)
end)

test("frontmost app is recognised by bundle id", function()
  eq(true, S.is_rex('[ NULL ]  ASN:0x0-0x1: (in front) \n    bundleID="com.superlogical.rex"\n    bundle path=[ NULL ] \n'))
  eq(false, S.is_rex('[ NULL ]  ASN:0x0-0x2: (in front) \n    bundleID="com.google.Chrome"\n'))
  eq(false, S.is_rex('"Rex Beta" ASN:0x0-0x1: (in front) \n    bundleID=[ NULL ] \n'))
  eq(false, S.is_rex(""))
  eq(false, S.is_rex(nil))
end)
