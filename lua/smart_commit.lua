--[[
    智能上屏处理器 - 五笔拼音混合模式
    功能：智能判断五笔和拼音输入，五笔四码自动上屏，拼音保持候选
    作者: shawx、Liuyt151
    优化日期: 2026-05-20 - 修复退格键触发自动上屏的问题
    问题：按下退格键时，context.input 尚未删除最后一个编码，仍为四码，
         导致错误执行自动上屏。现增加按键过滤：退格键直接放行。

    【方案配置说明】
    本脚本为处理器，需在 schema.yaml 中添加以下配置：

    engine:
      processors:
        - lua_processor@*smart_commit           # 智能上屏处理器

    建议配置位置：在 ascii_composer 之后，recognizer 之前

    speller:                                     # 可选配置
      auto_select_pattern: ^;.$|^\w{4}$        # 四码自动上屏（由脚本补充）

    无需识别器配置，脚本通过以下方式判断：
      - 检测按键类型（只处理 a-z 字母键）
      - 检测候选类型（table=五笔，reverse_lookup=拼音）
      - 输入长度和正则匹配

    判断逻辑：
    1. 五笔模式：输入长度=4，第一个候选是 table 类型（五笔字典匹配）
    2. 拼音模式：候选来自 reverse_lookup 类型，不自动上屏
]]

local M = {}

-- 内部常量
local RIME_PROCESS_RESULTS = {
    kRejected = 0,
    kAccepted = 1,
    kNoop = 2,
}

-- 按键码（Rime 中定义）
local XK_BackSpace = 0xff08   -- 退格键
local XK_Delete    = 0xffff    -- 删除键（可选）

-- 配置参数
M.config = {
    auto_commit_length = 4,      -- 五笔自动上屏的编码长度
    max_pinyin_length = 6,       -- 超过此长度不自动上屏（可能是拼音词组）
}

--[[
    判断是否应该自动上屏（原逻辑，未修改）
    
    五笔模式判断条件：
    1. 输入长度等于配置的 auto_commit_length（默认4）
    2. 第一个候选的类型是 "table"（来自五笔字典）
    3. 第一个候选是单字（utf8.len == 1）
    
    拼音模式判断条件：
    1. 候选类型是 "reverse_lookup"（来自拼音反查）
    2. 输入长度超过 max_pinyin_length
    3. 候选是词组（多字）
]]
local function should_auto_commit(context)
    local input = context.input
    local input_len = #input
    
    -- 输入长度检查
    if input_len ~= M.config.auto_commit_length then
        return false
    end
    
    -- 检查是否有候选菜单
    if not context:has_menu() then
        return false
    end
    
    local composition = context.composition
    if composition:empty() then
        return false
    end
    
    local segment = composition:back()
    if not segment then
        return false
    end
    
    -- 获取第一个候选
    local first_cand = segment:get_candidate_at(0)
    if not first_cand then
        return false
    end
    
    -- 判断候选类型
    local cand_type = first_cand.type or ""
    
    -- 如果是 reverse_lookup 类型，说明是拼音输入，不自动上屏
    if cand_type == "reverse_lookup" then
        return false
    end
    
    -- 如果是 table 类型（五笔字典匹配）
    if cand_type == "table" then
        -- 检查是否是单字
        local text = first_cand.text or ""
        if utf8.len(text) == 1 then
            return true
        end
    end
    
    return false
end

--[[
    判断当前输入模式（原逻辑）
    
    返回值：
    - "wubi" - 五笔模式
    - "pinyin" - 拼音模式
    - "unknown" - 未知模式
]]
local function detect_input_mode(context)
    local input = context.input
    local input_len = #input
    
    -- 没有输入
    if input_len == 0 then
        return "unknown"
    end
    
    -- 检查是否有候选菜单
    if not context:has_menu() then
        return "unknown"
    end
    
    local composition = context.composition
    if composition:empty() then
        return "unknown"
    end
    
    local segment = composition:back()
    if not segment then
        return "unknown"
    end
    
    -- 获取第一个候选
    local first_cand = segment:get_candidate_at(0)
    if not first_cand then
        return "unknown"
    end
    
    local cand_type = first_cand.type or ""
    
    -- reverse_lookup 类型是拼音输入
    if cand_type == "reverse_lookup" then
        return "pinyin"
    end
    
    -- table 类型是五笔输入
    if cand_type == "table" then
        return "wubi"
    end
    
    return "unknown"
end

-- 初始化函数
function M.init(env)
    -- 可以从配置中读取参数
    local config = env.engine.schema.config
    local auto_len = config:get_int("smart_commit/auto_commit_length")
    if auto_len and auto_len > 0 then
        M.config.auto_commit_length = auto_len
    end
end

-- 处理器主函数（修复版）
function M.func(key, env)
    local context = env.engine.context
    local engine = env.engine

    -- ========== 关键修复：仅在字母键输入时尝试自动上屏 ==========
    -- BackSpace/Delete 由 speller 先处理删除，其他非字母键不应触发自动上屏
    local key_value = key:repr()
    local keycode = key.keycode
    if keycode == nil then
        return RIME_PROCESS_RESULTS.kNoop
    end
    if key_value == "BackSpace" or key_value == "Delete"
       or keycode == XK_BackSpace or keycode == XK_Delete then
        return RIME_PROCESS_RESULTS.kNoop
    end
    if not key_value:match("^[a-z]$") then
        return RIME_PROCESS_RESULTS.kNoop
    end
    -- ============================================

    -- 只处理字母输入后的状态
    if not context:is_composing() then
        return RIME_PROCESS_RESULTS.kNoop
    end

    local input = context.input
    
    -- 忽略特殊输入模式（如命令、标点等）
    if input:find("^[/%=~`]") then
        return RIME_PROCESS_RESULTS.kNoop
    end
    
    -- 忽略非字母输入
    if not input:match("^[a-z]+$") then
        return RIME_PROCESS_RESULTS.kNoop
    end
    
    -- 检测输入模式
    local mode = detect_input_mode(context)
    
    -- 五笔模式：四码自动上屏
    if mode == "wubi" and should_auto_commit(context) then
        local commit_text = context:get_commit_text()
        if commit_text and commit_text ~= "" then
            engine:commit_text(commit_text)
            context:clear()
            return RIME_PROCESS_RESULTS.kAccepted
        end
    end
    
    -- 拼音模式：不自动上屏，保持候选状态
    return RIME_PROCESS_RESULTS.kNoop
end

-- 导出检测函数供外部使用
M.detect_input_mode = detect_input_mode
M.should_auto_commit = should_auto_commit

return M