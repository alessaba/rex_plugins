-- ~/.config/rex/git.lua
--
-- Git actions. Loaded from init.lua with dofile().
--
--   git_switch_branch   switch branch (current first, then alphabetical)
--   git_add             pick changed and untracked files to stage
--   git_commit          commit the staged files with a typed message
--   git_commit_push     commit, then pick a remote branch and push
--   git_push            push HEAD to a remote branch
--   git_pull            fast-forward the current branch
--   git_new_branch      create a branch and switch to it
--   git_clone           clone a repository and open it in a new split
--
-- The pane's shell directory picks the repository. From the CLI:
--
--   rex do git_switch_branch dir=~/src/project
--   rex do git_commit dir=~/src/project message="Tidy the palette chip"
--   rex do git_clone url=git@github.com:alessaba/dotfiles.git parent=~/Developer
--
-- Push targets list the current branch's upstream first, then every other
-- remote branch alphabetically.

local terminal = "com.superlogical.terminal"

local function trim(text)
  return (tostring(text):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_slash(path)
  local p = path:gsub("/+$", "")
  if p == "" then return "/" end
  return p
end

local function expand(path)
  if path == "~" or path:sub(1, 2) == "~/" then
    return (os.getenv("HOME") or "~") .. path:sub(2)
  end
  return path
end

local function block_cwd(block_id)
  if block_id == nil then return nil end
  local p = rex.block.call(terminal, "process", { block_id = block_id })
  if p == nil then return nil end
  local process = p.foreground or p.child
  return process and process.cwd or nil
end

local function pane_dir(ctx, arg)
  local dir = arg
  if dir == nil or trim(dir) == "" then
    dir = block_cwd(ctx.block_id)
    if dir == nil then return nil end
  else
    dir = expand(trim(dir))
  end
  return strip_slash(dir)
end

local function run_git(root, ...)
  local argv = { "git" }
  for i = 1, select("#", ...) do
    argv[#argv + 1] = select(i, ...)
  end

  local r, err = rex.exec(argv, { cwd = root })
  if r == nil then return nil, err end
  if not r.ok then
    local detail = trim(r.stderr)
    if detail == "" then detail = trim(r.stdout) end
    if detail == "" then detail = "exit " .. tostring(r.code) end
    return nil, detail
  end
  return r.stdout
end

local function repo_root(ctx, arg)
  local dir = pane_dir(ctx, arg)
  if dir == nil then
    error("git: run this from a pane or pass dir=...", 0)
  end

  local out, err = run_git(dir, "rev-parse", "--show-toplevel")
  if out == nil then error("git: " .. tostring(err), 0) end

  local root = trim(out)
  if root == "" then error("git: not a repository: " .. dir, 0) end
  return root
end

local function current_branch(root)
  local out = run_git(root, "rev-parse", "--abbrev-ref", "HEAD")
  if out == nil then return nil end
  local name = trim(out)
  if name == "" or name == "HEAD" then return nil end
  return name
end

local UNITS = {
  second = "s", seconds = "s",
  minute = "m", minutes = "m",
  hour = "h", hours = "h",
  day = "d", days = "d",
  week = "w", weeks = "w",
  month = "mo", months = "mo",
  year = "y", years = "y",
}

local function short_ago(text)
  text = trim(text)
  if text == "" then return nil end
  local count, unit = text:match("^(%d+) ([%a]+) ago$")
  if count == nil then return text end
  return count .. (UNITS[unit] or unit)
end

local function branch_state(branch)
  if branch.upstream == nil or branch.upstream == "" then return "no upstream" end
  if branch.track == "[gone]" then return "upstream gone" end

  local ahead = branch.track:match("ahead (%d+)")
  local behind = branch.track:match("behind (%d+)")
  if ahead ~= nil and behind ~= nil then
    return ahead .. " ahead, " .. behind .. " behind"
  end
  if ahead ~= nil then return ahead .. " ahead" end
  if behind ~= nil then return behind .. " behind" end
  return branch.upstream
end

local BRANCH_FORMAT =
  "%(refname:short)\t%(upstream:short)\t%(upstream:track)\t%(committerdate:relative)"

local function choose_branch(root)
  local out, err = run_git(root, "for-each-ref",
    "--format=" .. BRANCH_FORMAT, "refs/heads")
  if out == nil then return nil, err end

  local branches = {}
  for line in out:gmatch("[^\n]+") do
    local name, upstream, track, date =
      line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if name ~= nil and name ~= "" then
      branches[#branches + 1] = {
        name = name,
        upstream = upstream,
        track = track,
        date = date,
      }
    end
  end
  if #branches == 0 then return nil, "no local branches" end

  local current = current_branch(root)
  local current_entry = nil
  for _, branch in ipairs(branches) do
    if branch.name == current then current_entry = branch end
  end

  table.sort(branches, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  local ordered = {}
  if current_entry ~= nil then ordered[#ordered + 1] = current_entry end
  for _, branch in ipairs(branches) do
    if branch ~= current_entry then ordered[#ordered + 1] = branch end
  end

  local items = {}
  for _, branch in ipairs(ordered) do
    local subtitle = branch_state(branch)
    if branch == current_entry and branch.upstream ~= "" then
      subtitle = branch.upstream
    end
    items[#items + 1] = {
      id       = branch.name,
      title    = branch.name,
      subtitle = subtitle,
      detail   = short_ago(branch.date),
      icon     = "branch",
    }
  end

  local choice, why = rex.ui.pick{
    title       = "Switch branch",
    placeholder = "Filter branches",
    items       = items,
  }
  if choice == nil then return nil, why end
  return choice
end

local function is_conflict(code)
  local x, y = code:sub(1, 1), code:sub(2, 2)
  return x == "U" or y == "U"
    or (x == "A" and y == "A")
    or (x == "D" and y == "D")
end

local function describe_change(code)
  if code == "??" then return "new" end
  if is_conflict(code) then return "conflict" end

  local x, y = code:sub(1, 1), code:sub(2, 2)
  local label
  if x == "R" then label = "renamed"
  elseif x == "C" then label = "copied"
  elseif x == "A" then label = "added"
  elseif x == "D" or y == "D" then label = "deleted"
  elseif x == "M" or y == "M" then label = "modified"
  elseif x == "T" or y == "T" then label = "type change"
  else label = "changed" end

  if y == " " then label = label .. " (staged)" end
  return label
end

-- Tracked files with worktree changes start selected; untracked files and
-- unresolved conflicts do not.
local function needs_stage(change)
  if change.code == "??" then return false end
  if is_conflict(change.code) then return false end
  return change.code:sub(2, 2) ~= " "
end

local function change_order(change)
  if is_conflict(change.code) then return 3 end
  if change.code == "??" then return 2 end
  if needs_stage(change) then return 0 end
  return 1
end

local function list_changes(root)
  local out, err = run_git(root, "status", "--porcelain=v1", "-z",
    "--untracked-files=all")
  if out == nil then return nil, err end

  local records = {}
  for record in out:gmatch("([^%z]+)") do records[#records + 1] = record end

  local changes = {}
  local i = 1
  while i <= #records do
    local record = records[i]
    local code = record:sub(1, 2)
    local path = record:sub(4)
    local old = nil
    -- In -z output a rename or copy is "XY new\0old\0".
    if code:find("[RC]") and i < #records then
      old = records[i + 1]
      i = i + 1
    end
    if code ~= "!!" then
      changes[#changes + 1] = { code = code, path = path, old = old }
    end
    i = i + 1
  end

  table.sort(changes, function(a, b)
    local oa, ob = change_order(a), change_order(b)
    if oa ~= ob then return oa < ob end
    return a.path:lower() < b.path:lower()
  end)
  return changes
end

local function ask_message(arg)
  local message = arg
  if message == nil or trim(message) == "" then
    local answer, why = rex.ui.input{
      title       = "Commit message",
      placeholder = "Describe the change",
      confirm     = "Commit",
    }
    if answer == nil then
      if why == "cancelled" then return nil end
      error("git_commit: " .. tostring(why), 0)
    end
    message = answer
  end

  message = trim(message or "")
  if message == "" then error("git_commit: empty commit message", 0) end
  return message
end

local function ensure_staged(root)
  local conflicts = run_git(root, "diff", "--name-only", "--diff-filter=U")
  if conflicts ~= nil and trim(conflicts) ~= "" then
    error("git_commit: unresolved conflicts: " .. trim(conflicts), 0)
  end

  local r, err = rex.exec({ "git", "diff", "--cached", "--quiet" }, { cwd = root })
  if r == nil then error("git_commit: " .. tostring(err), 0) end
  if r.code == 0 then
    error("git_commit: nothing staged; use Git: Add Files… first", 0)
  end
  if r.code ~= 1 then
    local detail = trim(r.stderr)
    if detail == "" then detail = trim(r.stdout) end
    if detail == "" then detail = "exit " .. tostring(r.code) end
    error("git_commit: " .. detail, 0)
  end
end

local function do_commit(root, message)
  local _, cerr = run_git(root, "commit", "-m", message)
  if cerr ~= nil then error("git_commit: " .. cerr, 0) end

  local hash = trim(run_git(root, "rev-parse", "--short", "HEAD") or "")
  return { commit = hash, branch = current_branch(root) }
end

local function upstream_of(root, branch)
  local out = run_git(root, "for-each-ref",
    "--format=%(upstream:remotename)\t%(upstream:remoteref)",
    "refs/heads/" .. branch)
  if out == nil then return nil end

  local first = out:match("^([^\n]*)")
  if first == nil then return nil end

  local remote, ref = first:match("^([^\t]*)\t([^\t]*)$")
  if remote == nil or remote == "" or ref == nil or ref == "" then return nil end
  return remote, (ref:gsub("^refs/heads/", ""))
end

local function remote_branches(root)
  local out, err = run_git(root, "for-each-ref", "--format=%(refname)", "refs/remotes")
  if out == nil then return nil, err end

  local remotes_out = run_git(root, "remote")
  local remotes = {}
  for name in (remotes_out or ""):gmatch("[^\n]+") do
    remotes[#remotes + 1] = name
  end
  -- Longest first, so a remote whose name contains a slash still matches.
  table.sort(remotes, function(a, b) return #a > #b end)

  local branches, seen = {}, {}
  for ref in out:gmatch("[^\n]+") do
    for _, remote in ipairs(remotes) do
      local prefix = "refs/remotes/" .. remote .. "/"
      if ref:sub(1, #prefix) == prefix then
        local branch = ref:sub(#prefix + 1)
        local key = remote .. "/" .. branch
        if branch ~= "" and branch ~= "HEAD" and not seen[key] then
          seen[key] = true
          branches[#branches + 1] = {
            remote = remote,
            branch = branch,
            name = key,
          }
        end
        break
      end
    end
  end
  return branches
end

local function push_targets(root)
  local branch = current_branch(root)
  if branch == nil then
    return nil, "detached HEAD; check out a branch first"
  end

  local list, err = remote_branches(root)
  if list == nil then return nil, err end
  if #list == 0 then return nil, "no remote branches; add a remote first" end

  local upstream_remote, upstream_branch = upstream_of(root, branch)
  local ordered, seen = {}, {}
  if upstream_remote ~= nil then
    local key = upstream_remote .. "/" .. upstream_branch
    seen[key] = true
    ordered[#ordered + 1] = {
      remote = upstream_remote,
      branch = upstream_branch,
      name = key,
      upstream = true,
    }
  end

  local rest = {}
  for _, target in ipairs(list) do
    if not seen[target.name] then rest[#rest + 1] = target end
  end
  table.sort(rest, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  for _, target in ipairs(rest) do ordered[#ordered + 1] = target end

  return ordered
end

local function choose_push_target(root)
  local targets, err = push_targets(root)
  if targets == nil then return nil, err end

  local items = {}
  for i, target in ipairs(targets) do
    items[#items + 1] = {
      id       = tostring(i),
      title    = target.branch,
      subtitle = target.remote,
      detail   = target.upstream and "upstream" or nil,
      icon     = "branch",
    }
  end

  local choice, why = rex.ui.pick{
    title       = "Push to branch",
    placeholder = "Filter remote branches",
    items       = items,
  }
  if choice == nil then return nil, why end
  return targets[tonumber(choice)]
end

local function push(root, target)
  local argv = { "git", "push" }
  local current = current_branch(root)
  if not target.upstream and current ~= nil and target.branch == current then
    argv[#argv + 1] = "-u"
  end
  argv[#argv + 1] = target.remote
  argv[#argv + 1] = "HEAD:" .. target.branch

  local r, err = rex.exec(argv, { cwd = root })
  if r == nil then error("git_push: " .. tostring(err), 0) end
  if not r.ok then
    local detail = trim(r.stderr)
    if detail == "" then detail = trim(r.stdout) end
    if detail == "" then detail = "exit " .. tostring(r.code) end
    error("git_push: " .. detail, 0)
  end
  return { remote = target.remote, branch = target.branch }
end

local function commit_flow(ctx, args, push_after)
  local root = repo_root(ctx, args.dir)
  ensure_staged(root)

  local message = ask_message(args.message)
  if message == nil then return nil end

  local info = do_commit(root, message)
  if not push_after then return info end

  local target, why = choose_push_target(root)
  if target == nil then
    if why == "cancelled" then
      return { commit = info.commit, branch = info.branch, pushed = false }
    end
    error("git_commit_push: " .. tostring(why), 0)
  end

  info.pushed = push(root, target)
  return info
end

rex.action{
  name        = "git_switch_branch",
  title       = "Git: Switch Branch…",
  description = "Pick a local branch and switch to it. The current branch is first.",
  category    = "Git",
  keywords    = "git branch checkout switch",
  args        = { dir = "string?" },
  run         = function(ctx, args)
    local root = repo_root(ctx, args.dir)
    local choice, why = choose_branch(root)
    if choice == nil then
      if why == "cancelled" then return end
      error("git_switch_branch: " .. tostring(why), 0)
    end

    if choice == current_branch(root) then
      return { branch = choice, changed = false }
    end

    local _, err = run_git(root, "switch", choice)
    if err ~= nil then error("git_switch_branch: " .. err, 0) end
    return { branch = choice, changed = true }
  end,
}

rex.action{
  name        = "git_add",
  title       = "Git: Add Files…",
  description = "Pick changed and untracked files to stage. Changed files start selected.",
  category    = "Git",
  keywords    = "git add stage files untracked",
  args        = { dir = "string?" },
  run         = function(ctx, args)
    local root = repo_root(ctx, args.dir)
    local changes, err = list_changes(root)
    if changes == nil then error("git_add: " .. tostring(err), 0) end
    if #changes == 0 then error("git_add: no changes to stage", 0) end
    if #changes > 2000 then
      error("git_add: more than 2000 changes; ignore some files first", 0)
    end

    local items = {}
    for _, change in ipairs(changes) do
      items[#items + 1] = {
        id       = change.path,
        title    = change.path,
        subtitle = change.old and ("from " .. change.old) or nil,
        detail   = describe_change(change.code),
        selected = needs_stage(change),
        icon     = change.code == "??" and "plus" or "document",
      }
    end

    local choices, why = rex.ui.pick{
      title       = "Add files",
      placeholder = "Filter changed files",
      multiple    = true,
      confirm     = "Stage",
      items       = items,
    }
    if choices == nil then
      if why == "cancelled" then return end
      error("git_add: " .. tostring(why), 0)
    end
    if #choices == 0 then return { staged = 0 } end

    local by_path = {}
    for _, change in ipairs(changes) do by_path[change.path] = change end

    local argv = { "git", "--literal-pathspecs", "add", "-A", "--" }
    local staged = {}
    for _, path in ipairs(choices) do
      local change = by_path[path]
      if change ~= nil then
        argv[#argv + 1] = change.path
        staged[#staged + 1] = change.path
      end
    end
    if #staged == 0 then return { staged = 0 } end

    local r, gerr = rex.exec(argv, { cwd = root })
    if r == nil then error("git_add: " .. tostring(gerr), 0) end
    if not r.ok then
      local detail = trim(r.stderr)
      if detail == "" then detail = trim(r.stdout) end
      if detail == "" then detail = "exit " .. tostring(r.code) end
      error("git_add: " .. detail, 0)
    end

    return { staged = #staged, files = staged }
  end,
}

rex.action{
  name        = "git_commit",
  title       = "Git: Commit…",
  description = "Commit the staged changes with a typed message.",
  category    = "Git",
  keywords    = "git commit save message",
  args        = { dir = "string?", message = "string?" },
  run         = function(ctx, args)
    return commit_flow(ctx, args, false)
  end,
}

rex.action{
  name        = "git_commit_push",
  title       = "Git: Commit and Push…",
  description = "Commit the staged changes, then pick a remote branch to push to.",
  category    = "Git",
  keywords    = "git commit push upload",
  args        = { dir = "string?", message = "string?" },
  run         = function(ctx, args)
    return commit_flow(ctx, args, true)
  end,
}

rex.action{
  name        = "git_push",
  title       = "Git: Push…",
  description = "Pick a remote branch and push HEAD to it.",
  category    = "Git",
  keywords    = "git push upload remote",
  args        = { dir = "string?" },
  run         = function(ctx, args)
    local root = repo_root(ctx, args.dir)
    local target, why = choose_push_target(root)
    if target == nil then
      if why == "cancelled" then return end
      error("git_push: " .. tostring(why), 0)
    end
    return push(root, target)
  end,
}

rex.action{
  name        = "git_pull",
  title       = "Git: Pull",
  description = "Fast-forward the current branch from its upstream.",
  category    = "Git",
  keywords    = "git pull fetch update",
  args        = { dir = "string?" },
  run         = function(ctx, args)
    local root = repo_root(ctx, args.dir)
    local _, err = run_git(root, "pull", "--ff-only")
    if err ~= nil then error("git_pull: " .. err, 0) end
    return { branch = current_branch(root) }
  end,
}

rex.action{
  name        = "git_new_branch",
  title       = "Git: New Branch…",
  description = "Create a branch from HEAD and switch to it.",
  category    = "Git",
  keywords    = "git branch create new",
  args        = { dir = "string?", name = "string?" },
  run         = function(ctx, args)
    local root = repo_root(ctx, args.dir)

    local name = args.name
    if name == nil or trim(name) == "" then
      local answer, why = rex.ui.input{
        title       = "New branch",
        placeholder = "feature/…",
        confirm     = "Create branch",
      }
      if answer == nil then
        if why == "cancelled" then return end
        error("git_new_branch: " .. tostring(why), 0)
      end
      name = answer
    end

    name = trim(name)
    if name == "" then error("git_new_branch: empty branch name", 0) end

    local _, err = run_git(root, "switch", "-c", name)
    if err ~= nil then error("git_new_branch: " .. err, 0) end
    return { branch = name }
  end,
}

local function clone_name(url)
  local base = url:gsub("/+$", ""):match("([^/:]+)$") or ""
  base = base:gsub("%.git$", "")
  if base == "" or base == "." or base == ".." or base:find("[/\\]") then
    error("git_clone: cannot derive a folder name from " .. url, 0)
  end
  return base
end

local function clone_parent(ctx, arg)
  if arg == nil or trim(arg) == "" then
    return pane_dir(ctx, nil) or (os.getenv("HOME") or ".")
  end

  local path = expand(trim(arg))
  if path:sub(1, 1) ~= "/" then
    local base = pane_dir(ctx, nil)
    if base == nil then
      error("git_clone: pass an absolute parent or run this from a pane", 0)
    end
    path = base .. "/" .. path
  end
  return strip_slash(path)
end

rex.action{
  name        = "git_clone",
  title       = "Git: Clone…",
  description = "Clone a repository recursively and open it in a new split.",
  category    = "Git",
  keywords    = "git clone recursive download",
  args        = { url = "string?", parent = "string?", name = "string?" },
  run         = function(ctx, args)
    local url = args.url
    if url == nil or trim(url) == "" then
      local answer, why = rex.ui.input{
        title       = "Clone repository",
        placeholder = "git@github.com:owner/repo.git",
        confirm     = "Clone",
      }
      if answer == nil then
        if why == "cancelled" then return end
        error("git_clone: " .. tostring(why), 0)
      end
      url = answer
    end

    url = trim(url)
    if url == "" then error("git_clone: empty URL", 0) end

    local parent = clone_parent(ctx, args.parent)
    local r = rex.exec({ "test", "-d", parent })
    if r == nil or not r.ok then
      error("git_clone: parent folder not found: " .. parent, 0)
    end

    local name = args.name
    if name == nil or trim(name) == "" then
      name = clone_name(url)
    else
      name = trim(name)
      if name == "" or name:find("[/\\]") then
        error("git_clone: invalid folder name: " .. name, 0)
      end
    end

    local target = parent == "/" and ("/" .. name) or (parent .. "/" .. name)
    local exists = rex.exec({ "test", "-e", target })
    if exists ~= nil and exists.ok then
      error("git_clone: " .. target .. " already exists", 0)
    end

    local clone, cerr = rex.exec({
      "env", "GIT_TERMINAL_PROMPT=0",
      "git", "clone", "--recursive", "--", url, target,
    }, { cwd = parent, timeout = 600 })
    if clone == nil then error("git_clone: " .. tostring(cerr), 0) end
    if not clone.ok then
      local detail = trim(clone.stderr)
      if detail == "" then detail = trim(clone.stdout) end
      if detail == "" then detail = "exit " .. tostring(clone.code) end
      error("git_clone: " .. detail, 0)
    end

    local opened = false
    local _, serr = rex.session.new_split{
      direction = "horizontal",
      side      = "after",
      focus     = true,
      layout    = rex.layout.block{
        flavor  = "com.superlogical.terminal.shell",
        options = { cwd = target },
      },
    }
    if serr ~= nil then
      rex.log("warn", "git_clone: " .. tostring(serr))
    else
      opened = true
    end

    return { path = target, opened = opened }
  end,
}
