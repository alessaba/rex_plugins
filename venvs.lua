-- ~/.config/rex/venvs.lua
--
-- Python virtualenvs. Loaded from init.lua with dofile().
--
--   venv_shell   pick a virtualenv near this pane and open it activated
--   venv_new     create a virtualenv in this pane's folder and open it
--
-- "Near" means the pane's folder and two levels below it, plus the parent
-- folder. Only folders whose name ends in "venv" count (.venv, venv, myvenv).
--
-- From the CLI:
--
--   rex do venv_shell dir=~/src/project
--   rex do venv_new dir=~/src/project name=.venv
--
-- A venv is recognized by its bin/activate, so Conda environments are not
-- listed. The new shell is a window in the current session, with the venv's
-- parent as its working directory.

local terminal = "com.superlogical.terminal"

local function trim(text)
  return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function shquote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function strip_slash(path)
  local p = path:gsub("/+$", "")
  if p == "" then return "/" end
  return p
end

local function join(dir, name)
  if dir == "/" then return "/" .. name end
  return dir .. "/" .. name
end

local function basename(path)
  return strip_slash(path):match("([^/]+)$") or "/"
end

local function dirname(path)
  local p = strip_slash(path)
  if p == "/" then return nil end
  local parent = p:match("^(.*)/[^/]+$")
  if parent == "" then return "/" end
  return parent
end

