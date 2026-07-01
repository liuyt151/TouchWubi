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
-- 【其他命令】
--   /txql   清除所有调序记录（清空整个数据库）
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

---判断是否处于造词模式（mkst，反引号引导）
---造词模式下 context.input 包含反引号分隔符（如 `amwu`amwu`），
---而手动调序数据库的 key 是纯字母编码（如 amwu），需要剥离反引号才能匹配。
---@param context Context | nil
---@return boolean
local function is_mkst_mode(context)
    if not context or not context.composition or context.composition:empty() then
        return false
    end
    local seg = context.composition:back()
    if not seg then return false end
    return seg:has_tag("mkst")
end

---从 mkst 模式的输入中提取当前正在编辑的单字纯字母编码。
---mkst 输入格式为 "编码1`编码2`..." 或 "`编码1`编码2" 等，
---需要根据 caret_pos 定位当前编辑位置，提取光标所在段的纯字母编码。
---@param input string context.input 的子串（到 caret_pos 为止）
---@return string 纯小写字母编码
local function extract_mkst_code(input)
    if not input or input == "" then return "" end
    -- 去除所有反引号，得到纯字母串
    -- mkst 的编码段之间用反引号分隔，当前段的编码即 caret_pos 所在段的字母部分
    local cleaned = input:gsub("`", "")
    -- 仅保留小写字母
    return cleaned:match("^[a-z]*") or cleaned
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

-- 添加一个标记，用于跟踪是否需要导出
local need_export = false

-- 💡适配iOS的路径
-- local db_file_name = is_ios_device() and
--                      (os.getenv("HOME") .. "/Documents/sequence") or
--                      "lua/sequence"
--👇修改了数据库的数据，存放在lua目录下
local db_file_name = is_ios_device() and
                     (os.getenv("HOME") .. "/Documents/sequence") or
                     "lua/sequence"  -- 数据库存放在lua目录下

                     local _user_db = nil

-- 获取或创建 LevelDb 实例，避免重复打开
local function get_user_db()
    _user_db = _user_db or LevelDb(db_file_name)

    local function close()
        if _user_db:loaded() then
            collectgarbage()
            _user_db:close()
        end
    end

    if _user_db and not _user_db:loaded() then
        _user_db:open()
    end

    return _user_db, close
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
---@return table<string, { to_position: integer, updated_at: integer, from_position?: integer, candidate?: Candidate}> | nil
local function get_adjustment(code)
    if code == "" or code == nil then return nil end

    local db = get_user_db()

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

---@param code string 匹配的输入码
---@param adjust_key string | number 匹配键，为候选索引（命令模式），或候选词（普通模式）
---@param to_position integer | nil 目标位置，`nil` 为从数据库中移除该纪录
---@param timestamp? number 操作时间戳，默认去当前时间戳
local function save_adjustment(code, adjust_key, to_position, timestamp)
    if code == "" or code == nil then return end

    local db = get_user_db()
    local key = string.format("%s|%s", code, adjust_key)

    if to_position == nil or to_position <= 0 then
        if type(adjust_key) == "number" then
            -- 遍历目标位置，去最后一个再此位置的项重置
            local user_adjustment = get_adjustment(code)

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
                need_export = true
                return db:erase(string.format("%s|%s", code, erase_item.key))
            end

            return false
        else
            need_export = true
            return db:erase(key)
        end
    end

    -- 由于 lua os.time() 的精度只到秒，排序可能会引起问题
    if not timestamp then
        timestamp = rime_api.get_time_ms
            and os.time() + tonumber(string.format("0.%s", rime_api.get_time_ms()))
            or os.time()
    end
    local value = string.format("%s\t%s", to_position, timestamp)
    need_export = true
    return db:update(key, value)
end

---从 context 中获取当前排序匹配码
---造词模式（mkst）下，输入含反引号分隔符，需剥离反引号提取纯字母编码，
---以便与数据库中存储的纯编码 key（如 "amwu|黄"）匹配。
---@param context Context
---@return string
local function extract_adjustment_code(context)
    if is_function_mode_active(context) then
        return context:get_property("sequence_adjustment_code") or ""
    end

    local raw_input = context.input:sub(1, context.caret_pos)

    -- 造词模式：剥离反引号，提取纯字母编码
    if is_mkst_mode(context) then
        return extract_mkst_code(raw_input)
    end

    return raw_input
end

-- 💡导入导出文件使用标准位置（方便用户访问）
-- local sync_file_name = rime_api.get_user_data_dir() .. "/lua/sequence.txt"
--修改导出文件到用户文件夹
local sync_file_name = nil  -- 设置为 nil 禁用文本导出功能

local function file_exists(name)
    local f = io.open(name, "r")
    return f ~= nil and io.close(f)
end

local function export_to_file(db)
    -- 如果 sync_file_name 为 nil，则跳过导出
    if not sync_file_name then return end

    -- 总是导出，覆盖旧文件
    local file = io.open(sync_file_name, "w")
    if not file then return end

    -- 获取当前Windows用户名
    local current_username = os.getenv("USERNAME") or "unknown1"

    ---@type nil | DbAccessor
    local da = db:query("")
    if not da then
        file:close()
        return
    end

    -- 先写入当前用户ID行
    file:write(string.format("%s\t%s\n", "\001/user_id", current_username))

    for key, value in da:iter() do
        -- 跳过原/user_id行避免重复写入
        if key ~= "\001/user_id" then
            local line = string.format("%s\t%s\n", key, value)
            file:write(line)
        end
    end

    log.info(string.format("[super_sequence] 已导出排序数据至文件 %s", sync_file_name))
    file:close()
    need_export = false  -- 重置标记
end

