-- 输入统计工具
-- 作者：Liuyt151
-- 日期：2025-10-25
-- 
-- 命令列表：
--   显示统计：    /tj 或 tjxs    - 在候选栏显示日、周、月、年统计报告
--   清空统计：    /qk 或 tjqk    - 清空所有统计数据（保留昨日数据）
--   开始临时统计：/ks 或 tjks    - 开始临时统计会话
--   结束临时统计：/js 或 tjjs    - 结束临时统计并生成报告
--   退出临时统计：/tc 或 tjtc    - 退出临时统计（不生成报告）
--
-- 特性：
--   📊 支持日、周、月、年多维度统计
--   💾 自动保存统计数据，重启后不丢失（按方案分开存储）
--   📈 自动保存昨日统计数据，方便与昨日进行对比
--   ⏱️ 临时统计功能，可记录特定时间段输入情况
--   ⚡ 极速基于≥3秒输入段中最快的段速度（字/分）
--   📊 均速基于总字数/总连续输入时间（字/分），仅统计持续≥3秒的段
--   🔄 10秒间隙自动切断连续输入段，统计真实净速度
--   💾 保存前自动备份（.bak文件）
--   🎤 智能过滤语音输入（候选栏标志法）：
--       - translator 按键时记录候选栏状态，语音不触发 translator
--       - 有候选栏 → 正常打字，无候选栏 → 语音输入
--       - 语音输入时会结算当前手打段并重置状态，避免时间污染
--
-- 【平台配置】请根据您的使用平台修改以下变量
--   PC版（小狼毫/鼠须管）：MOBILE_MODE = false   （提示不上屏，报告可上屏）
--   手机版（同文/小企鹅）：MOBILE_MODE = true    （所有内容都可上屏）

-- 【语音检测增强参数】用于区分键盘输入和语音输入
-- 当字数超过阈值且距离上次按键间隔超过阈值时，判定为语音输入
-- 注意：阈值设置需平衡准确性和误判风险
--   - 阈值过低：可能将手动输入的长句误判为语音（如思考后输入）
--   - 阈值过高：可能漏检实际的语音输入
-- 建议：若出现误判（长句手打被当语音），可提高阈值至30或50
local VOICE_LEN_THRESHOLD = 20   -- 字数阈值（默认20字，保守设置）
local VOICE_GAP_THRESHOLD = 5    -- 时间间隔阈值（秒，默认5秒）

local SEPARATOR_LINE = string.rep("─", 12)

-- 自动检测是否为移动设备（智能平台检测）
-- 支持的输入法：同文(Trime)、仓(Hamster)、鼠须管(Squirrel)、超越输入法(Beyond)、鸿蒙系统等
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
        lower_dist == "hamster3" or
        lower_dist == "squirrel" then
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
    -- 注意：去掉末尾斜杠，避免路径为 /data/storage/el2（无尾随/）时漏匹配
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

    return false
end

local MOBILE_MODE = is_mobile_device()

-- 【方案配置说明】
-- 本脚本为翻译器（含 init 初始化），需在 schema.yaml 中添加以下配置：
--
-- engine:
--   translators:
--     - lua_translator@*input_statistics      # 输入统计翻译器
--
-- speller:                                     # 必须配置引导符
--   alphabet: zyxwvutsrqponmlkjihgfedcba`/@=  # 必须包含 /（斜杠）
--   initials: zyxwvutsrqponmlkjihgfedcba`/@=  # 必须包含 /（斜杠）

local input_stats = input_stats or {
    daily = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
    weekly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
    monthly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
    yearly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
    lengths = {},
    daily_max = 0,
    weekly_max = 0,
    recent = {},          -- 用于临时统计的最快一分钟，主统计不再使用
    yesterday = {count = 0, length = 0, fastest = 0, ts = 0}
}

-- 连续输入段追踪（全局，跨方案共享）
avgSpdInfo = avgSpdInfo or {
    logSts = 0,           -- 0=空闲/段结束，1=记录中
    startTime = 0,        -- 当前段起始时间
    clickTime = 0,        -- 最后一次按键时间
    commitTime = 0,       -- 当前段最后一次上屏时间
    gapThd = 10,          -- 间隙阈值（秒）
    count = 0             -- 当前段累计字数
}

