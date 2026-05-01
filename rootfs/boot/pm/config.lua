-- Configuration for ljpm on LJOS
-- Lives at /boot/pm/config.lua
--
-- LJOS directory layout:
--   /boot/                    OS system files (boot, core, pm source)
--   /boot/system/             OS system modules
--   /boot/pm/                 ljpm source + runtime data
--   /boot/pm/db.json          installed-package database
--   /boot/pm/cache/           downloaded archives + index
--   /boot/pm/config.json      user config (optional)
--   /packages/               installed third-party Lua packages
--   /bin/                    installed package scripts (alongside busybox)
--   /share/                  installed package data files

local json = require("pm.json")
local fs   = require("pm.fs")

local config = {}

-- ─── Defaults ────────────────────────────────────────────────────────────────

config.DEFAULTS = {
  -- Where third-party packages are installed
  packages_dir  = "/packages",
  -- Where package scripts go (alongside busybox)
  bin_dir       = "/bin",
  -- Shared data files
  share_dir     = "/share",
  -- pm internal data (stays under /boot since it's a system component)
  pm_dir        = "/boot/pm",
  -- Downloaded archives cache
  cache_dir     = "/boot/pm/cache",
  -- Package database
  db_file       = "/boot/pm/db.json",
  -- User config
  config_file   = "/boot/pm/config.json",
  -- Lock file
  lock_file     = "/boot/pm/ljpm.lock",
  -- Registry URL (default: local file during development, real URL in production)
  registry_url  = os.getenv("LJPM_REGISTRY") or "https://registry.ljos.dev",
  -- Log level
  log_level     = "info",
}

-- Allow env var overrides
if os.getenv("LJPM_PACKAGES") then config.DEFAULTS.packages_dir = os.getenv("LJPM_PACKAGES") end
if os.getenv("LJPM_CACHE")    then config.DEFAULTS.cache_dir    = os.getenv("LJPM_CACHE")    end

-- ─── Config Load/Save ─────────────────────────────────────────────────────────

function config.load(path)
  path = path or config.DEFAULTS.config_file
  if not fs.exists(path) then
    return config.copy_defaults()
  end
  local content, err = fs.read(path)
  if not content then return config.copy_defaults() end
  local ok, data = pcall(json.decode, content)
  if not ok then return config.copy_defaults() end
  local merged = config.copy_defaults()
  for k, v in pairs(data) do merged[k] = v end
  return merged
end

function config.save(cfg, path)
  path = path or cfg.config_file or config.DEFAULTS.config_file
  fs.mkdir(fs.dirname(path), true)
  local content = json.encode(cfg, true)
  return fs.write(path, content .. "\n")
end

function config.copy_defaults()
  local t = {}
  for k, v in pairs(config.DEFAULTS) do t[k] = v end
  return t
end

-- ─── Package Database ─────────────────────────────────────────────────────────
--
-- Format: { version: 1, packages: { [name]: manifest+install_info, ... } }

function config.load_db(cfg)
  local path = (cfg and cfg.db_file) or config.DEFAULTS.db_file
  if not fs.exists(path) then
    return {version = 1, packages = {}}
  end
  local content, err = fs.read(path)
  if not content then
    return nil, "Cannot read package database: "..(err or "")
  end
  local ok, data = pcall(json.decode, content)
  if not ok then
    return nil, "Package database is corrupt: "..tostring(data)
  end
  data.packages = data.packages or {}
  return data
end

function config.save_db(db, cfg)
  local path = (cfg and cfg.db_file) or config.DEFAULTS.db_file
  fs.mkdir(fs.dirname(path), true)
  local content = json.encode(db, true)
  local ok, err = fs.write(path, content .. "\n")
  if not ok then return false, "Cannot write package database: "..(err or "") end
  return true
end

-- ─── Manifest Normalization ───────────────────────────────────────────────────
--
-- Package manifests live inside the archive as package.json.
-- Fields:
--   name         string  required
--   version      string  required
--   description  string
--   author       string
--   license      string
--   homepage     string
--   luajit_min   string  minimum LuaJIT version required (e.g. "2.1")
--   dependencies { [name]: constraint }
--   conflicts    [name]
--   provides     [name]  virtual packages this satisfies
--   keywords     [string]
--   source       string  download URL for the archive
--   checksum     string  sha256 of the archive
--   size         number  uncompressed size in bytes
--   -- Install layout hints (optional):
--   install_to   string  default: "packages"  ("packages"|"system"|"bin")
--   scripts      { postinstall, preremove }  paths inside the archive

function config.normalize_manifest(data)
  if not data.name    then return nil, "Manifest missing 'name'"    end
  if not data.version then return nil, "Manifest missing 'version'" end
  return {
    name          = data.name,
    version       = data.version,
    description   = data.description   or "",
    author        = data.author        or "",
    license       = data.license       or "Unknown",
    homepage      = data.homepage      or "",
    luajit_min    = data.luajit_min    or "2.0",
    dependencies  = data.dependencies  or {},
    conflicts     = data.conflicts     or {},
    provides      = data.provides      or {},
    keywords      = data.keywords      or {},
    source        = data.source        or "",
    checksum      = data.checksum,
    size          = data.size          or 0,
    install_to    = data.install_to    or "packages",
    scripts       = data.scripts       or {},
  }
end

function config.parse_manifest(content)
  local ok, data = pcall(json.decode, content)
  if not ok then return nil, "Manifest parse error: "..tostring(data) end
  return config.normalize_manifest(data)
end

-- ─── Lock File ───────────────────────────────────────────────────────────────

function config.acquire_lock(cfg)
  local path = (cfg and cfg.lock_file) or config.DEFAULTS.lock_file
  if fs.exists(path) then
    local pid = fs.read(path)
    pid = pid and pid:match("^(%d+)")
    return nil, "Another ljpm process is running (PID "..(pid or "?").."). Delete "..path.." if stale."
  end
  -- Write our PID (use os.time as proxy since no getpid without FFI here)
  fs.write(path, tostring(os.time()).."\n")
  return true
end

function config.release_lock(cfg)
  local path = (cfg and cfg.lock_file) or config.DEFAULTS.lock_file
  if fs.exists(path) then fs.remove(path) end
  return true
end

return config
