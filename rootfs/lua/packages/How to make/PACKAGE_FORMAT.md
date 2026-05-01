# LJOS Package Format

## Archive Structure

Packages are `.tar.gz` archives with the following layout:

```
mypackage-1.0.0.tar.gz
└── mypackage-1.0.0/          (or flat, no wrapper dir)
    ├── package.json           REQUIRED: package manifest
    ├── init.lua               main module entry (require("packages.mypackage"))
    ├── util.lua               other module files
    ├── submodule/
    │   └── init.lua
    ├── bin/
    │   └── mytool.lua         installed to /lua/bin/mytool.lua
    └── share/
        └── mypackage/
            └── data.json      installed to /lua/share/mypackage/data.json
```

## Manifest (`package.json`)

```json
{
  "name":        "mypackage",
  "version":     "1.2.3",
  "description": "A LuaJIT package for LJOS",
  "author":      "Your Name <you@example.com>",
  "license":     "MIT",
  "homepage":    "https://github.com/you/mypackage",
  "luajit_min":  "2.1",

  "dependencies": {
    "lualinux":  ">=0.4.0",
    "luasocket": "^3.0.0"
  },
  "conflicts": [],
  "provides":  ["virtual-name"],
  "keywords":  ["tag1", "tag2"],

  "source":    "https://registry.ljos.dev/packages/mypackage-1.2.3.tar.gz",
  "checksum":  "sha256hexstring",
  "size":      12345,

  "install_to": "packages",

  "scripts": {
    "postinstall": "install.lua",
    "preremove":   "uninstall.lua"
  }
}
```

### `install_to` values

| Value      | Installed to            | `require()` path               |
|------------|-------------------------|--------------------------------|
| `packages` | `/lua/packages/<name>/` | `require("packages.<name>")`   |
| `system`   | `/lua/system/<name>/`   | `require("system.<name>")`     |

Scripts in `bin/` always go to `/lua/bin/` regardless of `install_to`.

## Version Constraints

| Constraint | Meaning                              |
|------------|--------------------------------------|
| `*`        | Any version                          |
| `1.2.3`    | Exactly 1.2.3                        |
| `>=1.2.0`  | 1.2.0 or newer                       |
| `^1.2.0`   | >=1.2.0 <2.0.0 (same major)         |
| `~1.2.0`   | >=1.2.0 <1.3.0 (same major.minor)   |
| `<2.0.0`   | Older than 2.0.0                     |

## Registry Index Format

The registry exposes `https://<registry>/index.json`:

```json
{
  "updated": 1746000000,
  "packages": {
    "<name>": {
      "<version>": { ...manifest fields... },
      "<version>": { ... }
    }
  }
}
```

## Using an Installed Package

After `pm install mypackage`, use it in LJOS:

```lua
local mp = require("packages.mypackage")
```

The LJOS `package.path` already includes `/lua/?.lua` and `/lua/?/init.lua`,
so `/lua/packages/mypackage/init.lua` is found automatically.