-- 候选栏状态标志（在 translator 按键阶段记录，commit_notifier 中读取）
-- true = 上屏前有候选栏（按键输入），false = 上屏前无候选栏（语音输入）
hadCandidatesBeforeCommit = hadCandidatesBeforeCommit or false

-- 安全的字符长度计算函数
local function get_text_length(text)
    if not text or text == "" then
        return 0
    end
    
    if utf8 and utf8.len then
        local utf8_len = utf8.len(text)
        if utf8_len then
            return utf8_len
        end
    end
    
    local count = 0
    local i = 1
    while i <= #text do
        local byte = text:byte(i)
        if byte < 128 then
            count = count + 1
            i = i + 1
        elseif byte >= 192 and byte < 224 then
            count = count + 1
            i = i + 2
        elseif byte >= 224 and byte < 240 then
            count = count + 1
            i = i + 3
        elseif byte >= 240 then
            count = count + 1
            i = i + 4
        else
            i = i + 1
        end
    end
    return count
end

-- 判断是否为汉字（CJK统一表意文字）
local function is_chinese_char(code)
    return (code >= 0x4E00 and code <= 0x9FFF) or   -- CJK统一表意文字
           (code >= 0x3400 and code <= 0x4DBF) or   -- CJK扩展A
           (code >= 0x20000 and code <= 0x2A6DF) or -- CJK扩展B
           (code >= 0x2A700 and code <= 0x2B73F) or -- CJK扩展C
           (code >= 0x2B740 and code <= 0x2B81F) or -- CJK扩展D
           (code >= 0x2B820 and code <= 0x2CEAF) or -- CJK扩展E
           (code >= 0x2CEB0 and code <= 0x2EBEF) or -- CJK扩展F
           (code >= 0x30000 and code <= 0x3134F) or -- CJK扩展G
           (code >= 0x31350 and code <= 0x323AF) or -- CJK扩展H
           (code >= 0x2EBF0 and code <= 0x2EE5F) or -- CJK扩展I
           (code >= 0xF900 and code <= 0xFAFF) or   -- CJK兼容表意文字
           (code >= 0x2F800 and code <= 0x2FA1F) or -- CJK兼容表意文字增补
           (code >= 0x2E80 and code <= 0x2EFF) or   -- CJK部首补充
           (code >= 0x2F00 and code <= 0x2FDF)     -- 康熙部首
end

-- 获取纯汉字长度（排除标点、数字、英文等）
local function get_chinese_length(text)
    if not text or text == "" then
        return 0
    end
    local count = 0
    for _, code in utf8.codes(text) do
        if is_chinese_char(code) then
            count = count + 1
        end
    end
    return count
end

-- 时间戳工具函数
local function start_of_day(t)
    if not t or not t.year or not t.month or not t.day then
        return 0
    end
    return os.time{year=t.year, month=t.month, day=t.day, hour=0}
end

local function start_of_week(t)
    if not t or not t.year or not t.month or not t.day or not t.wday then
        return 0
    end
    local d = t.wday == 1 and 6 or (t.wday - 2)
    return os.time{year=t.year, month=t.month, day=t.day - d, hour=0}
end

local function start_of_month(t)
    if not t or not t.year or not t.month then
        return 0
    end
    return os.time{year=t.year, month=t.month, day=1, hour=0}
end

local function start_of_year(t)
    if not t or not t.year then
        return 0
    end
    return os.time{year=t.year, month=1, day=1, hour=0}
end

-- 判断是否是统计命令
local function is_summary_command(text)
    return text == "/tj" or text == "/qk" or text == "/ks" or text == "/js" or text == "/tc" or
           text == "tjxs" or text == "tjqk" or text == "tjks" or text == "tjjs" or text == "tjtc"
end

-- 获取方案显示名称（优先中文名）
local function get_schema_display_name(env)
    if not env or not env.engine or not env.engine.schema then
        return "未知方案"
    end
    
    local schema = env.engine.schema
    local config = schema.config
    
    if config then
        local name = config:get_string("schema/name")
        if name and name ~= "" then
            return name
        end
    end
    
    return schema.schema_id or "未知方案"
end

