local root = rex.args.root
package.path = root .. "/lua/?.lua;" .. root .. "/test/?.lua;" .. package.path

local specs = { "status_spec", "watch_spec", "next_spec", "restore_spec" }
local stats = { count = 0, failures = 0 }

local function show(v)
  if type(v) == "table" then
    return rex.json.encode(v) or tostring(v)
  end
  return tostring(v)
end

local function same(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not same(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

function test(name, fn)
  stats.count = stats.count + 1
  local ok, err = pcall(fn)
  if not ok then
    stats.failures = stats.failures + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end

function eq(expected, actual)
  if not same(expected, actual) then
    error("expected " .. show(expected) .. " got " .. show(actual), 2)
  end
end

function fixture(name)
  local f = assert(io.open(root .. "/test/fixtures/" .. name, "r"))
  local text = f:read("*a")
  f:close()
  return text
end

for _, spec in ipairs(specs) do
  local ok, err = pcall(require, spec)
  if not ok then
    stats.count = stats.count + 1
    stats.failures = stats.failures + 1
    print("FAIL loading " .. spec .. ": " .. tostring(err))
  end
end

print(string.format("test/run.lua: %d tests, %d failed", stats.count, stats.failures))
rex.stop(stats.failures > 0 and 1 or 0)
