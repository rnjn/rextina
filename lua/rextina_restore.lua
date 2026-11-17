local M = {}

local TERMINAL = "com.superlogical.terminal"
local ID_PATTERN = "^[A-Za-z0-9][A-Za-z0-9-]*$"
local MAX_DEPTH = 32

function M.valid_id(value)
  return type(value) == "string" and value:match(ID_PATTERN) ~= nil
end

function M.claude_id(process, record)
  local foreground = type(process) == "table" and process.foreground
  if type(foreground) ~= "table" or foreground.name ~= "claude" then
    return nil
  end
  if type(record) ~= "table" or record.kind ~= "interactive" or record.cwd ~= foreground.cwd then
    return nil
  end
  if not M.valid_id(record.sessionId) then
    return nil
  end
  return record.sessionId
end

local function chosen_label(label, generated)
  if type(label) ~= "string" or label == "" or label:match(generated) then
    return nil
  end
  return label
end

local function save_pane(deps, session_id, block, flags)
  local pane = {}
  if not block or block.creator_name ~= TERMINAL then
    return pane
  end
  if flags.ids then
    pane.block_id = block.block_id
  end
  pane.label = chosen_label(block.label, "^shell$")
  local process = deps.process(session_id, block.block_id)
  local foreground = type(process) == "table" and process.foreground
  if type(foreground) == "table" then
    pane.cwd = foreground.cwd
    pane.program = foreground.name
    pane.claude = M.claude_id(process, foreground.pid and deps.claude(foreground.pid))
  else
    flags.incomplete = true
  end
  return pane
end

local function save_layout(deps, session_id, node, blocks, flags)
  if type(node) ~= "table" then
    return { pane = {} }
  end
  if node.split then
    return {
      split = {
        direction = node.split.direction,
        ratio = node.split.ratio,
        before = save_layout(deps, session_id, node.split.before, blocks, flags),
        after = save_layout(deps, session_id, node.split.after, blocks, flags),
      },
    }
  end
  return { pane = save_pane(deps, session_id, blocks[node.block_id], flags) }
end

local function tiled(window)
  for _, layer in ipairs(window.layers or {}) do
    if layer.kind == "tiled" then
      return layer
    end
  end
  return nil
end

function M.build(deps, ids)
  local status = deps.status()
  if type(status) ~= "table" or not status.instance_id then
    return nil
  end
  local save = {
    version = 1,
    instance_id = status.instance_id,
    host_id = status.host_id,
    saved_at = deps.now(),
    host = deps.host,
    sessions = {},
  }
  local flags = { incomplete = false, ids = ids }
  for _, session in ipairs(deps.sessions() or {}) do
    local view = deps.view(session.session_id)
    if type(view) == "table" then
      local tabs = {}
      for _, window in ipairs(view.windows or {}) do
        local layer = tiled(window)
        if layer then
          local blocks = {}
          for _, block in ipairs(layer.blocks or {}) do
            blocks[block.block_id] = block
          end
          tabs[#tabs + 1] = {
            label = chosen_label(window.label, "^Window %x+$"),
            active = window.window_id == view.active_window_id,
            layout = save_layout(deps, session.session_id, layer.layout, blocks, flags),
          }
        end
      end
      save.sessions[#save.sessions + 1] = {
        session_id = ids and session.session_id or nil,
        label = session.label,
        tabs = tabs,
      }
    else
      flags.incomplete = true
    end
  end
  return save, flags.incomplete
end

local function valid_layout(node, depth)
  if type(node) ~= "table" or depth > MAX_DEPTH then
    return false
  end
  if node.split ~= nil then
    local split = node.split
    return type(split) == "table"
      and type(split.direction) == "string"
      and type(split.ratio) == "number"
      and valid_layout(split.before, depth + 1)
      and valid_layout(split.after, depth + 1)
  end
  return type(node.pane) == "table"
end

function M.valid_save(save)
  if type(save) ~= "table" or save.version ~= 1 then
    return false
  end
  if type(save.instance_id) ~= "string" or type(save.saved_at) ~= "string" or type(save.sessions) ~= "table" then
    return false
  end
  if save.host_id ~= nil and type(save.host_id) ~= "string" then
    return false
  end
  for _, session in pairs(save.sessions) do
    if type(session) ~= "table" or type(session.tabs) ~= "table" then
      return false
    end
    for _, tab in pairs(session.tabs) do
      if type(tab) ~= "table" or not valid_layout(tab.layout, 1) then
        return false
      end
    end
  end
  return true
end

local function walk(node, visit)
  if type(node) ~= "table" then
    return
  end
  if node.split then
    walk(node.split.before, visit)
    walk(node.split.after, visit)
  elseif node.pane then
    visit(node.pane)
  end
end

function M.counts(session)
  local counts = { tabs = 0, panes = 0, resumed = 0 }
  for _, tab in ipairs(session.tabs or {}) do
    counts.tabs = counts.tabs + 1
    walk(tab.layout, function(pane)
      counts.panes = counts.panes + 1
      if pane.claude then
        counts.resumed = counts.resumed + 1
      end
    end)
  end
  return counts
end

function M.is_trivial(save)
  local sessions = save.sessions or {}
  if #sessions == 0 then
    return true
  end
  if #sessions > 1 then
    return false
  end
  local counts = M.counts(sessions[1])
  return counts.tabs == 1 and counts.panes == 1 and counts.resumed == 0
end

function M.from_here(save, status)
  return save.host_id == nil or save.host_id == status.host_id
end