-- 计算均速（字/分）：只统计持续≥3秒的输入段，排除零碎敲击
local function calculate_avg_speed(stat)
    local total_gaps = 0
    local total_cnts = 0
    for i = 1, #stat.avgGaps do
        local gap = stat.avgGaps[i] or 0
        local cnt = stat.avgCnts[i] or 0
        if gap >= 3 then  -- 只统计持续≥3秒的输入段
            total_gaps = total_gaps + gap
            total_cnts = total_cnts + cnt
        end
    end
    if total_gaps > 0 then
        return total_cnts / total_gaps * 60
    end
    return 0
end

-- 更新极速（基于≥3秒的输入段速度：所有段中速度最快的那个段）
-- @param seg_time: 段持续时间（秒）
-- @param seg_count: 段内字数
local function update_fastest(stat, seg_time, seg_count)
    if seg_time >= 3 and seg_count > 0 then
        local spd = seg_count / seg_time * 60
        if spd > (stat.fastest or 0) then
            stat.fastest = spd
        end
    end
end

-- 语音输入检测
--
-- 核心逻辑：
-- hadCandidatesBeforeCommit == true → 按键输入，放行
-- hadCandidatesBeforeCommit == false → 可能是语音输入，需进一步判断
--
-- 注意：若用户先键盘输入（标志变为true），随后立即使用语音输入（不经过translator），
-- 标志仍为true，会导致语音被误判。因此需要结合时间间隔进行辅助判断。
--
-- @return: true=语音输入(应过滤), false=正常按键输入
local function is_voice_input()
    -- 上屏前有候选栏 → 一定是按键输入
    if hadCandidatesBeforeCommit then
        return false
    end

    -- 无候选栏，但检查与最后一次按键的间隔
    -- 如果间隔过长（超过阈值），说明不是连续按键输入，可能是语音
    local timeNow = os.time()
    local gap = timeNow - avgSpdInfo.clickTime

    -- 如果最后一次按键在 10 秒之前，且当前无候选栏，则视为语音输入
    -- 10 秒是连续输入段的间隙阈值
    if gap > avgSpdInfo.gapThd then
        return true
    end

    -- 间隔较短，可能是快速输入或异常情况，保守起见视为按键输入
    return false
end

