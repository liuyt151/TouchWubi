-- 万象拼音方案新成员：手动自由排序 + 自动词频排序（支持PC端快捷键 + 移动端数字键）
-- 数据存放于 userdb 中，处于性能考量，此排序仅影响当前输入码
--
-- 【PC端快捷键】
--   Ctrl+J  前移当前高亮候选一位
--   Ctrl+K  后移当前高亮候选一位
--   Ctrl+L  重置当前编码的所有调序记录（恢复默认顺序）
--   Ctrl+P  置顶当前高亮候选
--
-- 【移动端数字键】（Trime / Hamster 等，需启用下滑数字）
--   数字键 2-9  前移对应序号的候选（例如 3 将第3候选前移一位）
--   数字键 0    前移第10候选
--   数字键 1    撤销上次调序操作（仅对当前编码有效）
--
-- 【其他命令】（均仅影响当前方案）
--   /txql   调序清理（清除所有调序记录，仅清空 userdb，保留备份文件）
--   /txdc   调序导出（导出调序数据至 sequence_<schema_id>.txt，仅当数据库条目数大于备份时允许覆盖）
--   /txdr   调序导入（从 sequence_<schema_id>.txt 恢复调序数据）
--   /txtj   调序统计（查看所有调序记录，按空格上屏）
--
-- 【方案配置说明】
-- 本脚本包含处理器(P)和过滤器(F、S)，需在 schema.yaml 中添加相应配置：
--
-- engine:
--   processors:
--     - lua_processor@*super_sequence*P       # 处理器：处理 Ctrl+J/K/L/P 及移动端数字键
--   filters:
--     - lua_filter@*super_sequence*F          # 过滤器：应用手动调序记录（调整候选项顺序）
--     - lua_filter@*super_sequence*S          # 过滤器：自动按词频排序（基于 quality 降序，可选）
--
-- key_binder:                                  # 按键绑定配置（可选，仅影响 PC 端 Ctrl 快捷键）
--   sequence:
--     up: "Control+j"                         # 前移
--     down: "Control+k"                       # 后移
--     reset: "Control+l"                      # 重置
--     pin: "Control+p"                        # 置顶
--
-- 无需识别器配置，脚本通过以下方式判断：
--   - 检测 Ctrl 键组合（key_event:ctrl()）
--   - is_function_mode_active() 排除功能模式
--   - 输入 "/txql" 触发清空数据库
--   - 移动端自动检测并启用数字键调序
--
-- 注意：
--   - S 过滤器（自动词频排序）为可选组件，若不需要可省略。
--   - 若同时使用 F 和 S，建议先执行 S（词频排序），再执行 F（手动调序），
--     以确保手动调序覆盖自动排序结果（顺序由 filters 列表顺序决定）。

-- 内部常量定义（从 wanxiang.lua 提取）
local RIME_PROCESS_RESULTS = {
    kRejected = 0, -- 表示处理器明确拒绝了这个按键，停止处理链但不返回 true
    kAccepted = 1, -- 表示处理器成功处理了这个按键，停止处理链并返回 true
    kNoop = 2,     -- 表示处理器没有处理这个按键，继续传递给下一个处理器
}

---判断是否在命令模式（从 wanxiang.lua 提取）
---@param context Context | nil
---@return boolean
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

-- 更可靠的 iOS 检测
local function is_ios_device()
    return os.getenv("HOME") and os.getenv("HOME"):find("/var/mobile/") ~= nil
end

