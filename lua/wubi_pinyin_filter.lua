--[[
    wubi_pinyin_filter.lua - 五笔候选筛选过滤器（支持点击模糊/右滑精确）
    作者: Liuyt151
    日期: 2026-06-30（修订）

    【功能概述】
    1. 第五码拼音首字母筛选（可配置首字/末字）
    2. 错误编码过滤
    3. z键拼音反查放行
    4. 智能区分点击与右滑（需配合 Submit_text.lua 提供 raw_input）：
       - 点击（左字母）：启用双键模糊匹配（如点击 Q 键可匹配 q 或 w 开头的候选）
       - 右滑（右字母）：只精确匹配该字母本身（如右滑 W 键只匹配 w 开头的候选）
    此特性完美适配14键布局的滑动手势输入。

    【配置选项】（均为可选）
    wubi_pinyin_filter:
      use_key_pairs: true      # 是否启用双键模糊匹配（默认自动检测，有 derive 规则则启用）
      use_last_char: false     # true=末字拼音首字母, false=首字（默认false）

    【依赖】
    本过滤器需要处理器（如 Submit_text.lua）维护 context 属性 "raw_input"。
    若未提供 raw_input，则按 use_key_pairs 统一处理。
]]

local basic = require('lib/basic')
local utf8chars = basic.utf8chars

-- ===================================================================
-- 动态构建键对映射（从 derive 规则解析）
-- ===================================================================

local function build_key_mapping(config)
    local left_to_right = {}
    local right_to_left = {}
    local left_set = {}
    local right_set = {}
    
    local algebra = config:get_list('speller/algebra')
    if not algebra then return left_to_right, right_to_left, left_set, right_set end
    for i = 0, algebra.size - 1 do
        local item = algebra:get_value_at(i)
        if item and item.value then
            local from, to = item.value:match("^derive/([a-z])/([a-z])/$")
            if from and to and from ~= to then
                right_to_left[from] = to
                left_to_right[to] = from
                left_set[to] = true
                right_set[from] = true
            end
        end
    end
    return left_to_right, right_to_left, left_set, right_set
end

-- ===================================================================
-- 检测是否为双键布局（用于自动启用 use_key_pairs）
-- ===================================================================
local function has_derive_rules(config)
    local algebra = config:get_list('speller/algebra')
    if not algebra then return false end
    for i = 0, algebra.size - 1 do
        local item = algebra:get_value_at(i)
        if item and item.value then
            local from, to = item.value:match("^derive/([a-z])/([a-z])/$")
            if from and to and from ~= to then return true end
        end
    end
    return false
end

-- ===================================================================
-- 初始化
-- ===================================================================
local function init(env)
    local config = env.engine.schema.config

    -- 读取拼音反向数据库
    local spll_rvdb_name = config:get_string('lua_reverse_db/spelling')
    if spll_rvdb_name then
        env.spll_rvdb = ReverseDb('build/' .. spll_rvdb_name .. '.reverse.bin')
    end

    -- 构建键对映射（每个方案独立，避免方案切换时映射混乱）
    env.left_to_right, env.right_to_left, env.left_set, env.right_set = build_key_mapping(config)

    -- 判断是否启用双键匹配（显式配置优先）
    local use_pairs = config:get_bool('wubi_pinyin_filter/use_key_pairs')
    if use_pairs == nil then
        use_pairs = has_derive_rules(config)
    end
    env.use_key_pairs = use_pairs

    -- 读取末字/首字配置
    local use_last = config:get_bool('wubi_pinyin_filter/use_last_char')
    env.use_last_char = use_last ~= nil and use_last or false
end

-- ===================================================================
-- 工具函数
-- ===================================================================
local function get_candidate_wubi_code(cand)
    local comment = cand.comment or ""
    local preedit = cand.preedit or ""

    -- 优先从 comment 中提取编码（new_spelling 会修改 comment 格式）
    -- 策略1：提取最后一个 〈...〉 中的纯字母内容（通常是编码）
    if comment ~= "" then
        local extracted = comment:match("〈([^〉]+)〉$")
        if extracted then
            extracted = extracted:gsub("[%s%p]", ""):lower()
            if extracted ~= "" and extracted:match("^[a-z]+$") and #extracted >= 2 then
                return extracted
            end
        end
        -- 策略2：尝试提取所有括号中的纯字母
        for code in comment:gmatch("〈([^〉]+)〉") do
            local clean_code = code:gsub("[%s%p]", ""):lower()
            if clean_code ~= "" and clean_code:match("^[a-z]+$") and #clean_code >= 2 then
                return clean_code
            end
        end
        -- 策略3：从整个 comment 中提取最长的连续纯字母序列
        local longest_code = ""
        for code in comment:gmatch("[a-z]+") do
            if #code > #longest_code and #code >= 2 then
                longest_code = code
            end
        end
        if longest_code ~= "" then
            return longest_code
        end
    end

    -- 回退到 preedit
    preedit = preedit:gsub("[%s%p]", ""):lower()
    if preedit ~= "" then return preedit end

    -- 最后尝试从 comment 中提取（去掉标点后）
    if comment ~= "" then
        local extracted = comment:match("〈([^〉]+)〉")
        if extracted then return extracted:lower() end
        comment = comment:gsub("[%s%p]", ""):lower()
        if comment ~= "" then return comment end
    end
    return ""
