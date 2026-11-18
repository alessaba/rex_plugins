-- Shell history picker for Rex
--
-- Ctrl-H opens a floating fzf list of the focused pane's shell history and
-- types the chosen command into that pane without running it.
--
--   * Detects zsh, bash, or fish from the pane's process tree.
--   * On an ssh pane, reads the remote host's history over a second,
--     non-interactive ssh connection (key or agent auth required).
--   * The floating window title is the detected shell, e.g. "zsh history".
--   * fzf chrome stays stock; optional bat coloring uses the terminal palette.
--
-- Install:
--   1. Save this as ~/.config/rex/history.lua
--   2. In init.lua add:
--        local dir = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
--        dofile(dir .. "/rex/history.lua")
--   3. Run: rex config reload
--
-- Requires fzf. bat is optional, used only when HIGHLIGHT is true. The picker
-- itself runs under sh; zsh, bash, and fish are only invoked to read their own
-- history. ssh and ps are used only for ssh panes.
--
-- Change KEY, FLOAT_BOUNDS, HISTORY_SIZE, or HIGHLIGHT below to taste.

local KEY          = "ctrl+h"
local FLOAT_BOUNDS = { x = 0.08, y = 0.08, w = 0.84, h = 0.62 }
local HISTORY_SIZE = 50000
-- Color command rows with bat when it is installed. false keeps them plain.
local HIGHLIGHT    = true
local TERMINAL     = "com.superlogical.terminal"

-- The terminal's process view: foreground, child, and ancestors.
local function block_process(block_id)
  local ok, p = pcall(rex.block.call, TERMINAL, "process", { block_id = block_id })
  if not ok then return nil end
  return p
end