-- 检测是否为移动端（Trime / Hamster / 超越输入法等）
-- 自动检测是否为移动设备（智能平台检测）
-- 支持的输入法：同文(Trime)、仓(Hamster)、超越输入法(Beyond)、鸿蒙系统等
local function is_mobile_device()
    -- 获取路径（支持 rime_api 和回退到环境变量）
    local user_data_dir = ""
    local shared_data_dir = ""
    local dist = ""
    local dist_name = ""

    if rime_api then
        user_data_dir = rime_api.get_user_data_dir() or ""
        shared_data_dir = rime_api.get_shared_data_dir() or ""
        dist = rime_api.get_distribution_code_name() or ""
        dist_name = rime_api.get_distribution_name() or ""
    end

    local lower_dist = dist:lower()
    local dist_name_lower = dist_name:lower()
    local lower_path = user_data_dir:lower()
    local sys_lower_path = shared_data_dir:lower()
    local home = (os.getenv("HOME") or ""):lower()

    -- 1. 已知移动端输入法（distribution_code_name）
    if lower_dist == "trime" or
        lower_dist == "hamster" or
        lower_dist == "hamster3" then
        return true
    end

    -- 2. 超越输入法检测（RimeAPI + /space/ 路径）
    if dist_name_lower == "rimeapi" and
        (lower_path:find("/space/") or sys_lower_path:find("/space/")) then
        return true
    end

    -- 3. 通用移动路径关键词（Android/iOS/macOS）
    local mobile_keywords = {"/android/", "/mobile/", "/sdcard/", "/storage/emulated/",
                             "applications", "library"}
    for _, kw in ipairs(mobile_keywords) do
        if lower_path:find(kw) or sys_lower_path:find(kw) then
            return true
        end
    end

    -- 4. 鸿蒙系统路径特征（HarmonyOS / HarmonyOS NEXT）
    -- 4.1 传统鸿蒙路径标识
    if lower_path:find("/harmony/") or
        lower_path:find("/hap/") or
        lower_path:find("/harmonyos/") or
        lower_path:find("/openharmony/") or
        sys_lower_path:find("/harmony/") or
        sys_lower_path:find("/hap/") then
        return true
    end

    -- 4.2 鸿蒙沙箱存储路径（el数字 是鸿蒙特有，/data/storage/ 是 Android/鸿蒙共有）
    if lower_path:find("/data/storage/el%d+") or
        sys_lower_path:find("/data/storage/el%d+") then
        return true
    end

    -- 4.3 鸿蒙 bundle 路径（应用资源目录）
    if lower_path:find("/bundle/") or sys_lower_path:find("/bundle/") then
        return true
    end

    -- 4.4 鸿蒙用户目录特征（/storage/Users/）
    if lower_path:find("/storage/users/") or
        sys_lower_path:find("/storage/users/") or
        home:find("/storage/users/") then
        return true
    end

    -- 4.5 超越输入法 + 鸿蒙组合检测
    if dist_name_lower == "rimeapi" and
        (lower_path:find("/data/storage/el%d+") or
         lower_path:find("/space/") or
         home:find("/storage/users/")) then
        return true
    end

    -- 5. JIT 平台检测（Android/HarmonyOS）
    if jit and jit.os then
        local os_name = jit.os:lower()
        if os_name:find("android") or os_name:find("harmony") then
            return true
        end
    end

    -- 6. 环境变量检测
    if os.getenv("HMOS") or os.getenv("HARMONYOS") then
        return true
    end

    -- 7. iOS 路径检测
    if home:find("/var/mobile/") then
        return true
    end

    -- 8. HOME 目录回退检测（Android 兜底）
    if home:find("/storage/emulated/") then return true end
    if home:find("/data/data/") then return true end

    return false
end

local MOBILE_MODE = is_mobile_device()

---@type string | nil 当前选中的键，命令模式为 0 开始的位置索引，正常模式为候选词
local cur_adjustment_phrase = nil

---@type integer | nil 当前高亮索引
local cur_highlight_idx = nil

---- `0`: 无调整，默认值
---- `-1`: 前移一位
---- `1`: 后移一位
---- `nil`: 重置/置顶
---@type -1 | 1 | 0 | nil
local cur_adjust_offset = 0

---@type boolean 是否处于 pin 模式
local in_pin_mode = false

---@type integer | nil 数字键置顶的候选索引（1-indexed），nil 表示无待处理置顶
--- 1 = 撤销，2-9/0 = 前移对应候选
local pin_candidate_index = nil

---@type table | nil 上次调序记录 { code, text, from_position }，用于撤销
local last_adjustment = nil

---@type table<string, table> 移动端会话内候选顺序追踪 { [code] = {text1, text2, ...} }
--- 避免 S 排序覆盖手动调序结果
local mobile_candidate_order = {}

-- 按方案存储的导出标记
local _need_export = {}
-- 当前方案ID（用于 fini 时关闭数据库）
local current_schema_id = nil
-- 按方案存储的清空标记（清空后阻止自动导入）
local _cleared_schemas = {}

-- 按方案存储的数据库连接
local _user_dbs = {}

-- 获取方案特定的数据库文件名
local function get_db_file_name(schema_id)
    local base_name = is_ios_device() and
                      (os.getenv("HOME") .. "/Documents/sequence") or
                      "lua/sequence"
    return base_name .. "_" .. schema_id
end

-- 获取方案特定的导出文件名
local function get_export_file_name(schema_id)
    return (rime_api.get_user_data_dir() and (rime_api.get_user_data_dir() .. "/lua/sequence_" .. schema_id .. ".txt") or "lua/sequence_" .. schema_id .. ".txt")
end

