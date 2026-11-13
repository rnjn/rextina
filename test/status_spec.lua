local S = require("rextina_status")

local function steps(list, min)
  local entry, event
  for _, step in ipairs(list) do
    entry, event = S.transition(entry, step[1] and { state = step[1] } or nil, step[2], min or 30)
  end
  return entry, event
end

test("blocked always notifies", function()
  local e, ev = S.transition(nil, { state = "blocked" }, 100, 30)
  eq("blocked", ev)
  eq("blocked", e.state)
end)

test("same state twice is silent", function()
  local _, ev = steps({ { "blocked", 100 }, { "blocked", 101 } })
  eq(nil, ev)
end)

test("short turn done is silent", function()
  local _, ev = steps({ { "working", 100 }, { "done", 110 } })
  eq(nil, ev)
end)

test("long turn done notifies", function()
  local _, ev = steps({ { "working", 100 }, { "done", 140 } })
  eq("done", ev)
end)

test("approval does not reset the turn clock", function()
  local _, ev = steps({ { "working", 100 }, { "blocked", 110 }, { "working", 120 }, { "done", 135 } })
  eq("done", ev)
end)

test("done without seeing the start is silent", function()
  local _, ev = S.transition(nil, { state = "done" }, 500, 30)
  eq(nil, ev)
end)

test("error notifies without a start", function()
  local _, ev = S.transition(nil, { state = "error" }, 500, 30)
  eq("error", ev)
end)

test("removed record clears the entry", function()
  local e, ev = steps({ { "working", 100 }, { nil, 105 } })
  eq(nil, e)
  eq(nil, ev)
end)

test("new turn after done restarts the clock", function()
  local e = steps({ { "working", 100 }, { "done", 140 }, { "working", 200 } })
  eq(200, e.working_since)
end)

test("idle after working clears the clock", function()
  local e = steps({ { "working", 100 }, { "idle", 105 } })
  eq(nil, e.working_since)
end)

test("worked reports seconds since the start", function()
  local e = steps({ { "working", 100 } })
  eq(60, S.worked(e, 160))
  eq(nil, S.worked(nil, 160))
end)

test("duration", function()
  eq("45s", S.duration(45))
  eq("1m 0s", S.duration(60))
  eq("4m 12s", S.duration(252))
  eq("1h 2m", S.duration(3725))
end)

test("text titles for each event", function()
  eq("Claude needs approval", (S.text({ event = "blocked", kind = "permission" })))
  eq("Claude has a question", (S.text({ event = "blocked", kind = "question" })))
  eq("Claude needs sign-in", (S.text({ event = "blocked", kind = "auth" })))
  eq("Claude is blocked", (S.text({ event = "blocked" })))
  eq("Claude finished", (S.text({ event = "done" })))
  eq("Claude failed", (S.text({ event = "error" })))
end)

test("text subtitle joins the parts that exist", function()
  local _, full = S.text({ event = "blocked", host = "fred", session = "infra", window = "deploy" })
  eq("fred › infra › deploy", full)
  local _, partial = S.text({ event = "blocked", session = "infra" })
  eq("infra", partial)
  local _, empty = S.text({ event = "blocked", host = "", session = "infra", window = "" })
  eq("infra", empty)
end)

test("text body is the message, or the duration for done", function()
  local _, _, blocked = S.text({ event = "blocked", msg = "approve Write: a.txt" })
  eq("approve Write: a.txt", blocked)
  local _, _, none = S.text({ event = "error" })
  eq("", none)
  local _, _, done = S.text({ event = "done", worked = 252, msg = "ignored" })
  eq("Worked for 4m 12s", done)
end)

test("applescript escapes quotes and backslashes", function()
  local script = S.applescript("T", "S", [[say "hi" \ there]])
  eq([[display notification "say \"hi\" \\ there" with title "T" subtitle "S"]], script)
end)

test("applescript replaces control characters", function()
  local script = S.applescript("T", "S", "a\nb\tc")
  eq([[display notification "a b c" with title "T" subtitle "S"]], script)
end)

test("locate finds labels and focus in the fixture", function()
  local view = rex.json.decode(fixture("view.json"))
  eq({ session_label = "infra", window_id = "window:w2", window_label = "tests", focused = true },
    S.locate(view, "block:b3"))
  eq({ session_label = "infra", window_id = "window:w1", window_label = "deploy", focused = false },
    S.locate(view, "block:b1"))
  eq(false, S.locate(view, "block:b2").focused)
end)

test("locate returns nil for an unknown block or a missing view", function()
  local view = rex.json.decode(fixture("view.json"))
  eq(nil, S.locate(view, "block:zzz"))
  eq(nil, S.locate(nil, "block:b1"))
  eq(nil, S.locate({}, "block:b1"))
end)

test("order filters and sorts", function()
  local ordered = S.order({
    { block_id = "d2", state = "done", updated_at = "2026-11-13T10:00:05" },
    { block_id = "w", state = "working", updated_at = "2026-11-13T10:00:00" },
    { block_id = "e", state = "error", updated_at = "2026-11-13T10:00:09" },
    { block_id = "b2", state = "blocked", updated_at = "2026-11-13T10:00:08" },
    { block_id = "i", state = "idle", updated_at = "2026-11-13T10:00:00" },
    { block_id = "d1", state = "done", updated_at = "2026-11-13T10:00:01" },
    { block_id = "b1", state = "blocked", updated_at = "2026-11-13T10:00:02" },
  })
  local ids = {}
  for i, item in ipairs(ordered) do
    ids[i] = item.block_id
  end
  eq({ "b1", "b2", "e", "d1", "d2" }, ids)
end)

test("next cycles and wraps", function()
  local list = { { block_id = "a" }, { block_id = "b" }, { block_id = "c" } }
  eq("a", S.next(list, nil).block_id)
  eq("b", S.next(list, "a").block_id)
  eq("a", S.next(list, "c").block_id)
  eq("a", S.next(list, "zzz").block_id)
  eq(nil, S.next({}, "a"))
  eq("a", S.next({ { block_id = "a" } }, "a").block_id)
end)

test("root ignores child records", function()
  eq("done", S.root({ { id = "build", state = "working" }, { state = "done" } }).state)
  eq("idle", S.root({ { id = "", state = "idle" } }).state)
  eq(nil, S.root({ { id = "build", state = "working" } }))
  eq(nil, S.root(nil))
end)

test("applescript keeps non-ASCII text and neutralises script syntax", function()
  local script = S.applescript("T", "fred › infra", 'é 日本 " & (do shell script "x") & "')
  eq([[display notification "é 日本 \" & (do shell script \"x\") & \"" with title "T" subtitle "fred › infra"]], script)
end)
