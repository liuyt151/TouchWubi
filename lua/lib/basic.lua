-- basic.lua
-- 基础工具函数库
--
-- 【方案配置说明】
-- 本脚本为工具库，不直接在方案中配置，被其他 Lua 脚本引用：
--
-- 引用方式：
--   local basic = require('lib/basic')
--
-- 主要功能：
--   - basic.index(table, item)              -- 查找元素在表中的索引
--   - basic.map(table, func)                -- 对表进行映射操作
--   - basic.matchstr(str, pat)              -- 字符串匹配
--   - basic.utf8chars(str)                  -- 将UTF-8字符串转为字符数组
--
-- 无需在 schema.yaml 中配置，无需识别器

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

local POS_PATTERNS = {
  "^n%.", "^v%.", "^vi%.", "^vt%.",
  "^a%.", "^adj%.", "^ad%.", "^adv%.",
  "^prep%.", "^conj%.", "^int%.", "^pron%.",
  "^num%.", "^art%.", "^abbr%."
}

function basic.is_pos_tag(text)
  for _, pat in ipairs(POS_PATTERNS) do
    if text:match(pat) then return true end
  end
  return false
end

function basic.count_pos_tags(parts)
  local count = 0
  for _, part in ipairs(parts) do
    if basic.is_pos_tag(part) then count = count + 1 end
  end
  return count
end

