local Restore = require("rextina_restore")

local Store = {}
Store.__index = Store

local ID_PATTERN = "^[A-Za-z0-9-]+$"

function Store.new(lib, dir)
  return setmetatable({ lib = lib, dir = dir }, Store)
end

function Store.default_dir(getenv)
  local explicit = getenv("REXTINA_STATE_DIR")
  if explicit and explicit ~= "" then
    return explicit
  end
  local state = getenv("XDG_STATE_HOME")
  if not state or state == "" then
    state = (getenv("HOME") or "") .. "/.local/state"
  end
  return state .. "/rextina/saves"
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

function Store:path(instance_id)
  return self.dir .. "/" .. instance_id .. ".json"
end

function Store:write(save)
  local id = save.instance_id
  if type(id) ~= "string" or not id:match(ID_PATTERN) then
    return nil, "invalid instance id"
  end
  local made = self.lib.exec({ "mkdir", "-p", self.dir })
  if not made or not made.ok then
    return nil, "cannot create " .. self.dir
  end
  self.lib.exec({ "chmod", "700", self.dir })
  local text, encode_err = self.lib.json.encode(save, { indent = true })
  if not text then
    return nil, encode_err
  end
  local path = self:path(id)
  local tmp = path .. ".tmp"
  local f, open_err = io.open(tmp, "w")
  if not f then
    return nil, open_err
  end
  f:write(text)
  f:close()
  self.lib.exec({ "chmod", "600", tmp })
  local ok, rename_err = os.rename(tmp, path)
  if not ok then
    os.remove(tmp)
    return nil, rename_err
  end
  return path
end

function Store:load(name)
  local text = read_file(self.dir .. "/" .. name)
  if not text or text == "" then
    return nil
  end
  local save = self.lib.json.decode(text)
  local checked, valid = pcall(Restore.valid_save, save)
  if not checked or not valid or save.instance_id .. ".json" ~= name then
    return nil
  end
  return save
end

function Store:read(instance_id)
  if type(instance_id) ~= "string" or not instance_id:match(ID_PATTERN) then
    return nil
  end
  return self:load(instance_id .. ".json")
end

function Store:read_all()
  local saves = {}
  local listed = self.lib.exec({ "ls", self.dir })
  if not listed or not listed.ok then
    return saves
  end
  for name in listed.stdout:gmatch("[^\n]+") do
    if name:match("%.json$") then
      local save = self:load(name)
      if save then
        saves[#saves + 1] = save
      end
    end
  end
  return saves
end

function Store:prune(keep)
  local saves = self:read_all()
  table.sort(saves, function(a, b)
    return a.saved_at > b.saved_at
  end)
  local kept = { real = 0, trivial = 0 }
  for _, save in ipairs(saves) do
    local kind = Restore.is_trivial(save) and "trivial" or "real"
    kept[kind] = kept[kind] + 1
    if kept[kind] > keep then
      os.remove(self:path(save.instance_id))
    end
  end
end

return Store
