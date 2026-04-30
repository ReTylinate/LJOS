local core = {}

-- =========================
-- STATE
-- =========================
local cwd = "/"

-- =========================
-- LOGGING
-- =========================
function core.log(msg)
    print("[LuaOS] " .. tostring(msg))
end

-- =========================
-- PATH HELPERS
-- =========================
local function resolve(path)
    if not path or path == "" then
        return cwd
    end

    if path:sub(1,1) == "/" then
        return path
    end

    if cwd == "/" then
        return "/" .. path
    end

    return cwd .. "/" .. path
end
-- =========================
-- FILE OPS (via io, simplest possible)
-- =========================
function core.cat(path)
    path = resolve(path)
    local f = io.open(path, "r")
    if not f then
        core.log("file not found: " .. path)
        return
    end
    print(f:read("*a"))
    f:close()
end

function core.write(path, data)
    path = resolve(path)
    local f = io.open(path, "w")
    if not f then
        core.log("cannot write: " .. path)
        return
    end
    f:write(data or "")
    f:close()
end

function core.touch(path)
    path = resolve(path)
    local f = io.open(path, "a")
    if f then f:close() end
end

-- =========================
-- DIRECTORY OPS (limited)
-- =========================
function core.mkdir(path)
    path = resolve(path)
    os.execute("mkdir -p " .. path)
end

function core.rm(path)
    path = resolve(path)
    os.execute("rm -rf " .. path)
end

function core.ls(path)
    path = resolve(path or cwd)
    os.execute("ls " .. path)
end

-- =========================
-- NAVIGATION
-- =========================
function core.cd(path)
    path = resolve(path)
    cwd = path
end

function core.pwd()
    print(cwd)
end

-- =========================
-- SHELL
-- =========================
function core.shell()
    core.log("LuaOS shell started")

    while true do
        io.write(cwd .. " $ ")
        local input = io.read()

        if not input then break end

        local args = {}
        for word in input:gmatch("%S+") do
            table.insert(args, word)
        end

        local cmd = args[1]

        if cmd == "cd" then
            core.cd(args[2] or "/")

        elseif cmd == "ls" then
            core.ls(args[2])

        elseif cmd == "pwd" then
            core.pwd()

        elseif cmd == "cat" then
            core.cat(args[2])

        elseif cmd == "mkdir" then
            core.mkdir(args[2])

        elseif cmd == "touch" then
            core.touch(args[2])

        elseif cmd == "rm" then
            core.rm(args[2])

        elseif cmd == "echo" then
            print(table.concat(args, " ", 2))

        elseif cmd == "write" then
            core.write(args[2], table.concat(args, " ", 3))

        elseif cmd == "exit" then
            break

        else
            print("unknown command: " .. tostring(cmd))
        end
    end
end

return core