local function get_user_db(schema_id)
    if not schema_id then return nil, function() end end
    
    -- 如果数据库连接已存在且正常，直接返回
    if _user_dbs[schema_id] and _user_dbs[schema_id]:loaded() then
        local function close()
            if _user_dbs[schema_id] and _user_dbs[schema_id]:loaded() then
                collectgarbage()
                _user_dbs[schema_id]:close()
            end
        end
        return _user_dbs[schema_id], close
    end
    
    -- 尝试重新打开或创建数据库（最多重试3次）
    local max_retries = 3
    local db = nil
    
    for i = 1, max_retries do
        -- 如果之前的连接存在但未加载，先关闭
        if _user_dbs[schema_id] then
            pcall(function() _user_dbs[schema_id]:close() end)
            _user_dbs[schema_id] = nil
        end
        
        -- 创建新连接
        db = LevelDb(get_db_file_name(schema_id))
        
        if db then
            -- 尝试打开
            local ok, err = pcall(function() db:open() end)
            if ok and db:loaded() then
                _user_dbs[schema_id] = db
                break
            end
        end
        
        -- 重试前稍作等待
        if i < max_retries then
            collectgarbage()
        end
    end
    
    local function close()
        if _user_dbs[schema_id] and _user_dbs[schema_id]:loaded() then
            collectgarbage()
            _user_dbs[schema_id]:close()
        end
    end

    return db, close
end

---@param value string LevelDB 中序列化的值
---@return { to_position: integer, updated_at: integer }
local function parse_adjustment_value(value)
    local result = {}

    local match = value:gmatch("[-.%d]+")
    result.to_position = tonumber(match());
    result.updated_at = tonumber(match());

    return result
end

---@param code string 当前输入码
---@param schema_id string 方案ID
---@return table<string, { to_position: integer, updated_at: integer, from_position?: integer, candidate?: Candidate}> | nil
local function get_adjustment(code, schema_id)
    if code == "" or code == nil then return nil end

    local db = get_user_db(schema_id)
    if not db then return nil end

    local accessor = db:query(code .. "|")
    if accessor == nil then return nil end

    local table = nil
    for key, value in accessor:iter() do
        if table == nil then table = {} end
        local adjustment_key = string.match(key, "^.*|(%S+)$")
        table[adjustment_key] = parse_adjustment_value(value)
    end

    ---@diagnostic disable-next-line: cast-local-type
    accessor = nil

    return table
end

local last_export_date = nil

local function get_today_date()
    local now = os.date("*t")
    return string.format("%04d%02d%02d", now.year, now.month, now.day)
end

local function should_auto_export(schema_id)
    if not _need_export[schema_id] then return false end
    local today = get_today_date()
    if last_export_date ~= today then
        last_export_date = today
        return true
    end
    return false
end

---@param code string 匹配的输入码
---@param adjust_key string | number 匹配键，为候选索引（命令模式），或候选词（普通模式）
---@param to_position integer | nil 目标位置，`nil` 为从数据库中移除该纪录
---@param timestamp? number 操作时间戳，默认去当前时间戳
---@param schema_id? string 方案ID
local function save_adjustment(code, adjust_key, to_position, timestamp, schema_id)
    if code == "" or code == nil then return end

    local db = get_user_db(schema_id)
    if not db then return end
    
    local key = string.format("%s|%s", code, adjust_key)
    local result = false

    if to_position == nil or to_position <= 0 then
        if type(adjust_key) == "number" then
            local user_adjustment = get_adjustment(code, schema_id)

            if user_adjustment == nil then return false end

            ---@type table{key: string, updated_at: number} | nil
            local erase_item = {}
            for db_key, db_value in pairs(user_adjustment) do
                if adjust_key + 1 == db_value.to_position
                    and (erase_item.updated_at == nil
                        or erase_item.updated_at < db_value.updated_at)
                then
                    erase_item.key = db_key
                    erase_item.updated_at = db_value.updated_at
                end
            end

            if erase_item.key ~= nil then
                _need_export[schema_id] = true
                result = db:erase(string.format("%s|%s", code, erase_item.key))
            end

            return result
        else
            _need_export[schema_id] = true
            result = db:erase(key)
        end
    else
        if not timestamp then
            timestamp = rime_api.get_time_ms
                and os.time() + tonumber(string.format("0.%s", rime_api.get_time_ms()))
                or os.time()
        end
        local value = string.format("%s\t%s", to_position, timestamp)
        _need_export[schema_id] = true
        result = db:update(key, value)
    end

    return result
end

---从 context 中获取当前排序匹配码
---@param context Context
---@return string
local function extract_adjustment_code(context)
    if is_function_mode_active(context) then
        return context:get_property("sequence_adjustment_code") or ""
    end

    return context.input:sub(1, context.caret_pos)
end

local function file_exists(name)
    local f = io.open(name, "r")
    return f ~= nil and io.close(f)
end