-- 更新统计数据（核心：处理连续输入段）
-- @param input_length: 本次上屏字数（0 表示仅结算段）
-- @param is_segment_end: 1 表示当前段结束，需要将本段时间和字数存入统计
local function update_stats(input_length, is_segment_end, env)
    local now = os.date("*t")

    local day_ts = start_of_day(now)
    local week_ts = start_of_week(now)
    local month_ts = start_of_month(now)
    local year_ts = start_of_year(now)

    -- 确保所有统计对象都存在
    input_stats.daily = input_stats.daily or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
    input_stats.weekly = input_stats.weekly or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
    input_stats.monthly = input_stats.monthly or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
    input_stats.yearly = input_stats.yearly or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
    input_stats.yesterday = input_stats.yesterday or {count = 0, length = 0, fastest = 0, ts = 0}
    input_stats.lengths = input_stats.lengths or {}
    input_stats.recent = input_stats.recent or {}

    -- 检查是否是新的一天，如果是则保存昨日数据
    if input_stats.daily.ts ~= 0 and input_stats.daily.ts ~= day_ts then
        input_stats.yesterday = {
            count = input_stats.daily.count,
            length = input_stats.daily.length,
            fastest = input_stats.daily.fastest,
            ts = input_stats.daily.ts
        }
    end

    -- 周期重置逻辑
    if input_stats.daily.ts ~= day_ts then
        -- 每日重置前：将当日极速同步到周/月/年（取最大值）
        local daily_fastest = input_stats.daily.fastest or 0
        if daily_fastest > 0 then
            for _, period in ipairs({"weekly", "monthly", "yearly"}) do
                if not input_stats[period] then break end
                input_stats[period].fastest = math.max(input_stats[period].fastest or 0, daily_fastest)
            end
        end
        input_stats.daily = {count = 0, length = 0, fastest = 0, ts = day_ts, avgGaps = {}, avgCnts = {}}
        input_stats.daily_max = 0
        input_stats.recent = {}
        -- 检测到新的一天，立即保存到文件（确保昨日数据持久化）
        if env and env.engine and env.engine.schema then
            save_stats(env.engine.schema.schema_id)
        end
    end
    
    if input_stats.weekly.ts ~= week_ts then
        if input_stats.weekly.length > (input_stats.weekly_max or 0) then
            input_stats.weekly_max = input_stats.weekly.length
        end
        input_stats.weekly = {count = 0, length = 0, fastest = 0, ts = week_ts, avgGaps = {}, avgCnts = {}}
    end
    
    if input_stats.monthly.ts ~= month_ts then
        input_stats.monthly = {count = 0, length = 0, fastest = 0, ts = month_ts, avgGaps = {}, avgCnts = {}}
        input_stats.weekly_max = 0
    end
    
    if input_stats.yearly.ts ~= year_ts then
        input_stats.yearly = {count = 0, length = 0, fastest = 0, ts = year_ts, avgGaps = {}, avgCnts = {}}
        input_stats.lengths = {}
    end

    -- 处理段结束：将当前连续输入段的时间与字数存入各周期
    if is_segment_end == 1 then
        local delt = avgSpdInfo.clickTime - avgSpdInfo.startTime
        if delt > 0 and avgSpdInfo.count > 0 then
            local function add_to_stat(stat)
                table.insert(stat.avgGaps, delt)
                table.insert(stat.avgCnts, avgSpdInfo.count)
            end
            add_to_stat(input_stats.daily)
            add_to_stat(input_stats.weekly)
            add_to_stat(input_stats.monthly)
            add_to_stat(input_stats.yearly)
            -- 段结束时更新极速（基于≥3秒段速度）
            update_fastest(input_stats.daily, delt, avgSpdInfo.count)
            update_fastest(input_stats.weekly, delt, avgSpdInfo.count)
            update_fastest(input_stats.monthly, delt, avgSpdInfo.count)
            update_fastest(input_stats.yearly, delt, avgSpdInfo.count)
        end
    end

    -- 统计字数（只有 input_length > 0 才计入）
    if input_length > 0 then
        local function add(stat)
            stat.count = stat.count + 1
            stat.length = stat.length + input_length
        end
        add(input_stats.daily)
        add(input_stats.weekly)
        add(input_stats.monthly)
        add(input_stats.yearly)

        if input_length > (input_stats.daily_max or 0) then
            input_stats.daily_max = input_length
        end

        input_stats.lengths[input_length] = (input_stats.lengths[input_length] or 0) + 1
    end
end

-- 序列化工具
local function serialize_table(tbl, indent)
    indent = indent or 0
    local spaces = string.rep(" ", indent)
    local lines = {"{"}
    
    for k, v in pairs(tbl) do
        local key = (type(k) == "string") and ("[\"" .. k .. "\"]") or ("[" .. k .. "]")
        local val
        
        if type(v) == "table" then
            val = serialize_table(v, indent + 4)
        elseif type(v) == "string" then
            val = '"' .. v .. '"'
        else
            val = tostring(v)
        end
        table.insert(lines, string.format("%s    %s = %s,", spaces, key, val))
    end
    table.insert(lines, spaces .. "}")
    return table.concat(lines, "\n")
end

-- 保存统计到文件（按方案分开存储，自动备份）
local function save_stats(schema_id)
    if not schema_id then return false end
    local dir = (rime_api and rime_api.get_user_data_dir and rime_api:get_user_data_dir() or "") .. "/lua/"
    local path = dir .. "input_stats_" .. schema_id .. ".lua"
    local bak_path = path .. ".bak"

    -- 备份旧文件
    local old = io.open(path, "r")
    if old then
        old:close()
        os.rename(path, bak_path)
    end

    local file = io.open(path, "w")
    if not file then return false end
    file:write("return " .. serialize_table(input_stats) .. "\n")
    file:close()
    return true
end

