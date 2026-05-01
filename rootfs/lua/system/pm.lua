-- ljpm — LuaJIT Package Manager for LJOS
-- Lives at /lua/system/pm.lua
--
-- Usage from LJOS shell:
--   pm install <pkg>
--   pm remove <pkg>
--   pm update
--   pm upgrade
--   pm search <query>
--   pm show <pkg>
--   pm list [--installed] [--all] [--upgradeable]
--   pm autoremove
--   pm cache clean|stats
--   pm source list|add|remove
--   pm help
--
-- Integration with core.shell():
--   local pm = require("system.pm")
--   pm.register_shell(core)   -- adds "pm" command to core.shell dispatch
--
-- Or run standalone (used when invoked as /lua/bin/pm.lua):
--   pm.main(arg)

-- Set up module search path so pm.* modules are findable
package.path = "/lua/?.lua;/lua/?/init.lua;" .. package.path

local ui       = require("pm.ui")
local fs       = require("pm.fs")
local json     = require("pm.json")
local config   = require("pm.config")
local ver      = require("pm.version")
local registry = require("pm.registry")
local resolver = require("pm.resolver")
local installer = require("pm.installer")

local pm = {}

pm.VERSION = "1.0.0"

-- ─── Option Parser ───────────────────────────────────────────────────────────

