-- userdb.lua
-- LevelDB 数据库封装工具库
--
-- 【方案配置说明】
-- 本脚本为工具库，不直接在方案中配置，被其他 Lua 脚本引用：
--
-- 引用方式：
--   local userdb = require('lib/userdb')
--   local db = userdb.LevelDb("database_name")
--
-- 主要功能：
--   - LevelDb()                             -- 创建/获取数据库实例
--   - db:fetch(key)                         -- 获取键值
--   - db:update(key, value)                 -- 更新键值
--   - db:erase(key)                         -- 删除键值
--   - db:query(prefix)                      -- 前缀查询
--   - db:meta_fetch(key)                    -- 获取元数据
--   - db:meta_update(key, value)            -- 更新元数据
--
-- 无需在 schema.yaml 中配置，无需识别器

local META_KEY_PREFIX = "\001" .. "/"

-- UserDb 缓存，使用弱引用表，不阻止垃圾回收并能自动清理
local db_pool = setmetatable({}, { __mode = "v" })

---@class WrappedUserDb: UserDb
---@field meta_query fun(self: self, prefix: string): DbAccessor
---@field meta_fetch fun(self: self, key: string): string|nil
---@field meta_update fun(self: self, key: string, value: string): boolean
---@field meta_erase fun(self: self, key: string): boolean
---@field query_with fun(self: self, prefix: string, handler: fun(key: string, value: string))
---@field empty fun(self: self, include_metafield?: boolean) -- 清空数据库

-- 用于存放包装器对象的自定义方法
local extends = {}

--- @param key string
--- @return string|nil
function extends:meta_fetch(key)
  return self._db:fetch(META_KEY_PREFIX .. key)
end

--- @param key string
--- @param value string
--- @return boolean
function extends:meta_update(key, value)
  return self._db:update(META_KEY_PREFIX .. key, value)
end

--- @param key string
--- @return boolean
function extends:meta_erase(key)
  return self._db:erase(META_KEY_PREFIX .. key)
end

--- @param prefix string
--- @return DbAccessor
function extends:meta_query(prefix)
  return self._db:query(META_KEY_PREFIX .. prefix)
end

function extends:query_with(prefix, handler)
  local da = self._db:query(prefix)
  if da then
    for key, value in da:iter() do
      handler(key, value)
    end
  end
  da = nil
  collectgarbage()
end

--- @param include_metafield boolean 是否也清理元数据。
function extends:empty(include_metafield)
  self:query_with("", function(key, _)
    local is_metafield = key:find(META_KEY_PREFIX, 1, true) == 1
    if include_metafield or not is_metafield then
      self._db:erase(key)
    end
  end)
end

local mt = {
  __index = function(wrapper, key)
    -- 优先使用自定义方法
    if extends[key] then
      return extends[key]
    end

    -- 不是自定义方法，委托给真实的 UserDb 对象
    local real_db = wrapper._db
    local value = real_db[key]

    if type(value) == "function" then
      return function(_, ...)
        return value(real_db, ...)
      end
    end

    return value
  end,
}

local userdb = {}

--- @param db_name string
--- @param db_class "userdb" | "plain_userdb" | nil
--- @return WrappedUserDb
function userdb.UserDb(db_name, db_class)
  db_class = db_class or "userdb"
  local key = db_name .. "." .. db_class

  ---@type UserDb
  local db = db_pool[key]
  if not db then
    db = UserDb(db_name, db_class)
    db_pool[key] = db
  end

  local wrapper = {
    _db = db,
    _pool_key = key,
  }

  return setmetatable(wrapper, mt)
end

function userdb.LevelDb(db_name)
  return userdb.UserDb(db_name, "userdb")
end

function userdb.TableDb(db_name)
  return userdb.UserDb(db_name, "plain_userdb")
end

return userdb
