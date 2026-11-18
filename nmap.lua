-- ~/.config/rex/nmap.lua
--
-- Nmap scans. Loaded from init.lua with dofile().
--
--   nmap_scan   run a full TCP scan in a new split
--
-- The action is the same as the zsh portscan alias:
--
--   sudo nmap -sS -Pn -sC -p- <target>
--
-- Running it in a pane lets sudo ask for a password and keeps the output
-- after the scan finishes.
--
-- From the CLI:
--
--   rex do nmap_scan target=10.10.14.7

local shell = "com.superlogical.terminal.shell"
local home = os.getenv("HOME") or ""

local function trim(text)
  return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function find_bin(candidates)
  for _, path in ipairs(candidates) do
    local r = rex.exec({ "test", "-x", path })
    if r ~= nil and r.ok then return path end
  end
  return nil
end

local function valid_target(target)
  if target:sub(1, 1) == "-" then return false end
  if target:find("%s") then return false end
  return target:match("^[%w%._:%%/%[%]%-]+$") ~= nil
end

rex.action{
  name        = "nmap_scan",
  title       = "Nmap: Scan Host…",
  description = "Run sudo nmap -sS -Pn -sC -p- in a new split.",
  category    = "Security",
  keywords    = "nmap scan ports network recon",
  args        = { target = "string?" },
  run         = function(ctx, args)
    local target = args.target
    if target == nil or trim(target) == "" then
      local answer, why = rex.ui.input{
        title       = "Nmap target",
        placeholder = "host, IP, or CIDR",
        confirm     = "Scan",
      }
      if answer == nil then
        if why == "cancelled" then return end
        error("nmap_scan: " .. tostring(why), 0)
      end
      target = answer
    end

    target = trim(target)
    if target == "" then error("nmap_scan: empty target", 0) end
    if not valid_target(target) then
      error("nmap_scan: invalid target: " .. target, 0)
    end

    local nmap = find_bin({
      "/opt/homebrew/bin/nmap",
      "/usr/local/bin/nmap",
      "/usr/bin/nmap",
      home .. "/.local/bin/nmap",
    })
    if nmap == nil then error("nmap_scan: nmap not found", 0) end

    local sudo = find_bin({ "/usr/bin/sudo" })
    if sudo == nil then error("nmap_scan: sudo not found", 0) end

    local split, err = rex.session.new_split{
      direction = "horizontal",
      side      = "after",
      ratio     = 0.55,
      focus     = true,
      layout    = rex.layout.block{
        flavor  = shell,
        options = {
          command = { sudo, nmap, "-sS", "-Pn", "-sC", "-p-", target },
          shell   = "none",
          exit    = { on_completion = false },
        },
      },
    }
    if split == nil then error("nmap_scan: " .. tostring(err), 0) end

    return { target = target }
  end,
}
