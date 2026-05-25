-- SDL2 FFI bindings for LJOS
-- Lives at /boot/system/sdl2.lua

local ffi = require("ffi")

ffi.cdef[[
    typedef struct SDL_Window SDL_Window;
    typedef struct SDL_Renderer SDL_Renderer;
    typedef struct SDL_Texture SDL_Texture;

    typedef struct SDL_Rect {
        int x, y;
        int w, h;
    } SDL_Rect;

    typedef struct SDL_Color {
        uint8_t r, g, b, a;
    } SDL_Color;

    typedef union SDL_Event {
        uint32_t type;
        uint8_t padding[56];
    } SDL_Event;

    int SDL_Init(uint32_t flags);
    SDL_Window* SDL_CreateWindow(const char* title, int x, int y, int w, int h, uint32_t flags);
    SDL_Renderer* SDL_CreateRenderer(SDL_Window* window, int index, uint32_t flags);
    
    int SDL_SetRenderDrawColor(SDL_Renderer* renderer, uint8_t r, uint8_t g, uint8_t b, uint8_t a);
    int SDL_RenderClear(SDL_Renderer* renderer);
    void SDL_RenderPresent(SDL_Renderer* renderer);
    int SDL_RenderFillRect(SDL_Renderer* renderer, const SDL_Rect* rect);
    int SDL_RenderDrawRect(SDL_Renderer* renderer, const SDL_Rect* rect);
    
    int SDL_PollEvent(SDL_Event* event);
    void SDL_Quit(void);
    void SDL_DestroyRenderer(SDL_Renderer* renderer);
    void SDL_DestroyWindow(SDL_Window* window);

    uint32_t SDL_GetTicks(void);
    void SDL_Delay(uint32_t ms);
]]

local sdl
local ok, err = pcall(function()
    sdl = ffi.load("SDL2")
end)

if not ok then
    -- Fallback/Mock if library not found, to allow system to at least load
    return nil, "Could not load SDL2 library: " .. tostring(err)
end

local M = {}

M.INIT_VIDEO = 0x00000020
M.WINDOW_SHOWN = 0x00000004
M.RENDERER_ACCELERATED = 0x00000002
M.QUIT = 0x100

-- Re-expose C functions through M
for k, v in pairs(sdl) do
    M[k] = v
end

return M
