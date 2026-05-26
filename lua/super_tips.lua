-- 万象家族lua,超级提示,表情\化学式\方程式\简码等等直接上屏,不占用候选位置
-- 采用leveldb数据库,支持大数据遍历,支持多种类型混合,多种拼音编码混合,维护简单
-- 支持候选匹配和编码匹配两种，候选支持方向键高亮遍历
-- https://github.com/amzxyz/rime_wanxiang
--
-- 【方案配置说明】
-- 本脚本为处理器，需在 schema.yaml 中添加以下配置：
--
-- engine:
--   processors:
--     - lua_processor@*super_tips             # 超级提示处理器
--
-- switches:                                    # 添加开关控制
--   - name: super_tips
--     reset: 0
--     states: [ 关提, 开提 ]
--
-- key_binder:                                  # 上屏按键配置
--   tips_key: "slash"                         # 默认使用 / 键上屏
--
-- tips:                                        # 可选配置
--   disabled_types: []                        # 禁用的 tips 类型
--
-- 数据文件：
--   - lua/tips/tips_show.txt                  # 预设提示数据
--   - lua/tips/tips_user.txt                  # 用户自定义提示（用户目录）
--
-- 无需识别器配置，脚本通过 context:get_option("super_tips") 开关控制
local bit = require("lib/bit")
local userdb = require("lib/userdb")

-- ==================== 独立工具函数（原 wanxiang.lua 依赖）====================

-- RIME 处理结果常量
local RIME_PROCESS_RESULTS = {
    kRejected = 0, -- 表示处理器明确拒绝了这个按键，停止处理链但不返回 true
    kAccepted = 1, -- 表示处理器成功处理了这个按键，停止处理链并返回 true
    kNoop = 2,     -- 表示处理器没有处理这个按键，继续传递给下一个处理器
}

-- 版本号（用于数据库重建判断）
local SUPER_TIPS_VERSION = "v13.9.4"

-- 判断文件是否存在
local function file_exists(filename)
    local f = io.open(filename, "r")
    if f ~= nil then
        io.close(f)
        return true
    else
        return false
    end
end

-- 按照优先顺序获取文件：用户目录 > 系统目录
local function get_filename_with_fallback(filename)
    local _path = filename:gsub("^/+", "") -- 去掉开头的斜杠

    local user_path = rime_api.get_user_data_dir() .. '/' .. _path
    if file_exists(user_path) then
        return user_path
    end

    local shared_path = rime_api.get_shared_data_dir() .. '/' .. _path
    if file_exists(shared_path) then
        return shared_path
    end

    return nil
end

-- 判断是否处于功能模式
local function is_function_mode_active(context)
    if not context or not context.composition or context.composition:empty() then
        return false
    end

    local seg = context.composition:back()
    if not seg then return false end

    return seg:has_tag("number") or  -- number_translator.lua 数字金额转换 R+数字
        seg:has_tag("unicode") or    -- unicode.lua 输出 Unicode 字符 U+小写字母或数字
        seg:has_tag("calculator") or -- super_calculator.lua V键计算器
        seg:has_tag("shijian") or    -- shijian.lua /rq /sr 等与时间日期相关功能
        seg:has_tag("Ndate")         -- shijian.lua N日期功能
end

local tips_db = userdb.LevelDb("lua/tips")

-- 获取文件内容哈希值，使用 FNV-1a 哈希算法
local function calculate_file_hash(filepath)
    local file = io.open(filepath, "rb")
    if not file then return nil end

    -- FNV-1a 哈希参数（32位）
    local FNV_OFFSET_BASIS = 0x811C9DC5
    local FNV_PRIME = 0x01000193

    local hash = FNV_OFFSET_BASIS
    while true do
        local chunk = file:read(4096)
        if not chunk then break end
        for i = 1, #chunk do
            local byte = string.byte(chunk, i)
            hash = bit.bxor(hash, byte)
            hash = (hash * FNV_PRIME) % 0x100000000
            hash = bit.band(hash, 0xFFFFFFFF)
        end
    end

    file:close()
    return string.format("%08x", hash)
end

local tips = {}

---@type "pending" | "initialing" | "done"
tips.status = "pending"

---@type table<string, boolean>
tips.disabled_types = {}
tips.preset_file_path = get_filename_with_fallback("lua/tips/tips_show.txt")
tips.user_override_path = rime_api.get_user_data_dir() .. "/lua/tips/tips_user.txt"

local META_KEY = {
    version = "super_tips_version",
    user_file_hash = "user_tips_file_hash",
    disabled_types = "disabled_types",
}

---@param tip string
function tips.is_disabled(tip)
    local type = tip:match("^(..-):")
        or tip:match("^(..-)：")

    if not type then return false end
    return tips.disabled_types[type] == true
end

function tips.init_db_from_file(path)
    local file = io.open(path, "r")
    if not file then return end

    for line in file:lines() do
        local value, key = line:match("([^\t]+)\t([^\t]+)")
        if key and value
            and not tips.is_disabled(value)
        then
            tips_db:update(key, value)
        end
    end

    file:close()
end

