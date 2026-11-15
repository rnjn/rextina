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

return M
