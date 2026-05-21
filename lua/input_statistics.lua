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
--   ⚡ 极速基于≥5秒输入段中最快的段速度（字/分）
--   📊 均速基于总字数/总连续输入时间（字/分），仅统计持续≥3秒的段
--   🔄 10秒间隙自动切断连续输入段，统计真实净速度
--   💾 保存前自动备份（.bak文件）
--
-- 配置方法：在方案文件中添加以下字段
-- engine:
--   translators:
--     - lua_translator@*input_statistics
--

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

-- 辅助：表求和
local function table_sum(tb)
    if type(tb) ~= "table" then return 0 end
    local sum = 0
    for i = 1, #tb do
        sum = sum + (tb[i] or 0)
    end
    return sum
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

-- 更新极速（基于≥5秒的输入段速度：所有段中速度最快的那个段）
-- @param seg_time: 段持续时间（秒）
-- @param seg_count: 段内字数
local function update_fastest(stat, seg_time, seg_count)
    if seg_time >= 5 and seg_count > 0 then
        local spd = seg_count / seg_time * 60
        if spd > (stat.fastest or 0) then
            stat.fastest = spd
        end
    end
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
        local delt = avgSpdInfo.commitTime - avgSpdInfo.startTime
        if delt > 0 and avgSpdInfo.count > 0 then
            local function add_to_stat(stat)
                table.insert(stat.avgGaps, delt)
                table.insert(stat.avgCnts, avgSpdInfo.count)
            end
            add_to_stat(input_stats.daily)
            add_to_stat(input_stats.weekly)
            add_to_stat(input_stats.monthly)
            add_to_stat(input_stats.yearly)
            -- 段结束时更新极速（基于≥5秒段速度）
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

-- 临时统计报告格式化（保持不变）
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
        "◉ 方案：%s",
        string.rep("─", 12),
        os.date("%Y-%m-%d %H:%M:%S", temp_stats.start_time),
        os.date("%Y-%m-%d %H:%M:%S", end_ts),
        math.floor(minutes), math.floor(duration_sec % 60),
        temp_stats.count,
        temp_stats.length,
        speed,
        temp_stats.fastest,
        string.rep("─", 12),
        schema_name or "未知方案"
    )
end

-- 日统计报告（加入均速和极速）
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
        "◉ 方案：%s",
        string.rep("─", 12),
        s.count,
        s.length,
        fastest,
        avg_speed,
        comparison_text,
        string.rep("─", 12),
        schema_name
    )
end

-- 周统计报告
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
        "◉ 方案：%s",
        string.rep("─", 12),
        s.count,
        s.length,
        fastest,
        avg_speed,
        input_stats.daily_max or 0,
        string.rep("─", 12),
        schema_name
    )
end

-- 月统计报告
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
        "◉ 方案：%s",
        string.rep("─", 12),
        s.count,
        s.length,
        fastest,
        avg_speed,
        input_stats.weekly_max or 0,
        string.rep("─", 12),
        schema_name
    )
end

-- 年统计报告
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
        "◉ 方案：%s",
        string.rep("─", 12),
        s.count,
        s.length,
        fastest,
        avg_speed,
        fav,
        string.rep("─", 12),
        schema_name
    )
end

-- 转换器函数：处理统计命令
local function translator(input, seg, env)
    local summary = ""
    local schema_name = get_schema_display_name(env)
    
    -- 按键时检测连续输入段是否超时
    local timeNow = os.time()
    if timeNow - avgSpdInfo.clickTime > avgSpdInfo.gapThd then
        if avgSpdInfo.commitTime - avgSpdInfo.startTime >= 1 and avgSpdInfo.count > 0 then
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
    
    -- 命令处理
    if input == "/tj" or input == "tjxs" then
        yield(Candidate("stat", seg.start, seg._end, format_daily_summary(schema_name), ""))
        yield(Candidate("stat", seg.start, seg._end, format_weekly_summary(schema_name), ""))
        yield(Candidate("stat", seg.start, seg._end, format_monthly_summary(schema_name), ""))
        yield(Candidate("stat", seg.start, seg._end, format_yearly_summary(schema_name), ""))
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
        summary = "※ 所有统计数据已清空（昨日数据保留）。"
        if summary ~= "" then
            yield(Candidate("stat", seg.start, seg._end, summary, ""))
        end
    elseif input == "/ks" or input == "tjks" then
        env.temp_stats = {
            count = 0,
            length = 0,
            fastest = 0,
            recent = {},
            start_time = os.time(),
            is_collecting = true
        }
        yield(Candidate("stat", seg.start, seg._end, "", "📝 临时统计已开始（按空格确认）"))
    elseif input == "/js" or input == "tjjs" then
        if env.temp_stats and env.temp_stats.is_collecting then
            env.temp_stats.is_collecting = false
            env.temp_stats.last_slash_time = os.time()
            local report = format_custom_summary(env.temp_stats, schema_name)
            yield(Candidate("stat", seg.start, seg._end, report, ""))
        else
            yield(Candidate("stat", seg.start, seg._end, "※ 当前没有进行中的临时统计", ""))
        end
    elseif input == "/tc" or input == "tjtc" then
        if env.temp_stats and env.temp_stats.is_collecting then
            env.temp_stats.is_collecting = false
            env.temp_stats = nil
            yield(Candidate("stat", seg.start, seg._end, "※ 临时统计已退出，数据已清空", ""))
        else
            yield(Candidate("stat", seg.start, seg._end, "※ 当前没有进行中的临时统计", ""))
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

            local input_length = get_text_length(commit_text)
            local timeNow = os.time()

            -- 连续输入段处理
            if avgSpdInfo.logSts ~= 1 then
                avgSpdInfo.logSts = 1
                avgSpdInfo.startTime = timeNow
                avgSpdInfo.commitTime = timeNow
                avgSpdInfo.count = input_length
            else
                local delt = timeNow - avgSpdInfo.commitTime
                if delt > avgSpdInfo.gapThd then
                    if avgSpdInfo.commitTime - avgSpdInfo.startTime >= 1 and avgSpdInfo.count > 0 then
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
            
            -- 更新临时统计（保持原有逻辑）
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

-- 可选清理（如需要可取消注释）
-- local function fini(env)
--     if env.notifier then
--         env.notifier:disconnect()
--         env.notifier = nil
--     end
-- end

return { init = init, func = translator }