-- 加载统计数据（按方案）
local function load_stats_from_lua_file(schema_id)
    if not schema_id then return end
    local path = (rime_api and rime_api.get_user_data_dir and rime_api:get_user_data_dir() or "") .. "/lua/input_stats_" .. schema_id .. ".lua"
    local ok, result = pcall(function()
        local env = {}
        local f = loadfile(path)
        if not f then
            return nil
        end

        if setfenv then
            setfenv(f, env)
            local ret = f()
            if type(ret) == "table" then
                return ret
            end
            return env.input_stats
        else
            local f2 = loadfile(path, "t", env)
            if not f2 then
                return nil
            end
            local ret = f2()
            if type(ret) == "table" then
                return ret
            end
            return env.input_stats
        end
    end)
    
    if ok and type(result) == "table" then
        for k, v in pairs(result) do
            input_stats[k] = v
        end
        -- 确保各周期有 avgGaps/avgCnts
        for _, period in ipairs({"daily", "weekly", "monthly", "yearly"}) do
            input_stats[period] = input_stats[period] or {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}}
            input_stats[period].avgGaps = input_stats[period].avgGaps or {}
            input_stats[period].avgCnts = input_stats[period].avgCnts or {}
        end
        input_stats.lengths = input_stats.lengths or {}
        input_stats.recent = input_stats.recent or {}
        input_stats.yesterday = input_stats.yesterday or {count = 0, length = 0, fastest = 0, ts = 0}
        input_stats.daily_max = input_stats.daily_max or 0
        input_stats.weekly_max = input_stats.weekly_max or 0
    else
        -- 初始化空表
        input_stats = {
            daily = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            weekly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            monthly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            yearly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            lengths = {},
            daily_max = 0,
            weekly_max = 0,
            recent = {},
            yesterday = {count = 0, length = 0, fastest = 0, ts = 0}
        }
    end
end

-- 临时统计报告格式化（末尾增加换行）
local function format_custom_summary(temp_stats, schema_name)
    local end_ts = temp_stats.last_slash_time or os.time()
    local duration_sec = end_ts - temp_stats.start_time
    local minutes = duration_sec / 60
    
    local speed = 0
    if minutes > 0 then
        speed = math.floor((temp_stats.length / minutes) * 100) / 100
    end
    
    return string.format(
        "◉ 临时统计报告\n"..
        "%s\n"..
        "◉ 开始时间：%s\n"..
        "◉ 结束时间：%s\n"..
        "◉ 统计时长：%d分 %d秒\n"..
        "◉ 输入条数：%d条\n"..
        "◉ 总字数：%d字\n"..
        "◉ 平均速度：%.2f 字/分钟\n"..
        "◉ 最快一分钟输入：%d字\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        os.date("%Y-%m-%d %H:%M:%S", temp_stats.start_time),
        os.date("%Y-%m-%d %H:%M:%S", end_ts),
        math.floor(minutes), math.floor(duration_sec % 60),
        temp_stats.count,
        temp_stats.length,
        speed,
        temp_stats.fastest,
        SEPARATOR_LINE,
        schema_name or "未知方案"
    )
end

-- 日统计报告（末尾增加换行）
local function format_daily_summary(schema_name)
    local s = input_stats.daily or {count = 0, length = 0, fastest = 0, avgGaps = {}, avgCnts = {}}
    local y = input_stats.yesterday or {count = 0, length = 0, fastest = 0}
    
    if s.count == 0 then 
        return "※ 今天没有任何记录"
    end
    
    local avg_speed = calculate_avg_speed(s)
    local fastest = s.fastest or 0  -- 极速为最快段速度（字/分）
    
    -- 计算与昨日的对比
    local comparison_text = ""
    if y and y.length > 0 then
        local diff = s.length - y.length
        local diff_percent = 0
        if y.length > 0 then
            diff_percent = (diff / y.length) * 100
        end
        if diff > 0 then
            comparison_text = string.format("比昨日多%d字 (+%.1f%%)", diff, diff_percent)
        elseif diff < 0 then
            comparison_text = string.format("比昨日少%d字 (%.1f%%)", -diff, diff_percent)
        else
            comparison_text = "与昨日持平"
        end
    else
        comparison_text = "昨日无记录"
    end
    
    return string.format(
        "◉ 今日统计\n"..
        "%s\n"..
        "共上屏[%d]次\n"..
        "共输入[%d]字\n"..
        "极速[%.1f]字/分\n"..
        "均速[%.1f]字/分\n"..
        "%s\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        s.count,
        s.length,
        fastest,
        avg_speed,
        comparison_text,
        SEPARATOR_LINE,
        schema_name
    )