function M.choose(saves, current_instance_id, wanted_id)
  if wanted_id then
    if wanted_id == current_instance_id then
      return nil, "running"
    end
    for _, save in ipairs(saves) do
      if save.instance_id == wanted_id then
        return save
      end
    end
    return nil, "unknown"
  end
  local newest
  for _, save in ipairs(saves) do
    if save.instance_id ~= current_instance_id and not M.is_trivial(save) then
      if not newest or (save.saved_at or "") > (newest.saved_at or "") then
        newest = save
      end
    end
  end
  if not newest then
    return nil, "none"
  end
  if newest.closed_at then
    return nil, "closed"
  end
  return newest
end

local function text(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function api_layout(node, deps)
  if type(node) == "table" and type(node.split) == "table" then
    return {
      split = {
        direction = node.split.direction,
        ratio = node.split.ratio,
        before = api_layout(node.split.before, deps),
        after = api_layout(node.split.after, deps),
      },
    }
  end
  local pane = type(node) == "table" and type(node.pane) == "table" and node.pane or {}
  local options = {}
  local cwd = text(pane.cwd)
  if cwd and deps.dir_exists(cwd) then
    options.cwd = cwd
  end
  if M.valid_id(pane.claude) then
    options.initial_input = "claude --resume " .. pane.claude .. "\n"
  end
  local block = { flavor = TERMINAL .. ".shell", label = text(pane.label) }
  if next(options) then
    block.options = options
  end
  return { block = block }
end

function M.window_spec(tab, deps)
  return { window_label = text(tab.label), layout = api_layout(tab.layout, deps) }
end

local SHELLS = { sh = true, bash = true, zsh = true, fish = true, dash = true, ksh = true, tcsh = true, nu = true }

local function at_prompt(pane, cwd)
  local program = type(pane.program) == "string" and pane.program:gsub("^%-", "") or ""
  return SHELLS[program] == true and pane.cwd == cwd
end

local function pair(saved, live, pairs_out)
  if type(saved) ~= "table" or type(live) ~= "table" then
    return false
  end
  if saved.split or live.split then
    return type(saved.split) == "table"
      and type(live.split) == "table"
      and saved.split.direction == live.split.direction
      and pair(saved.split.before, live.split.before, pairs_out)
      and pair(saved.split.after, live.split.after, pairs_out)
  end
  if type(saved.pane) ~= "table" or type(live.pane) ~= "table" then
    return false
  end
  pairs_out[#pairs_out + 1] = { saved = saved.pane, live = live.pane }
  return true
end

local function match(session, candidate)
  local tabs, live_tabs = session.tabs or {}, candidate.tabs or {}
  if #tabs == 0 or #tabs ~= #live_tabs then
    return nil
  end
  local found = {}
  for i, tab in ipairs(tabs) do
    if tab.label ~= live_tabs[i].label or not pair(tab.layout, live_tabs[i].layout, found) then
      return nil
    end
  end
  return found
end

local function running(sessions)
  local ids = {}
  for _, session in ipairs(sessions) do
    for _, tab in ipairs(session.tabs or {}) do
      walk(tab.layout, function(pane)
        if pane.claude then
          ids[pane.claude] = true
        end
      end)
    end
  end
  return ids
end

local function resume(found, session_id, deps, live_ids, entry)
  entry.in_place = true
  entry.resumed = 0
  local skipped = 0
  for _, both in ipairs(found) do
    local id = both.saved.claude
    if M.valid_id(id) and not live_ids[id] then
      if both.live.block_id
        and at_prompt(both.live, both.saved.cwd)
        and deps.write(session_id, both.live.block_id, "claude --resume " .. id .. "\n")
      then
        live_ids[id] = true
        entry.resumed = entry.resumed + 1
      else
        skipped = skipped + 1
      end
    end
  end
  if skipped > 0 then
    entry.skipped = skipped
  end
end

function M.restore(save, deps, all)
  local report = { saved_at = save.saved_at, host = save.host, complete = true, sessions = {} }
  local live = deps.live and deps.live() or {}
  local live_ids, used = running(live), {}
  for _, session in ipairs(save.sessions or {}) do
    if all or not session.restored_at then
      local tabs = session.tabs or {}
      local entry = M.counts(session)
      entry.label = session.label
      local created, err = true, nil
      local found
      for _, same_label in ipairs({ true, false }) do
        for i, candidate in ipairs(live) do
          found = not found
            and not used[i]
            and candidate.session_id
            and (candidate.label == session.label) == same_label
            and match(session, candidate)
          if found then
            used[i] = true
            resume(found, candidate.session_id, deps, live_ids, entry)
            break
          end
        end
        if found then
          break
        end
      end
      if not found and #tabs > 0 then
        local windows, active = {}, nil
        for i, tab in ipairs(tabs) do
          windows[i] = M.window_spec(tab, deps)
          if tab.active == true then
            active = i
          end
        end
        created, err = deps.create({ label = text(session.label), initial_windows = windows })
        local made = type(created) == "table" and created.initial_windows
        if active and type(made) == "table" and made[active] then
          deps.focus_window(created.session_id, made[active].window_id)
        end
      end
      if created then
        session.restored_at = deps.now()
        deps.persist(save)
        report.sessions[#report.sessions + 1] = entry
      else
        entry.error = tostring(err)
        report.complete = false
        report.sessions[#report.sessions + 1] = entry
      end
    end
  end
  for _, session in ipairs(save.sessions or {}) do
    if not session.restored_at then
      report.complete = false
    end
  end
  if report.complete and not save.closed_at then
    save.closed_at = deps.now()
    deps.persist(save)
  end
  return report
end

return M
