-- Mugen OBS Titlebars v1.8.3 BETA (Windows 11 / OBS 32-33)
-- Copyright (c) 2026 MrSoichi / Mugen Art Lab
-- SPDX-License-Identifier: MIT
-- Full license text: LICENSE (distributed alongside this script)
-- Auto matches the applied OBS menu palette after Settings closes; saved
-- user.ini is a fallback because OBS 33 can leave a stale style ID on disk.
-- Colors come from OBS .obt/.ovt files; manual override remains available.
-- Optional LIVE preview follows visible menu pixels even before Apply/OK.
-- Screen sampling requires two consistent matches and retains last-good color
-- if other windows cover the menu. No synchronous OBS frontend callbacks.
-- Avoids a possible GUI/Lua mutex deadlock during Qt theme changes.
local obs = obslua
local ffi = require("ffi")

ffi.cdef[[
typedef void *HWND;
typedef void *HANDLE;
typedef void *HDC;
typedef struct { long x; long y; } POINT;
typedef struct { long left, top, right, bottom; } RECT;
typedef unsigned long DWORD;
typedef int BOOL;
typedef long long LPARAM;
typedef struct { DWORD dwLowDateTime; DWORD dwHighDateTime; } FILETIME;
typedef struct {
  DWORD dwFileAttributes;
  FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime;
  DWORD nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
  char cFileName[260], cAlternateFileName[14];
} WIN32_FIND_DATAA;
typedef BOOL (__stdcall *WNDENUMPROC)(HWND, LPARAM);
DWORD __stdcall GetCurrentProcessId(void);
BOOL __stdcall GetUserPreferredUILanguages(DWORD flags, DWORD *num_languages,
  unsigned short *language_buffer, DWORD *buffer_length);
BOOL __stdcall EnumWindows(WNDENUMPROC callback, LPARAM parameter);
DWORD __stdcall GetWindowThreadProcessId(HWND hwnd, DWORD *pid);
BOOL __stdcall IsWindowVisible(HWND hwnd);
BOOL __stdcall IsIconic(HWND hwnd);
BOOL __stdcall IsWindowEnabled(HWND hwnd);
long __stdcall GetWindowLongW(HWND hwnd, int index);
HWND __stdcall GetWindow(HWND hwnd, unsigned int command);
BOOL __stdcall GetClientRect(HWND hwnd, RECT *rect);
BOOL __stdcall GetWindowRect(HWND hwnd, RECT *rect);
BOOL __stdcall ClientToScreen(HWND hwnd, POINT *point);
HDC __stdcall GetDC(HWND hwnd);
int __stdcall ReleaseDC(HWND hwnd, HDC hdc);
DWORD __stdcall GetModuleFileNameA(void *module, char *filename, DWORD size);
HANDLE __stdcall FindFirstFileA(const char *pattern, WIN32_FIND_DATAA *data);
BOOL __stdcall FindNextFileA(HANDLE h, WIN32_FIND_DATAA *data);
BOOL __stdcall FindClose(HANDLE h);
DWORD __stdcall GetPixel(HDC hdc, int x, int y);
int __stdcall DwmSetWindowAttribute(HWND hwnd, DWORD attribute, const void *value, DWORD value_size);
]]

local kernel32 = ffi.load("kernel32")
local user32 = ffi.load("user32")
local dwmapi = ffi.load("dwmapi")
local gdi32 = ffi.load("gdi32")
local process_id = kernel32.GetCurrentProcessId()
local invalid_handle = ffi.cast("HANDLE", -1)
local DWMWA_CAPTION_COLOR, DWMWA_TEXT_COLOR = 35, 36
local POLL_MS, REFRESH_TICKS = 500, 60
local DWORD_SIZE = ffi.sizeof("DWORD")
local default_color = ffi.new("DWORD[1]", 0xFFFFFFFF)

local enabled = true
local color_mode = "auto"
local manual_caption, manual_text = "#1D1F26", "#E0E2EA"
local extra_theme_directory = ""
local custom_user_ini_path = ""
local ui_language_choice = "auto"
local show_advanced = false
local cached_theme_id = nil
local preview_last = nil
local preview_hits = 0
local preview_status = "not active"
local preview_sample = "none"
local preview_good = nil
local catalog, catalog_dirty = {}, true
local painted, errors = {}, {}
local current_style, current_key, counter = nil, "", 0
local last_notice = ""

local function log_once(message, _level)
  -- Avoid OBS script logging on its graphics-thread timer.
  if last_notice ~= message then last_notice = message end
end

local function colorref(hex)
  if type(hex) ~= "string" then return nil end
  local r, g, b = hex:match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then return nil end
  return tonumber(b, 16) * 65536 + tonumber(g, 16) * 256 + tonumber(r, 16)
