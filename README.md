A LuaJIT-based userland running on Linux.

Current state:
- boots in QEMU
- runs LuaJIT as init
- basic shell works

Goal:
- full Lua-based userland
- no external CLI tools
- graphical environment built on SDL2

everything that doesn't NEED to be C will eventually be LuaJIT.
