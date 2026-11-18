-- ~/.config/rex/layouts.lua
--
-- Window layouts as JSON. Loaded from init.lua with dofile().
--
--   save_layout      save this window to ~/.config/rex/layouts/<name>.json
--   layout_open      pick any saved layout from the command palette
--   layout_default   "New Tab with Default Layout", opens default.json
--
-- From the CLI:
--
--   rex do save_layout              # asks for a name in the command palette
--   rex do save_layout name=dev     # no prompt
--   rex do layout_open              # pick a layout in the command palette
--   rex do layout_default           # open default.json
--
-- The layouts folder is read each time layout_open runs, so adding or removing
-- files needs no reload.
--
-- The file name is the layout's ID.
--
-- Saved: split directions and ratios, floating layers with their bounds and
-- whether they are minimized, each block's flavor and label, and each
-- terminal's working directory.
--
-- Not saved: the program running in a pane. Rex doesn't expose another
-- process's arguments (they can contain secrets). If you want a pane restored
-- with a specific program, add an options.command list by hand, for example:
--
--   "block": { "flavor": "com.superlogical.terminal.shell",
--              "label": "editor",
--              "options": { "cwd": "/Users/you/src/app",
--                           "command": ["nvim", "README.md"] } }

local terminal = "com.superlogical.terminal"
local dir = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config"))
  .. "/rex/layouts"

local function slug(text)
  local s = (text or ""):lower():gsub("[^%w]+", "-")
  s = s:gsub("^%-+", ""):gsub("%-+$", "")
  if s == "" then s = "layout" end
  return s
end

local function ensure_dir()
  local r, err = rex.exec({ "mkdir", "-p", dir })
  if r == nil then return nil, err end
  if not r.ok then return nil, r.stderr end
  return true
end