local function parse_args(raw_args)
  local args    = {}
  local opts    = {}

  local i = 1
  while i <= #raw_args do
    local a = raw_args[i]
    if a:sub(1,2) == "--" then
      local key = a:sub(3)
      -- flags with values: --key=value
      local k, v = key:match("^([^=]+)=(.+)$")
      if k then
        opts[k:gsub("%-","_")] = v
      else
        opts[key:gsub("%-","_")] = true
      end
    elseif a:sub(1,1) == "-" and #a > 1 then
      -- short flags: -y -q -v (combined: -yq)
      for j = 2, #a do
        local ch = a:sub(j,j)
        if ch == "y" then opts.yes    = true
        elseif ch=="q" then opts.quiet  = true; ui.quiet = true
        elseif ch=="v" then opts.verbose= true; ui.verbose = true
        elseif ch=="f" then opts.force  = true
        elseif ch=="n" then opts.dry_run= true
        end
      end
    else
      args[#args+1] = a
    end
    i = i + 1
  end

  return args, opts
end

-- ─── Command Dispatch ────────────────────────────────────────────────────────

local commands = {}

-- ─── pm update ───────────────────────────────────────────────────────────────

commands.update = function(args, opts)
  local cfg  = config.load()

  local index, err = registry.fetch_index(cfg, {force = true})
  if not index then
    ui.error("Failed to update package lists: "..tostring(err))
    return false
  end

  local n = 0
  for _ in pairs(index.packages or {}) do n = n + 1 end
  local ts = index.updated and os.date("%Y-%m-%d %H:%M", index.updated) or "unknown"
  ui.ok(string.format("Package lists updated — %d packages available (index from %s)", n, ts))

  -- Show upgrade hint
  local db = config.load_db(cfg)
  if db and db.packages then
    local ups = resolver.find_upgrades(db.packages, index.packages or {})
    if #ups > 0 then
      io.write("\n")
      ui.info(#ups.." package(s) can be upgraded. Run 'pm upgrade' to apply.")
    end
  end
  return true
end

-- ─── pm install ──────────────────────────────────────────────────────────────

commands.install = function(args, opts)
  if #args == 0 then
    ui.error("Usage: pm install <package>[=version] ...")
    return false
  end

  local cfg  = config.load()
  local ok, err = config.acquire_lock(cfg)
  if not ok then ui.error(err); return false end

  -- Parse package specs
  local requests = {}
  for _, spec in ipairs(args) do
    local name, con = spec:match("^([^=>=<^~!]+)(.*)$")
    name = name and name:match("^%s*(.-)%s*$") or spec
    con  = (con and con ~= "") and con or "*"
    requests[#requests+1] = {name=name, constraint=con}
  end

  -- Fetch index + db
  local index, ierr = registry.fetch_index(cfg, {})
  if not index then
    ui.error("Cannot fetch package index: "..tostring(ierr))
    config.release_lock(cfg); return false
  end

  local db, derr = config.load_db(cfg)
  if not db then
    ui.error("Cannot load package database: "..tostring(derr))
    config.release_lock(cfg); return false
  end

  -- Resolve
  local plan, errs = resolver.resolve(requests, index.packages or {}, db.packages or {}, {
    upgrade  = not opts.no_upgrade,
    force    = opts.force,
    reinstall = opts.reinstall,
  })

  if not plan then
    ui.error("Dependency resolution failed:")
    for _, e in ipairs(errs) do io.write("  ✗ "..e.."\n") end
    config.release_lock(cfg); return false
  end

  if #plan.install == 0 and #plan.upgrade == 0 then
    for _, p in ipairs(plan.skip) do
      ui.ok(p.name.." is already the latest version ("..p.version..")")
    end
    config.release_lock(cfg); return true
  end

  -- Show summary
  local upgrade_display = {}
  for _, u in ipairs(plan.upgrade) do
    upgrade_display[#upgrade_display+1] = {
      name=u.name, old_version=u.old_version, new_version=u.new_version
    }
  end
  ui.summary(plan.install, {}, upgrade_display)

  if opts.dry_run then
    ui.info("Dry run — no changes made.")
    config.release_lock(cfg); return true
  end

  if not opts.yes then
    local proceed = ui.confirm("Do you want to continue?", true)
    if not proceed then
      ui.info("Aborted.")
      config.release_lock(cfg); return true
    end
  end

  local failed = 0

  for _, pkg in ipairs(plan.install) do
    local ok2, err2 = installer.install(pkg.manifest, cfg, db, {reason = pkg.reason})
    if not ok2 then
      failed = failed + 1
      ui.error("Failed: "..pkg.name.." — "..tostring(err2))
    else
      config.save_db(db, cfg)
    end
  end

  for _, pkg in ipairs(plan.upgrade) do
    installer.remove(pkg.name, db, cfg, {})
    local ok2, err2 = installer.install(pkg.manifest, cfg, db, {reason="manual"})
    if not ok2 then
      failed = failed + 1
      ui.error("Failed: "..pkg.name.." — "..tostring(err2))
    else
      config.save_db(db, cfg)
    end
  end

  if failed > 0 then ui.warn(failed.." package(s) failed.") end
  config.release_lock(cfg)
  return failed == 0
end

-- ─── pm remove ───────────────────────────────────────────────────────────────

commands.remove = function(args, opts)
  if #args == 0 then
    ui.error("Usage: pm remove <package> ...")
    return false
  end

  local cfg = config.load()
  local ok, err = config.acquire_lock(cfg)
  if not ok then ui.error(err); return false end

  local db, derr = config.load_db(cfg)
  if not db then
    ui.error("Cannot load package database: "..tostring(derr))
    config.release_lock(cfg); return false
  end

  local plan, errs = resolver.resolve_remove(args, db.packages or {}, {
    force      = opts.force,
    autoremove = opts.autoremove,
  })

  if not plan then
    ui.error("Cannot resolve removal:")
    for _, e in ipairs(errs) do io.write("  ✗ "..e.."\n") end
    config.release_lock(cfg); return false
  end

  local all = {}
  for _, p in ipairs(plan.remove)  do all[#all+1] = p end
  for _, p in ipairs(plan.orphans) do all[#all+1] = p end

  if #all == 0 then
    ui.info("Nothing to remove.")
    config.release_lock(cfg); return true
  end

  ui.summary({}, all, {})

  if opts.dry_run then
    ui.info("Dry run — no changes made.")
    config.release_lock(cfg); return true
  end

  if not opts.yes then
    local proceed = ui.confirm("Remove these packages?", true)
    if not proceed then
      ui.info("Aborted.")
      config.release_lock(cfg); return true
    end
  end

  for _, pkg in ipairs(all) do
    installer.remove(pkg.name, db, cfg, {purge = opts.purge})
    config.save_db(db, cfg)
  end

  config.release_lock(cfg)
  return true
end

-- ─── pm upgrade ──────────────────────────────────────────────────────────────

commands.upgrade = function(args, opts)
  local cfg = config.load()
  local ok, err = config.acquire_lock(cfg)
  if not ok then ui.error(err); return false end

  local db, derr = config.load_db(cfg)
  if not db then
    ui.error("Cannot load database: "..tostring(derr))
    config.release_lock(cfg); return false
  end

  local index, ierr = registry.fetch_index(cfg, {})
  if not index then
    ui.error("Cannot fetch index: "..tostring(ierr))
    config.release_lock(cfg); return false
  end

  local ups = resolver.find_upgrades(db.packages or {}, index.packages or {})

  -- Filter if specific names given
  if #args > 0 then
    local want = {}
    for _, n in ipairs(args) do want[n] = true end
    local filtered = {}
    for _, u in ipairs(ups) do
      if want[u.name] then filtered[#filtered+1] = u end
    end
    ups = filtered
  end

  if #ups == 0 then
    ui.ok("All packages are up to date.")
    config.release_lock(cfg); return true
  end

  local display = {}
  for _, u in ipairs(ups) do
    display[#display+1] = {name=u.name, old_version=u.old_version, new_version=u.new_version}
  end
  ui.summary({}, {}, display)

  if opts.dry_run then
    ui.info("Dry run — no changes made.")
    config.release_lock(cfg); return true
  end

  if not opts.yes then
    local proceed = ui.confirm("Upgrade these packages?", true)
    if not proceed then ui.info("Aborted."); config.release_lock(cfg); return true end
  end

  local failed = 0
  for _, u in ipairs(ups) do
    local old_reason = (db.packages[u.name] or {}).install_reason or "manual"
    installer.remove(u.name, db, cfg, {})
    local ok2, err2 = installer.install(u.manifest, cfg, db, {reason=old_reason})
    if not ok2 then
      failed = failed + 1
      ui.error("Failed: "..u.name.." — "..tostring(err2))
    else
      config.save_db(db, cfg)
    end
  end

  if failed == 0 then
    ui.ok(#ups.." package(s) upgraded successfully.")
  else
    ui.warn(failed.." upgrade(s) failed.")
  end

  config.release_lock(cfg)
  return failed == 0
end

-- ─── pm search ───────────────────────────────────────────────────────────────

commands.search = function(args, opts)
  if #args == 0 then
    ui.error("Usage: pm search <query>")
    return false
  end
  local query = table.concat(args, " ")
  local cfg   = config.load()
  local db    = config.load_db(cfg) or {packages={}}

  local index, err = registry.fetch_index(cfg, {})
  if not index then
    ui.error("Cannot load index: "..tostring(err))
    return false
  end

  local results = registry.search(index, query, {names_only=opts.names_only})

  if opts.installed then
    local filtered = {}
    for _, r in ipairs(results) do
      if db.packages[r.name] then filtered[#filtered+1] = r end
    end
    results = filtered
  end

  for _, r in ipairs(results) do
    if db.packages[r.name] then
      r.installed = true
      r.upgradeable = ver.gt(r.version, db.packages[r.name].version)
    end
  end

  if #results == 0 then
    ui.info("No packages found for '"..query.."'")
    return true
  end

  if not opts.quiet then
    io.write(string.format("Searching '%s'... %d result(s)\n\n", query, #results))
  end

  if opts.quiet then
    for _, r in ipairs(results) do io.write(r.name.." "..r.version.."\n") end
  else
    ui.pkg_table(results)
  end
  return true
end

-- ─── pm show ─────────────────────────────────────────────────────────────────

commands.show = function(args, opts)
  if #args == 0 then
    ui.error("Usage: pm show <package>[=version]")
    return false
  end
  local cfg = config.load()
  local db  = config.load_db(cfg) or {packages={}}
  local index, err = registry.fetch_index(cfg, {})
  if not index then
    ui.error("Cannot load index: "..tostring(err)); return false
  end

  for _, arg in ipairs(args) do
    local name, req_ver = arg:match("^([^=]+)=?(.*)$")
    name    = name and name:match("^%s*(.-)%s*$")
    req_ver = (req_ver and req_ver ~= "") and req_ver or nil

    local manifest
    if req_ver then
      manifest = registry.get_manifest(index, name, req_ver)
    else
      manifest = registry.get_manifest(index, name)
    end

    if not manifest then
      if db.packages[name] then
        ui.pkg_info(db.packages[name], db.packages[name])
      else
        ui.error("Package '"..name.."' not found.")
      end
    else
      ui.pkg_info(manifest, db.packages[name])
      local vs = registry.get_versions(index, name)
      if #vs > 1 then
        io.write(string.format("%-18s %s\n", "Versions:", table.concat(vs,", ")))
      end
    end
    io.write("\n")
  end
  return true
end

-- ─── pm list ─────────────────────────────────────────────────────────────────

commands.list = function(args, opts)
  local cfg = config.load()
  local db  = config.load_db(cfg) or {packages={}}
  local pattern = args[1]

  if opts.all or opts.upgradeable then
    local index, err = registry.fetch_index(cfg, {})
    if not index then
      ui.error("Cannot load index: "..tostring(err)); return false
    end

    if opts.upgradeable then
      local ups = resolver.find_upgrades(db.packages or {}, index.packages or {})
      if #ups == 0 then
        ui.ok("All packages are up to date.")
        return true
      end
      io.write(string.format("%-24s  %-14s  %s\n",
        ui.color("bold","Package"), ui.color("bold","Installed"),
        ui.color("bold","Available")))
      io.write(ui.color("dim",string.rep("─",55)).."\n")
      for _, u in ipairs(ups) do
        io.write(string.format("%-24s  %-14s  %s\n",
          ui.color("bold",u.name),
          ui.color("dim",u.old_version),
          ui.color("cyan",u.new_version)))
      end
      io.write("\n"..#ups.." package(s) can be upgraded.\n")
      return true
    end

    local all = registry.list_all(index, db.packages)
    if pattern then
      local pat = pattern:gsub("%*",".*"):gsub("%?",".")
      local f = {}
      for _, p in ipairs(all) do
        if p.name:match(pat) then f[#f+1] = p end
      end
      all = f
    end

    if opts.quiet then
      for _, p in ipairs(all) do
        io.write(p.name.."/"..p.version..(p.installed and " [installed]" or "").."\n")
      end
    else
      ui.pkg_table(all)
      io.write("\n"..#all.." package(s) found.\n")
    end
    return true
  end

  -- Default: installed packages
  local installed = {}
  for name, info in pairs(db.packages or {}) do
    if opts.manual and info.install_reason ~= "manual" then goto skip end
    if opts.auto   and info.install_reason ~= "dependency" then goto skip end
    if pattern then
      local pat = pattern:gsub("%*",".*"):gsub("%?",".")
      if not name:match(pat) then goto skip end
    end
    installed[#installed+1] = {
      name=name, version=info.version,
      description=info.description or "",
      installed=true,
    }
    ::skip::
  end
  table.sort(installed, function(a,b) return a.name < b.name end)

  if #installed == 0 then
    ui.info("No installed packages".. (pattern and " matching '"..pattern.."'" or "").. ".")
    return true
  end

  if opts.quiet then
    for _, p in ipairs(installed) do io.write(p.name.."/"..p.version.."\n") end
  else
    ui.pkg_table(installed)
    io.write("\n"..#installed.." package(s) installed.\n")
  end
  return true
end

-- ─── pm autoremove ───────────────────────────────────────────────────────────

commands.autoremove = function(args, opts)
  local cfg = config.load()
  local db  = config.load_db(cfg) or {packages={}}

  -- Find orphans
  local orphans = {}
  for name, info in pairs(db.packages or {}) do
    if info.install_reason == "dependency" then
      local needed = false
      for other, oinfo in pairs(db.packages) do
        if other ~= name and (oinfo.dependencies or {})[name] then
          needed = true; break
        end
      end
      if not needed then
        orphans[#orphans+1] = {name=name, version=info.version}
      end
    end
  end

  if #orphans == 0 then
    ui.ok("No packages to autoremove.")
    return true
  end

  ui.summary({}, orphans, {})
  if opts.dry_run then ui.info("Dry run."); return true end

  if not opts.yes then
    local proceed = ui.confirm("Remove these orphaned packages?", true)
    if not proceed then ui.info("Aborted."); return true end
  end

  local ok, err = config.acquire_lock(cfg)
  if not ok then ui.error(err); return false end

  for _, pkg in ipairs(orphans) do
    installer.remove(pkg.name, db, cfg, {purge = opts.purge})
    config.save_db(db, cfg)
  end

  config.release_lock(cfg)
  ui.ok("Done.")
  return true
end

-- ─── pm cache ────────────────────────────────────────────────────────────────

commands.cache = function(args, opts)
  local cfg    = config.load()
  local subcmd = args[1]
  table.remove(args, 1)

  if subcmd == "clean" then
    local archive_dir = (cfg.cache_dir or "/lua/pm/cache") .. "/archives"
    local entries = fs.listdir(archive_dir) or {}
    local count, freed = 0, 0
    for _, name in ipairs(entries) do
      local path = archive_dir .. "/" .. name
      local sz   = fs.size(path) or 0
      count = count + 1; freed = freed + sz
      if not opts.dry_run then fs.remove(path) end
    end
    if opts.dry_run then
      ui.info(string.format("Would remove %d file(s) (%s)", count, ui.fmt_size(freed)))
    else
      ui.ok(string.format("Removed %d archive(s), freed %s", count, ui.fmt_size(freed)))
    end

  elseif subcmd == "stats" then
    local cache_dir   = cfg.cache_dir or "/lua/pm/cache"
    local archive_dir = cache_dir .. "/archives"
    local entries = fs.listdir(archive_dir) or {}
    local total, size = 0, 0
    for _, name in ipairs(entries) do
      total = total + 1
      size  = size + (fs.size(archive_dir.."/"..name) or 0)
    end
    local index_size = fs.size(cache_dir.."/index.json") or 0
    local mtime_raw  = fs.read(cache_dir.."/index.mtime")
    local mtime_str  = mtime_raw and os.date("%Y-%m-%d %H:%M", tonumber(mtime_raw)) or "N/A"

    ui.section("Cache Statistics")
    io.write(string.format("  Directory    : %s\n", cache_dir))
    io.write(string.format("  Archives     : %d file(s)\n", total))
    io.write(string.format("  Archive size : %s\n", ui.fmt_size(size)))
    io.write(string.format("  Index size   : %s\n", ui.fmt_size(index_size)))
    io.write(string.format("  Index date   : %s\n", mtime_str))
    io.write(string.format("  Total        : %s\n", ui.fmt_size(size + index_size)))
    io.flush()

  elseif subcmd == "autoclean" then
    local db          = config.load_db(cfg) or {packages={}}
    local archive_dir = (cfg.cache_dir or "/lua/pm/cache") .. "/archives"
    local entries     = fs.listdir(archive_dir) or {}
    local removed, freed = 0, 0
    for _, name in ipairs(entries) do
      -- Extract package name and version from filename
      local pname, pver = name:match("^(.-)%-(%d[%d%.%-]+)%.tar%.gz$")
      local inst = pname and db.packages[pname]
      local keep = inst and pver and (pver == inst.version)
      if not keep then
        local fpath = archive_dir .. "/" .. name
        local sz    = fs.size(fpath) or 0
        removed = removed + 1; freed = freed + sz
        if not opts.dry_run then fs.remove(fpath) end
      end
    end
    if opts.dry_run then
      ui.info(string.format("Would remove %d file(s) (%s)", removed, ui.fmt_size(freed)))
    else
      ui.ok(string.format("Autoclean: removed %d stale archive(s), freed %s",
        removed, ui.fmt_size(freed)))
    end
  else
    ui.error("Usage: pm cache <clean|autoclean|stats>")
    return false
  end
  return true
end

-- ─── pm source ───────────────────────────────────────────────────────────────

commands.source = function(args, opts)
  local cfg      = config.load()
  local src_file = (cfg.pm_dir or "/lua/pm") .. "/sources.json"
  local subcmd   = args[1]
  table.remove(args, 1)

  local function load_sources()
    if not fs.exists(src_file) then
      return {sources={{url=cfg.registry_url, name="default", enabled=true}}}
    end
    local ok, data = pcall(json.decode, fs.read(src_file) or "")
    return ok and data or {sources={}}
  end

  local function save_sources(data)
    fs.mkdir(fs.dirname(src_file), true)
    fs.write(src_file, json.encode(data, true).."\n")
  end

  if not subcmd or subcmd == "list" then
    local data = load_sources()
    ui.section("Package Sources")
    for i, src in ipairs(data.sources or {}) do
      local status = src.enabled and ui.color("green","enabled") or ui.color("dim","disabled")
      io.write(string.format("  %s  %-20s  %s\n",
        status, src.name or ("src-"..i), src.url))
    end
    io.write("\n")

  elseif subcmd == "add" then
    local url = args[1]
    if not url then ui.error("Usage: pm source add <url>"); return false end
    local data = load_sources()
    for _, s in ipairs(data.sources or {}) do
      if s.url == url then ui.warn("Already configured: "..url); return true end
    end
    local name = url:match("//([^/]+)") or url
    table.insert(data.sources, {url=url, name=name, enabled=true})
    save_sources(data)
    ui.ok("Added: "..url)
    ui.info("Run 'pm update' to fetch the new package list.")

  elseif subcmd == "remove" then
    local url = args[1]
    if not url then ui.error("Usage: pm source remove <url>"); return false end
    local data = load_sources()
    local new, found = {}, false
    for _, s in ipairs(data.sources or {}) do
      if s.url == url then found=true else new[#new+1]=s end
    end
    if not found then ui.error("Source not found: "..url); return false end
    data.sources = new
    save_sources(data)
    ui.ok("Removed: "..url)

  elseif subcmd == "enable" or subcmd == "disable" then
    local url  = args[1]
    local enbl = (subcmd == "enable")
    if not url then ui.error("Usage: pm source "..subcmd.." <url>"); return false end
    local data = load_sources()
    local found = false
    for _, s in ipairs(data.sources or {}) do
      if s.url == url then s.enabled=enbl; found=true; break end
    end
    if not found then ui.error("Source not found: "..url); return false end
    save_sources(data)
    ui.ok((enbl and "Enabled" or "Disabled")..": "..url)
  else
    ui.error("Usage: pm source <list|add|remove|enable|disable>")
    return false
  end
  return true
end

-- ─── pm help ─────────────────────────────────────────────────────────────────

commands.help = function(args, opts)
  io.write([[
ljpm ]] .. pm.VERSION .. [[ — LuaJIT Package Manager for LJOS

Usage: pm <command> [options] [packages...]

Commands:
  update                  Refresh the package index
  install <pkg...>        Install packages (with dependency resolution)
  remove  <pkg...>        Remove installed packages
  upgrade [pkg...]        Upgrade packages to latest versions
  search  <query>         Search for packages
  show    <pkg>           Show detailed package info
  list    [--installed|--all|--upgradeable]
                          List packages
  autoremove              Remove orphaned auto-installed packages
  cache   <clean|autoclean|stats>
                          Manage the download cache
  source  <list|add|remove|enable|disable>
                          Manage registry sources
  help                    Show this help

Common options:
  -y, --yes               Assume yes to all prompts
  -q, --quiet             Suppress non-essential output
  -v, --verbose           Verbose/debug output
  -n, --dry-run           Show what would happen, do nothing
  -f, --force             Force operation (override safety checks)
  --no-upgrade            Don't upgrade dependencies during install
  --reinstall             Reinstall even if already up to date
  --purge                 Also remove config files on remove
  --autoremove            Remove unneeded dependencies after remove

Packages are installed to:
  Modules → /lua/packages/<name>/   (require("packages.<name>"))
  Scripts → /lua/bin/<name>.lua
  Data    → /lua/share/<name>/

Examples:
  pm install luasocket
  pm install luasocket=3.0.0 luafilesystem
  pm remove luasocket --purge
  pm search sdl
  pm upgrade
  pm list --upgradeable
  pm cache clean
]])
  io.flush()
  return true
end

-- ─── Command Aliases ─────────────────────────────────────────────────────────

local ALIASES = {
  i          = "install",
  add        = "install",
  rm         = "remove",
  uninstall  = "remove",
  ["delete"] = "remove",
  up         = "upgrade",
  ["dist-upgrade"] = "upgrade",
  find       = "search",
  s          = "search",
  info       = "show",
  display    = "show",
  ls         = "list",
  refresh    = "update",
  ["auto-remove"] = "autoremove",
  ["--help"] = "help",
  ["-h"]     = "help",
}

-- ─── Main Entry Point ────────────────────────────────────────────────────────

function pm.main(raw_args)
  raw_args = raw_args or arg or {}

  local all_args, opts = parse_args(raw_args)
  local cmd_name = all_args[1]
  table.remove(all_args, 1)

  if opts.quiet  then ui.quiet   = true end
  if opts.verbose then ui.verbose = true end

  -- Print version
  if opts.version then
    io.write("ljpm "..pm.VERSION.." — LuaJIT Package Manager for LJOS\n")
    return
  end

  -- Default to help
  if not cmd_name then
    commands.help({}, opts)
    return
  end

  -- Resolve alias
  local resolved = ALIASES[cmd_name] or cmd_name
  local fn = commands[resolved]

  if not fn then
    ui.error("Unknown command: '"..cmd_name.."'. Run 'pm help' for usage.")
    os.exit(1)
  end

  local ok = fn(all_args, opts)
  if ok == false then os.exit(1) end
end

-- ─── Shell Integration ────────────────────────────────────────────────────────
-- Registers "pm" as a command in the LJOS core shell.
-- Usage: pm.register_shell(core)
-- Then in core.shell(), add to the dispatch:
--   elseif cmd == "pm" then
--     require("system.pm").register_shell(core); core.pm_dispatch(args)

function pm.register_shell(core)
  -- Attach a dispatch function to core
  core.pm_dispatch = function(words)
    -- words[1] = "pm", words[2] = subcommand, ...
    local sub_args = {}
    for i = 2, #words do sub_args[#sub_args+1] = words[i] end
    pm.main(sub_args)
  end
  ui.debug("ljpm registered with LJOS shell.")
end

return pm
