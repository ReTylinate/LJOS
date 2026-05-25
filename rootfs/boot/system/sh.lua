-- Pure LuaJIT shell for LJOS
-- Lives at /boot/system/sh.lua

local sys = require("system.syscall")
local ffi = require("ffi")

local sh = {}

-- Constants
local SIGINT = 2
local SIG_IGN = ffi.cast("sighandler_t", 1)
local SIG_DFL = ffi.cast("sighandler_t", 0)

-- Reboot magic
local REBOOT_MAGIC1 = 0xfee1dead
local REBOOT_MAGIC2 = 672274793
local LINUX_REBOOT_CMD_RESTART  = 0x01234567
local LINUX_REBOOT_CMD_POWER_OFF = 0x4321fedc

local function clean(s)
    if type(s) ~= "string" then return s end
    -- Remove all non-printable characters and control codes
    return s:gsub("[%z\1-\31\127-\255]", ""):match("^%s*(.-)%s*$")
end

function sh.main(raw_args)
    -- Set LUA_PATH for the current process and children
    local path = "/boot/?.lua;/boot/?/init.lua;/packages/?.lua;/packages/?/init.lua;"
    ffi.C.setenv("LUA_PATH", path .. ";", 1)
    
    -- Shell should ignore SIGINT so it doesn't exit on Ctrl+C
    ffi.C.signal(SIGINT, SIG_IGN)

    if raw_args and raw_args[1] == "-c" then
        sh.execute_line(clean(raw_args[2]))
        return
    end

    print("LuaBox sh v0.4")
    while true do
        local cwd = sys.getcwd() or "?"
        io.write(cwd .. " # ")
        io.flush()
        
        local line = io.read()
        if not line then 
            print("") 
            break 
        end
        
        line = clean(line)
        if line ~= "" then
            print("DEBUG: Executing line: '" .. line .. "'")
            local ok, err = pcall(sh.execute_line, line)
            if not ok then print("Shell error: " .. tostring(err)) end
        end
    end
end

function sh.execute_line(line)
    -- Pipeline parsing
    local stages = {}
    for stage in line:gmatch("[^|]+") do
        local words = {}
        for w in stage:gmatch("%S+") do 
            local clean_w = clean(w)
            if clean_w ~= "" then words[#words+1] = clean_w end
        end
        if #words > 0 then table.insert(stages, words) end
    end
    
    if #stages == 0 then return end
    if #stages == 1 then
        sh.run_command(stages[1])
    else
        sh.run_pipeline(stages)
    end
end

local BUILTINS = {
    cd = function(words)
        local target = words[2] or "/root"
        local ok, err = sys.chdir(target)
        if not ok then print("cd: " .. err) end
    end,
    echo = function(words)
        local parts = {}
        for i = 2, #words do parts[#parts+1] = words[i] end
        print(table.concat(parts, " "))
    end,
    pwd = function(words)
        print(sys.getcwd() or "?")
    end,
    clear = function(words)
        io.write("\27[2J\27[H")
        io.flush()
    end,
    export = function(words)
        if not words[2] then return end
        local k, v = words[2]:match("^([^=]+)=(.*)$")
        if k then ffi.C.setenv(k, v or "", 1) end
    end,
    reboot = function(words)
        print("Rebooting...")
        sys.reboot(REBOOT_MAGIC1, REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART, nil)
    end,
    poweroff = function(words)
        print("Powering off...")
        local ok, err = sys.reboot(REBOOT_MAGIC1, REBOOT_MAGIC2, LINUX_REBOOT_CMD_POWER_OFF, nil)
        if not ok then print("Poweroff failed: " .. tostring(err)) end
    end,
    exit = function(words)
        if sys.getpid() == 1 then
            print("You are running as init (PID 1). Exit would panic the kernel.")
            print("Use 'poweroff' or 'reboot' instead.")
        else
            os.exit(0)
        end
    end,
    debug = function(words)
        print("DEBUG: ARGS (" .. #words .. ")")
        for i, w in ipairs(words) do
            print("  ["..i.."] = '"..w.."' (len="..#w..")")
            for j = 1, #w do
                io.write(string.format("%02X ", w:byte(j)))
            end
            io.write("\n")
        end
    end,
    help = function(words)
        print([[
LuaBox Shell Commands:
  cd <dir>          Change directory
  pwd               Print working directory
  ls [dir]          List files
  cat [file]        Show file content
  touch <file>      Create empty file
  tee <file>        Write stdin to stdout and file
  echo <text>       Print text
  clear             Clear the screen
  export K=V        Set environment variable
  pm <cmd>          Package manager
  reboot            Restart the system
  poweroff          Shutdown the system
  exit              Exit the shell (not allowed for PID 1)
  debug <cmd>       Show hex bytes of command arguments

Note: Use Ctrl+D (EOF) to exit cat or the shell.
      Use Ctrl+C to interrupt a running process.
]])
    end
}

function sh.run_command(words)
    local cmd = words[1]
    if BUILTINS[cmd] then
        BUILTINS[cmd](words)
        return
    end

    -- External commands
    local pid, err = sys.fork()
    if pid == nil then
        print("fork failed: " .. err)
    elseif pid == 0 then
        -- Child: Restore default SIGINT handling
        ffi.C.signal(SIGINT, SIG_DFL)
        sys.execvp(cmd, words)
        -- If execvp returns, it failed
        print(cmd .. ": command not found")
        os.exit(1)
    else
        -- Parent
        local status = ffi.new("int[1]")
        sys.waitpid(pid, status, 0)
    end
end

function sh.run_pipeline(stages)
    local prev_pipe_rd = nil
    local pids = {}

    for i, words in ipairs(stages) do
        local fds = ffi.new("int[2]")
        local has_next = (i < #stages)
        if has_next then
            if sys.pipe(fds) == nil then
                print("pipe failed")
                return
            end
        end

        local pid = sys.fork()
        if pid == 0 then
            -- Child: Restore default SIGINT handling
            ffi.C.signal(SIGINT, SIG_DFL)
            
            if prev_pipe_rd then
                sys.dup2(prev_pipe_rd, 0)
                sys.close(prev_pipe_rd)
            end
            if has_next then
                sys.close(fds[0])
                sys.dup2(fds[1], 1)
                sys.close(fds[1])
            end
            
            if BUILTINS[words[1]] then
                BUILTINS[words[1]](words)
                os.exit(0)
            else
                sys.execvp(words[1], words)
                os.exit(1)
            end
        else
            -- Parent
            if prev_pipe_rd then sys.close(prev_pipe_rd) end
            if has_next then
                sys.close(fds[1])
                prev_pipe_rd = fds[0]
            end
            table.insert(pids, pid)
        end
    end

    for _, pid in ipairs(pids) do
        sys.waitpid(pid, nil, 0)
    end
end

return sh
