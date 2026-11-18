-- ~/.config/rex/ports.lua
--
-- Listening TCP ports. Loaded from init.lua with dofile().
--
--   ports_open   pick a local listening port and open it in the browser
--
-- Picking a port probes https and then http with curl. Only a port that
-- answers HTTP is opened; anything else is reported instead.

local function trim(text)
  return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
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

-- TCP listeners with their process, one entry per port.
local function list_ports()
  local r, err = rex.exec({ "lsof", "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn" })
  if r == nil then return nil, err end
  if not r.ok and trim(r.stdout) == "" then
    local detail = trim(r.stderr)
    if detail ~= "" then return nil, detail end
  end

  local ports, seen = {}, {}
  local pid, command
  for line in r.stdout:gmatch("[^\n]+") do
    local tag, value = line:sub(1, 1), line:sub(2)
    if tag == "p" then
      pid = tonumber(value)
      command = nil
    elseif tag == "c" then
      command = value
    elseif tag == "n" then
      local port = tonumber(value:match(":(%d+)$") or "")
      if port ~= nil and not seen[port] then
        seen[port] = true
        ports[#ports + 1] = { port = port, pid = pid, command = command }
      end
    end
  end

  table.sort(ports, function(a, b) return a.port < b.port end)
  return ports
end

local function process_cwd(pid)
  if pid == nil then return nil end
  local r = rex.exec({ "lsof", "-a", "-p", tostring(pid), "-d", "cwd", "-Fn" })
  if r == nil or not r.ok then return nil end
  return r.stdout:match("n([^\n]+)")
end

-- nil means curl itself failed; false means the port did not answer HTTP.
local function probe(url)
  local r, err = rex.exec({
    "curl", "-k", "-sS", "-o", "/dev/null", "--noproxy", "*",
    "-w", "%{http_code}", "--max-time", "1", url,
  })
  if r == nil then return nil, err end

  local code = trim(r.stdout)
  return r.ok and code ~= "" and code ~= "000"
end

rex.action{
  name        = "ports_open",
  title       = "Show open ports…",
  description = "Pick a listening TCP port and open it in the browser when it serves HTTP or HTTPS.",
  category    = "Network",
  keywords    = "ports localhost server http browser open",
  run         = function()
    local ports, err = list_ports()
    if ports == nil then error("ports_open: " .. tostring(err), 0) end
    if #ports == 0 then error("ports_open: no listening TCP ports", 0) end

    local cwds = {}
    local items = {}
    for _, entry in ipairs(ports) do
      local cwd = cwds[entry.pid]
      if cwd == nil and entry.pid ~= nil then
        cwd = process_cwd(entry.pid) or false
        cwds[entry.pid] = cwd
      end

      local subtitle = entry.command or "listening"
      if cwd then subtitle = subtitle .. " · " .. home_relative(cwd) end

      items[#items + 1] = {
        id       = tostring(entry.port),
        title    = "localhost:" .. entry.port,
        subtitle = subtitle,
        detail   = entry.pid and tostring(entry.pid) or nil,
        icon     = "globe",
      }
    end

    local choice, why = rex.ui.pick{
      title       = "Open local server",
      placeholder = "Filter ports",
      items       = items,
    }
    if choice == nil then
      if why == "cancelled" then return end
      error("ports_open: " .. tostring(why), 0)
    end

    local port = tonumber(choice)
    local scheme
    local https, perr = probe("https://localhost:" .. port)
    if https == nil then error("ports_open: " .. tostring(perr), 0) end
    if https then
      scheme = "https"
    else
      local http, herr = probe("http://localhost:" .. port)
      if http == nil then error("ports_open: " .. tostring(herr), 0) end
      if http then scheme = "http" end
    end

    if scheme == nil then
      error("ports_open: port " .. port .. " did not answer HTTP or HTTPS", 0)
    end

    local url = scheme .. "://localhost:" .. port
    local r, oerr = rex.exec({ "open", url })
    if r == nil then error("ports_open: " .. tostring(oerr), 0) end
    if not r.ok then
      local detail = trim(r.stderr)
      if detail == "" then detail = "exit " .. tostring(r.code) end
      error("ports_open: open " .. url .. ": " .. detail, 0)
    end

    return { url = url }
  end,
}
