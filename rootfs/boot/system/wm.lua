-- Window System for LJOS using SDLua
-- Lives at /boot/system/wm.lua

local sdl = require("system.sdlua")

local wm = {}

wm.windows = {}
wm.running = false

function wm.init()
    local ok, err = sdl.init()
    if not ok then return false, err end
    wm.running = true
    return true
end

function wm.create_window(title, x, y, w, h)
    local win = sdl.create_window(title, x, y, w, h)
    if not win then return nil, "Could not create SDLua window" end
    
    local window_obj = {
        handle = win,
        renderer = win.renderer,
        title = title,
        x = x, y = y, w = w, h = h,
        background = {0, 0, 0},
        elements = {}
    }
    
    table.insert(wm.windows, window_obj)
    return window_obj
end

function wm.poll()
    local event = {}
    if sdl.poll_event(event) ~= 0 then
        if event.type == sdl.QUIT then
            wm.running = false
        end
    end
end

function wm.update()
    for _, win in ipairs(wm.windows) do
        sdl.set_render_draw_color(win.renderer, win.background[1], win.background[2], win.background[3], 255)
        sdl.render_clear(win.renderer)
        
        for _, el in ipairs(win.elements) do
            if el.type == "rect" then
                sdl.set_render_draw_color(win.renderer, el.r, el.g, el.b, 255)
                sdl.render_fill_rect(win.renderer, el)
            end
        end
        
        sdl.render_present(win.renderer)
    end
end

function wm.cleanup()
    sdl.cleanup()
end

return wm