-- Return the first zsh, bash, or fish in the pane's process tree. Looking past
-- the foreground process keeps this working while a command is running.
local function detect_shell(block_id)
  local p = block_process(block_id)
  if p == nil then return nil end

  local candidates = {}
  if p.foreground ~= nil then candidates[#candidates + 1] = p.foreground end
  if p.child ~= nil then candidates[#candidates + 1] = p.child end
  for _, proc in ipairs(p.ancestors or {}) do candidates[#candidates + 1] = proc end

  for _, proc in ipairs(candidates) do
    local name = (proc.name or ""):lower():gsub("^-", "")
    if name == "zsh" or name == "bash" or name == "fish" then
      return name
    end
  end
  return nil
end

local function shquote(text)
  return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function fill(template, values)
  return (template:gsub("__([A-Z_]+)__", function(key)
    local value = values[key]
    if value == nil then return "__" .. key .. "__" end
    return value
  end))
end

-- ssh options that take a separate value, used when locating the destination.
local ssh_value_opts = {
  B = true, b = true, c = true, D = true, E = true, e = true, F = true,
  I = true, i = true, J = true, L = true, l = true, m = true, O = true,
  o = true, p = true, Q = true, R = true, S = true, W = true, w = true,
}

-- If the pane is an ssh client, return its arguments and destination.
-- is_ssh is true even when the arguments can't be reused, so the caller can
-- explain why instead of silently reading the local history.
local function ssh_pane(block_id)
  local p = block_process(block_id)
  if p == nil or p.foreground == nil then return nil, nil, false end

  local fg = p.foreground
  local name = (fg.name or ""):lower():gsub("^-", "")
  if name ~= "ssh" then return nil, nil, false end

  local r, err = rex.exec({ "ps", "-o", "args=", "-p", tostring(fg.pid) })
  if r == nil or not r.ok then return nil, err or "ps failed", true end

  local tokens = {}
  for token in r.stdout:gmatch("%S+") do tokens[#tokens + 1] = token end
  table.remove(tokens, 1) -- the ssh executable

  local i, dest_at = 1, nil
  while i <= #tokens do
    local t = tokens[i]
    if t == "--" then
      dest_at = i + 1
      break
    elseif t:sub(1, 1) == "-" and #t > 1 then
      local opt = t:sub(2, 2)
      i = i + ((ssh_value_opts[opt] and #t == 2) and 2 or 1)
    else
      dest_at = i
      break
    end
  end

  if dest_at == nil or tokens[dest_at] == nil then
    return nil, "no ssh destination", true
  end
  if dest_at ~= #tokens then
    return nil, "this ssh pane already runs a remote command", true
  end

  return tokens, tokens[dest_at], true
end

-- Local pane: ask the pane's shell for its own history. The ~ is expanded by
-- that shell, so a remote Rex server reads its own home, not the client's.
-- These are the default history files; change the paths if you set HISTFILE
-- or fish_history to a custom location.
local local_history = [==[
case "$shell_name" in
  bash)
    raw=$(bash -c "HISTSIZE=$HISTORY_SIZE; HISTFILE=~/.bash_history; set -o history; history -r; history" 2>/dev/null \
      | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' \
      | awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }')
    ;;
  fish)
    raw=$(fish -c 'history' 2>/dev/null)
    ;;
  *)
    raw=$(zsh -c "HISTSIZE=$HISTORY_SIZE; fc -R ~/.zsh_history 2>/dev/null; fc -rl 1 2>/dev/null" \
      | sed -E 's/^[[:space:]]*[0-9]+\**[[:space:]]+//')
    ;;
esac
]==]

-- Remote side of an ssh dump: the same idea, run by the remote login shell.
-- __HISTORY_SIZE__ is filled from the Lua constant above.
local remote_history = [==[
HISTORY_SIZE=__HISTORY_SIZE__
shell_name=$(basename "${SHELL:-sh}")
if [ "$shell_name" = "sh" ] || [ -z "$shell_name" ]; then
  if [ -f "$HOME/.zsh_history" ]; then
    shell_name=zsh
  elif [ -f "$HOME/.bash_history" ]; then
    shell_name=bash
  elif [ -f "${XDG_DATA_HOME:-$HOME/.local/share}/fish/fish_history" ]; then
    shell_name=fish
  fi
fi

case "$shell_name" in
  bash)
    if [ -f "$HOME/.bash_history" ]; then
      awk '!/^#[0-9]+$/ { print }' "$HOME/.bash_history" \
        | awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }'
    fi
    ;;
  fish)
    if command -v fish >/dev/null 2>&1; then
      fish -c 'history' 2>/dev/null
    else
      hist="${XDG_DATA_HOME:-$HOME/.local/share}/fish/fish_history"
      if [ -f "$hist" ]; then
        sed -n 's/^- cmd: //p' "$hist" | awk '
          function unescape(s,   out, i, c) {
            out = ""
            for (i = 1; i <= length(s); i++) {
              c = substr(s, i, 1)
              if (c == "\\" && i < length(s)) {
                i++
                c = substr(s, i, 1)
                if (c == "n" || c == "r") c = " "
              }
              out = out c
            }
            return out
          }
          { line[NR] = unescape($0) }
          END { for (i = NR; i > 0; i--) print line[i] }'
      fi
    fi
    ;;
  *)
    if [ -f "$HOME/.zsh_history" ] && command -v zsh >/dev/null 2>&1; then
      zsh -c "HISTSIZE=$HISTORY_SIZE; fc -R ~/.zsh_history 2>/dev/null; fc -rl 1 2>/dev/null" \
        | sed -E 's/^[[:space:]]*[0-9]+\**[[:space:]]+//'
    fi
    ;;
esac
]==]

-- Run the remote dump over a fresh, non-interactive ssh connection, reusing
-- the destination and options of the pane's existing ssh process. The remote
-- script goes in a temporary file so the shell never has to parse a here-doc
-- inside a command substitution. BatchMode avoids a password prompt.
local ssh_history = [==[
tmp=$(mktemp) || { printf 'mktemp failed\n'; sleep 3; exit 1; }
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'__REX_REMOTE__'
__REMOTE__
__REX_REMOTE__

raw=$(ssh -o BatchMode=yes -o ConnectTimeout=5 __ARGS__ 'sh -s' < "$tmp")
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'ssh to %s failed (exit %s)\n' __DEST__ "$rc"
  sleep 4
  exit 1
fi
]==]

