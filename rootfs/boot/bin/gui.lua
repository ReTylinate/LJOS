#!/bin/luajit
-- LJOS GUI Demo
-- Lives at /boot/bin/gui.lua

package.path = "/boot/?.lua;/boot/?/init.lua;/packages/?.lua;/packages/?/init.lua;" .. package.path

local wm = require("system.wm")

local ok, err = wm.init()
if not ok then
    print("Error initializing window system: " .. tostring(err))
    return
end

local win, werr = wm.create_window("LJOS Desktop", 100, 100, 800, 600)
if not win then
    print("Error creating window: " .. tostring(werr))
    wm.cleanup()
    return
end

win.background = {40, 44, 52} -- Modern dark gray

-- Add some "aesthetic" placeholder elements
table.insert(win.elements, {type="rect", x=10, y=10, w=100, h=30, r=97, g=175, b=239}) -- Blue button-like
table.insert(win.elements, {type="rect", x=120, y=10, w=100, h=30, r=152, g=195, b=121}) -- Green button-like
table.insert(win.elements, {type="rect", x=230, y=10, w=100, h=30, r=224, g=108, b=117}) -- Red button-like

print("GUI running... Close window to exit.")

while wm.running do
    wm.poll()
    wm.update()
    require("system.sdlua").delay(16) -- ~60 FPS
end

wm.cleanup()
print("GUI closed.")