--- 统计数据库中有效条目数（排除系统元数据键）
---@param db LevelDB
---@return integer
local function count_db_entries(db)
    if not db or not db:loaded() then return 0 end
    local accessor = db:query("")
    if not accessor then return 0 end
    local count = 0
    for key, _ in accessor:iter() do
        if key:sub(1, 1) ~= "\001" then
            count = count + 1
        end
    end
    accessor = nil
    return count
end

--- 统计备份文件中有效条目数（排除注释行和空行，要求包含 tab 分隔符）
---@param schema_id string
---@return integer
local function count_txt_entries(schema_id)
    local filename = get_export_file_name(schema_id)
    if not filename then return 0 end
    local file = io.open(filename, "rb")
    if not file then return 0 end
    local content = file:read("*a")
    file:close()
    if content:sub(1, 3) == "\xef\xbb\xbf" then
        content = content:sub(4)
    end
    local count = 0
    for line in content:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" and line:match("\t") then
            count = count + 1
        end
    end
    return count
end

--- 导出调序数据到文件（返回导出条目数，若失败或被保护拒绝则返回 nil）
---@param db LevelDB
---@param schema_id string
---@return integer | nil
local function export_to_file(db, schema_id)
    -- 如果 schema_id 为 nil，则跳过导出
    if not schema_id then return nil end
    
    -- 如果数据库连接失败，跳过导出
    if not db or not db:loaded() then
        return nil
    end
    
    local sync_file_name = get_export_file_name(schema_id)
    if not sync_file_name then return nil end

    -- 【导出保护】统计备份文件条目数
    local txt_entries = count_txt_entries(schema_id)

    -- 【关键修复】只查询一次数据库，同时用于统计和写入，避免两次查询之间数据库状态变化
    local da = db:query("")
    if not da then return nil end

    -- 统计数据库条目数（同时收集数据）
    local db_entries = 0
    local export_data = {}
    for key, value in da:iter() do
        if key:sub(1, 1) ~= "\001" then
            db_entries = db_entries + 1
            table.insert(export_data, {key = key, value = value})
        end
    end
    da = nil

    -- 【导出保护】如果备份存在且条目数 >= 数据库条目数，则拒绝覆盖
    if txt_entries > 0 and db_entries <= txt_entries then
        return nil
    end

    -- 开始导出，覆盖旧文件，使用二进制模式确保UTF-8 BOM正确写入
    local file = io.open(sync_file_name, "wb")
    if not file then return nil end

    -- 写入 UTF-8 BOM，确保工具能正确识别编码
    file:write("\xef\xbb\xbf")

    -- 获取当前Windows用户名
    local current_username = os.getenv("USERNAME") or "unknown1"

    -- 先写入当前用户ID行（使用 # 作为注释前缀，避免控制字符导致二进制识别）
    file:write(string.format("#/user_id\t%s\n", current_username))

    -- 写入收集的数据
    for _, item in ipairs(export_data) do
        local line = string.format("%s\t%s\n", item.key, item.value)
        file:write(line)
    end

    file:close()
    _need_export[schema_id] = false  -- 重置标记
    return db_entries
end

local function import_from_file(db, schema_id)
    -- 如果 schema_id 为 nil，则跳过导入
    if not schema_id then return false, 0 end
    
    -- 如果数据库连接失败，跳过导入
    if not db or not db:loaded() then
        return false, 0
    end
    
    -- 如果该方案已被清空，跳过自动导入
    if _cleared_schemas[schema_id] then
        return false, 0
    end
    
    local sync_file_name = get_export_file_name(schema_id)
    if not sync_file_name then return false, 0 end

    -- 使用二进制模式读取，处理 UTF-8 BOM
    local file = io.open(sync_file_name, "rb")
    if not file then
        return false, 0
    end

    -- 读取全部内容并处理 BOM
    local content = file:read("*a")
    file:close()
    
    -- 移除 UTF-8 BOM（如果存在）
    if content:sub(1, 3) == "\xef\xbb\xbf" then
        content = content:sub(4)
    end

    local import_count = 0

    -- 按行分割处理
    for line in content:gmatch("[^\r\n]+") do
        if line == "" then goto continue end

        -- 忽略系统元数据行（注释行以 # 开头）
        if line:sub(1, 1) == "#" then goto continue end

        -- 数据处理逻辑（保持不变）
        local key, value = string.match(line, "^(.-)\t(.+)$")
        if key and value then
            local code, phrase = string.match(key, "^(.+)|(.+)$")
            if not code or not phrase then goto continue end

            local info = parse_adjustment_value(value)
            local exist_value = db:fetch(key)
            if exist_value then -- 跳过旧的数据
                local exist_info = parse_adjustment_value(exist_value)
                if info.updated_at <= exist_info.updated_at then
                    goto continue
                end
            end

            import_count = import_count + 1
            save_adjustment(code, phrase, info.to_position, info.updated_at, schema_id)
        end

        ::continue::
    end

    _need_export[schema_id] = true  -- 导入后标记需要导出
    return true, import_count