end

-- 根据 raw_input 构建字母集合（混合模式）
local function build_letter_sets_mixed(raw_input, max_len, left_to_right, right_set)
    max_len = max_len or #raw_input
    local sets = {}
    for i = 1, max_len do
        local ch = raw_input:sub(i, i)
        if right_set[ch] then
            sets[i] = {ch}
        elseif left_to_right[ch] then
            sets[i] = {ch, left_to_right[ch]}
        else
            sets[i] = {ch}
        end
    end
    return sets
end

-- 根据 use_key_pairs 构建字母集合（传统模式）
local function build_letter_sets_legacy(input_str, max_len, use_pairs, left_to_right)
    max_len = max_len or #input_str
    local sets = {}
    for i = 1, max_len do
        local ch = input_str:sub(i, i)
        if use_pairs and left_to_right[ch] then
            sets[i] = {ch, left_to_right[ch]}
        else
            sets[i] = {ch}
        end
    end
    return sets
end

local function matches_letter_sets(candidate_code, letter_sets)
    if not candidate_code or candidate_code == "" then return false end
    local need = #letter_sets
    if #candidate_code < need then return false end
    for i = 1, need do
        local char = candidate_code:sub(i, i)
        local set = letter_sets[i]
        local found = false
        for _, letter in ipairs(set) do
            if char == letter then
                found = true
                break
            end
        end
        if not found then return false end
    end
    return true
end

local function matches_prefix(cand, input_str, n, use_pairs, left_to_right, right_set, raw_input)
    if n == 0 then return true end
    
    local wubi_code = get_candidate_wubi_code(cand)
    if wubi_code == "" then return true end

    local letter_sets
    if raw_input and #raw_input >= n then
        letter_sets = build_letter_sets_mixed(raw_input, n, left_to_right, right_set)
    else
        letter_sets = build_letter_sets_legacy(input_str, n, use_pairs, left_to_right)
    end
    
    if matches_letter_sets(wubi_code, letter_sets) then
        return true
    end
    
    local preedit = cand.preedit or ""
    preedit = preedit:gsub("[%s%p]", ""):lower()
    if preedit ~= "" then
        return matches_letter_sets(preedit, letter_sets)
    end
    
    return false
end

-- 拼音首字母缓存，避免重复查询反向数据库
local pinyin_initial_cache = setmetatable({}, { __mode = "v" })
local MAX_PINYIN_CACHE_SIZE = 3000

-- 清理过期拼音缓存
local function clean_pinyin_cache()
    local count = 0
    for k in pairs(pinyin_initial_cache) do
        count = count + 1
    end
    if count > MAX_PINYIN_CACHE_SIZE then
        local i = 0
        for k in pairs(pinyin_initial_cache) do
            pinyin_initial_cache[k] = nil
            i = i + 1
            if i >= count - MAX_PINYIN_CACHE_SIZE then break end
        end
    end
end

local function get_pinyin_initial(char, spll_rvdb)
    if not char or char == '' then return nil end
    
    -- 优先从缓存中获取
    if pinyin_initial_cache[char] then
        return pinyin_initial_cache[char]
    end
    
    local spll_raw = spll_rvdb:lookup(char)
    if not spll_raw or spll_raw == '' then return nil end
    local clean_raw = spll_raw:gsub("※", "")
    local pinyin = clean_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')
    if pinyin == '' or pinyin == clean_raw then
        pinyin = spll_raw:match("^([^,]+)")
    end
    if not pinyin or pinyin == '' then return nil end
    local initial = pinyin:sub(1,1):lower()
    if pinyin:sub(1,2) == 'zh' then initial = 'z'
    elseif pinyin:sub(1,2) == 'ch' then initial = 'c'
    elseif pinyin:sub(1,2) == 'sh' then initial = 's'
    end
    
    -- 缓存结果
    pinyin_initial_cache[char] = initial
    clean_pinyin_cache()
    
    return initial
end

