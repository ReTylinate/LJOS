-- Terminal UI for ljpm on LJOS
-- Pure LuaJIT — no FFI, no ncurses.
-- Color support is detected from TERM env var.
-- Lives at /lua/pm/ui.lua

local ui = {}

-- ─── Color Support ───────────────────────────────────────────────────────────

local TERM = os.getenv("TERM") or ""
local HAS_COLOR = (TERM ~= "" and TERM ~= "dumb")

-- Override with env vars
if os.getenv("NO_COLOR") then HAS_COLOR = false end
if os.getenv("FORCE_COLOR") then HAS_COLOR = true end

local C = {
  reset   = "\27[0m",
  bold    = "\27[1m",
  dim     = "\27[2m",
  red     = "\27[31m",
  green   = "\27[32m",
  yellow  = "\27[33m",
  blue    = "\27[34m",
  magenta = "\27[35m",
  cyan    = "\27[36m",
  white   = "\27[37m",
  gray    = "\27[90m",
}

function ui.color(name, text)
  if not HAS_COLOR then return text end
  return (C[name] or "") .. text .. C.reset
end

local function c(name, text) return ui.color(name, text) end

-- ─── Flags ───────────────────────────────────────────────────────────────────

ui.quiet    = false
ui.verbose  = false

-- ─── Term Width ──────────────────────────────────────────────────────────────

local _width = nil
function ui.width()
  if _width then return _width end
  -- Try reading from stty (busybox has stty)
  local p = io.popen("stty size 2>/dev/null")
  if p then
    local out = p:read("*l")
    p:close()
    if out then
      local _, cols = out:match("^(%d+)%s+(%d+)$")
      if cols then _width = tonumber(cols) end
    end
  end
  return _width or 80
end

-- ─── Print Helpers ───────────────────────────────────────────────────────────

function ui.info(msg)
  if not ui.quiet then
    io.write(c("blue", "  Info") .. " " .. tostring(msg) .. "\n")
    io.flush()
  end
end

function ui.ok(msg)
  if not ui.quiet then
    io.write(c("green", "    OK") .. " " .. tostring(msg) .. "\n")
    io.flush()
  end
end

function ui.warn(msg)
  io.write(c("yellow", "  Warn") .. " " .. tostring(msg) .. "\n")
  io.flush()
end

function ui.error(msg)
  io.stderr:write(c("red", " Error") .. " " .. tostring(msg) .. "\n")
  io.stderr:flush()
end

function ui.fatal(msg, code)
  ui.error(msg)
  os.exit(code or 1)
end

function ui.debug(msg)
  if ui.verbose then
    io.write(c("gray", " Debug") .. " " .. tostring(msg) .. "\n")
    io.flush()
  end
end