local function home_relative(path)
  local home = os.getenv("HOME")
  if home ~= nil and home ~= "" then
    if path == home then return "~" end
    if path:sub(1, #home + 1) == home .. "/" then
      return "~" .. path:sub(#home + 1)
    end
  end
  return path
end

-- A folder named ".venv" or "venv" says nothing on its own, so call it after
-- its project. Other names, such as "myvenv", are already meaningful.
local function venv_name(path)
  local name = basename(path)
  local lower = name:lower()
  if lower == ".venv" or lower == "venv" then
    local parent = dirname(path)
    if parent ~= nil then return basename(parent) end
  end
  return name
end

local function block_cwd(block_id)
  if block_id == nil then return nil end
  local p = rex.block.call(terminal, "process", { block_id = block_id })
  if p == nil then return nil end
  local process = p.foreground or p.child
  return process and process.cwd or nil
end

-- args.dir wins; otherwise the pane's shell directory. Relative paths are
-- resolved against the pane. Returns nil outside a pane with no dir.
local function resolve_dir(arg, block_id)
  local dir = arg
  if dir == nil or trim(dir) == "" then
    dir = block_cwd(block_id)
    if dir == nil then return nil end
    return strip_slash(dir)
  end

  dir = trim(dir)
  if dir == "~" or dir:sub(1, 2) == "~/" then
    dir = (os.getenv("HOME") or "~") .. dir:sub(2)
  end
  if dir:sub(1, 1) ~= "/" then
    local base = block_cwd(block_id)
    if base == nil then return nil end
    dir = join(base, dir)
  end
  return strip_slash(dir)
end

local function check_dir(dir)
  local r, err = rex.exec({ "test", "-d", dir })
  if r == nil then return nil, err end
  if not r.ok then return nil, "not a directory: " .. dir end
  return true
end

-- The terminal's activate script is the marker; it works for venv, virtualenv,
-- and uv-created environments alike.
local function has_activate(path)
  local r = rex.exec({ "test", "-f", join(path, "bin/activate") })
  return r ~= nil and r.ok
end

local function find_named_venvs(root, depth)
  local r, err = rex.exec({
    "find", root,
    "-mindepth", "1",
    "-maxdepth", tostring(depth),
    "-type", "d",
    "-iname", "*venv",
  })
  if r == nil then return nil, err end

  local paths = {}
  for line in r.stdout:gmatch("[^\n]+") do
    if has_activate(line) then paths[#paths + 1] = line end
  end
  return paths
end

-- Groups: 1 = directly in dir, 2 = up to two levels below, 3 = in the parent.
local function discover(dir)
  local found, seen = {}, {}

  local function add(group, path)
    if not seen[path] then
      seen[path] = true
      found[#found + 1] = { path = path, group = group }
    end
  end

  local here, err = find_named_venvs(dir, 2)
  if here == nil then return nil, err end
  for _, path in ipairs(here) do
    local rel = path
    if rel:sub(1, #dir) == dir then rel = rel:sub(#dir + 1) end
    rel = rel:gsub("^/+", "")
    if rel:find("/", 1, true) == nil then
      add(1, path)
    else
      add(2, path)
    end
  end

  local parent = dirname(dir)
  if parent ~= nil and parent ~= dir then
    local around, perr = find_named_venvs(parent, 1)
    if around == nil then return nil, perr end
    for _, path in ipairs(around) do add(3, path) end
  end

  table.sort(found, function(a, b)
    if a.group ~= b.group then return a.group < b.group end
    return a.path < b.path
  end)
  return found
end

local function open_venv(path)
  local dir = dirname(path) or "/"
  local name = venv_name(path)
  local activate = join(path, "bin/activate")

  local win, err = rex.session.new_window{
    window_label = "venv " .. name,
    layout = rex.layout.block{
      flavor  = "com.superlogical.terminal.shell",
      label   = name,
      -- Sourcing from initial_input keeps the venv's prompt and deactivate
      -- function in the shell that stays open, instead of a parent shell.
      options = {
        cwd           = dir,
        initial_input = "source " .. shquote(activate) .. "\r",
      },
    },
  }
  if win == nil then error("venv: " .. tostring(err), 0) end
  return win
end

local function new_venv(dir, name)
  local wanted = name
  if wanted == nil or trim(wanted) == "" then
    local answer, why = rex.ui.input{
      title       = "New virtualenv in " .. basename(dir),
      placeholder = ".venv",
      confirm     = "Create",
    }
    if answer == nil then
      if why == "cancelled" then return nil end
      error("venv_new: " .. tostring(why), 0)
    end
    wanted = answer
  end

  wanted = trim(wanted or "")
  if wanted == "" then wanted = ".venv" end
  if wanted == "~" or wanted:sub(1, 2) == "~/" then
    wanted = (os.getenv("HOME") or "~") .. wanted:sub(2)
  end

  local path = wanted
  if path:sub(1, 1) ~= "/" then path = join(dir, path) end
  path = strip_slash(path)

  local r, err = rex.exec(
    { "python3", "-m", "venv", path },
    { cwd = dir, timeout = 300 })
  if r == nil then error("venv_new: " .. tostring(err), 0) end
  if not r.ok then
    local detail = trim(r.stderr)
    if detail == "" then detail = trim(r.stdout) end
    if detail == "" then detail = "exit " .. tostring(r.code) end
    error("venv_new: python3 -m venv " .. path .. ": " .. detail, 0)
  end

  local win = open_venv(path)
  return { venv = path, window_id = win.window_id }
end

rex.action{
  name        = "venv_shell",
  title       = "Python: Activate Virtualenv…",
  description = "Pick a virtualenv near this pane and open a window with it activated.",
  category    = "Python",
  keywords    = "venv virtualenv python activate",
  args        = { dir = "string?" },
  run         = function(ctx, args)
    local dir = resolve_dir(args.dir, ctx.block_id)
    if dir == nil then
      error("venv_shell: pass dir=... when running outside a pane", 0)
    end
    local ok, derr = check_dir(dir)
    if not ok then error("venv_shell: " .. tostring(derr), 0) end

    local found, err = discover(dir)
    if found == nil then error("venv_shell: " .. tostring(err), 0) end

    local items = {}
    for _, entry in ipairs(found) do
      items[#items + 1] = {
        id       = entry.path,
        title    = venv_name(entry.path),
        subtitle = home_relative(entry.path),
        icon     = "package",
      }
    end

    local new_id = "new"
    items[#items + 1] = {
      id       = new_id,
      title    = "New virtualenv in " .. basename(dir) .. "…",
      subtitle = home_relative(dir),
      icon     = "plus",
    }

    local choice, why = rex.ui.pick{
      title       = "Python virtualenv",
      placeholder = "Filter virtualenvs",
      items       = items,
    }
    if choice == nil then
      if why == "cancelled" then return end
      error("venv_shell: " .. tostring(why), 0)
    end
    if choice == new_id then return new_venv(dir) end

    local win = open_venv(choice)
    return { venv = choice, window_id = win.window_id }
  end,
}

rex.action{
  name        = "venv_new",
  title       = "Python: New Virtualenv…",
  description = "Create a virtualenv in this pane's folder and open a window with it activated.",
  category    = "Python",
  keywords    = "venv virtualenv python create",
  args        = { dir = "string?", name = "string?" },
  run         = function(ctx, args)
    local dir = resolve_dir(args.dir, ctx.block_id)
    if dir == nil then
      error("venv_new: pass dir=... when running outside a pane", 0)
    end
    local ok, derr = check_dir(dir)
    if not ok then error("venv_new: " .. tostring(derr), 0) end

    return new_venv(dir, args.name)
  end,
}

rex.bind("alt+cmd+v", "venv_shell")
