-- 单字/词组优先过滤器
-- 功能：根据用户设置，优先显示单字或词组
-- 作者：基于TouchWB项目扩展
-- 日期：2026-05-20

local basic = require('lib/basic')
local utf8chars = basic.utf8chars

-- 开关配置
local single_char_priority_key = "single_char_priority"  -- 单字优先开关
local phrase_priority_key = "phrase_priority"            -- 词组优先开关

-- 主过滤器函数
local function filter(input, env)
    local context = env.engine.context
    local single_char_priority = context:get_option(single_char_priority_key) or false
    local phrase_priority = context:get_option(phrase_priority_key) or false

    -- 如果两个开关都没开，直接返回原候选
    if not single_char_priority and not phrase_priority then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 收集所有候选
    local candidates = {}
    for cand in input:iter() do
        table.insert(candidates, cand)
    end

    -- 根据设置排序
    if single_char_priority then
        -- 单字优先：单字排在前面，词组排在后面
        local single_chars = {}
        local phrases = {}
        
        for _, cand in ipairs(candidates) do
            local len = utf8.len(cand.text)
            if len == 1 then
                table.insert(single_chars, cand)
            else
                table.insert(phrases, cand)
            end
        end

        -- 先输出单字，再输出词组
        for _, cand in ipairs(single_chars) do
            yield(cand)
        end
        for _, cand in ipairs(phrases) do
            yield(cand)
        end
    elseif phrase_priority then
        -- 词组优先：词组排在前面，单字排在后面
        local single_chars = {}
        local phrases = {}
        
        for _, cand in ipairs(candidates) do
            local len = utf8.len(cand.text)
            if len == 1 then
                table.insert(single_chars, cand)
            else
                table.insert(phrases, cand)
            end
        end

        -- 先输出词组，再输出单字
        for _, cand in ipairs(phrases) do
            yield(cand)
        end
        for _, cand in ipairs(single_chars) do
            yield(cand)
        end
    end
end

return { func = filter }
