local function list_containers()
     local names = {}
     local cmd = "/usr/local/bin/docker ps --format '{{.Names}}'"
     local r, err = rex.exec({ "sh", "-c", cmd })
     if r == nil then return nil, err end
     if not r.ok then return nil, r.stderr end

     for line in r.stdout:gmatch("[^\n]+") do
       names[#names + 1] = { id = line, title = line, icon = "package" }      
     end
    
     return names
end

rex.action{
  name  = "docker_shell",
  title = "Docker: Open Shell…",
  run   = function(ctx, args)
    local containers, err = list_containers()
    local choice, why = rex.ui.pick{
      title       = "Container",
      placeholder = "Filter",
      items = containers,
    }
    if choice == nil then return end
    
    rex.session.new_layer{
      bounds = { x = 0.08, y = 0.08, w = 0.75, h = 0.75 },
      focus = true, 
      layout = rex.layout.block{
        flavor  = "com.superlogical.terminal.shell",
        options = { command = {"/usr/local/bin/orbctl", "debug", choice} }, -- if you have OrbStack
--      options = { command = {"/usr/local/bin/docker", "exec", "-it", choice, "/bin/sh"} },
      },
    }
  end,
}

rex.bind("cmd+alt+n", "docker_shell")