function tips.ensure_dir_exist(dir)
    -- 获取系统路径分隔符
    local sep = package.config:sub(1, 1)

    dir = dir:gsub([["]], [[\"]]) -- 处理双引号

    if sep == "/" then
        local cmd = 'mkdir -p "' .. dir .. '" 2>/dev/null'
        os.execute(cmd)
    end
end

---@param config Config
function tips.init(config)
    if tips.status ~= "pending" then return end

    local dist = rime_api.get_distribution_code_name() or ""
    local user_lua_dir = rime_api.get_user_data_dir() .. "/lua"
    if dist ~= "hamster" and dist ~= "hamster3" and dist ~= "Weasel" then
        tips.ensure_dir_exist(user_lua_dir)
        tips.ensure_dir_exist(user_lua_dir .. "/tips")
    end

    -- 读取配置
    local disabled_types_list = config:get_list("tips/disabled_types")
    if disabled_types_list then
        for i = 1, disabled_types_list.size do
            local item = disabled_types_list:get_value_at(i - 1)
            if item and #item.value > 0 then
                tips.disabled_types[item.value] = true
            end
        end
    end

    -- 检查是否需要重建数据库
    tips_db:open()
    local needs_rebuild = false

    -- 检查 1: super_tips 版本号
    if tips_db:meta_fetch(META_KEY.version) ~= SUPER_TIPS_VERSION then
        needs_rebuild = true
    end

    -- 检查 2: 用户文件哈希 (仅在版本号相同时检查)
    local user_file_hash = calculate_file_hash(tips.user_override_path) or ""
    if not needs_rebuild
        and (tips_db:meta_fetch(META_KEY.user_file_hash) or "") ~= user_file_hash
    then
        needs_rebuild = true
    end

    -- 检查 3: 禁用类型 (仅在前两者都相同时检查)
    local disabled_keys = {}
    for k, _ in pairs(tips.disabled_types) do
        table.insert(disabled_keys, k)
    end
    table.sort(disabled_keys) -- 排序以确保顺序一致
    local disabled_types_str = table.concat(disabled_keys, ",")

    if not needs_rebuild
        and (tips_db:meta_fetch(META_KEY.disabled_types) or "") ~= disabled_types_str
    then
        needs_rebuild = true
    end

    -- 如果需要，则执行重建
    if needs_rebuild then
        tips_db:empty()
        tips.init_db_from_file(tips.preset_file_path)
        tips.init_db_from_file(tips.user_override_path)

        -- 重建成功后，再更新所有元数据，确保操作的原子性
        tips_db:meta_update(META_KEY.version, SUPER_TIPS_VERSION)
        tips_db:meta_update(META_KEY.user_file_hash, user_file_hash)
        tips_db:meta_update(META_KEY.disabled_types, disabled_types_str)
    end

    -- 关闭并以只读模式重新打开
    tips_db:close()
    tips_db:open_read_only()
end

---从数据库中查询 tips
---@param keys string | string[] 接受一个字符串或一个字符串数组作为键，使用数组时会挨个查询，直到获得有效值
---@return string | nil
function tips.get_tip(keys)
    -- 输入归一化：如果输入是 string，将其包装成单元素的 table
    if type(keys) == 'string' then
        keys = { keys }
    end

    for _, key in ipairs(keys) do
        if key and key ~= "" then
            local tip = tips_db:fetch(key)
            if tip and #tip > 0 then
                return tip
            end
        end
    end

    return nil
end

---@class Env
---@field current_tip string | nil 当前 tips 值
---@field last_prompt string 最后一次设置的 prompt 值
---@field tips_update_connection Connection

---tips prompt 处理
---@param context Context
---@param env Env
local function update_tips_prompt(context, env)
    env.current_tip = nil

    local is_tips_enabled = context:get_option("super_tips")
    if not is_tips_enabled then return end

    local segment = context.composition:back()
    if not segment then return end

    local cand = context:get_selected_candidate() or {}

    if segment.selected_index == 0 then
        env.current_tip = tips.get_tip({ context.input, cand.text })
    else
        env.current_tip = tips.get_tip(cand.text)
    end

    if env.current_tip ~= nil and env.current_tip ~= "" then
        -- 有 tips 则直接设置 prompt
        segment.prompt = "〔" .. env.current_tip .. "〕"
        env.last_prompt = segment.prompt
    elseif segment.prompt ~= "" and env.last_prompt == segment.prompt then
        -- 没有 tips，且当前 prompt 不为空，且是由 super_tips 设置的，则重置
        segment.prompt = ""
        env.last_prompt = segment.prompt
    end
end

local P = {}

-- Processor：按键触发上屏 (S)
---@param env Env
function P.init(env)
    local config = env.engine.schema.config
    tips.init(config)

    P.tips_key = config:get_string("key_binder/tips_key")

    -- 注册 tips 查找监听器
    local context = env.engine.context
    env.tips_update_connection = context.update_notifier:connect(
        function(context)
            update_tips_prompt(context, env)
        end
    )
end

function P.fini(env)
    -- 清理连接
    if env.tips_update_connection then
        env.tips_update_connection:disconnect()
        env.tips_update_connection = nil
    end
end

---@param key KeyEvent
---@param env Env
---@return ProcessResult
function P.func(key, env)
    local context = env.engine.context

    local is_tips_enabled = context:get_option("super_tips")
    if not is_tips_enabled then
        return RIME_PROCESS_RESULTS.kNoop
    end

    -- 以下处理 tips 上屏逻辑
    if not P.tips_key                                   -- 未设置上屏键
        or P.tips_key ~= key:repr()                     -- 或者当前按下的不是上屏键
        or is_function_mode_active(context)             -- 或者是功能模式不用上屏
        or not env.current_tip or env.current_tip == "" --  或匹配的 tips 为空/空字符串
    then
        return RIME_PROCESS_RESULTS.kNoop
    end

    ---@type string 从 tips 内容中获取上屏文本
    local commit_txt = env.current_tip:match("：%s*(.*)%s*") -- 优先匹配常规的全角冒号
        or env.current_tip:match(":%s*(.*)%s*") -- 没有匹配则回落到半角冒号

    if commit_txt and #commit_txt > 0 then
        env.engine:commit_text(commit_txt)
        context:clear()
        return RIME_PROCESS_RESULTS.kAccepted
    end

    return RIME_PROCESS_RESULTS.kNoop
end

return P
