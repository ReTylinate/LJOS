#!/bin/luajit
-- dispatcher for LuaBox (replaces sh)

-- Make sure we can find system modules
package.path = "/boot/?.lua;/boot/?/init.lua;/packages/?.lua;/packages/?/init.lua;" .. package.path

local ffi = require("ffi")
local sys = require("system.syscall")

local function clean(s)
    if type(s) ~= "string" then return s end
    return s:gsub("[%z\1-\31]", ""):match("^%s*(.-)%s*$")
end

local arg0 = clean(arg[0]):match("([^/]+)$") or "sh"

-- Clean all arguments
for i=1, #arg do arg[i] = clean(arg[i]) end

if arg0 == "sh" then
    require("system.sh").main(arg)
elseif arg0 == "ls" then
    -- Simply forward to busybox ls for now to support flags like -l
    os.execute("/bin/busybox ls " .. table.concat(arg, " "))
elseif arg0 == "cat" then
    if #arg == 0 then
        for line in io.lines() do print(line) end
    else
        for i = 1, #arg do
            local f = io.open(arg[i], "r")
            if f then io.write(f:read("*a")); f:close()
            else print("cat: " .. arg[i] .. ": No such file or directory") end
        end
    end
elseif arg0 == "mkdir" then
    local ok, err = sys.mkdir(arg[1] or "", 493) -- 0755
    if not ok then print("mkdir failed: "..(err or "no path")); os.exit(1) end
elseif arg0 == "touch" then
    for i = 1, #arg do
        local f = io.open(arg[i], "a")
        if f then f:close() else print("touch: cannot touch " .. arg[i]) end
    end
elseif arg0 == "tee" then
    local files = {}
    for i = 1, #arg do
        local f = io.open(arg[i], "w")
        if f then table.insert(files, f) end
    end
    for line in io.lines() do
        print(line)
        for _, f in ipairs(files) do
            f:write(line .. "\n")
            f:flush()
        end
    end
    for _, f in ipairs(files) do f:close() end
elseif arg0 == "mount" then
    local ok, err = sys.mount(arg[1] or "", arg[2] or "", arg[3] or "", 0, nil)
    if not ok then print("mount failed: "..tostring(err)); os.exit(1) end
elseif arg0 == "poweroff" then
    os.execute("/bin/busybox poweroff -f")
elseif arg0 == "reboot" then
    os.execute("/bin/busybox reboot -f")
else
    -- Fallback
    local cmd = "/bin/busybox " .. arg0 .. " " .. table.concat(arg, " ")
    os.execute(cmd)
end
