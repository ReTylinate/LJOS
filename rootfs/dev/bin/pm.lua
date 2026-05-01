#!/usr/bin/env luajit
-- ljpm standalone entry point for LJOS
-- Located at /dev/bin/pm.lua
-- Can be run directly: luajit /dev/bin/pm.lua install <pkg>
-- Or via the pm alias registered in the LJOS shell.

-- /dev/ = OS system files.  /packages/ = user-installed packages.
package.path = "/dev/?.lua;/dev/?/init.lua;/packages/?.lua;/packages/?/init.lua;" .. package.path

local pm = require("system.pm")
pm.main(arg)