function ui.section(title)
  if ui.quiet then return end
  local w = ui.width()
  local line = string.rep("─", math.max(1, w - #title - 2))
  io.write("\n" .. c("bold", title) .. " " .. c("dim", line) .. "\n")
  io.flush()
end

-- ─── Prompts ─────────────────────────────────────────────────────────────────

function ui.confirm(msg, default)
  local hint = (default == true) and "[Y/n]" or (default == false) and "[y/N]" or "[y/n]"
  io.write(c("yellow", "?") .. " " .. msg .. " " .. hint .. " ")
  io.flush()
  local line = (io.read("*l") or ""):lower():match("^%s*(.-)%s*$")
  if line == "" then return default end
  return line == "y" or line == "yes"
end

-- ─── Progress Bar ────────────────────────────────────────────────────────────

function ui.progress(label, done, total, width)
  if ui.quiet then return end
  width = width or 28
  local frac   = (total and total > 0) and (done/total) or 0
  local filled = math.floor(frac * width)
  local empty  = width - filled
  local bar    = c("green",  string.rep("█", filled)) ..
                 c("dim",    string.rep("░", empty))
  local pct    = string.format("%3d%%", math.floor(frac*100))
  io.write(string.format("\r[%s] %s %s  ", bar, pct, label or ""))
  io.flush()
  if done and total and done >= total then io.write("\n") end
end

-- ─── Spinner ─────────────────────────────────────────────────────────────────

local SPIN_FRAMES = {"⠋","⠙","⠹","⠸","⠼","⠴","⠦","⠧","⠇","⠏"}
local _spin_i = 1

function ui.spin(msg)
  if ui.quiet then return end
  io.write("\r" .. c("cyan", SPIN_FRAMES[_spin_i]) .. " " .. tostring(msg) .. "   ")
  io.flush()
  _spin_i = _spin_i % #SPIN_FRAMES + 1
end

function ui.spin_done(msg)
  if ui.quiet then return end
  io.write("\r" .. c("green", "✓") .. " " .. tostring(msg) .. "   \n")
  io.flush()
end

-- ─── Package Table ───────────────────────────────────────────────────────────

function ui.pkg_table(pkgs, opts)
  opts = opts or {}
  if #pkgs == 0 then ui.info("No packages."); return end

  local w    = ui.width()
  local NW   = 24
  local VW   = 14
  local DW   = math.max(20, w - NW - VW - 6)

  if not opts.no_header then
    local hdr = string.format("%-"..NW.."s  %-"..VW.."s  %s", "Package", "Version", "Description")
    io.write(c("bold", hdr) .. "\n" .. c("dim", string.rep("─", math.min(w, #hdr))) .. "\n")
  end

  for _, p in ipairs(pkgs) do
    local mark = ""
    if p.upgradeable then mark = c("yellow","[upgrade] ")
    elseif p.installed then mark = c("green", "[installed] ") end

    io.write(string.format("%-"..NW.."s  %-"..VW.."s  %s%s\n",
      c("bold", (p.name    or ""):sub(1,NW)),
      c("cyan", (p.version or ""):sub(1,VW)),
      mark,
      (p.description or ""):sub(1,DW)
    ))
  end
  io.flush()
end

-- ─── Package Info Block ──────────────────────────────────────────────────────

function ui.pkg_info(manifest, installed)
  local function field(label, value)
    if value and value ~= "" then
      io.write(c("bold", string.format("%-18s", label..":")) .. " " .. tostring(value) .. "\n")
    end
  end
  field("Package",     manifest.name)
  field("Version",     manifest.version)
  field("Description", manifest.description)
  field("Author",      manifest.author)
  field("License",     manifest.license)
  field("Homepage",    manifest.homepage)
  field("LuaJIT min", manifest.luajit_min)

  if installed then
    field("Status",    c("green","installed"))
    field("Installed", installed.installed_at)
    field("Reason",    installed.install_reason)
  else
    field("Status",    c("dim","not installed"))
  end

  local deps = manifest.dependencies or {}
  if next(deps) then
    local parts = {}
    for k,v in pairs(deps) do parts[#parts+1] = k.."("..v..")" end
    field("Depends",  table.concat(parts,", "))
  end

  local conflicts = manifest.conflicts or {}
  if #conflicts > 0 then
    field("Conflicts", table.concat(conflicts, ", "))
  end

  if manifest.size and manifest.size > 0 then
    field("Size", ui.fmt_size(manifest.size))
  end
  io.flush()
end

-- ─── Transaction Summary ─────────────────────────────────────────────────────

function ui.summary(install, remove, upgrade)
  install = install or {}
  remove  = remove  or {}
  upgrade = upgrade or {}

  if #install > 0 then
    ui.section("Packages to install ("..#install..")")
    for _, p in ipairs(install) do
      io.write("  " .. c("green","+ ") .. c("bold",p.name) .. " " .. c("cyan",p.version or "") .. "\n")
    end
  end
  if #upgrade > 0 then
    ui.section("Packages to upgrade ("..#upgrade..")")
    for _, p in ipairs(upgrade) do
      io.write("  " .. c("yellow","↑ ") .. c("bold",p.name) ..
        " " .. c("dim",p.old_version) .. " → " .. c("cyan",p.new_version) .. "\n")
    end
  end
  if #remove > 0 then
    ui.section("Packages to remove ("..#remove..")")
    for _, p in ipairs(remove) do
      io.write("  " .. c("red","- ") .. c("bold",p.name) .. " " .. c("dim",p.version or "") .. "\n")
    end
  end
  io.write("\n")

  local parts = {}
  if #install > 0 then parts[#parts+1] = c("green",  #install.." to install") end
  if #upgrade > 0 then parts[#parts+1] = c("yellow", #upgrade.." to upgrade") end
  if #remove  > 0 then parts[#parts+1] = c("red",    #remove .." to remove")  end
  if #parts > 0 then
    io.write("Summary: " .. table.concat(parts, ", ") .. "\n\n")
  end
  io.flush()
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

function ui.fmt_size(bytes)
  if not bytes then return "?" end
  if bytes < 1024     then return bytes.." B" end
  if bytes < 1048576  then return string.format("%.1f KiB", bytes/1024) end
  if bytes < 1073741824 then return string.format("%.1f MiB", bytes/1048576) end
  return string.format("%.2f GiB", bytes/1073741824)
end

function ui.hr()
  io.write(c("dim", string.rep("─", ui.width())) .. "\n")
  io.flush()
end

return ui