end

local function parse_color(raw, vars, depth)
  if not raw or depth > 12 then return nil end
  raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
  local alias = raw:match("^var%s*%(%s*%-%-([%w_]+)%s*%)$")
  if alias then return parse_color(vars[alias], vars, depth + 1) end
  local hex = raw:match("^(#%x%x%x%x%x%x)$")
  if hex then return hex:upper() end
  local r, g, b = raw:match("^rgb%s*%(%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*%)$")
  r, g, b = tonumber(r), tonumber(g), tonumber(b)
  if r and g and b and r <= 255 and g <= 255 and b <= 255 then
    return string.format("#%02X%02X%02X", r, g, b)
  end
  return nil
end

local function theme_paths()
  local directories = {}
  local seen = {}
  local function add(path)
    if path and path ~= "" then
      path = path:gsub("[/\\]+$", "")
      local key = path:lower()
      if not seen[key] then
        directories[#directories + 1] = path
        seen[key] = true
      end
    end
  end
  local executable = ffi.new("char[4096]")
  local size = kernel32.GetModuleFileNameA(nil, executable, 4096)
  if size > 0 and size < 4096 then
    local exe = ffi.string(executable, size)
    local bin = exe:match("^(.*)[/\\][^/\\]+$")
    if bin then
      local root = bin:gsub("[/\\]bin[/\\]64bit$", ""):gsub("[/\\]bin[/\\]32bit$", "")
      add(root .. "\\data\\obs-studio\\themes")
    end
  end
  for _, name in ipairs({"ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"}) do
    local root = os.getenv(name)
    if root then add(root .. "\\obs-studio\\data\\obs-studio\\themes") end
  end
  local appdata = os.getenv("APPDATA")
  if appdata then add(appdata .. "\\obs-studio\\themes") end
  add(extra_theme_directory)
  return directories
end

local function read_theme(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  if not contents or #contents > 1024 * 1024 then return nil end
  contents = contents:gsub("/%*.-%*/", "")
  local meta = contents:match("@OBSThemeMeta%s*%{(.-)%}")
  if not meta then return nil end
  local function field(name)
    return meta:match(name .. "%s*:%s*['\"]([^'\"]+)['\"]")
  end
  local id = field("id")
  if not id or id == "" then return nil end
  local vars = {}
  local body = contents:match("@OBSThemeVars%s*%{(.-)%}")
  if body then
    for key, raw in body:gmatch("%-%-([%w_]+)%s*:%s*(.-)%s*;") do
      vars[key] = raw
    end
  end
  local dark = field("dark")
  local is_dark = nil
  if dark == "true" then is_dark = true
  elseif dark == "false" then is_dark = false end
  return {id = id, extends = field("extends"), dark = is_dark, vars = vars}
end

local function rebuild_catalog()
  local next_catalog = {}
  for _, directory in ipairs(theme_paths()) do
    local data = ffi.new("WIN32_FIND_DATAA[1]")
    local handle = kernel32.FindFirstFileA(directory .. "\\*", data)
    if handle ~= invalid_handle then
      repeat
        local name = ffi.string(data[0].cFileName)
        if name:lower():match("%.o[bv]t$") and not name:match("^%.") then
          local def = read_theme(directory .. "\\" .. name)
          -- Like OBS, first matching theme ID wins (bundled themes before user themes).
          if def and not next_catalog[def.id] then next_catalog[def.id] = def end
        end
      until kernel32.FindNextFileA(handle, data) == 0
      kernel32.FindClose(handle)
    end
  end
  catalog = next_catalog
  catalog_dirty = false
end

local function resolve_theme(id, stack)
  local entry = catalog[id]
  if not entry or stack[id] then return nil end
  stack[id] = true
  local vars = {}
  if entry.extends then
    local ancestor = resolve_theme(entry.extends, stack)
    if not ancestor then return nil end
    for name, val in pairs(ancestor.vars) do vars[name] = val end
  end
  for name, val in pairs(entry.vars) do vars[name] = val end
  stack[id] = nil
  return {vars = vars, dark = entry.dark, id = id}
end

-- Resolve this OBS instance's own user.ini once. Portable mode stores its
-- config beside the executable root, NOT in the installed OBS AppData folder.
-- In particular, if a portable marker exists but user.ini does not yet exist,
-- never silently read another OBS installation's config.
local automatic_user_ini_path, automatic_config_source = nil, nil

local function exists_file(path)
  local handle = io.open(path, "rb")
  if not handle then return false end
  handle:close()
  return true
end

local function resolve_user_ini_path()
  -- Explicit UI override always wins, including for portable installations.
  if custom_user_ini_path ~= "" then return custom_user_ini_path, "override" end
  if automatic_config_source then
    return automatic_user_ini_path, automatic_config_source
  end

  local executable = ffi.new("char[4096]")
  local size = kernel32.GetModuleFileNameA(nil, executable, 4096)
  if size > 0 and size < 4096 then
    local exe = ffi.string(executable, size)
    local bin = exe:match("^(.*)[/\\][^/\\]+$")
    local root = bin and (bin:match("^(.*)[/\\]bin[/\\]64bit$") or
      bin:match("^(.*)[/\\]bin[/\\]32bit$"))
    if root then
      local portable_ini = root .. "\\config\\obs-studio\\user.ini"
      local markers = {
        "portable_mode", "portable_mode.txt",
        "obs_portable_mode", "obs_portable_mode.txt"
      }
      local portable = exists_file(portable_ini) -- also supports --portable
      for _, marker in ipairs(markers) do
        if exists_file(root .. "\\" .. marker) then
          portable = true
          break
        end
      end
      if portable then
        automatic_user_ini_path, automatic_config_source = portable_ini, "portable"
        return automatic_user_ini_path, automatic_config_source
      end
    end
  end

  local appdata = os.getenv("APPDATA")
  automatic_user_ini_path =
    appdata and (appdata .. "\\obs-studio\\user.ini") or nil
  automatic_config_source = "installed"
  return automatic_user_ini_path, automatic_config_source
end

local function selected_theme_id()
  -- Disk-only: do not lock live OBS settings from a graphics-thread callback.
  local path = resolve_user_ini_path()
  if not path then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local section, found = "", nil
  for line in f:lines() do
    line = line:gsub("^\239\187\191", ""):gsub("^%s+", "")
    local header = line:match("^%[([^%]]+)%]")
    if header then
      section = header
    elseif section == "Appearance" then
      local value = line:match("^Theme%s*=%s*(.-)%s*$")
      if value then
        found = value:gsub('^"(.*)"$', "%1")
        break
      end
    end
  end
  f:close()
  return (found and found ~= "") and found or "com.obsproject.Yami.Original"
end

-- Experimental live preview: read three *visible screen* pixels from the blank
-- right-hand part of the OBS main menu bar. Yami paints QMenuBar with --bg_window.
-- Windows GetPixel/ClientToScreen read existing pixels/coordinates; they do not
-- SendMessage/WM_GETTEXT to the OBS GUI thread. Obscured/hidden bars are ignored.
local function main_window()
  local selected, largest = nil, 0
  local callback = ffi.cast("WNDENUMPROC", function(hwnd, _)
    local pid = ffi.new("DWORD[1]")
    user32.GetWindowThreadProcessId(hwnd, pid)
    if pid[0] ~= process_id or user32.IsWindowVisible(hwnd) == 0 or
       user32.IsIconic(hwnd) ~= 0 then return 1 end
    if bit.band(user32.GetWindowLongW(hwnd, -16), 0x00C00000) ~= 0x00C00000 then
      return 1
    end
    -- Prefer top-level main window; owned dialogs should never be sampled.
    if tonumber(ffi.cast("uintptr_t", user32.GetWindow(hwnd, 4))) ~= 0 then
      return 1
    end
    local rect = ffi.new("RECT[1]")
    if user32.GetClientRect(hwnd, rect) == 0 then return 1 end
    local w = tonumber(rect[0].right - rect[0].left)
    local h = tonumber(rect[0].bottom - rect[0].top)
    if w >= 760 and h >= 360 and w * h > largest then
      largest, selected = w * h, hwnd
    end
    return 1
  end)
  user32.EnumWindows(callback, 0)
  callback:free()
  return selected
end

local function rgb_distance(a, b)
  local d = math.abs(bit.band(a, 255) - bit.band(b, 255))
  d = d + math.abs(bit.band(bit.rshift(a, 8), 255) - bit.band(bit.rshift(b, 8), 255))
  return d + math.abs(bit.band(bit.rshift(a, 16), 255) - bit.band(bit.rshift(b, 16), 255))
end

-- Check z-order before sampling: a different app can cover OBS' menu with
-- pixels that coincidentally match a known theme. EnumWindows enumerates
-- top-level windows in z-order; rectangles are a conservative occlusion test.
-- Neither EnumWindows nor GetWindowRect sends WM_GETTEXT to OBS' GUI thread.
local function menu_is_covered(main_hwnd, x_points, y)
  local covered = false
  local found_main = false
  local callback = ffi.cast("WNDENUMPROC", function(hwnd, _)
    if hwnd == main_hwnd then
      found_main = true
      return 0
    end
    if user32.IsWindowVisible(hwnd) == 0 or user32.IsIconic(hwnd) ~= 0 then
      return 1
    end
    local r = ffi.new("RECT[1]")
    if user32.GetWindowRect(hwnd, r) ~= 0 then
      for _, x in ipairs(x_points) do
        if x >= r[0].left and x < r[0].right and
           y >= r[0].top and y < r[0].bottom then
          covered = true
          return 0
        end
      end
    end
    return 1
  end)
  user32.EnumWindows(callback, 0)
  callback:free()
  -- Fail closed if we could not determine the OBS main window's z-position.
  return covered or not found_main
end

local function retain_preview(reason)
  -- A missing/obscured sample does NOT imply a theme change. Keep the
  -- last confirmed live style (including when an app covers the menu).
  preview_last, preview_hits = nil, 0
  if preview_good then
    preview_status = reason .. "; retaining " .. preview_good.id
  else
    preview_status = reason .. "; no visual match yet, using saved theme"
  end
  return preview_good
end

local function visible_menu_color(require_main_enabled)
  local hwnd = main_window()
  if not hwnd then return nil, "main OBS window not visible or too small" end
  -- OBS Settings runs as a modal QDialog and disables the main window.
  -- AUTO waits until it closes; unsaved appearance previews are not applied.
  -- IsWindowEnabled is a nonblocking Win32 state query, not SendMessage.
  if require_main_enabled and user32.IsWindowEnabled(hwnd) == 0 then
    return nil, "OBS modal dialog open; wait for close before auto matching"
  end
  local rect = ffi.new("RECT[1]")
  local origin = ffi.new("POINT[1]")
  if user32.GetClientRect(hwnd, rect) == 0 or user32.ClientToScreen(hwnd, origin) == 0 then
    return nil, "cannot map OBS menu coordinates"
  end
  local width = tonumber(rect[0].right - rect[0].left)
  local x0, y0 = tonumber(origin[0].x), tonumber(origin[0].y)
  -- Menu is the first ~20-25 px of the client region; use a blank area far
  -- to the right of File/Edit/View/Help. Do not sample the native title bar.
  local y = y0 + 10
  local x_points = {}
  for i, fraction in ipairs({0.74, 0.84, 0.94}) do
    x_points[i] = x0 + math.floor(width * fraction)
  end
  -- Avoid reading even one pixel from a foreign overlapping window.
  if menu_is_covered(hwnd, x_points, y) then
    return nil, "menu sampling points covered by another window"
  end
  local dc = user32.GetDC(nil)
  if dc == nil then return nil, "screen device context unavailable" end
  local values = {}
  for i, x in ipairs(x_points) do
    values[i] = tonumber(gdi32.GetPixel(dc, x, y))
  end
  user32.ReleaseDC(nil, dc)
  for i = 1, 3 do
    if not values[i] or values[i] == 0xFFFFFFFF then
      return nil, "screen pixel unavailable"
    end
  end
  if rgb_distance(values[1], values[2]) > 4 or
     rgb_distance(values[2], values[3]) > 4 then
    return nil, "menu sampling points disagree (occluded or decorated)"
  end
  return values[2], "screen color sampled"
end

local function detect_live_preview(require_main_enabled)
  local pixel, explanation = visible_menu_color(require_main_enabled)
  if not pixel then
    return retain_preview(explanation)
  end
  preview_sample = string.format("#%02X%02X%02X",
    bit.band(pixel, 255), bit.band(bit.rshift(pixel, 8), 255),
    bit.band(bit.rshift(pixel, 16), 255))
  local best, best_score, tied = nil, 999, false
  for id in pairs(catalog) do
    local theme = resolve_theme(id, {})
    if theme then
      local bg = parse_color(theme.vars.palette_window or theme.vars.bg_window, theme.vars, 0)
      local fg = parse_color(theme.vars.palette_windowText or theme.vars.text, theme.vars, 0)
      local caption, lettering = colorref(bg), colorref(fg)
      if caption and lettering then
        local score = rgb_distance(pixel, caption)
        if score < best_score then
          best_score, best, tied = score,
            {caption = caption, text = lettering, label = id .. ": " .. bg .. " / " .. fg, id = id}, false
        elseif score == best_score and best and
               (best.caption ~= caption or best.text ~= lettering) then
          tied = true
        end
      end
    end
  end
  if not best or best_score > 8 or tied then
    return retain_preview("no unique theme palette match for " .. preview_sample)
  end
  local key = string.format("%06X:%06X", best.caption, best.text)
  if key == preview_last then
    preview_hits = math.min(preview_hits + 1, 3)
  else
    preview_last, preview_hits = key, 1
  end
  if preview_hits < 2 then
    preview_status = "confirming " .. best.id ..
      (preview_good and "; retaining " .. preview_good.id or "; using saved theme")
    return preview_good
  end
  best.label = (color_mode == "auto" and "AUTO " or "LIVE ") .. best.label
  preview_good = best
  preview_status = "matched " .. best.id .. " (" .. preview_sample .. ")"
  return preview_good
end

local function detect_style()
  if color_mode == "manual" then
    local caption, text = colorref(manual_caption), colorref(manual_text)
    if not caption or not text then
      log_once("Invalid manual color; use #RRGGBB.", obs.LOG_WARNING)
      return nil
    end
    return {caption = caption, text = text, label = "manual"}
  end
  if catalog_dirty then rebuild_catalog() end
  -- AUTO also uses the occlusion-safe palette matcher, but it refuses to
  -- read pixels while a modal OBS dialog is open. OBS 33.0.2 can leave
  -- Appearance/Theme stale after returning to its initial style (Yami Default).
  -- Reconcile only after closing Settings; fall back to saved user.ini if
  -- there is no confirmed screen match yet.
  if color_mode == "preview" or color_mode == "auto" then
    local matched = detect_live_preview(color_mode == "auto")
    if matched then return matched end
  end
  local saved_id = cached_theme_id
  if not saved_id then
    log_once("Cannot read saved OBS user.ini; use Manual mode or provide config path.", obs.LOG_WARNING)
    return nil
  end
  local resolved = resolve_theme(saved_id, {})
  if not resolved then
    log_once("Theme files not found for " .. saved_id .. "; use Manual mode.", obs.LOG_WARNING)
    return nil
  end
  local bg = parse_color(resolved.vars.palette_window or resolved.vars.bg_window, resolved.vars, 0)
  local fg = parse_color(resolved.vars.palette_windowText or resolved.vars.text, resolved.vars, 0)
  local caption, text = colorref(bg), colorref(fg)
  if caption and text then
    return {caption = caption, text = text, label = resolved.id .. ": " .. bg .. " / " .. fg}
  end
  log_once("No solid window/text palette in theme " .. resolved.id .. "; use Manual mode.", obs.LOG_WARNING)
  return nil
end

local function set_caption(hwnd, style)
  local bg = ffi.new("DWORD[1]", style and style.caption or 0xFFFFFFFF)
  local fg = ffi.new("DWORD[1]", style and style.text or 0xFFFFFFFF)
  local a = dwmapi.DwmSetWindowAttribute(hwnd, DWMWA_CAPTION_COLOR, bg, DWORD_SIZE)
  local b = dwmapi.DwmSetWindowAttribute(hwnd, DWMWA_TEXT_COLOR, fg, DWORD_SIZE)
  return a, b
end

local function enumerate_windows(style, reset, force)
  local present = {}
  local callback = ffi.cast("WNDENUMPROC", function(hwnd, _)
    local owner = ffi.new("DWORD[1]", 0)
    user32.GetWindowThreadProcessId(hwnd, owner)
    if owner[0] ~= process_id or user32.IsWindowVisible(hwnd) == 0 then return 1 end
    -- Nonblocking inspection of WS_CAPTION; no SendMessage to window thread.
    if bit.band(user32.GetWindowLongW(hwnd, -16), 0x00C00000) ~= 0x00C00000 then
      return 1
    end
    local key = tostring(hwnd)
    present[key] = true
    if not reset and not force and painted[key] == current_key then return 1 end
    if reset and not painted[key] then return 1 end
    local ok, a, b = pcall(set_caption, hwnd, style)
    if ok and a == 0 and b == 0 then
      if reset then painted[key] = nil else painted[key] = current_key end
      errors[key] = nil
    elseif not errors[key] then
      local description = ok and string.format("DWM failed: 0x%08X / 0x%08X",
          tonumber(ffi.cast("uint32_t", a)), tonumber(ffi.cast("uint32_t", b))) or tostring(a)
      log_once(description)
      errors[key] = true
    end
    return 1
  end)
  local ok = user32.EnumWindows(callback, 0)
  callback:free()
  if ok == 0 then log_once("EnumWindows failed.", obs.LOG_WARNING) end
  for key in pairs(painted) do if not present[key] then painted[key] = nil end end
  for key in pairs(errors) do if not present[key] then errors[key] = nil end end
end

local function update_style()
  if not enabled then return end
  local next_style = detect_style()
  local next_key = next_style and
     (string.format("%06X:%06X", next_style.caption, next_style.text)) or "system"
  if next_key ~= current_key then
    if not next_style then enumerate_windows(nil, true, false) end
    current_style, current_key = next_style, next_key
    if next_style then log_once("Applied " .. next_style.label, obs.LOG_INFO) end
  end
end

local function tick()
  if not enabled then return end
  counter = counter + 1
  if counter % 2 == 1 then cached_theme_id = selected_theme_id() end
  update_style()
  if current_style then
    enumerate_windows(current_style, false, counter % REFRESH_TICKS == 0)
  end
end

-- All translation work happens only in UI callbacks, never inside the timer.
-- The interface language follows OBS [General]/Language in saved user.ini.
-- Missing/unsupported language values fall back to English.
local strings = {
  en = {
    enabled = "Enable Mugen OBS Titlebars",
    language = "Interface language",
    language_auto = "Follow OBS",
    language_en = "English",
    language_ru = "Русский",
    mode = "Color mode",
    mode_saved = "Automatic (after closing Settings)",
    mode_preview = "Live preview (experimental)",
    mode_manual = "Manual colors",
    manual_group = "Manual colors",
    caption = "Title bar color (#RRGGBB)",
    text = "Title text color (#RRGGBB)",
    advanced_switch = "Show advanced settings",
    advanced_group = "Advanced settings and diagnostics",
    theme_folder = "Additional theme folder (optional)",
    user_ini = "OBS user.ini override (optional)",
    log_status = "Write diagnostics to script log",
    palette_test = "Test Yami palette parser"
  },
  ru = {
    enabled = "Включить Mugen OBS Titlebars",
    language = "Язык интерфейса",
    language_auto = "Как в OBS",
    language_en = "English",
    language_ru = "Русский",
    mode = "Режим цвета",
    mode_saved = "Автоматически (после закрытия настроек)",
    mode_preview = "Живой предпросмотр (эксперимент)",
    mode_manual = "Свои цвета",
    manual_group = "Ручная настройка цветов",
    caption = "Цвет заголовка (#RRGGBB)",
    text = "Цвет текста заголовка (#RRGGBB)",
    advanced_switch = "Показать дополнительные настройки",
    advanced_group = "Дополнительные настройки и диагностика",
    theme_folder = "Дополнительная папка тем (необязательно)",
    user_ini = "Другой путь к OBS user.ini (необязательно)",
    log_status = "Записать диагностику в журнал",
    palette_test = "Проверить палитры Yami"
  }
}

-- OBS 33 uses [General]/Language when explicitly set. If absent, OBS
-- calls GetUserPreferredUILanguages(MUI_LANGUAGE_NAME), then picks the first
-- matching installed OBS locale. Support RU directly; other locales use EN UI.
-- Called from UI/description only, never in the 500 ms graphics-thread timer.
local function windows_preferred_language()
  local count, size = ffi.new("DWORD[1]"), ffi.new("DWORD[1]")
  local ok = kernel32.GetUserPreferredUILanguages(0x8, count, nil, size)
  local chars = tonumber(size[0])
  if ok == 0 or chars < 2 or chars > 4096 then return "en" end
  local buffer = ffi.new("unsigned short[?]", chars)
  if kernel32.GetUserPreferredUILanguages(0x8, count, buffer, size) == 0 then
    return "en"
  end
  -- The preferred language names are UTF-16 MULTI_SZ. Locale prefixes are
  -- ASCII, so the first nonempty locale can be inspected without conversion.
  local prefix = ""
  for i = 0, math.min(7, chars - 1) do
    local c = tonumber(buffer[i])
    if c == 0 then break end
    if c > 127 then return "en" end
    prefix = prefix .. string.char(c)
  end
  return prefix:lower():match("^ru[%-%_]") and "ru" or "en"
end

local function obs_language_on_disk()
  local path = resolve_user_ini_path()
  if not path then return nil end
  local file = io.open(path, "rb")
  if not file then return nil end
  local section, lang = "", nil
  for line in file:lines() do
    line = line:gsub("^\239\187\191", ""):gsub("^%s+", "")
    local header = line:match("^%[([^%]]+)%]")
    if header then
      section = header
    elseif section == "General" then
      local value = line:match("^Language%s*=%s*(.-)%s*$")
      if value and value ~= "" then
        lang = value:gsub('^"(.*)"$', "%1")
        break
      end
    end
  end
  file:close()
  if not lang or lang == "" then return nil end
  return lang:lower():match("^ru[%-%_]") and "ru" or "en"
end

local function interface_language()
  if ui_language_choice == "ru" then return "ru" end
  if ui_language_choice == "en" then return "en" end
  return obs_language_on_disk() or windows_preferred_language()
end

local function label(key)
  local lang = interface_language()
  return strings[lang][key] or strings.en[key] or key
end

-- Update labels and group visibility immediately when language/mode changes.
-- The controls retain their settings keys; only their presentation changes.
local function refresh_ui(props, _property, settings)
  ui_language_choice = obs.obs_data_get_string(settings, "language")
  local mode = obs.obs_data_get_string(settings, "mode")
  local advanced = obs.obs_data_get_bool(settings, "show_advanced")
  local function set_label(parent, name, key)
    local p = obs.obs_properties_get(parent, name)
    if p then obs.obs_property_set_description(p, label(key)) end
    return p
  end
  set_label(props, "enabled", "enabled")
  local language_prop = set_label(props, "language", "language")
  if language_prop then
    -- Rebuild dropdown items as well as the label when language changes.
    -- The stored values auto/en/ru are stable; only their captions change.
    obs.obs_property_list_clear(language_prop)
    obs.obs_property_list_add_string(language_prop, label("language_auto"), "auto")
    obs.obs_property_list_add_string(language_prop, label("language_en"), "en")
    obs.obs_property_list_add_string(language_prop, label("language_ru"), "ru")
  end
  local mode_prop = set_label(props, "mode", "mode")
  if mode_prop then
    obs.obs_property_list_clear(mode_prop)
    obs.obs_property_list_add_string(mode_prop, label("mode_saved"), "auto")
    obs.obs_property_list_add_string(mode_prop, label("mode_preview"), "preview")
    obs.obs_property_list_add_string(mode_prop, label("mode_manual"), "manual")
  end
  local manual_prop = set_label(props, "manual_group", "manual_group")
  if manual_prop then
    obs.obs_property_set_visible(manual_prop, mode == "manual")
    local group = obs.obs_property_group_content(manual_prop)
    set_label(group, "caption", "caption")
    set_label(group, "text", "text")
  end
  set_label(props, "show_advanced", "advanced_switch")
  local advanced_prop = set_label(props, "advanced_group", "advanced_group")
  if advanced_prop then
    obs.obs_property_set_visible(advanced_prop, advanced)
    local group = obs.obs_property_group_content(advanced_prop)
    set_label(group, "theme_folder", "theme_folder")
    set_label(group, "user_ini", "user_ini")
    set_label(group, "log_status", "log_status")
    set_label(group, "palette_test", "palette_test")
  end
  return true
end

function script_description()
  -- OBS caches the description on Lua load. Qt supports safe external
  -- links here and OBS asks the user before opening http(s) URLs.
  -- Keep it short and language-neutral; the settings labels localize live.
  return "<b>Mugen OBS Titlebars v1.8.3 BETA</b><br>" ..
         "For OBS Studio 32–33 | Windows 11<br>" ..
         "<a href=\"https://mugenartlab.com\">Made by Mugen Art Lab</a>"
end

local function log_status_button(_properties, _property)
  local config_file, config_source = resolve_user_ini_path()
  obs.script_log(obs.LOG_INFO, "OBS config: " .. tostring(config_file) ..
    " | Source: " .. tostring(config_source) ..
    " | Exists: " .. tostring(config_file and exists_file(config_file)))
  obs.script_log(obs.LOG_INFO, "Mugen Titlebars v1.8.3: " .. (last_notice ~= "" and last_notice or "No status yet"))
  obs.script_log(obs.LOG_INFO, "Saved theme: " .. tostring(cached_theme_id) ..
    " | Mode: " .. tostring(color_mode) .. " | Sampled menu: " .. tostring(preview_sample))
  obs.script_log(obs.LOG_INFO, "Visual matching: " .. tostring(preview_status))
  obs.script_log(obs.LOG_INFO, "Last confirmed screen theme: " ..
    tostring(preview_good and preview_good.id or "none"))
  return false
end

-- The real Lua parser/resolver is tested on installed Yami files on user click.
local function palette_selftest_button(_properties, _property)
  if catalog_dirty then rebuild_catalog() end
  local expected = {
    {"com.obsproject.Yami.Original", "#1D1F26", "#FFFFFF"},
    {"com.obsproject.Yami.Classic", "#3A393A", "#FFFFFF"},
    {"com.obsproject.Yami.Light", "#D3D3D3", "#0A0A0A"},
    {"com.obsproject.Yami.Rachni", "#31363B", "#FFFFFF"},
    {"com.obsproject.Yami.Grey", "#212121", "#FFFFFF"},
    {"com.obsproject.Yami.Acri", "#101010", "#FFFFFF"}
  }
  local good, failed = 0, 0
  for _, row in ipairs(expected) do
    local theme = resolve_theme(row[1], {})
    local bg, fg = nil, nil
    if theme then
      bg = parse_color(theme.vars.palette_window or theme.vars.bg_window, theme.vars, 0)
      fg = parse_color(theme.vars.palette_windowText or theme.vars.text, theme.vars, 0)
    end
    if bg == row[2] and fg == row[3] then
      good = good + 1
      obs.script_log(obs.LOG_INFO, "Mugen palette PASS " .. row[1] .. ": " .. bg .. " / " .. fg)
    else
      failed = failed + 1
      obs.script_log(obs.LOG_WARNING, "Mugen palette FAIL " .. row[1] ..
        " expected " .. row[2] .. "/" .. row[3] ..
        ", got " .. tostring(bg) .. "/" .. tostring(fg))
    end
  end
  obs.script_log(obs.LOG_INFO,
    "Mugen palette self-test: " .. good .. " PASS, " .. failed .. " FAIL. " ..
    "This tests installed Yami files and the actual Lua parser, not screen sampling.")
  return false
end

function script_defaults(settings)
  obs.obs_data_set_default_bool(settings, "enabled", true)
  obs.obs_data_set_default_string(settings, "mode", "auto")
  obs.obs_data_set_default_string(settings, "language", "auto")
  obs.obs_data_set_default_bool(settings, "show_advanced", false)
  obs.obs_data_set_default_string(settings, "caption", "#1D1F26")
  obs.obs_data_set_default_string(settings, "text", "#E0E2EA")
  obs.obs_data_set_default_string(settings, "theme_folder", "")
  obs.obs_data_set_default_string(settings, "user_ini", "")
end

function script_properties()
  local props = obs.obs_properties_create()
  obs.obs_properties_add_bool(props, "enabled", label("enabled"))

  local language = obs.obs_properties_add_list(props, "language", label("language"),
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(language, label("language_auto"), "auto")
  obs.obs_property_list_add_string(language, "English", "en")
  obs.obs_property_list_add_string(language, "Русский", "ru")
  obs.obs_property_set_modified_callback(language, refresh_ui)

  local mode = obs.obs_properties_add_list(props, "mode", label("mode"),
    obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
  obs.obs_property_list_add_string(mode, label("mode_saved"), "auto")
  obs.obs_property_list_add_string(mode, label("mode_preview"), "preview")
  obs.obs_property_list_add_string(mode, label("mode_manual"), "manual")
  obs.obs_property_set_modified_callback(mode, refresh_ui)

  local manual_props = obs.obs_properties_create()
  obs.obs_properties_add_text(manual_props, "caption", label("caption"), obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text(manual_props, "text", label("text"), obs.OBS_TEXT_DEFAULT)
  local manual = obs.obs_properties_add_group(props, "manual_group", label("manual_group"),
    obs.OBS_GROUP_NORMAL, manual_props)
  obs.obs_property_set_visible(manual, color_mode == "manual")

  local advanced_toggle = obs.obs_properties_add_bool(props, "show_advanced", label("advanced_switch"))
  obs.obs_property_set_modified_callback(advanced_toggle, refresh_ui)

  local advanced_props = obs.obs_properties_create()
  obs.obs_properties_add_text(advanced_props, "theme_folder", label("theme_folder"), obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text(advanced_props, "user_ini", label("user_ini"), obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_button(advanced_props, "log_status", label("log_status"), log_status_button)
  obs.obs_properties_add_button(advanced_props, "palette_test", label("palette_test"), palette_selftest_button)
  local advanced = obs.obs_properties_add_group(props, "advanced_group", label("advanced_group"),
    obs.OBS_GROUP_NORMAL, advanced_props)
  obs.obs_property_set_visible(advanced, show_advanced)

  return props
end

function script_update(settings)
  ui_language_choice = obs.obs_data_get_string(settings, "language")
  show_advanced = obs.obs_data_get_bool(settings, "show_advanced")
  local new_enabled = obs.obs_data_get_bool(settings, "enabled")
  local updated_mode = obs.obs_data_get_string(settings, "mode")
  if updated_mode ~= color_mode then
    preview_last, preview_hits, preview_good = nil, 0, nil
    preview_status = "mode changed"
  end
  color_mode = updated_mode
  manual_caption = obs.obs_data_get_string(settings, "caption")
  manual_text = obs.obs_data_get_string(settings, "text")
  local folder = obs.obs_data_get_string(settings, "theme_folder")
  if folder ~= extra_theme_directory then
    extra_theme_directory = folder
    catalog_dirty = true
  end
  custom_user_ini_path = obs.obs_data_get_string(settings, "user_ini")
  if not new_enabled then
    enabled = false
    enumerate_windows(nil, true, false)
    current_style, current_key = nil, ""
    preview_last, preview_hits, preview_good = nil, 0, nil
    log_once("Disabled; restored Windows title bars.", obs.LOG_INFO)
  else
    enabled = true
    -- Timer will asynchronously apply changed options; never enumerate from script_update.
  end
end

function script_load(settings)
  obs.timer_add(tick, POLL_MS)
end

function script_unload()
  obs.timer_remove(tick)
  enumerate_windows(nil, true, false)
  obs.script_log(obs.LOG_INFO, "Mugen Titlebars: unloaded; restored Windows defaults.")
end