local function import_from_file(db)
    -- 如果 sync_file_name 为 nil，则跳过导入
    if not sync_file_name then return end

    local file = io.open(sync_file_name, "r")
    if not file then
        log.info("[super_sequence] 未找到排序数据文件，跳过导入")
        return
    end

    local import_count = 0

    for line in file:lines() do
        if line == "" then goto continue end

        -- 忽略系统元数据行
        if line:sub(1, 2) == "\001" .. "/" then goto continue end

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
            save_adjustment(code, phrase, info.to_position, info.updated_at)
        end

        ::continue::
    end

    log.info(string.format("[super_sequence] 自动导入排序数据 %s 条", import_count))
    file:close()
    need_export = true  -- 导入后标记需要导出
end

--- 清空数据库
local function clear_database()
    local db, close_db = get_user_db()
    
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
    _user_db = nil
    get_user_db()
    
    log.info("[super_sequence] 已清空手动调序数据库")
    need_export = true  -- 标记需要导出
end

---执行排序调整
---@param context Context
local function process_adjustment(context)
    local selected_cand = context:get_selected_candidate()

    if cur_adjust_offset == nil then -- 如果是重置/置顶，直接设置位置
        -- 非索引匹配的情况下，我们可以直接重置，提高效率
        local code = extract_adjustment_code(context)
        local adjustment_key = is_function_mode_active(context)
            and context.composition:back().selected_index
            or selected_cand.text
        save_adjustment(code, adjustment_key, in_pin_mode and 1 or nil)
    else -- 否则进入 filter 调整位移
        cur_adjustment_phrase = selected_cand.text
    end

    context:refresh_non_confirmed_composition()

    if context.highlight and cur_highlight_idx and cur_highlight_idx > 0 then
        context:highlight(cur_highlight_idx)
    end
end

local P = {}
function P.init()
    local db = get_user_db()
    import_from_file(db)
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
            log.warning(string.format("[sequence] 暂不支持当前指令的手动排序"))
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

        process_adjustment(context)
        return RIME_PROCESS_RESULTS.kAccepted
    end

    return RIME_PROCESS_RESULTS.kNoop
end

local F = {}
function F.init() end

function F.fini()
    local db, db_close = get_user_db()
    if need_export then
        export_to_file(db)
    end
    db_close()
end

---@param input Translation
---@param env Env
function F.func(input, env)
    local context = env.engine.context
    -- 处理清空数据库指令（生成空候选）
    if env.engine.context.input == "/txql" then
        clear_database()
        yield(Candidate("clear_db", 0, #context.input, "※ 手动调序数据库已清空", ""))
        return
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
        local user_adjustment = get_adjustment(code)
        if user_adjustment then
            -- 为每个记录绑定候选及其当前原始位置
            for pos, cand in ipairs(candidates) do
                local key = is_func_mode and tostring(pos - 1) or cand.text
                if user_adjustment[key] then
                    user_adjustment[key].candidate = cand
                    user_adjustment[key].from_position = pos
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
            for _, record in ipairs(list) do
                if record.from_position and record.from_position ~= record.to_position then
                    local from = record.from_position
                    local to = record.to_position
                    table.remove(candidates, from)
                    table.insert(candidates, to, record.candidate)
                    -- 修正其他记录的 from_position（因为数组移位）
                    for _, r in ipairs(list) do
                        if r.from_position then
                            local minp = math.min(from, to)
                            local maxp = math.max(from, to)
                            if minp <= r.from_position and r.from_position <= maxp then
                                r.from_position = r.from_position + (to < from and 1 or -1)
                            end
                        end
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
                        save_adjustment(code, key, target)
                        break
                    end
                end
                last_adjustment = nil
            end
        elseif pin_idx >= 2 and pin_idx <= #candidates then
            -- 前移一位
            local moved = table.remove(candidates, pin_idx)
            local new_pos = pin_idx - 1
            table.insert(candidates, new_pos, moved)
            local key = is_func_mode and tostring(new_pos - 1) or moved.text
            save_adjustment(code, key, new_pos)
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
    local user_adjustment = get_adjustment(adjust_code)

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
                user_adjustment[adjust_key].from_position = dedupe_position
            end
            dedupe_position = dedupe_position + 1
        end
    end

    -- 应用数据库中的调序记录（如果有）
    if user_adjustment ~= nil then
        local list = {}
        for _, info in pairs(user_adjustment) do
            if info.candidate then
                table.insert(list, info)
            end
        end
        table.sort(list, function(a, b) return a.updated_at < b.updated_at end)
        for _, record in ipairs(list) do
            if record.from_position and record.from_position ~= record.to_position then
                local from = record.from_position
                local to = record.to_position
                table.remove(candidates, from)
                table.insert(candidates, to, record.candidate)
                -- 修正其他记录的 from_position
                for _, r in ipairs(list) do
                    if r.from_position then
                        local minp = math.min(from, to)
                        local maxp = math.max(from, to)
                        if minp <= r.from_position and r.from_position <= maxp then
                            r.from_position = r.from_position + (to < from and 1 or -1)
                        end
                    end
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
                    save_adjustment(adjust_code, adjust_key, to_position)
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
    local input_len = #(env.engine.context.input or "")
    -- 1码时仅限制候选数量，不排序（简码候选无需排序，用户会继续输入第二码）
    local limit = (input_len <= 1) and 50 or MAX_CANDIDATES

    local candidates = {}
    for cand in input:iter() do
        if #candidates >= limit then break end
        table.insert(candidates, cand)
    end
    if input_len > 1 and #candidates > 1 then
        table.sort(candidates, function(a, b) return (a.quality or 0) > (b.quality or 0) end)
    end
    for _, cand in ipairs(candidates) do yield(cand) end
end

local S = { func = sorter }

return { P = P, F = F, S = S }