end

--- 清空数据库
local function clear_database(schema_id)
    local db, close_db = get_user_db(schema_id)
    if not db or not db:loaded() then return end
    
    -- 遍历删除所有键
    local accessor = db:query("")
    if accessor then
        for key, _ in accessor:iter() do
            db:erase(key)
        end
        accessor = nil
    end
    
    close_db()
    
    -- 重新初始化数据库
    _user_dbs[schema_id] = nil
    get_user_db(schema_id)
    
    _need_export[schema_id] = false  -- 清除导出标记，防止退出时导出空数据覆盖备份
    _cleared_schemas[schema_id] = true  -- 设置清空标记，阻止自动导入
end

---执行排序调整
---@param context Context
---@param schema_id string 方案ID
local function process_adjustment(context, schema_id)
    local selected_cand = context:get_selected_candidate()

    if cur_adjust_offset == nil then -- 如果是重置/置顶，直接设置位置
        -- 非索引匹配的情况下，我们可以直接重置，提高效率
        local code = extract_adjustment_code(context)
        local adjustment_key = is_function_mode_active(context)
            and context.composition:back().selected_index
            or selected_cand.text
        save_adjustment(code, adjustment_key, in_pin_mode and 1 or nil, nil, schema_id)
    else -- 否则进入 filter 调整位移
        cur_adjustment_phrase = selected_cand.text
    end

    context:refresh_non_confirmed_composition()

    if context.highlight and cur_highlight_idx and cur_highlight_idx > 0 then
        context:highlight(cur_highlight_idx)
    end
end

local P = {}
function P.init(env)
    local schema_id = env and env.engine and env.engine.schema and env.engine.schema.schema_id
    local db = get_user_db(schema_id)
    import_from_file(db, schema_id)
end

-- P 阶段按键处理
---@param key_event KeyEvent
---@param env Env
---@return ProcessResult
function P.func(key_event, env)
    local context = env.engine.context

    if key_event:release() then
        return RIME_PROCESS_RESULTS.kNoop
    end

    -- 移动端数字键调序（PC端数字正常上屏）
    if MOBILE_MODE and context:has_menu() then
        local input_text = context.input:sub(1, context.caret_pos)
        -- 计算器模式（=开头）不拦截数字键
        if input_text:find("^=") then
            return RIME_PROCESS_RESULTS.kNoop
        end

        local keycode = key_event.keycode

        -- 数字键 1：撤销上次调序（移动端下滑数字）
        if keycode == 0x31 then
            pin_candidate_index = 1  -- 1 表示撤销
            context:refresh_non_confirmed_composition()
            return RIME_PROCESS_RESULTS.kAccepted
        end

        -- 数字键 2-9：有候选菜单时前移对应候选
        if keycode >= 0x32 and keycode <= 0x39 then
            pin_candidate_index = keycode - 0x30  -- 1-indexed
            context:refresh_non_confirmed_composition()
            return RIME_PROCESS_RESULTS.kAccepted
        end

        -- 数字键 0：前移第10候选
        if keycode == 0x30 then
            pin_candidate_index = 10
            context:refresh_non_confirmed_composition()
            return RIME_PROCESS_RESULTS.kAccepted
        end
    end

    if not context:has_menu() then
        return RIME_PROCESS_RESULTS.kNoop
    end

    local selected_cand = context:get_selected_candidate()
    if selected_cand == nil or selected_cand.text == nil then
        return RIME_PROCESS_RESULTS.kNoop
    end

    -- 桌面端：Ctrl+J/K/L/P（保留原有行为）
    if key_event:ctrl() then
        if is_function_mode_active(context)
            and not context:get_property("sequence_adjustment_code")
        then
            return RIME_PROCESS_RESULTS.kNoop
        end

        local kc = key_event.keycode   -- 修复：在此处定义局部变量，避免与移动端 keycode 作用域混淆
        in_pin_mode = kc == 0x70
        if kc == 0x6A then
            cur_adjust_offset = -1
        elseif kc == 0x6B then
            cur_adjust_offset = 1
        elseif kc == 0x6C then
            cur_adjust_offset = nil
        elseif in_pin_mode then
            cur_adjust_offset = nil
        else
            return RIME_PROCESS_RESULTS.kNoop
        end

        if cur_adjust_offset == 0 then
            return RIME_PROCESS_RESULTS.kNoop
        end

        local schema_id = env.engine and env.engine.schema and env.engine.schema.schema_id
        process_adjustment(context, schema_id)
        return RIME_PROCESS_RESULTS.kAccepted
    end

    return RIME_PROCESS_RESULTS.kNoop
