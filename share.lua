-- ~/.config/rex/share.lua
--
-- Web server and reverse-shell helpers. Loaded from init.lua with dofile().
--
--   webserver_open   serve a folder with updog, optionally via ngrok or bore
--   revshell_open    listen with nc, optionally exposed through bore
--
-- Both actions open a floating layer, so the service stays visible without
-- taking over the current pane.
--
-- From the CLI:
--
--   rex do webserver_open dir=~/Downloads port=16737 expose=local
--   rex do revshell_open port=1337 expose=bore
--
-- expose is one of local, ngrok, or bore for webserver_open, and local or
-- bore for revshell_open. Leaving it out asks with a picker.

local shell = "com.superlogical.terminal.shell"
local home = os.getenv("HOME") or ""

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

local function home_relative(path)
  if home ~= "" then
    if path == home then return "~" end
    if path:sub(1, #home + 1) == home .. "/" then
      return "~" .. path:sub(#home + 1)
    end
  end
  return path
end

local function block_cwd(block_id)
  if block_id == nil then return nil end
  local p = rex.block.call("com.superlogical.terminal", "process", { block_id = block_id })
  if p == nil then return nil end
  local process = p.foreground or p.child
  return process and process.cwd or nil
end

local function find_bin(candidates)
  for _, path in ipairs(candidates) do
    local r = rex.exec({ "test", "-x", path })
    if r ~= nil and r.ok then return path end
  end
  return nil
end

local function terminal_block(command, cwd)
  return rex.layout.block{
    flavor  = shell,
    options = {
      command = command,
      cwd     = cwd,
      shell   = "none",
      exit    = { on_completion = false },
    },
  }
end

local function resolve_dir(ctx, path)
  path = trim(path)
  if path == "~" or path:sub(1, 2) == "~/" then
    path = home .. path:sub(2)
  elseif path:sub(1, 1) ~= "/" then
    local base = block_cwd(ctx.block_id)
    if base == nil then return nil, "not an absolute path: " .. path end
    path = join(base, path)
  end

  path = strip_slash(path)
  local r = rex.exec({ "test", "-d", path })
  if r == nil or not r.ok then return nil, "not a folder: " .. path end
  return path
end

local function pick_dir(ctx, arg)
  if arg ~= nil and trim(arg) ~= "" then
    local dir, err = resolve_dir(ctx, arg)
    if dir == nil then error("webserver_open: " .. tostring(err), 0) end
    return dir
  end

  local cwd = block_cwd(ctx.block_id)
  local items, seen = {}, {}
  local function add(path)
    if path == nil or path == "" or seen[path] then return end
    seen[path] = true
    local r = rex.exec({ "test", "-d", path })
    if r ~= nil and r.ok then
      items[#items + 1] = {
        id       = path,
        title    = basename(path),
        subtitle = home_relative(path),
        icon     = "folder",
      }
    end
  end

  add(cwd)
  add(join(home, "Downloads"))
  add(join(home, "Developer"))
  add(home)

  local choice, why = rex.ui.pick{
    title       = "Serve folder",
    placeholder = "Choose a folder or type a path",
    items       = items,
    allow_other = true,
  }
  if choice == nil then
    if why == "cancelled" then return nil end
    error("webserver_open: " .. tostring(why), 0)
  end

  if type(choice) == "table" then choice = choice.text end
  local dir, err = resolve_dir(ctx, choice)
  if dir == nil then error("webserver_open: " .. tostring(err), 0) end
  return dir
end

local function ask_port(name, title, arg, default)
  local port
  if arg ~= nil and trim(arg) ~= "" then
    port = tonumber(trim(arg))
  else
    local answer, why = rex.ui.input{
      title       = title,
      value       = tostring(default),
      placeholder = tostring(default),
      confirm     = "Next",
    }
    if answer == nil then
      if why == "cancelled" then return nil end
      error(name .. ": " .. tostring(why), 0)
    end
    port = tonumber(trim(answer))
  end

  if port == nil or port < 1 or port > 65535 or port % 1 ~= 0 then
    error(name .. ": invalid port", 0)
  end

  local lsof = rex.exec({ "lsof", "-nP", "-iTCP:" .. port, "-sTCP:LISTEN" })
  if lsof ~= nil and lsof.ok then
    error(name .. ": port " .. port .. " is already listening", 0)
  end
  return port
end

local function pick_exposure(name, choices, arg)
  if arg ~= nil and trim(arg) ~= "" then
    local wanted = trim(arg):lower()
    for _, choice in ipairs(choices) do
      if choice.id == wanted then return choice.id end
    end
    error(name .. ": unknown exposure " .. wanted, 0)
  end

  local choice, why = rex.ui.pick{
    title = "Exposure",
    items = choices,
  }
  if choice == nil then
    if why == "cancelled" then return nil end
    error(name .. ": " .. tostring(why), 0)
  end
  return choice
end

local function open_layer(name, layout, bounds)
  local layer, err = rex.session.new_layer{
    bounds = bounds,
    focus  = true,
    layout = layout,
  }
  if layer == nil then error(name .. ": " .. tostring(err), 0) end
  return layer
end

rex.action{
  name        = "webserver_open",
  title       = "Open WebServer…",
  description = "Serve a folder with updog and optionally expose it with ngrok or bore.",
  category    = "Network",
  keywords    = "web server http serve folder updog ngrok bore",
  args        = { dir = "string?", port = "string?", expose = "string?" },
  run         = function(ctx, args)
    local dir = pick_dir(ctx, args.dir)
    if dir == nil then return end

    local port = ask_port("webserver_open", "Port", args.port, 16737)
    if port == nil then return end

    local exposure = pick_exposure("webserver_open", {
      { id = "local", title = "Local only", subtitle = "http://localhost:" .. port, icon = "globe" },
      { id = "ngrok", title = "Public with ngrok", subtitle = "ngrok http " .. port, icon = "link" },
      { id = "bore",  title = "Public with bore",  subtitle = "bore local " .. port .. " --to bore.pub", icon = "link" },
    }, args.expose)
    if exposure == nil then return end

    local updog = find_bin({
      home .. "/.local/bin/updog",
      "/opt/homebrew/bin/updog",
      "/usr/local/bin/updog",
    })
    if updog == nil then error("webserver_open: updog not found", 0) end

    local server = terminal_block({
      updog, "-d", dir, "-p", tostring(port),
    })

    local layout = server
    if exposure == "ngrok" then
      local ngrok = find_bin({ "/opt/homebrew/bin/ngrok", "/usr/local/bin/ngrok" })
      if ngrok == nil then error("webserver_open: ngrok not found", 0) end
      layout = rex.layout.horizontal(0.55, server, terminal_block({
        ngrok, "http", tostring(port),
      }))
    elseif exposure == "bore" then
      local bore = find_bin({ "/opt/homebrew/bin/bore", "/usr/local/bin/bore" })
      if bore == nil then error("webserver_open: bore not found", 0) end
      layout = rex.layout.horizontal(0.55, server, terminal_block({
        bore, "local", tostring(port), "--to", "bore.pub",
      }))
    end

    open_layer("webserver_open", layout, {
      x = 0.06, y = 0.16, w = 0.88, h = 0.6,
    })

    local url = "http://localhost:" .. port
    local probe = string.format(
      "for i in 1 2 3 4 5; do if curl -fsS --noproxy '*' -o /dev/null --max-time 1 %s; then open %s; exit 0; fi; sleep 0.3; done",
      shquote(url), shquote(url))
    rex.exec({ "sh", "-c", probe })

    return { url = url, dir = dir, port = port, exposure = exposure }
  end,
}

rex.action{
  name        = "revshell_open",
  title       = "Open Reverse Shell…",
  description = "Listen for a reverse shell with nc, optionally exposed through bore.",
  category    = "Network",
  keywords    = "reverse shell listener nc netcat bore payload",
  args        = { port = "string?", expose = "string?" },
  run         = function(ctx, args)
    local port = ask_port("revshell_open", "Listener port", args.port, 1337)
    if port == nil then return end

    local exposure = pick_exposure("revshell_open", {
      { id = "local", title = "Local only", subtitle = "nc -lv " .. port, icon = "terminal" },
      { id = "bore",  title = "Public with bore", subtitle = "bore local " .. port .. " --to bore.pub", icon = "link" },
    }, args.expose)
    if exposure == nil then return end

    local nc = find_bin({ "/usr/bin/nc", "/usr/local/bin/nc", "/opt/homebrew/bin/nc" })
    if nc == nil then error("revshell_open: nc not found", 0) end

    local listener = terminal_block({ nc, "-lv", tostring(port) })
    local layout = listener
    if exposure == "bore" then
      local bore = find_bin({ "/opt/homebrew/bin/bore", "/usr/local/bin/bore" })
      if bore == nil then error("revshell_open: bore not found", 0) end
      layout = rex.layout.horizontal(0.55, listener, terminal_block({
        bore, "local", tostring(port), "--to", "bore.pub",
      }))
    end

    open_layer("revshell_open", layout, {
      x = 0.08, y = 0.2, w = 0.84, h = 0.55,
    })

    return { port = port, exposure = exposure }
  end,
}
