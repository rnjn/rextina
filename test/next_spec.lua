local N = require("rextina")

local function fake(statuses, opts)
  opts = opts or {}
  local api = { calls = {} }
  function api.call(method, args)
    api.calls[#api.calls + 1] = { method, args }
    if method == "session.list" then
      if opts.unreachable then
        return nil, "unreachable"
      end
      return { sessions = { { session_id = "session:s1", label = "infra" } } }
    end
    if method == "session.attach" then
      api.attached = true
      return {}
    end
    if method == "session.detach" then
      api.attached = false
      return {}
    end
    if opts.needs_attach and not api.attached and method ~= "session.list" then
      return nil, "stream is not attached to session"
    end
    if method == "session.view" then
      return rex.json.decode(fixture("view.json"))
    end
    if method == "block.method" then
      local records = statuses[args.block_id]
      if records == false then
        return nil, "gone"
      end
      return { records = records or {} }
    end
    return {}
  end
  return api
end

local function ids(items)
  local out = {}
  for i, item in ipairs(items) do
    out[i] = item.block_id
  end
  table.sort(out)
  return out
end

test("collect returns one item per block with a root record", function()
  local api = fake({
    ["block:b1"] = { { state = "blocked", updated_at = "t1" } },
    ["block:b2"] = { { id = "build", state = "working" } },
    ["block:b3"] = { { state = "done", updated_at = "t2" } },
  })
  local items = N.collect(api, "fred")
  eq({ "block:b1", "block:b3" }, ids(items))
  for _, item in ipairs(items) do
    if item.block_id == "block:b1" then
      eq({
        host = "fred",
        session_id = "session:s1",
        window_id = "window:w1",
        block_id = "block:b1",
        state = "blocked",
        updated_at = "t1",
      }, item)
    end
  end
end)

test("collect skips a block whose status call fails", function()
  local api = fake({ ["block:b1"] = false, ["block:b3"] = { { state = "done" } } })
  eq({ "block:b3" }, ids(N.collect(api, nil)))
end)

test("collect returns {} when session.list fails", function()
  eq({}, N.collect(fake({}, { unreachable = true }), "clu"))
end)

test("find_next merges hosts and prefers blocked over done", function()
  local apis = {
    { api = fake({ ["block:b1"] = { { state = "done", updated_at = "t1" } } }) },
    { host = "fred", api = fake({ ["block:b3"] = { { state = "blocked", updated_at = "t9" } } }) },
  }
  local item = N.find_next(apis, nil)
  eq("fred", item.host)
  eq("block:b3", item.block_id)
end)

test("find_next still answers when one host is unreachable", function()
  local apis = {
    { host = "clu", api = fake({}, { unreachable = true }) },
    { api = fake({ ["block:b1"] = { { state = "done" } } }) },
  }
  eq("block:b1", N.find_next(apis, nil).block_id)
end)

test("find_next cycles from the current block", function()
  local apis = { { api = fake({
    ["block:b1"] = { { state = "blocked", updated_at = "t1" } },
    ["block:b3"] = { { state = "blocked", updated_at = "t2" } },
  }) } }
  eq("block:b3", N.find_next(apis, "block:b1").block_id)
  eq("block:b1", N.find_next(apis, "block:b3").block_id)
end)

test("find_next returns nil when nobody is waiting", function()
  local apis = { { api = fake({ ["block:b1"] = { { state = "working" } } }) } }
  eq(nil, N.find_next(apis, nil))
end)

test("go focuses on the item's server and queues session.select", function()
  local here, there = fake({}), fake({})
  local apis = { { api = here }, { host = "fred", api = there } }
  local queued = {}
  N.go({ host = "fred", session_id = "session:s1", window_id = "window:w2", block_id = "block:b3" }, apis,
    function(name, args)
      queued[#queued + 1] = { name, args }
    end)
  eq({}, here.calls)
  eq({ { "session.focus_block", { session_id = "session:s1", block_id = "block:b3" } } }, there.calls)
  eq({ { "session.select", { session_id = "session:s1", window_id = "window:w2" } } }, queued)
end)

test("go survives a client that cannot be asked", function()
  local api = fake({})
  N.go({ session_id = "session:s1", window_id = "window:w1", block_id = "block:b1" }, { { api = api } }, function()
    error("no client")
  end)
  eq(1, #api.calls)
end)

test("find_next counts a block once when a stored host is the local server", function()
  local statuses = {
    ["block:b1"] = { { state = "blocked", updated_at = "t1" } },
    ["block:b3"] = { { state = "blocked", updated_at = "t2" } },
  }
  local apis = { { api = fake(statuses) }, { host = "spode", api = fake(statuses) } }
  local first = N.find_next(apis, "block:b1")
  eq("block:b3", first.block_id)
  eq(nil, first.host)
  eq("block:b1", N.find_next(apis, "block:b3").block_id)
end)

test("find_next moves on from the last target when focus did not follow", function()
  local apis = {
    { api = fake({ ["block:b1"] = { { state = "done", updated_at = "t1" } } }) },
    { host = "fred", api = fake({ ["block:b3"] = { { state = "blocked", updated_at = "t9" } } }) },
  }
  eq("block:b3", N.find_next(apis, "block:elsewhere", nil).block_id)
  eq("block:b1", N.find_next(apis, "block:elsewhere", "block:b3").block_id)
  eq("block:b3", N.find_next(apis, "block:b1", "block:b3").block_id)
end)

test("collect asks every terminal block and no other", function()
  local api = fake({})
  N.collect(api, nil)
  local asked = {}
  for _, call in ipairs(api.calls) do
    if call[1] == "block.method" then
      asked[#asked + 1] = call[2].block_id
    end
  end
  table.sort(asked)
  eq({ "block:b1", "block:b2", "block:b3" }, asked)
end)

test("collect attaches to a session that refuses unattached calls, then detaches", function()
  local api = fake({ ["block:b1"] = { { state = "blocked" } } }, { needs_attach = true })
  eq({ "block:b1" }, ids(N.collect(api, "fred")))
  eq(false, api.attached)
end)

test("collect does not attach when the session answers", function()
  local api = fake({ ["block:b1"] = { { state = "blocked" } } })
  N.collect(api, nil)
  for _, call in ipairs(api.calls) do
    eq(true, call[1] ~= "session.attach" and call[1] ~= "session.detach")
  end
end)

test("go attaches before focusing when the session refuses unattached calls", function()
  local api = fake({}, { needs_attach = true })
  local focused = false
  local call = api.call
  api.call = function(method, args)
    local result, err = call(method, args)
    if method == "session.focus_block" and result then
      focused = true
    end
    return result, err
  end
  N.go({ host = "fred", session_id = "session:s1", window_id = "window:w1", block_id = "block:b1" },
    { { host = "fred", api = api } }, function() end)
  eq(true, focused)
end)

test("the action looks only at the local server even when hosts are visible", function()
  local lib = {
    call = function() end,
    servers = function()
      return { "fred", "clu" }
    end,
    server = function()
      error("must not connect to other hosts")
    end,
  }
  local list = N.local_apis(lib)
  eq(1, #list)
  eq(nil, list[1].host)
  eq(lib.call, list[1].api.call)
end)

local function done_apis()
  return { { api = fake({
    ["block:b1"] = { { state = "done", updated_at = "t1" } },
    ["block:b3"] = { { state = "done", updated_at = "t2" } },
  }) } }
end

test("a done pane is offered once, then skipped", function()
  local seen = {}
  local first = N.find_next(done_apis(), "block:elsewhere", nil, seen)
  eq("block:b1", first.block_id)
  local second = N.find_next(done_apis(), "block:b1", first.block_id, seen)
  eq("block:b3", second.block_id)
  eq(nil, N.find_next(done_apis(), "block:b3", second.block_id, seen))
end)

test("a done pane is offered again after the agent finishes another turn", function()
  local seen = { ["block:b1"] = "t1", ["block:b3"] = "t2" }
  local apis = { { api = fake({
    ["block:b1"] = { { state = "done", updated_at = "t9" } },
    ["block:b3"] = { { state = "done", updated_at = "t2" } },
  }) } }
  eq("block:b1", N.find_next(apis, "block:elsewhere", nil, seen).block_id)
end)

test("the pane you are in counts as seen", function()
  local seen = {}
  local item = N.find_next(done_apis(), "block:b1", nil, seen)
  eq("block:b3", item.block_id)
  eq("t1", seen["block:b1"])
end)

test("blocked and failed panes are always offered", function()
  local seen = { ["block:b1"] = "t1", ["block:b3"] = "t2" }
  local apis = { { api = fake({
    ["block:b1"] = { { state = "blocked", updated_at = "t1" } },
    ["block:b3"] = { { state = "error", updated_at = "t2" } },
  }) } }
  eq("block:b1", N.find_next(apis, "block:elsewhere", nil, seen).block_id)
  eq("block:b3", N.find_next(apis, "block:b1", "block:b1", seen).block_id)
  eq("block:b1", N.find_next(apis, "block:b3", "block:b3", seen).block_id)
end)

test("seen entries for panes that no longer exist are dropped", function()
  local seen = { ["block:gone"] = "t0" }
  N.find_next(done_apis(), "block:elsewhere", nil, seen)
  eq(nil, seen["block:gone"])
end)

test("find_next works without a seen table", function()
  eq("block:b1", N.find_next(done_apis(), "block:elsewhere", nil).block_id)
end)