local function list_names()
  local names = {}
  local r, err = rex.exec({ "ls", "-1", dir })
  if r == nil then return nil, err end
  if not r.ok then return nil, r.stderr end
  for line in r.stdout:gmatch("[^\r\n]+") do
    local name = line:match("^(.*)%.json$")
    if name ~= nil then names[#names + 1] = name end
  end
  table.sort(names)
  return names
end

local function read_doc(path)
  local f = io.open(path, "r")
  if f == nil then return nil end
  local text = f:read("*a")
  f:close()
  return rex.json.decode(text)
end

-- The API hides other processes' arguments, but it does give their cwd.
local function block_cwd(block)
  if block.creator_name ~= terminal then return nil end
  local p = rex.block.call(terminal, "process", { block_id = block.block_id })
  if p == nil then return nil end
  local process = p.foreground or p.child
  return process and process.cwd or nil
end

-- Turn a session.view node into the layout table new_window/new_layer take.
local function capture_node(node, blocks)
  if node.block_id ~= nil then
    local b = blocks[node.block_id] or {}
    local out = { flavor = b.flavor or (terminal .. ".shell") }
    if b.label ~= nil and b.label ~= "" then out.label = b.label end
    local cwd = block_cwd(b)
    if cwd ~= nil then out.options = { cwd = cwd } end
    return { block = out }
  end

  local s = node.split
  if s == nil then return nil end
  local before = capture_node(s.before, blocks)
  local after = capture_node(s.after, blocks)
  if before == nil or after == nil then return nil end
  return {
    split = {
      direction = s.direction,
      ratio = s.ratio,
      before = before,
      after = after,
    },
  }
end

local function block_index(layer)
  local blocks = {}
  for _, b in ipairs(layer.blocks or {}) do blocks[b.block_id] = b end
  return blocks
end

local function layer_has_block(layer, block_id)
  for _, b in ipairs(layer.blocks or {}) do
    if b.block_id == block_id then return true end
  end
  return false
end

-- The window of the focused pane, or the active window when run from the CLI.
local function find_window(view, block_id)
  local windows = view.windows or {}
  if block_id ~= nil then
    for _, w in ipairs(windows) do
      for _, layer in ipairs(w.layers or {}) do
        if layer_has_block(layer, block_id) then return w end
      end
    end
  end
  for _, w in ipairs(windows) do
    if w.window_id == view.active_window_id then return w end
  end
  return nil
end

local function capture(window)
  local tiled, floating = nil, {}
  for _, layer in ipairs(window.layers or {}) do
    if layer.layout ~= nil then
      local node = capture_node(layer.layout, block_index(layer))
      if node ~= nil then
        if layer.kind == "tiled" then
          tiled = node
        else
          floating[#floating + 1] = {
            bounds = layer.bounds,
            layout = node,
            state  = layer.state,
          }
        end
      end
    end
  end
  return tiled, floating
end

local function write_layout(display, file, window, tiled, floating)
  local doc = {
    version      = 1,
    name         = display,
    window_label = window.label,
    saved_at     = os.date("%Y-%m-%dT%H:%M:%S"),
    tiled        = tiled,
  }
  if #floating > 0 then doc.floating = floating end

  local text, jerr = rex.json.encode(doc, { indent = true })
  if text == nil then return nil, jerr end

  local path = dir .. "/" .. file .. ".json"
  local f, ferr = io.open(path, "w")
  if f == nil then return nil, ferr end
  f:write(text)
  f:write("\n")
  f:close()
  return path
end

rex.action{
  name        = "save_layout",
  title       = "Save Window Layout",
  description = "Ask for a name and save this window's splits, floating layers, labels, and working directories.",
  category    = "Layouts",
  args        = { name = "string?" },
  run         = function(ctx, args)
    local ok, err = ensure_dir()
    if not ok then error("save_layout: " .. tostring(err), 0) end

    local view, verr = rex.session.view{}
    if view == nil then error("save_layout: " .. tostring(verr), 0) end

    local window = find_window(view, ctx.block_id)
    if window == nil then error("save_layout: no window to save", 0) end

    local name = args.name
    if name == nil or name == "" then
      local answer, why = rex.ui.input{
        title       = "Save layout",
        placeholder = window.label or "layout name",
        confirm     = "Save layout",
      }
      if answer == nil then
        if why == "cancelled" then return end
        error("save_layout: " .. tostring(why), 0)
      end
      name = answer
    end

    local tiled, floating = capture(window)
    if tiled == nil then error("save_layout: this window has no layout", 0) end

    local display = name:match("^%s*(.-)%s*$")
    if display == "" then display = (window.label or ""):match("^%s*(.-)%s*$") end
    if display == "" then display = "layout" end
    local file = slug(display)
    local path, werr = write_layout(display, file, window, tiled, floating)
    if path == nil then error("save_layout: " .. tostring(werr), 0) end

    return { name = display, file = file, path = path, window_id = window.window_id }
  end,
}

-- Drop a saved cwd that doesn't exist here, so a layout from another machine
-- still opens instead of failing when a block starts.
local function sanitize_node(node)
  if node == nil then return end
  if node.block ~= nil then
    local options = node.block.options
    if options ~= nil and options.cwd ~= nil then
      local r = rex.exec({ "test", "-d", options.cwd })
      if r == nil or not r.ok then options.cwd = nil end
    end
    return
  end
  local s = node.split
  if s ~= nil then
    sanitize_node(s.before)
    sanitize_node(s.after)
  end
end

local function load_path(path, label)
  local doc = read_doc(path)
  if doc == nil then
    error("layout: " .. tostring(label or path) .. " is missing or unreadable", 0)
  end
  if doc.tiled == nil then
    error("layout: " .. tostring(label or path) .. " has no tiled layout", 0)
  end

  sanitize_node(doc.tiled)
  for _, layer in ipairs(doc.floating or {}) do
    sanitize_node(layer.layout)
  end

  local win, werr = rex.session.new_window{
    window_label = doc.window_label,
    layout       = doc.tiled,
  }
  if win == nil then error("layout: " .. tostring(werr), 0) end

  local layer_ids = {}
  for _, layer in ipairs(doc.floating or {}) do
    local l, lerr = rex.session.new_layer{
      window_id = win.window_id,
      bounds    = layer.bounds,
      layout    = layer.layout,
    }
    if l == nil then error("layout: " .. tostring(lerr), 0) end
    if layer.state == "minimized" then
      local _, serr = rex.session.set_layer_state{
        layer_id = l.layer_id,
        state    = "minimized",
      }
      if serr ~= nil then error("layout: " .. tostring(serr), 0) end
    end
    layer_ids[#layer_ids + 1] = l.layer_id
  end

  local result = { window_id = win.window_id }
  if #layer_ids > 0 then result.layer_ids = layer_ids end
  return result
end

rex.action{
  name        = "layout_default",
  title       = "New Tab with Default Layout",
  description = "Open layouts/default.json as a new window.",
  category    = "Layouts",
  keywords    = "layout workspace default",
  run         = function()
    return load_path(dir .. "/default.json", "default.json")
  end,
}

rex.action{
  name        = "layout_open",
  title       = "Open Window Layout…",
  description = "Pick a saved layout and open it as a new window.",
  category    = "Layouts",
  keywords    = "layout workspace open load",
  run         = function()
    local names, err = list_names()
    if names == nil then error("layout_open: " .. tostring(err), 0) end

    local items = {}
    for _, base in ipairs(names) do
      local doc = read_doc(dir .. "/" .. base .. ".json")
      local title = base
      if doc ~= nil and type(doc.name) == "string" and doc.name ~= "" then
        title = doc.name
      end
      items[#items + 1] = {
        id       = base,
        title    = title,
        subtitle = base .. ".json",
        icon     = "document",
      }
    end
    if #items == 0 then
      error("layout_open: no layouts saved in " .. dir, 0)
    end

    local base, why = rex.ui.pick{
      title       = "Open layout",
      placeholder = "Filter layouts",
      confirm     = "Open layout",
      items       = items,
    }
    if base == nil then
      if why == "cancelled" then return end
      error("layout_open: " .. tostring(why), 0)
    end

    return load_path(dir .. "/" .. base .. ".json", base .. ".json")
  end,
}

rex.bind("alt+cmd+s", "save_layout")