end

local F = {}
function F.init() end

function F.fini()
    local schema_id = current_schema_id
    
    if _need_export[schema_id] then
        local db = get_user_db(schema_id)
        export_to_file(db, schema_id)
    end
    
    local _, close_db = get_user_db(schema_id)
    close_db()
    
    cur_adjustment_phrase = nil
    cur_highlight_idx = nil
    cur_adjust_offset = 0
    in_pin_mode = false
    pin_candidate_index = nil
    last_adjustment = nil
    mobile_candidate_order = {}
    current_schema_id = nil
end

---@param input Translation
---@param env Env
function F.func(input, env)
    local context = env.engine.context
    local schema_id = env.engine and env.engine.schema and env.engine.schema.schema_id
    current_schema_id = schema_id
    
    -- 处理清空数据库指令（生成空候选）
    if env.engine.context.input == "/txql" then
        clear_database(schema_id)
        yield(Candidate("clear_db", 0, #context.input, "※ 当前方案调序数据库已清空（备份保留）", ""))
        return
    end
    
    -- 处理手动导出指令（导出到文本文件）
    if env.engine.context.input == "/txdc" then
        local db = get_user_db(schema_id)
        if not db or not db:loaded() then
            yield(Candidate("export_db", 0, #context.input, "※ 导出失败：数据库连接失败", ""))
            return
        end
        
        -- 1. 统计数据库有效条目数
        local accessor = db:query("")
        local db_entries = 0
        if accessor then
            for key, _ in accessor:iter() do
                if key:sub(1, 1) ~= "\001" then
                    db_entries = db_entries + 1
                end
            end
            accessor = nil
        end
        
        -- 2. 统计备份文件条目数
        local txt_entries = count_txt_entries(schema_id)
        
        -- 3. 预先判断保护条件，直接提示（避免依赖 export_to_file 返回值）
        if txt_entries > 0 and db_entries <= txt_entries then
            yield(Candidate("export_db", 0, #context.input, "※ 导出失败：已有有效备份，请先执行 /txdr 恢复", ""))
            return
        end
        
        -- 4. 执行实际导出（此时允许覆盖）
        local count = export_to_file(db, schema_id)
        if count == nil then
            yield(Candidate("export_db", 0, #context.input, "※ 导出失败：未知错误", ""))
        elseif count > 0 then
            yield(Candidate("export_db", 0, #context.input, "※ 成功导出 " .. count .. " 条数据", ""))
        else
            yield(Candidate("export_db", 0, #context.input, "※ 导出失败：当前数据库无调序数据", ""))
        end
        return
    end
    
    -- 处理手动导入指令（从文本文件恢复）
    if env.engine.context.input == "/txdr" then
        local db = get_user_db(schema_id)
        -- 手动导入时临时清除清空标记，允许导入
        local was_cleared = _cleared_schemas[schema_id]
        _cleared_schemas[schema_id] = nil
        
        local success, count = import_from_file(db, schema_id)
        if success and count and count > 0 then
            yield(Candidate("import_db", 0, #context.input, "※ 成功导入 " .. count .. " 条数据", ""))
        elseif success and count == 0 then
            yield(Candidate("import_db", 0, #context.input, "※ 导入（无新记录）", ""))
        else
            -- 导入失败，恢复清空标记
            if was_cleared then
                _cleared_schemas[schema_id] = true
            end
            yield(Candidate("import_db", 0, #context.input, "※ 导入失败：备份不存在或无数据", ""))
        end
        return
    end
    
    -- 处理调序统计指令（查看所有调序数据）
    if env.engine.context.input == "/txtj" then
        local db = get_user_db(schema_id)
        if not db or not db:loaded() then
            yield(Candidate("query_db", 0, #context.input, "※ 调序统计：数据库连接失败", ""))
            return
        end
        
        local all_phrases = {}
        local seen = {}
        
        local accessor = db:query("")
        if accessor then
            for key, _ in accessor:iter() do
                if key:sub(1, 1) ~= "\001" then
                    local phrase = key:match("^.-|(.+)$")
                    if phrase and not seen[phrase] then
                        seen[phrase] = true
                        table.insert(all_phrases, {phrase = phrase, source = "db"})
                    end
                end
            end
            accessor = nil
        end
        
        local sync_file_name = get_export_file_name(schema_id)
        if sync_file_name then
            local file = io.open(sync_file_name, "rb")
            if file then
                local content = file:read("*a")
                file:close()
                if content:sub(1, 3) == "\xef\xbb\xbf" then
                    content = content:sub(4)
                end
                for line in content:gmatch("[^\r\n]+") do
                    if line:sub(1, 1) ~= "#" then
                        local key = string.match(line, "^(.-)\t")
                        if key then
                            local phrase = key:match("^.-|(.+)$")
                            if phrase and not seen[phrase] then
                                seen[phrase] = true
                                table.insert(all_phrases, {phrase = phrase, source = "file"})
                            end
                        end
                    end
                end
            end
        end
        
        local count = #all_phrases
        if count == 0 then
            yield(Candidate("query_db", 0, #context.input, "※ 调序统计：当前无调序数据", ""))
        else
            local lines = {}
            for i, item in ipairs(all_phrases) do
                local tag = item.source == "file" and "〔备份〕" or ""
                table.insert(lines, string.format("%d. %s %s", i, item.phrase, tag))
            end
            local header = "=== 调序统计 ===\n共 " .. count .. " 条记录（含备份）\n------------------------\n"
            local content = header .. table.concat(lines, "\n")
            yield(Candidate("query_db", 0, #context.input, content, "按空格上屏"))
        end
        return
    end
    
    -- 命令模式（/开头）和 z 键反查模式：直接输出所有候选，跳过排序和去重处理
    local input_text = context.input:sub(1, context.caret_pos)
    if input_text:find("^/") or input_text:find("^z") then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 次日第一次打字自动导出调序数据（受保护）
    if should_auto_export(schema_id) then
        local db = get_user_db(schema_id)
        export_to_file(db, schema_id)
    end

    -- 处理数字键调序操作（移动端下滑数字）
    -- pin_candidate_index = 1: 撤销, 2-10: 前移对应候选
    if pin_candidate_index then
        local pin_idx = pin_candidate_index
        pin_candidate_index = nil

        local code = extract_adjustment_code(context)
        local is_func_mode = is_function_mode_active(context)

        -- 收集候选（去重）
        local candidates = {}
        local phrase_count = {}
        for cand in input:iter() do
            local text = cand.text
            phrase_count[text] = (phrase_count[text] or 0) + 1
            if phrase_count[text] == 1 then
                table.insert(candidates, cand)
            end
        end

        -- 应用数据库中已有的全部调序记录
        -- 关键修复：from_position 应该动态计算当前位置，而不是基于原始顺序
        local user_adjustment = get_adjustment(code, schema_id)
        if user_adjustment then
            -- 为每个记录绑定候选
            for pos, cand in ipairs(candidates) do
                local key = is_func_mode and tostring(pos - 1) or cand.text
                if user_adjustment[key] then
                    user_adjustment[key].candidate = cand
                end
            end
            
            -- 按时间排序，逐个应用
            local list = {}
            for _, info in pairs(user_adjustment) do
                if info.candidate then
                    table.insert(list, info)
                end
            end
            table.sort(list, function(a, b) return a.updated_at < b.updated_at end)
            
            -- 逐个应用调序记录，动态计算 from_position
            for _, record in ipairs(list) do
                if record.to_position and record.to_position > 0 then
                    -- 动态查找当前位置
                    local from = nil
                    for pos, cand in ipairs(candidates) do
                        if cand == record.candidate then
                            from = pos
                            break
                        end
                    end
                    
                    if from and from ~= record.to_position then
                        local to = record.to_position
                        table.remove(candidates, from)
                        table.insert(candidates, to, record.candidate)
                    end
                end
            end
        end

        -- 执行数字键移动
        if pin_idx == 1 then
            -- 撤销：恢复上次调序的候选到原位置
            if last_adjustment and last_adjustment.code == code then
                for i, cand in ipairs(candidates) do
                    if cand.text == last_adjustment.text then
                        local moved = table.remove(candidates, i)
                        local target = math.min(last_adjustment.from_position, #candidates + 1)
                        table.insert(candidates, target, moved)
                        -- 保存新位置（实际上恢复）
                        local key = is_func_mode and tostring(target - 1) or moved.text
                        save_adjustment(code, key, target, nil, schema_id)
                        break
                    end
                end
                last_adjustment = nil
            end
        elseif pin_idx >= 2 and pin_idx <= #candidates then
            -- 前移一位：基于当前列表位置
            local moved = table.remove(candidates, pin_idx)
            local new_pos = pin_idx - 1
            table.insert(candidates, new_pos, moved)
            local key = is_func_mode and tostring(new_pos - 1) or moved.text
            save_adjustment(code, key, new_pos, nil, schema_id)
            last_adjustment = { code = code, text = moved.text, from_position = pin_idx }
        end

        -- 更新会话内顺序缓存（用于快速恢复，但本分支已从数据库读取，缓存仅作辅助）
        local new_order = {}
        for _, cand in ipairs(candidates) do
            table.insert(new_order, cand.text)
        end
        mobile_candidate_order[code] = new_order

        -- 输出结果
        for _, cand in ipairs(candidates) do yield(cand) end
        return
    end

    -- 非调序路径：常规候选输出，需应用数据库记录
    -- 清除移动端会话状态（编码变化或上屏后撤销不应再有效）
    mobile_candidate_order = {}
    last_adjustment = nil

    local adjust_code = extract_adjustment_code(context)
    local user_adjustment = get_adjustment(adjust_code, schema_id)

    local has_unsaved_adjustment = cur_adjustment_phrase ~= nil
        and cur_adjust_offset ~= 0
        and cur_adjust_offset ~= nil
        and adjust_code ~= ""

    -- 收集候选（去重）
    local candidates = {}
    local phrase_count = {}
    local dedupe_position = 1
    local cur_candidate = nil
    local cur_raw_index = nil
    local is_func_mode = is_function_mode_active(context)

    for cand in input:iter() do
        local text = cand.text
        phrase_count[text] = (phrase_count[text] or 0) + 1
        if phrase_count[text] == 1 then
            table.insert(candidates, cand)
            if cur_adjustment_phrase == text then
                cur_candidate = cand
                cur_raw_index = dedupe_position - 1
            end
            local adjust_key = is_func_mode and tostring(dedupe_position - 1) or text
            if user_adjustment and user_adjustment[adjust_key] then
                user_adjustment[adjust_key].candidate = cand
            end
            dedupe_position = dedupe_position + 1
        end
    end

    -- 应用数据库中的调序记录（如果有）
    -- 关键修复：动态查找当前位置，而不是使用绑定的 from_position
    if user_adjustment ~= nil then
        local list = {}
        for _, info in pairs(user_adjustment) do
            if info.candidate then
                table.insert(list, info)
            end
        end
        table.sort(list, function(a, b) return a.updated_at < b.updated_at end)
        for _, record in ipairs(list) do
            if record.to_position and record.to_position > 0 then
                -- 动态查找当前位置
                local from = nil
                for pos, cand in ipairs(candidates) do
                    if cand == record.candidate then
                        from = pos
                        break
                    end
                end
                
                if from and from ~= record.to_position then
                    local to = record.to_position
                    table.remove(candidates, from)
                    table.insert(candidates, to, record.candidate)
                end
            end
        end
    end

    -- 应用当前调整（Ctrl+J/K/L/P 产生的）
    if has_unsaved_adjustment then
        local from_position = nil
        for position, cand in ipairs(candidates) do
            if cand.text == cur_adjustment_phrase then
                from_position = position
                break
            end
        end

        if from_position ~= nil then
            local to_position = from_position + cur_adjust_offset
            if to_position < 1 then
                to_position = 1
            elseif to_position > #candidates then
                to_position = #candidates
            end

            if from_position ~= to_position then
                table.remove(candidates, from_position)
                table.insert(candidates, to_position, cur_candidate)
                local adjust_key = is_func_mode and cur_raw_index or cur_adjustment_phrase
                if adjust_key then
                    save_adjustment(adjust_code, adjust_key, to_position, nil, schema_id)
                    cur_highlight_idx = to_position - 1
                end
            end
        end
    end

    -- 更新会话内顺序缓存（用于移动端数字键分支快速读取，但不再依赖它）
    local new_order = {}
    for _, cand in ipairs(candidates) do
        table.insert(new_order, cand.text)
    end
    mobile_candidate_order[adjust_code] = new_order

    -- 输出最终结果
    for _, cand in ipairs(candidates) do
        yield(cand)
    end

    -- 在filter处理完成后重置临时状态
    if has_unsaved_adjustment then
        cur_adjustment_phrase = nil
        cur_highlight_idx = nil
        cur_adjust_offset = 0
        in_pin_mode = false
    end
end

-- ============================================================
-- 自动词频排序（通用版）
-- 适用于任意键位布局（26键、14键、18键等）
-- ============================================================
local MAX_CANDIDATES = 200

local function sorter(input, env)
    local input_text = env.engine.context.input:sub(1, env.engine.context.caret_pos)
    -- 命令模式（/开头）和 z 键反查模式：直接输出所有候选，跳过排序和数量限制
    if input_text:find("^/") or input_text:find("^z") then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end
    
    local input_len = #(env.engine.context.input or "")
    -- 1码时限制候选数量并排序，让常用字排在前面
    local limit = (input_len <= 1) and 25 or MAX_CANDIDATES

    local candidates = {}
    for cand in input:iter() do
        if #candidates >= limit then break end
        table.insert(candidates, cand)
    end
    if #candidates > 1 then
        table.sort(candidates, function(a, b) return (a.quality or 0) > (b.quality or 0) end)
    end
    for _, cand in ipairs(candidates) do yield(cand) end
end

local S = { func = sorter }

return { P = P, F = F, S = S }