end

-- 周统计报告（末尾增加换行）
local function format_weekly_summary(schema_name)
    local s = input_stats.weekly or {count = 0, length = 0, fastest = 0, avgGaps = {}, avgCnts = {}}
    if s.count == 0 then 
        return "※ 本周没有任何记录"
    end
    
    local avg_speed = calculate_avg_speed(s)
    local fastest = s.fastest or 0
    
    return string.format(
        "◉ 本周统计\n"..
        "%s\n"..
        "共上屏[%d]次\n"..
        "共输入[%d]字\n"..
        "极速[%.1f]字/分\n"..
        "均速[%.1f]字/分\n"..
        "周内单日最多一次输入[%d]字\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        s.count,
        s.length,
        fastest,
        avg_speed,
        input_stats.daily_max or 0,
        SEPARATOR_LINE,
        schema_name
    )
end

-- 月统计报告（末尾增加换行）
local function format_monthly_summary(schema_name)
    local s = input_stats.monthly or {count = 0, length = 0, fastest = 0, avgGaps = {}, avgCnts = {}}
    if s.count == 0 then 
        return "※ 本月没有任何记录"
    end
    
    local avg_speed = calculate_avg_speed(s)
    local fastest = s.fastest or 0
    
    return string.format(
        "◉ 本月统计\n"..
        "%s\n"..
        "共上屏[%d]次\n"..
        "共输入[%d]字\n"..
        "极速[%.1f]字/分\n"..
        "均速[%.1f]字/分\n"..
        "月内单周最多一次输入[%d]字\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        s.count,
        s.length,
        fastest,
        avg_speed,
        input_stats.weekly_max or 0,
        SEPARATOR_LINE,
        schema_name
    )
end

-- 年统计报告（末尾增加换行）
local function format_yearly_summary(schema_name)
    local s = input_stats.yearly or {count = 0, length = 0, fastest = 0, avgGaps = {}, avgCnts = {}}
    if s.count == 0 then 
        return "※ 本年没有任何记录"
    end
    
    local avg_speed = calculate_avg_speed(s)
    local fastest = s.fastest or 0
    
    local fav = 0
    if input_stats.lengths then
        local length_counts = {}
        for length, count in pairs(input_stats.lengths) do
            if type(length) == "number" and type(count) == "number" then
                table.insert(length_counts, {length = length, count = count})
            end
        end
        table.sort(length_counts, function(a, b) return a.count > b.count end)
        fav = length_counts[1] and length_counts[1].length or 0
    end
    
    return string.format(
        "◉ 本年统计\n"..
        "%s\n"..
        "共上屏[%d]次\n"..
        "共输入[%d]字\n"..
        "极速[%.1f]字/分\n"..
        "均速[%.1f]字/分\n"..
        "您最常输入长度为[%d]的词组\n"..
        "%s\n"..
        "◉ 方案：%s\n",
        SEPARATOR_LINE,
        s.count,
        s.length,
        fastest,
        avg_speed,
        fav,
        SEPARATOR_LINE,
        schema_name
    )
end

-- 辅助函数：判断字符串是否为“无数据”的提示消息
local function is_empty_report(str)
    return str == "※ 今天没有任何记录" or
           str == "※ 本周没有任何记录" or
           str == "※ 本月没有任何记录" or
           str == "※ 本年没有任何记录"
end

-- 根据平台生成候选
local function create_candidate(seg, content)
    -- 对于有数据的报告或手机模式，直接使用 text
    if MOBILE_MODE then
        return Candidate("stat", seg.start, seg._end, content, "")
    else
        -- PC 模式：空报告用 comment 不上屏，有数据的报告用 text 可上屏
        if is_empty_report(content) then
            return Candidate("stat", seg.start, seg._end, "", content)
        else
            return Candidate("stat", seg.start, seg._end, content, "")
        end
    end
end

local function create_message_candidate(seg, message)
    if MOBILE_MODE then
        return Candidate("stat", seg.start, seg._end, message, "")
    else
        return Candidate("stat", seg.start, seg._end, "", message)
    end
end