local function build_pinyin_filter_set(letter, left_to_right, right_set, raw_letter, use_pairs)
    local set = {}
    local valid_initials = {
        b=true,c=true,d=true,f=true,g=true,h=true,j=true,k=true,
        l=true,m=true,n=true,p=true,q=true,r=true,s=true,t=true,
        w=true,x=true,y=true,z=true
    }
    local function add_if_valid(ch)
        if valid_initials[ch] then set[ch] = true end
    end

    if raw_letter then
        if right_set[raw_letter] then
            add_if_valid(raw_letter)
        elseif left_to_right[raw_letter] then
            add_if_valid(raw_letter)
            add_if_valid(left_to_right[raw_letter])
        else
            add_if_valid(raw_letter)
        end
    else
        if use_pairs and left_to_right[letter] then
            add_if_valid(letter)
            add_if_valid(left_to_right[letter])
        else
            add_if_valid(letter)
        end
    end
    return set
end

local function make_candidate_key(cand) return tostring(cand.text) end

local function clone_candidate(cand, new_start, new_end, new_preedit)
    local comment = tostring(cand.comment or "")
    local text = tostring(cand.text or "")
    local preedit = new_preedit or tostring(cand.preedit or "")
    local new_cand = Candidate(cand.type, new_start, new_end, text, comment, preedit)
    if cand.quality then new_cand.quality = cand.quality end
    if cand.label then new_cand.label = cand.label end
    return new_cand
end

local function get_target_char(cand, use_last_char)
    local text = cand.text
    if not text or text == '' then return nil end
    local chars = utf8chars(text)
    if #chars == 0 then return nil end
    if use_last_char then
        return chars[#chars]
    else
        return chars[1]
    end
end

local function is_z_pinyin_input(input_str)
    return input_str:match("^z[a-z]+$") ~= nil
end

-- ===================================================================
-- 主过滤器
-- ===================================================================
local function filter(input, env)
    local context = env.engine.context
    local input_str = context.input or ""

    

    if input_str:find("^/") or input_str:find("^z") then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    local sanitized_input = input_str:gsub("[`' ]", "")
    local input_len = #sanitized_input
    local is_z_pinyin = is_z_pinyin_input(input_str)

    local raw_input = context:get_property("raw_input") or ""
    local pure_code = sanitized_input:gsub("[^a-z]", "")
    local pure_code_len = #pure_code

    local use_mixed = (#raw_input == pure_code_len and raw_input ~= "")

    if input_str:find("[`']") or sanitized_input:find("[^%a]") then
        if pure_code_len == 0 then
            for cand in input:iter() do
                yield(cand)
            end
            return
        end
        for cand in input:iter() do
            if not is_z_pinyin then
                if matches_prefix(cand, pure_code, pure_code_len, env.use_key_pairs, env.left_to_right, env.right_set, use_mixed and raw_input or nil) then
                    yield(cand)
                end
            else
                yield(cand)
            end
        end
        return
    end

    if is_z_pinyin then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    if not env.spll_rvdb then
        for cand in input:iter() do
            if matches_prefix(cand, sanitized_input, input_len, env.use_key_pairs, env.left_to_right, env.right_set, use_mixed and raw_input or nil) then
                yield(cand)
            end
        end
        return
    end

    if pure_code_len == 5 then
        local pinyin_filter = pure_code:sub(5,5):lower()
        local raw_letter = use_mixed and raw_input:sub(5,5) or nil
        local pinyin_filters = build_pinyin_filter_set(pinyin_filter, env.left_to_right, env.right_set, raw_letter, env.use_key_pairs)
        local matched = {}
        local seen = {}
        local original = {}

        for cand in input:iter() do
            table.insert(original, cand)
            local prefix_ok = matches_prefix(cand, pure_code, 4, env.use_key_pairs, env.left_to_right, env.right_set, use_mixed and raw_input:sub(1,4) or nil)
            if not prefix_ok then
                goto continue
            end
            local target_char = get_target_char(cand, env.use_last_char)
            if target_char then
                local initial = get_pinyin_initial(target_char, env.spll_rvdb)
                if initial and pinyin_filters[initial] then
                    local key = make_candidate_key(cand)
                    if not seen[key] then
                        seen[key] = true
                        local orig_start = tonumber(cand.start) or cand.start
                        local orig_end = tonumber(cand._end) or cand._end
                        local out = cand
                        if orig_start ~= 0 or orig_end ~= pure_code_len then
                            out = clone_candidate(cand, 0, pure_code_len, cand.preedit)
                        end
                        table.insert(matched, out)
                    end
                end
            end
            ::continue::
        end

        if #matched > 0 then
            table.sort(matched, function(a,b) return (a.quality or 0) > (b.quality or 0) end)
            for _, cand in ipairs(matched) do yield(cand) end
        else
            for _, cand in ipairs(original) do
                if matches_prefix(cand, pure_code, 4, env.use_key_pairs, env.left_to_right, env.right_set, use_mixed and raw_input:sub(1,4) or nil) then
                    yield(cand)
                end
            end
        end
        return
    end

    for cand in input:iter() do
        if matches_prefix(cand, sanitized_input, input_len, env.use_key_pairs, env.left_to_right, env.right_set, use_mixed and raw_input or nil) then
            yield(cand)
        end
    end
end

return { init = init, func = filter }