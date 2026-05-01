-- Registry client for ljpm on LJOS
-- Lives at /lua/pm/registry.lua
--
-- Registry index format (JSON):
-- {
--   "updated": <unix timestamp>,
--   "packages": {
--     "<name>": {
--       "<version>": {
--         "name": "...", "version": "...", "description": "...",
--         "dependencies": { "<dep>": "<constraint>", ... },
--         "source": "<download url>",
--         "checksum": "<sha256>",
--         "size": <bytes>,
--         ... all other manifest fields
--       }
--     }
--   }
-- }
--
-- Index is cached at /lua/pm/cache/index.json for 24 hours.

local json    = require("pm.json")
local fs      = require("pm.fs")
local http    = require("pm.http")
local ver     = require("pm.version")
local ui      = require("pm.ui")

local registry = {}

local CACHE_TTL = 86400  -- 24 hours

-- ─── Index Cache ─────────────────────────────────────────────────────────────

function registry.cache_path(cfg)
  return (cfg and cfg.cache_dir or "/lua/pm/cache") .. "/index.json"
end

function registry.cache_mtime_path(cfg)
  return (cfg and cfg.cache_dir or "/lua/pm/cache") .. "/index.mtime"
end

function registry.load_cache(cfg)
  local path  = registry.cache_path(cfg)
  local mpath = registry.cache_mtime_path(cfg)

  if not fs.exists(path) then return nil end

  -- Check TTL
  if fs.exists(mpath) then
    local mt = tonumber(fs.read(mpath) or "0") or 0
    if os.time() - mt > CACHE_TTL then
      ui.debug("Package cache is stale (>24h)")
      return nil
    end
  end

  local content, err = fs.read(path)
  if not content then return nil end
  local ok, data = pcall(json.decode, content)
  if not ok then return nil end
  return data
end

function registry.save_cache(data, cfg)
  local path  = registry.cache_path(cfg)
  local mpath = registry.cache_mtime_path(cfg)
  fs.mkdir(fs.dirname(path), true)
  fs.write(path, json.encode(data))
  fs.write(mpath, tostring(os.time()))
end

-- ─── Fetch Index ─────────────────────────────────────────────────────────────

function registry.fetch_index(cfg, opts)
  opts = opts or {}
  local url = (cfg and cfg.registry_url) or "/lua/pm/cache/index.json"

  -- Return cached if not forced
  if not opts.force then
    local cached = registry.load_cache(cfg)
    if cached then return cached end
  end

  -- Try local file first (for offline / local registry)
  if url:sub(1,1) == "/" then
    if fs.exists(url) then
      local content = fs.read(url)
      if content then
        local ok, data = pcall(json.decode, content)
        if ok then return data end
      end
    end
    return nil, "Local registry not found: "..url
  end

  -- Network fetch
  ui.info("Downloading package lists from "..url.." ...")
  local resp, err = http.get(url.."/index.json")
  if not resp then
    -- Try stale cache
    local cached = registry.load_cache(cfg)
    if cached then
      ui.warn("Cannot reach registry ("..tostring(err).."), using cached index.")
      return cached
    end
    return nil, "Cannot fetch package index: "..tostring(err)
  end

  if resp.status ~= 200 then
    return nil, "Registry returned HTTP "..resp.status
  end

  local ok, data = pcall(json.decode, resp.body)
  if not ok then return nil, "Registry index malformed: "..tostring(data) end

  registry.save_cache(data, cfg)
  return data
end

-- ─── Package Lookup ───────────────────────────────────────────────────────────

function registry.get_versions(index, name)
  if not index or not index.packages then return {} end
  local pkg = index.packages[name]
  if not pkg then return {} end
  local vs = {}
  for v in pairs(pkg) do vs[#vs+1] = v end
  ver.sort(vs)
  return vs
end

function registry.get_manifest(index, name, version)
  if not index or not index.packages then return nil end
  local pkg = index.packages[name]
  if not pkg then return nil end
  if version then return pkg[version] end
  local vs = registry.get_versions(index, name)
  return vs[#vs] and pkg[vs[#vs]] or nil
end

-- ─── Search ──────────────────────────────────────────────────────────────────

function registry.search(index, query, opts)
  opts  = opts or {}
  query = query:lower()
  local results = {}

  for name, versions in pairs(index.packages or {}) do
    local vs = registry.get_versions(index, name)
    local latest = vs[#vs]
    if not latest then goto cont end
    local m = versions[latest]

    local match = name:lower():find(query, 1, true)
    if not match and not opts.names_only then
      match = (m.description or ""):lower():find(query, 1, true)
      if not match then
        for _, kw in ipairs(m.keywords or {}) do
          if kw:lower():find(query, 1, true) then match = true; break end
        end
      end
    end

    if match then
      results[#results+1] = {
        name        = name,
        version     = latest,
        description = m.description or "",
        arch        = "lua",
        manifest    = m,
      }
    end
    ::cont::
  end

  table.sort(results, function(a,b) return a.name < b.name end)
  return results
end

-- ─── Download ─────────────────────────────────────────────────────────────────

function registry.download(cfg, manifest, dest_path)
  local url = manifest.source
  if not url or url == "" then
    local base = (cfg and cfg.registry_url) or "https://registry.ljos.dev"
    url = base .. "/packages/" .. manifest.name .. "-" .. manifest.version .. ".tar.gz"
  end

  ui.debug("Downloading: "..url)
  local tmp = dest_path .. ".tmp"
  local ok, err = http.download(url, tmp)
  if not ok then return false, "Download failed: "..tostring(err) end

  -- Verify checksum
  if manifest.checksum then
    local got = fs.sha256(tmp)
    if got and got ~= manifest.checksum then
      fs.remove(tmp)
      return false, string.format(
        "Checksum mismatch for %s: expected %s, got %s",
        manifest.name, manifest.checksum, got
      )
    end
  end

  fs.rename(tmp, dest_path)
  return true
end

-- ─── List All ─────────────────────────────────────────────────────────────────

function registry.list_all(index, installed_db)
  local results = {}
  for name, versions in pairs(index.packages or {}) do
    local vs = registry.get_versions(index, name)
    local latest = vs[#vs]
    if not latest then goto cont end
    local m = versions[latest]
    local inst = installed_db and installed_db[name]
    results[#results+1] = {
      name        = name,
      version     = latest,
      description = (m or {}).description or "",
      installed   = inst ~= nil,
      upgradeable = inst and ver.gt(latest, inst.version),
    }
    ::cont::
  end
  table.sort(results, function(a,b) return a.name < b.name end)
  return results
end

return registry
