-- ~/.config/rex/serial.lua
--
-- Serial consoles. Loaded from init.lua with dofile().
--
--   serial_console   pick a /dev/cu.* device and baud rate, then open screen
--
-- From the CLI:
--
--   rex do serial_console device=/dev/cu.usbserial-AH022NW9 baud=115200
--   rex do serial_console device=/dev/cu.usbserial-1420
--
-- The console opens in a floating layer, so the device stays visible while
-- you work. Leave screen with Ctrl-A then K.

local shell = "com.superlogical.terminal.shell"

local function trim(text)
  return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function exists(path)
  local r = rex.exec({ "test", "-e", path })
  return r ~= nil and r.ok
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function screen_path()
  for _, path in ipairs({
    "/usr/bin/screen",
    "/opt/homebrew/bin/screen",
    "/usr/local/bin/screen",
  }) do
    local r = rex.exec({ "test", "-x", path })
    if r ~= nil and r.ok then return path end
  end
  return nil
end

local function list_devices()
  local r, err = rex.exec({ "sh", "-c",
    [[for d in /dev/cu.*; do [ -e "$d" ] && printf '%s\n' "$d"; done]] })
  if r == nil then return nil, err end

  local devices = {}
  for path in r.stdout:gmatch("[^\n]+") do
    local name = basename(path)
    if name ~= "cu.Bluetooth-Incoming-Port" and name ~= "cu.debug-console" then
      devices[#devices + 1] = {
        path = path,
        name = name:gsub("^cu%.", ""),
      }
    end
  end

  table.sort(devices, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return devices
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

local BAUDS = {
  { rate = 115200, note = "most common" },
  { rate = 9600,   note = "legacy devices" },
  { rate = 57600 },
  { rate = 38400 },
  { rate = 19200 },
  { rate = 230400 },
  { rate = 460800 },
  { rate = 921600 },
  { rate = 4800 },
  { rate = 2400 },
}

local function check_baud(value)
  local baud = tonumber(trim(value))
  if baud == nil or baud < 1 or baud % 1 ~= 0 then
    error("serial_console: invalid baud rate", 0)
  end
  return baud
end

local function choose_baud(arg)
  if arg ~= nil and trim(arg) ~= "" then
    return check_baud(arg)
  end

  local items = {}
  for _, entry in ipairs(BAUDS) do
    items[#items + 1] = {
      id       = tostring(entry.rate),
      title    = tostring(entry.rate),
      subtitle = entry.note,
      icon     = "terminal",
    }
  end

  local choice, why = rex.ui.pick{
    title       = "Baud rate",
    placeholder = "Choose or type a baud rate",
    items       = items,
    allow_other = true,
  }
  if choice == nil then
    if why == "cancelled" then return nil end
    error("serial_console: " .. tostring(why), 0)
  end

  if type(choice) == "table" then choice = choice.text end
  return check_baud(choice)
end

rex.action{
  name        = "serial_console",
  title       = "Serial: Open Console…",
  description = "Pick a serial device and baud rate, then open it with screen.",
  category    = "Devices",
  keywords    = "serial console screen usb",
  args        = { device = "string?", baud = "string?" },
  run         = function(ctx, args)
    local device = args.device
    if device == nil or trim(device) == "" then
      local devices, err = list_devices()
      if devices == nil then error("serial_console: " .. tostring(err), 0) end
      if #devices == 0 then error("serial_console: no serial devices found", 0) end

      local items = {}
      for _, entry in ipairs(devices) do
        items[#items + 1] = {
          id       = entry.path,
          title    = entry.name,
          subtitle = entry.path,
          icon     = "terminal",
        }
      end

      local choice, why = rex.ui.pick{
        title       = "Serial console",
        placeholder = "Filter devices",
        items       = items,
      }
      if choice == nil then
        if why == "cancelled" then return end
        error("serial_console: " .. tostring(why), 0)
      end
      device = choice
    end

    device = trim(device)
    if device == "" then error("serial_console: empty device", 0) end
    if not exists(device) then
      error("serial_console: no such device: " .. device, 0)
    end

    local baud = choose_baud(args.baud)
    if baud == nil then return end

    local screen = screen_path()
    if screen == nil then
      error("serial_console: screen not found", 0)
    end

    open_layer("serial_console", rex.layout.block{
      flavor  = shell,
      options = {
        command = { screen, device, tostring(baud) },
        shell   = "none",
        exit    = { on_completion = false },
      },
    }, {
      x = 0.06, y = 0.06, w = 0.88, h = 0.82,
    })

    return { device = device, baud = baud }
  end,
}