-- Normalize the list, let fzf pick one line, and type the command into the
-- original pane. The number is only a visual row number; it is stripped.
local picker = [==[
if [ -z "$raw" ]; then
  printf 'No history found for %s\n' "$label"
  sleep 3
  exit 1
fi

# Deduplicate, newest first.
list=$(printf '%s\n' "$raw" | awk '{
  cmd = $0
  sub(/\r$/, "", cmd)
  if (cmd ~ /^[[:space:]]*$/) next
  if (!seen[cmd]++) { n++; line[n] = cmd }
} END {
  for (i = 1; i <= n; i++) print line[i]
}')

# Optional: color each command with bat's ANSI theme. This is a one-time pass,
# so fzf still filters at full speed. If bat is missing or fails, use plain.
fzf_color=
if [ "$highlight" = "1" ] && command -v bat >/dev/null 2>&1; then
  colored=$(printf '%s\n' "$list" | bat --style=plain --color=always \
    --paging=never --wrap=never --language="$bat_language" --theme=ansi 2>/dev/null) && {
    list=$colored
    fzf_color=--ansi
  }
fi

# Number from the newest (highest) down, then let fzf pick one.
set -- --height=100% --layout=reverse --info=inline-right --no-multi \
  --highlight-line --cycle --scroll-off=3 --ghost='type to filter' \
  --nth=2.. --scheme=history --prompt='❯ '
if [ -n "$fzf_color" ]; then
  set -- "$fzf_color" "$@"
fi

sel=$(
  printf '%s\n' "$list" | awk '{
    line[NR] = $0
  } END {
    for (i = 1; i <= NR; i++) printf "%d  %s\n", NR - i + 1, line[i]
  }' | fzf "$@"
)

[ -n "$sel" ] || exit 0

esc=$(printf '\033')
cmd=$(printf '%s\n' "$sel" \
  | sed -E "s/${esc}\\[[0-9;]*m//g; s/^[[:space:]]*[0-9]+  //" \
  | tr '\n' ' ')
[ -n "$cmd" ] || exit 0

rex send -s "$session" -b "$target" -- "$cmd"
]==]

rex.action{
  name        = "history",
  title       = "Search Shell History",
  description = "Pick a history entry from this pane's shell, local or over ssh, and type it into the pane.",
  category    = "Panes",
  run         = function(ctx)
    if ctx.block_id == nil then
      error("history: run this from the pane you want the command in", 0)
    end

    local ssh_args, dest, is_ssh = ssh_pane(ctx.block_id)
    local prefix, label, shell_name
    local bat_language = "bash"

    if is_ssh and ssh_args == nil then
      error("history: " .. tostring(dest), 0)
    elseif is_ssh then
      local quoted = {}
      for _, token in ipairs(ssh_args) do quoted[#quoted + 1] = shquote(token) end
      prefix = fill(ssh_history, {
        ARGS   = table.concat(quoted, " "),
        DEST   = shquote(dest),
        REMOTE = fill(remote_history, { HISTORY_SIZE = tostring(HISTORY_SIZE) }),
      })
      label = "ssh " .. dest:gsub("^.*@", "")
      shell_name = ""
    else
      shell_name = detect_shell(ctx.block_id)
      if shell_name == nil then
        error("history: this pane isn't running zsh, bash, or fish", 0)
      end
      prefix = local_history
      label = shell_name
      if shell_name == "fish" then bat_language = "fish" end
    end

    local script = "set -u\n"
      .. "HISTORY_SIZE=" .. HISTORY_SIZE .. "\n"
      .. "highlight=" .. (HIGHLIGHT and "1" or "0") .. "\n"
      .. "bat_language=" .. shquote(bat_language) .. "\n"
      .. "target=" .. shquote(ctx.block_id) .. "\n"
      .. "session=" .. shquote(ctx.session_id) .. "\n"
      .. "label=" .. shquote(label) .. "\n"
      .. "shell_name=" .. shquote(shell_name) .. "\n\n"
      .. prefix .. "\n" .. picker

    local layer, err = rex.session.new_layer{
      bounds = FLOAT_BOUNDS,
      focus  = true,
      layout = rex.layout.block{
        flavor  = TERMINAL .. ".shell",
        -- Rex shows the block label as the floating window's title.
        label   = label .. " history",
        options = { command = { "sh", "-c", script } },
      },
    }
    if layer == nil then error("history: " .. tostring(err), 0) end

    return { layer_id = layer.layer_id, block_id = layer.block_ids[1] }
  end,
}

rex.bind(KEY, "history")
