-- SDLua: A pure LuaJIT replacement for SDL2
-- Interacts with Linux Framebuffer (/dev/fb0)
-- Lives at /boot/system/sdlua.lua

local ffi = require("ffi")
local sys = require("system.syscall")

ffi.cdef[[
    struct fb_bitfield {
        uint32_t offset;
        uint32_t length;
        uint32_t msb_right;
    };

    struct fb_var_screeninfo {
        uint32_t xres;
        uint32_t yres;
        uint32_t xres_virtual;
        uint32_t yres_virtual;
        uint32_t xoffset;
        uint32_t yoffset;
        uint32_t bits_per_pixel;
        uint32_t grayscale;
        struct fb_bitfield red;
        struct fb_bitfield green;
        struct fb_bitfield blue;
        struct fb_bitfield transp;
        uint32_t nonstd;
        uint32_t activate;
        uint32_t height;
        uint32_t width;
        uint32_t accel_flags;
        uint32_t pixclock;
        uint32_t left_margin;
        uint32_t right_margin;
        uint32_t upper_margin;
        uint32_t lower_margin;
        uint32_t hsync_len;
        uint32_t vsync_len;
        uint32_t sync;
        uint32_t vmode;
        uint32_t rotate;
        uint32_t colorspace;
        uint32_t reserved[4];
    };

    struct fb_fix_screeninfo {
        char id[16];
        unsigned long smem_start;
        uint32_t smem_len;
        uint32_t type;
        uint32_t type_aux;
        uint32_t visual;
        uint16_t xpanstep;
        uint16_t ypanstep;
        uint16_t ywrapstep;
        uint32_t line_length;
        unsigned long mmio_start;
        uint32_t mmio_len;
        uint32_t accel;
        uint16_t capabilities;
        uint16_t reserved[2];
    };
]]

local FBIOGET_VSCREENINFO = 0x4600
local FBIOGET_FSCREENINFO = 0x4602

local sdlua = {}

sdlua.QUIT = 0x100

local ctx = {
    fd = -1,
    fb = nil,
    vinfo = nil,
    finfo = nil,
    screensize = 0
}

function sdlua.init()
    ctx.fd = sys.open("/dev/fb0", 2) -- O_RDWR
    if not ctx.fd then 
        return false, "Cannot open /dev/fb0 (errno: " .. tostring(sys.errno()) .. ")"
    end

    ctx.vinfo = ffi.new("struct fb_var_screeninfo")
    if sys.ioctl(ctx.fd, FBIOGET_VSCREENINFO, ctx.vinfo) < 0 then
        sys.close(ctx.fd)
        return false, "Cannot get vscreeninfo"
    end

    ctx.finfo = ffi.new("struct fb_fix_screeninfo")
    if sys.ioctl(ctx.fd, FBIOGET_FSCREENINFO, ctx.finfo) < 0 then
        sys.close(ctx.fd)
        return false, "Cannot get fscreeninfo"
    end

    ctx.screensize = ctx.vinfo.xres * ctx.vinfo.yres * (ctx.vinfo.bits_per_pixel / 8)
    ctx.fb = sys.mmap(nil, ctx.screensize, sys.PROT_READ + sys.PROT_WRITE, sys.MAP_SHARED, ctx.fd, 0)
    if not ctx.fb then
        sys.close(ctx.fd)
        return false, "Cannot mmap framebuffer"
    end

    return true
end

function sdlua.create_window(title, x, y, w, h)
    -- In a framebuffer world, windows are just regions of memory.
    -- For now, let's just return an object that represents a drawing context.
    return {
        title = title,
        x = x, y = y, w = w, h = h,
        renderer = {ctx = ctx} -- Mock renderer
    }
end

function sdlua.set_render_draw_color(renderer, r, g, b, a)
    renderer.color = {r=r, g=g, b=b, a=a}
end

function sdlua.render_clear(renderer)
    local c = renderer.color
    local pixel = bit.lshift(c.r, 16) + bit.lshift(c.g, 8) + c.b
    local fb_ptr = ffi.cast("uint32_t*", renderer.ctx.fb)
    for i = 0, (renderer.ctx.vinfo.xres * renderer.ctx.vinfo.yres) - 1 do
        fb_ptr[i] = pixel
    end
end

function sdlua.render_fill_rect(renderer, rect)
    local c = renderer.color
    local pixel = bit.lshift(c.r, 16) + bit.lshift(c.g, 8) + c.b
    local fb_ptr = ffi.cast("uint32_t*", renderer.ctx.fb)
    local stride = renderer.ctx.vinfo.xres
    
    for y = rect.y, rect.y + rect.h - 1 do
        if y >= 0 and y < renderer.ctx.vinfo.yres then
            for x = rect.x, rect.x + rect.w - 1 do
                if x >= 0 and x < renderer.ctx.vinfo.xres then
                    fb_ptr[y * stride + x] = pixel
                end
            end
        end
    end
end

function sdlua.render_present(renderer)
    -- Framebuffer is immediate, but we could implement double buffering here
end

function sdlua.poll_event(event)
    -- Mocking poll event for now. In real life we'd read from /dev/input/event*
    return 0
end

function sdlua.cleanup()
    if ctx.fb then sys.munmap(ctx.fb, ctx.screensize) end
    if ctx.fd ~= -1 then sys.close(ctx.fd) end
end

function sdlua.delay(ms)
    -- Simple busy wait or use a better sleep
    local start = os.clock()
    while os.clock() - start < ms/1000 do end
end

return sdlua
