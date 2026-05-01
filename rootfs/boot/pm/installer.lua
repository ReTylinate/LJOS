-- Package installer/uninstaller for ljpm on LJOS
-- Lives at /boot/pm/installer.lua
--
-- LJOS install layout:
--   Archive layout (inside .tar.gz):
--     package.json           -- manifest (required)
--     init.lua               -- main module entry point
--     *.lua                  -- other module files
--     bin/<name>.lua         -- executable scripts (optional)
--     share/<name>/          -- data files (optional)
--
--   Installed to:
--     /packages/<name>/      -- Lua module files (require("packages.<name>"))
--     /bin/<name>.lua        -- executable scripts (alongside busybox)
--     /share/<name>/         -- data files
--
-- Package archives are cached at /boot/pm/cache/archives/
-- PM runtime data stays under /boot/pm/ (it's a system component)

local json     = require("pm.json")
local fs       = require("pm.fs")
local config   = require("pm.config")
local registry = require("pm.registry")
local ui       = require("pm.ui")

local installer = {}

-- ─── Archive Extraction ───────────────────────────────────────────────────────
-- Uses busybox tar (available in /bin/tar via busybox)

local function extract_archive(archive_path, dest_dir)
  fs.mkdir(dest_dir, true)

  local cmd
  if archive_path:match("%.tar%.gz$") or archive_path:match("%.tgz$") then
    cmd = string.format("tar -xzf %s -C %s 2>/boot/null",
      fs.quote(archive_path), fs.quote(dest_dir))
  elseif archive_path:match("%.tar$") then
    cmd = string.format("tar -xf %s -C %s 2>/boot/null",
      fs.quote(archive_path), fs.quote(dest_dir))
  else
    return false, "Unknown archive format: "..archive_path
  end

  local ok = os.execute(cmd)
  return (ok == 0), (ok ~= 0 and "tar extraction failed" or nil)
end

-- Find the first actual content directory in an extracted archive
-- (handles archives that wrap everything in a <name>-<version>/ prefix)
local function find_content_root(extract_dir)
  local entries = fs.listdir(extract_dir)
  if not entries then return extract_dir end
  -- If there's exactly one directory, descend into it
  if #entries == 1 then
    local child = extract_dir .. "/" .. entries[1]
    if fs.isdir(child) then return child end
  end
  return extract_dir
end

-- ─── Install a Package ────────────────────────────────────────────────────────

function installer.install(manifest, cfg, db, opts)
  opts = opts or {}
  local name    = manifest.name
  local version = manifest.version
  local paths   = {
    packages_dir  = (cfg and cfg.packages_dir) or "/packages",
    bin_dir       = (cfg and cfg.bin_dir)       or "/bin",
    share_dir     = (cfg and cfg.share_dir)     or "/share",
    cache_dir     = (cfg and cfg.cache_dir)     or "/boot/pm/cache",
  }

  ui.info(string.format("Installing %s (%s)...", name, version))

  -- Ensure target dirs exist
  fs.mkdir(paths.packages_dir, true)
  fs.mkdir(paths.bin_dir, true)
  fs.mkdir(paths.share_dir, true)

  local archive_dir  = paths.cache_dir .. "/archives"
  local archive_name = name .. "-" .. version .. ".tar.gz"
  local archive_path = archive_dir .. "/" .. archive_name

  fs.mkdir(archive_dir, true)

  -- Download if not cached
  if not fs.exists(archive_path) or opts.reinstall then
    if fs.exists(archive_path) then fs.remove(archive_path) end
    ui.info("  Downloading "..name.." "..version.."...")
    local ok, err = registry.download(cfg, manifest, archive_path)
    if not ok then return false, err end
  else
    ui.debug("  Using cached archive: "..archive_path)
  end

  -- Extract to temp dir
  local extract_tmp = paths.cache_dir .. "/extract/" .. name .. "-" .. version
  fs.rmrf(extract_tmp)
  fs.mkdir(extract_tmp, true)

  local ok, err = extract_archive(archive_path, extract_tmp)
  if not ok then
    fs.rmrf(extract_tmp)
    return false, "Extraction failed: "..(err or "unknown")
  end

  -- Locate content root (strip top-level wrapper dir if present)
  local content_root = find_content_root(extract_tmp)

  -- Read manifest from archive (to get any additional fields)
  local manifest_path = content_root .. "/package.json"
  if fs.exists(manifest_path) then
    local raw = fs.read(manifest_path)
    if raw then
      local ok2, m2 = pcall(json.decode, raw)
      if ok2 then
        -- Merge any additional fields from bundled manifest
        for k, v in pairs(m2) do
          if manifest[k] == nil then manifest[k] = v end
        end
      end
    end
  end

  -- Determine install location
  local install_to = manifest.install_to or "packages"
  local pkg_dest

  if install_to == "system" then
    pkg_dest = "/boot/system/" .. name
  else
    pkg_dest = paths.packages_dir .. "/" .. name
  end

  -- Remove old version if reinstalling
  if fs.isdir(pkg_dest) then
    ui.debug("  Removing old version at "..pkg_dest)
    fs.rmrf(pkg_dest)
  end

  -- Place Lua files → /packages/<name>/
  fs.mkdir(pkg_dest, true)
  local installed_files = {}

  -- Copy all .lua files from content root (excluding bin/ and share/)
  local entries = fs.listdir(content_root)
  if entries then
    for _, entry in ipairs(entries) do
      local src = content_root .. "/" .. entry
      if entry == "bin" then
        -- Executables → /bin/
        if fs.isdir(src) then
          local bins = fs.listdir(src)
          if bins then
            for _, bname in ipairs(bins) do
              local bsrc  = src .. "/" .. bname
              local bdst  = paths.bin_dir .. "/" .. bname
              fs.copy(bsrc, bdst)
              os.execute("chmod +x "..fs.quote(bdst).." 2>/boot/null")
              installed_files[#installed_files+1] = bdst
            end
          end
        end
      elseif entry == "share" then
        -- Data → /boot/share/<name>/
        if fs.isdir(src) then
          local sdst = paths.share_dir .. "/" .. name
          fs.copydir(src, sdst)
          installed_files[#installed_files+1] = sdst
        end
      elseif entry == "package.json" then
        -- Skip — don't install the manifest itself as a module file
      else
        -- Lua modules → /packages/<name>/
        local dst = pkg_dest .. "/" .. entry
        if fs.isdir(src) then
          fs.copydir(src, dst)
        else
          fs.copy(src, dst)
        end
        installed_files[#installed_files+1] = dst
      end
    end
  end

  -- Clean up extract temp
  fs.rmrf(extract_tmp)

  -- Run post-install script if defined
  if manifest.scripts and manifest.scripts.postinstall then
    local script = pkg_dest .. "/" .. manifest.scripts.postinstall
    if fs.exists(script) then
      ui.info("  Running post-install script...")
      os.execute("luajit "..fs.quote(script).." 2>&1")
    end
  end

  -- Record in database
  installer.record(db, manifest, installed_files, opts.reason or "manual")

  ui.ok("Installed " .. name .. " " .. version)
  return true
end

-- ─── Record in Database ───────────────────────────────────────────────────────

function installer.record(db, manifest, files, reason)
  db.packages = db.packages or {}
  db.packages[manifest.name] = {
    name           = manifest.name,
    version        = manifest.version,
    description    = manifest.description,
    author         = manifest.author,
    license        = manifest.license,
    dependencies   = manifest.dependencies or {},
    conflicts      = manifest.conflicts or {},
    install_reason = reason or "manual",
    installed_at   = os.date("%Y-%m-%dT%H:%M:%S"),
    files          = files or {},
    scripts        = manifest.scripts,
    install_to     = manifest.install_to,
    size           = manifest.size,
  }
end

-- ─── Remove a Package ─────────────────────────────────────────────────────────

function installer.remove(name, db, cfg, opts)
  opts = opts or {}
  local info = db.packages and db.packages[name]
  if not info then
    return false, "Package '"..name.."' is not installed"
  end

  ui.info(string.format("Removing %s (%s)...", name, info.version))

  local paths = {
    packages_dir  = (cfg and cfg.packages_dir) or "/packages",
    bin_dir       = (cfg and cfg.bin_dir)       or "/bin",
    share_dir     = (cfg and cfg.share_dir)     or "/share",
    cache_dir     = (cfg and cfg.cache_dir)     or "/boot/pm/cache",
  }

  -- Run pre-remove script
  if info.scripts and info.scripts.preremove then
    local install_to = info.install_to or "packages"
    local pkg_dir = (install_to == "system")
      and "/boot/system/"..name   -- system packages stay under /boot
      or  paths.packages_dir.."/"..name

    local script = pkg_dir .. "/" .. info.scripts.preremove
    if fs.exists(script) then
      ui.info("  Running pre-remove script...")
      os.execute("luajit "..fs.quote(script).." 2>&1")
    end
  end

  -- Remove tracked files
  if info.files and #info.files > 0 then
    for _, fpath in ipairs(info.files) do
      if fs.isdir(fpath) then
        fs.rmrf(fpath)
      elseif fs.exists(fpath) then
        fs.remove(fpath)
      end
    end
  else
    -- Fallback: remove package directory
    local install_to = info.install_to or "packages"
    local pkg_dir = (install_to == "system")
      and "/boot/system/"..name   -- system packages stay under /boot
      or  paths.packages_dir.."/"..name
    if fs.isdir(pkg_dir) then fs.rmrf(pkg_dir) end
  end

  -- Purge cache if --purge
  if opts.purge then
    installer.purge_cache(name, paths)
  end

  -- Remove from db
  db.packages[name] = nil
  ui.ok("Removed "..name)
  return true
end

-- ─── Purge Cached Archives ────────────────────────────────────────────────────

function installer.purge_cache(name, paths)
  local cache_dir = paths.cache_dir .. "/archives"
  if not fs.isdir(cache_dir) then return true end
  local entries = fs.listdir(cache_dir) or {}
  for _, entry in ipairs(entries) do
    if entry:match("^"..name.."%-") then
      fs.remove(cache_dir .. "/" .. entry)
      ui.debug("  Purged: "..entry)
    end
  end
  return true
end

return installer
