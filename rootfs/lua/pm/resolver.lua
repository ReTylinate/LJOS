-- Dependency resolver for ljpm on LJOS
-- Lives at /lua/pm/resolver.lua
-- Pure LuaJIT, no FFI — just table operations and version comparisons.

local ver = require("pm.version")
local ui  = require("pm.ui")

local resolver = {}

-- ─── Install Plan Resolution ──────────────────────────────────────────────────
--
-- @param requests      list of { name=string, constraint=string, required_by=string }
-- @param pkg_index     index.packages table  { [name]: { [version]: manifest } }
-- @param installed_db  db.packages table     { [name]: installed_info }
-- @param opts          { upgrade=bool, force=bool }
--
-- Returns { install=[...], upgrade=[...], skip=[...] }
-- or nil, { errors }

function resolver.resolve(requests, pkg_index, installed_db, opts)
  opts         = opts or {}
  installed_db = installed_db or {}
  pkg_index    = pkg_index or {}

  local to_install = {}
  local to_upgrade = {}
  local to_skip    = {}
  local errors     = {}

  -- What version of each package we'll have after installation
  local will_have = {}
  for name, info in pairs(installed_db) do
    will_have[name] = info.version
  end

  -- BFS queue
  local queue   = {}
  local visited = {}
  for _, req in ipairs(requests) do
    queue[#queue+1] = {
      name        = req.name,
      constraint  = req.constraint or "*",
      required_by = req.required_by or "user",
    }
  end

  local qi = 1
  while qi <= #queue do
    local item = queue[qi]; qi = qi + 1
    local name       = item.name
    local constraint = item.constraint
    local req_by     = item.required_by

    local key = name .. "@" .. constraint
    if visited[key] then goto continue end
    visited[key] = true

    -- Find available versions
    local avail = pkg_index[name]
    if not avail then
      if installed_db[name] then goto continue end  -- installed from elsewhere, skip
      errors[#errors+1] = string.format(
        "Package '%s' not found in registry (required by %s)", name, req_by)
      goto continue
    end

    local vs = {}
    for v in pairs(avail) do vs[#vs+1] = v end

    local best = ver.resolve(vs, constraint)
    if not best then
      errors[#errors+1] = string.format(
        "No version of '%s' satisfies '%s' (required by %s)", name, constraint, req_by)
      goto continue
    end

    local manifest = avail[best]

    -- Check conflicts
    for _, conflict in ipairs(manifest.conflicts or {}) do
      if will_have[conflict] then
        errors[#errors+1] = string.format(
          "'%s' conflicts with installed package '%s'", name, conflict)
        goto continue
      end
    end

    local have = will_have[name]

    if have then
      if ver.eq(have, best) and not opts.reinstall then
        -- Already at the right version
        to_skip[#to_skip+1] = {name=name, version=best}
        goto continue
      elseif opts.upgrade and ver.gt(best, have) then
        will_have[name] = best
        to_upgrade[#to_upgrade+1] = {
          name=name, old_version=have, new_version=best,
          manifest=manifest, reason=req_by,
        }
      elseif ver.lt(best, have) then
        if opts.force then
          will_have[name] = best
          to_upgrade[#to_upgrade+1] = {
            name=name, old_version=have, new_version=best,
            manifest=manifest, reason=req_by, downgrade=true,
          }
        elseif ver.satisfies(have, constraint) then
          to_skip[#to_skip+1] = {name=name, version=have}
          goto continue
        else
          errors[#errors+1] = string.format(
            "Installed '%s' %s doesn't satisfy '%s'. Use --force to downgrade.",
            name, have, constraint)
          goto continue
        end
      else
        -- Installed version satisfies constraint
        to_skip[#to_skip+1] = {name=name, version=have}
        goto continue
      end
    else
      will_have[name] = best
      to_install[#to_install+1] = {
        name=name, version=best, manifest=manifest,
        reason = (req_by == "user") and "manual" or "dependency",
      }
    end

    -- Enqueue dependencies
    for dep_name, dep_constraint in pairs(manifest.dependencies or {}) do
      queue[#queue+1] = {
        name=dep_name, constraint=dep_constraint, required_by=name
      }
    end

    ::continue::
  end

  if #errors > 0 then return nil, errors end

  return {
    install   = resolver.topo_sort(to_install, pkg_index),
    upgrade   = to_upgrade,
    skip      = to_skip,
    will_have = will_have,
  }
end

-- ─── Topological Sort (dependencies before dependents) ───────────────────────

function resolver.topo_sort(packages, pkg_index)
  local by_name = {}
  for _, p in ipairs(packages) do by_name[p.name] = p end

  local order   = {}
  local visited = {}

  local function visit(p)
    if visited[p.name] then return end
    visited[p.name] = true
    for dep in pairs((p.manifest and p.manifest.dependencies) or {}) do
      if by_name[dep] then visit(by_name[dep]) end
    end
    order[#order+1] = p
  end

  for _, p in ipairs(packages) do visit(p) end
  return order
end

-- ─── Remove Plan Resolution ───────────────────────────────────────────────────

function resolver.resolve_remove(names, installed_db, opts)
  opts         = opts or {}
  installed_db = installed_db or {}
  local errors    = {}
  local remove_set = {}

  for _, name in ipairs(names) do
    if not installed_db[name] then
      errors[#errors+1] = "Package '"..name.."' is not installed"
    else
      remove_set[name] = true
    end
  end
  if #errors > 0 then return nil, errors end

  -- Check reverse deps
  if not opts.force then
    for pkg, info in pairs(installed_db) do
      if not remove_set[pkg] then
        for dep in pairs(info.dependencies or {}) do
          if remove_set[dep] then
            errors[#errors+1] = string.format(
              "Cannot remove '%s': '%s' depends on it. Use --force to override.",
              dep, pkg)
          end
        end
      end
    end
  end
  if #errors > 0 then return nil, errors end

  local to_remove = {}
  for name in pairs(remove_set) do
    to_remove[#to_remove+1] = {name=name, version=installed_db[name].version}
  end

  -- Orphan detection (autoremove)
  local orphans = {}
  if opts.autoremove then
    for name, info in pairs(installed_db) do
      if info.install_reason == "dependency" and not remove_set[name] then
        local needed = false
        for other, oinfo in pairs(installed_db) do
          if other ~= name and not remove_set[other] then
            if (oinfo.dependencies or {})[name] then needed=true; break end
          end
        end
        if not needed then
          orphans[#orphans+1] = {name=name, version=info.version}
        end
      end
    end
  end

  return {remove=to_remove, orphans=orphans}
end

-- ─── Find Upgradeable Packages ────────────────────────────────────────────────

function resolver.find_upgrades(installed_db, pkg_index)
  local ups = {}
  for name, info in pairs(installed_db) do
    local avail = pkg_index[name]
    if avail then
      local vs = {}
      for v in pairs(avail) do vs[#vs+1] = v end
      local best = ver.resolve(vs, "*")
      if best and ver.gt(best, info.version) then
        ups[#ups+1] = {
          name=name, old_version=info.version, new_version=best,
          manifest=avail[best],
        }
      end
    end
  end
  table.sort(ups, function(a,b) return a.name < b.name end)
  return ups
end

return resolver
