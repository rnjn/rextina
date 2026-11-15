local M = {}

local TERMINAL = "com.superlogical.terminal"
local ID_PATTERN = "^[A-Za-z0-9-]+$"

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

local function save_pane(deps, session_id, block)
  local pane = {}
  if not block or block.creator_name ~= TERMINAL then
    return pane
  end
  pane.label = chosen_label(block.label, "^shell$")
  local process = deps.process(session_id, block.block_id)
  local foreground = type(process) == "table" and process.foreground
  if type(foreground) == "table" then
    pane.cwd = foreground.cwd
    pane.program = foreground.name
    pane.claude = M.claude_id(process, foreground.pid and deps.claude(foreground.pid))
  end
  return pane
end

local function save_layout(deps, session_id, node, blocks)
  if type(node) ~= "table" then
    return { pane = {} }
  end
  if node.split then
    return {
      split = {
        direction = node.split.direction,
        ratio = node.split.ratio,
        before = save_layout(deps, session_id, node.split.before, blocks),
        after = save_layout(deps, session_id, node.split.after, blocks),
      },
    }
  end
  return { pane = save_pane(deps, session_id, blocks[node.block_id]) }
end

local function tiled(window)
  for _, layer in ipairs(window.layers or {}) do
    if layer.kind == "tiled" then
      return layer
    end
  end
  return nil
end

function M.build(deps)
  local status = deps.status()
  if type(status) ~= "table" or not status.instance_id then
    return nil
  end
  local save = {
    version = 1,
    instance_id = status.instance_id,
    saved_at = deps.now(),
    host = deps.host,
    sessions = {},
  }
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
            layout = save_layout(deps, session.session_id, layer.layout, blocks),
          }
        end
      end
      save.sessions[#save.sessions + 1] = { label = session.label, tabs = tabs }
    end
  end
  return save
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

function M.restore(save, deps, all)
  local report = { saved_at = save.saved_at, host = save.host, complete = true, sessions = {} }
  for _, session in ipairs(save.sessions or {}) do
    if all or not session.restored_at then
      local tabs = session.tabs or {}
      local entry = M.counts(session)
      entry.label = session.label
      local created, err = true, nil
      if #tabs > 0 then
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