-- 转换器函数：处理统计命令
local function translator(input, seg, env)
    local schema_name = get_schema_display_name(env)

    -- 【语音检测】每次按键时记录候选栏状态
    -- 语音输入不触发 translator，标志保持 false
    local ctx = env.engine.context
    local composition = ctx.composition
    local preedit = ctx:get_preedit()
    hadCandidatesBeforeCommit = (composition and not composition:empty())
        or (preedit and preedit.text and #preedit.text > 0)

    -- 按键时检测连续输入段是否超时
    local timeNow = os.time()
    if timeNow - avgSpdInfo.clickTime > avgSpdInfo.gapThd then
        if avgSpdInfo.clickTime - avgSpdInfo.startTime >= 1 and avgSpdInfo.count > 0 then
            update_stats(0, 1, env)
        end
        avgSpdInfo.logSts = 0
    end
    if avgSpdInfo.logSts == 0 then
        avgSpdInfo.logSts = 1
        avgSpdInfo.startTime = timeNow
        avgSpdInfo.commitTime = timeNow
        avgSpdInfo.count = 0
    end
    avgSpdInfo.clickTime = timeNow
    
    -- 【查看统计时强制结算当前段】确保实时显示速度，不会因为段未结束而显示0
    local function flush_current_segment()
        if avgSpdInfo.logSts == 1 and avgSpdInfo.count > 0 then
            local delt = avgSpdInfo.clickTime - avgSpdInfo.startTime
            if delt >= 1 then
                update_stats(0, 1, env)
            end
        end
    end
    
    -- 命令处理
    if input == "/tj" or input == "tjxs" then
        flush_current_segment()
        local daily = format_daily_summary(schema_name)
        local weekly = format_weekly_summary(schema_name)
        local monthly = format_monthly_summary(schema_name)
        local yearly = format_yearly_summary(schema_name)
        yield(create_candidate(seg, daily))
        yield(create_candidate(seg, weekly))
        yield(create_candidate(seg, monthly))
        yield(create_candidate(seg, yearly))
    elseif input == "/qk" or input == "tjqk" then
        local yesterday_data = input_stats.yesterday or {count = 0, length = 0, fastest = 0, ts = 0}
        input_stats = {
            daily = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            weekly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            monthly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            yearly = {count = 0, length = 0, fastest = 0, ts = 0, avgGaps = {}, avgCnts = {}},
            lengths = {},
            daily_max = 0,
            weekly_max = 0,
            recent = {},
            yesterday = yesterday_data
        }
        save_stats(env.engine.schema.schema_id)
        yield(create_message_candidate(seg, "※ 所有统计数据已清空（昨日数据保留）。"))
    elseif input == "/ks" or input == "tjks" then
        env.temp_stats = {
            count = 0,
            length = 0,
            fastest = 0,
            recent = {},
            start_time = os.time(),
            is_collecting = true
        }
        yield(create_message_candidate(seg, "📝 临时统计已开始"))
    elseif input == "/js" or input == "tjjs" then
        if env.temp_stats and env.temp_stats.is_collecting then
            flush_current_segment()
            env.temp_stats.is_collecting = false
            env.temp_stats.last_slash_time = os.time()
            local report = format_custom_summary(env.temp_stats, schema_name)
            -- 临时统计报告一定有内容，直接使用可上屏候选
            if MOBILE_MODE then
                yield(Candidate("stat", seg.start, seg._end, report, ""))
            else
                yield(Candidate("stat", seg.start, seg._end, report, ""))
            end
        else
            yield(create_message_candidate(seg, "※ 当前没有进行中的临时统计"))
        end
    elseif input == "/tc" or input == "tjtc" then
        if env.temp_stats and env.temp_stats.is_collecting then
            env.temp_stats.is_collecting = false
            env.temp_stats = nil
            yield(create_message_candidate(seg, "※ 临时统计已退出，数据已清空"))
        else
            yield(create_message_candidate(seg, "※ 当前没有进行中的临时统计"))
        end
    end
end

-- 初始化
local function init(env)
    if not env or not env.engine then
        return
    end

    local ctx = env.engine.context
    local schema_id = env.engine.schema.schema_id

    -- 加载统计数据（按方案）
    load_stats_from_lua_file(schema_id)

    -- 初始化临时统计状态
    env.temp_stats = env.temp_stats or {
        is_collecting = false,
        count = 0,
        length = 0,
        fastest = 0,
        recent = {}
    }

    -- 注册提交通知回调
    if ctx and ctx.commit_notifier then
        ctx.commit_notifier:connect(function(ctx)
            if not ctx then return end
            
            local commit_text = ctx:get_commit_text()
            if not commit_text or commit_text == "" then return end

            -- 排除统计命令
            if is_summary_command(commit_text) then return end

            -- 排除统计报告上屏
            if commit_text:match("^[※◉]") then return end

            -- 【数据精度优化】只统计汉字长度，排除标点数字
            local input_length = get_chinese_length(commit_text)
            local timeNow = os.time()

            -- ========== 增强语音检测 ==========
            -- 先获取原始标志（基于候选栏状态）
            local raw_is_voice = is_voice_input()

            -- 二次修正：当原始标志为按键输入（false），但实际符合语音特征时，强制转为语音
            -- 语音特征：长句 + 长时间无按键 + 无活跃输入段
            local final_is_voice = raw_is_voice
            if not raw_is_voice then
                local time_since_last_click = timeNow - (avgSpdInfo.clickTime or 0)
                local has_active_segment = (avgSpdInfo.logSts == 1 and avgSpdInfo.count > 0)

                if input_length >= VOICE_LEN_THRESHOLD and
                    time_since_last_click > VOICE_GAP_THRESHOLD and
                    not has_active_segment then
                    final_is_voice = true
                end
            end

            local isVoice = final_is_voice

            -- 重置标志，防止影响下一次判断
            hadCandidatesBeforeCommit = false

            if isVoice then
                -- 语音输入：结算当前手打段（如果有），然后完全重置状态
                if avgSpdInfo.logSts == 1 and avgSpdInfo.count > 0 then
                    local delt = avgSpdInfo.clickTime - avgSpdInfo.startTime
                    if delt >= 1 then
                        update_stats(0, 1, env)
                    end
                end
                avgSpdInfo.logSts = 0
                avgSpdInfo.startTime = 0
                avgSpdInfo.commitTime = 0
                avgSpdInfo.clickTime = 0
                avgSpdInfo.count = 0
                return
            end

            -- 以下是正常按键输入的处理
            -- 连续输入段处理
            if avgSpdInfo.logSts ~= 1 then
                avgSpdInfo.logSts = 1
                avgSpdInfo.startTime = timeNow
                avgSpdInfo.commitTime = timeNow
                avgSpdInfo.count = input_length
            else
                local delt = timeNow - avgSpdInfo.clickTime
                if delt > avgSpdInfo.gapThd then
                    if avgSpdInfo.clickTime - avgSpdInfo.startTime >= 1 and avgSpdInfo.count > 0 then
                        update_stats(0, 1, env)
                    end
                    avgSpdInfo.startTime = timeNow
                    avgSpdInfo.count = input_length
                else
                    avgSpdInfo.count = avgSpdInfo.count + input_length
                end
                avgSpdInfo.commitTime = timeNow
            end
            avgSpdInfo.clickTime = timeNow

            -- 更新字数统计（不结束段）
            update_stats(input_length, 0, env)
            
            -- 更新临时统计
            if env.temp_stats and env.temp_stats.is_collecting then
                env.temp_stats.count = env.temp_stats.count + 1
                env.temp_stats.length = env.temp_stats.length + input_length

                local ts = os.time()
                table.insert(env.temp_stats.recent, {ts = ts, len = input_length})
                local threshold = ts - 60
                local current_minute_total = 0
                local new_recent = {}
                for _, item in ipairs(env.temp_stats.recent) do
                    if item and item.ts and item.ts >= threshold then
                        current_minute_total = current_minute_total + (item.len or 0)
                        table.insert(new_recent, item)
                    end
                end
                env.temp_stats.recent = new_recent
                if current_minute_total > (env.temp_stats.fastest or 0) then
                    env.temp_stats.fastest = current_minute_total
                end
            end
            
            -- 保存统计
            save_stats(schema_id)
        end)
    end
end

return { init = init, func = translator }