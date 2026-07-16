-- basic.lua

local basic = {}
package.loaded[...] = basic

function basic.index(table, item)
  for k, v in pairs(table) do
    if v == item then return k end
  end
end

function basic.map(table, func)
  local t = {}
  for k, v in pairs(table) do
    t[k] = func(v)
  end
  return t
end

function basic.matchstr(str, pat)
  local t = {}
  for i in str:gmatch(pat) do
    t[#t + 1] = i
  end
  return t
end

function basic.utf8chars(str, ...)
  local chars = {}
  for pos, code in utf8.codes(str) do
    chars[#chars + 1] = utf8.char(code)
  end
  return chars
end

function basic.utf8sub(str, first, ...)
  local last = ...
  if last == nil or last > utf8.len(str) then
    last = utf8.len(str)
  elseif last < 0 then
    last = utf8.len(str) + 1 + last
  end
  local fstoff = utf8.offset(str, first)
  local lstoff = utf8.offset(str, last + 1)
  if fstoff == nil then fstoff = 1 end
  if lstoff ~= nil then lstoff = lstoff - 1 end
  return string.sub(str, fstoff, lstoff)
end

function basic.is_ios_device()
  local home = os.getenv("HOME") or ""
  return home:find("/var/mobile/", 1, true) ~= nil
end

function basic.get_user_data_dir()
  if rime_api and rime_api.get_user_data_dir then
    local dir = rime_api.get_user_data_dir()
    if dir and dir ~= "" then return dir end
  end
  local home = os.getenv("HOME") or ""
  if home ~= "" then
    if basic.is_ios_device() then
      return home .. "/Documents"
    else
      return home .. "/.config/fcitx/rime"
    end
  end
  return "."
end

local log_dir_created = false

function basic.get_log_file_path(filename)
  local log_dir = basic.get_user_data_dir() .. "/log/"
  if not log_dir_created then
    local test_file = log_dir .. ".test"
    local f = io.open(test_file, "w")
    if not f then
      local sep = package.config:sub(1, 1)
      if sep == "\\" then
        os.execute('cmd /c mkdir "' .. log_dir .. '"')
      else
        os.execute("mkdir -p " .. log_dir)
      end
    else
      f:close()
      os.remove(test_file)
    end
    log_dir_created = true
  end
  return log_dir .. filename
end