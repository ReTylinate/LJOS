package.path = "/lua/?.lua;/lua/?/init.lua;" .. package.path

local core = require("system.core")

print("[LuaOS] booting")

core.shell()
