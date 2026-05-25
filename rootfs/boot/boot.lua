package.path = "/boot/?.lua;/boot/?/init.lua;/packages/?.lua;/packages/?/init.lua;" .. package.path

local core = require("system.core")

print("[LuaOS] booting")
print("[LuaOS] ljpm package manager available — type 'pm help'")

local _pm_loaded = false
local function get_pm()
  if not _pm_loaded then
    local ok, pm = pcall(require, "system.pm")
    if not ok then
      print("[pm] Error loading package manager: " .. tostring(pm))
      return nil
    end
    _pm_loaded = pm
  end
  return _pm_loaded
end

local function extended_shell()
  print("[LuaOS] shell ready")

  local cwd = "/"

  local function resolve(path)
    if not path or path == "" then return cwd end
    if path:sub(1,1) == "/" then return path end
    if cwd == "/" then return "/" .. path end
    return cwd .. "/" .. path
  end

  while true do
    io.write(cwd .. " $ ")
    io.flush()
    local input = io.read()
    if not input then break end

    local words = {}
    for w in input:gmatch("%S+") do words[#words+1] = w end
    local cmd = words[1]

    if not cmd then
      -- Skip empty input
    elseif cmd == "pm" or cmd == "ljpm" then
      local pm = get_pm()
      if pm then
        local sub = {}
        for i = 2, #words do sub[#sub+1] = words[i] end
        local ok, err = pcall(pm.main, sub)
        if not ok then print("[pm] Runtime error: " .. tostring(err)) end
      end

    elseif cmd == "cd" then
      local target = resolve(words[2] or "/")
      if core.cd(target) then
        cwd = target
      end

    elseif cmd == "ls"    then core.ls(resolve(words[2]))
    elseif cmd == "pwd"   then print(cwd)
    elseif cmd == "cat"   then core.cat(resolve(words[2]))
    elseif cmd == "mkdir" then core.mkdir(resolve(words[2]))
    elseif cmd == "touch" then core.touch(resolve(words[2]))
    elseif cmd == "rm"    then core.rm(resolve(words[2]))
    elseif cmd == "echo"  then
      local parts = {}
      for i = 2, #words do parts[#parts+1] = words[i] end
      print(table.concat(parts, " "))
    elseif cmd == "write" then
      local parts = {}
      for i = 3, #words do parts[#parts+1] = words[i] end
      core.write(resolve(words[2]), table.concat(parts, " "))

    elseif cmd == "luajit" or cmd == "lua" then
      if words[2] then
        local path = resolve(words[2])
        local exec_args = {}
        for i = 3, #words do exec_args[#exec_args+1] = words[i] end
        local cmd_str = "luajit " .. path
        if #exec_args > 0 then
          cmd_str = cmd_str .. " " .. table.concat(exec_args, " ")
        end
        os.execute(cmd_str)
      else
        print("Usage: luajit <script.lua>")
      end

    elseif cmd == "exit" or cmd == "quit" then
      print("[LuaOS] shutting down")
      break

    elseif cmd == "help" then
      io.write([[
LJOS Shell Commands:
  cd <dir>          Change directory
  ls [dir]          List directory contents
  pwd               Print working directory
  cat <file>        Display file contents
  mkdir <dir>       Create directory
  touch <file>      Create empty file
  rm <path>         Remove file/directory
  echo <text>       Print text
  write <file> ...  Write text to file
  luajit <file>     Execute a Lua script
  pm <cmd>          Package manager (pm help for usage)
  exit              Exit the shell
]])

    else
      local bin_path = "/boot/bin/" .. cmd .. ".lua"
      local f = io.open(bin_path, "r")
      if f then
        f:close()
        local exec_parts = {"luajit", bin_path}
        for i = 2, #words do exec_parts[#exec_parts+1] = words[i] end
        os.execute(table.concat(exec_parts, " "))
      else
        print("unknown command: " .. cmd .. " (try 'help')")
      end
    end
  end
end

extended_shell()
