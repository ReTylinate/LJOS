#!/usr/bin/env luajit
-- ljpm standalone entry point for LJOS
-- Located at /lua/bin/pm.lua
-- Can be run directly: luajit /lua/bin/pm.lua install <pkg>
-- Or via the pm alias registered in the LJOS shell.

-- Ensure LJOS module paths are set
package.path = "/lua/?.lua;/lua/?/init.lua;" .. package.path

local pm = require("system.pm")
pm.main(arg)
