--[[
    统一拆分模块 - 整合版（自动适配纯五笔 / 五笔拼音混输）
    功能：提供汉字字根拆分、拼音、编码等注解功能
    作者: 空山明月、shawx、Liuyt151
    日期：2025-10-25
    优化日期: 2026-05-20
    用途: 独立的拆分过滤器模块，根据方案自动切换行为（纯五笔 or 混输）
    版本: 整合版 - 通过 schema 中的 mixed_input 标志自动适配
]]

-- =================================================================
-- == 配置参数 ==
-- =================================================================

local spelling_keyword = "new_spelling"        -- 字根显示开关
local phrase_pinyin_keyword = "new_phrase_pinyin"  -- 词组拼音开关（仅混输有效）

-- =================================================================
-- == 基础工具库 ==
-- =================================================================

local basic = require('lib/basic')
local map = basic.map
local index = basic.index
local utf8chars = basic.utf8chars
local matchstr = basic.matchstr

-- =================================================================
-- == 工具函数 ==
-- =================================================================

-- 判断字符串是否包含汉字（用于快速放行非汉字候选项）
local function has_chinese(str)
    return str:match("[\228-\233][\128-\191][\128-\191]") ~= nil
end

-- 格式化输入字符串（替换特殊字符为可读符号）
local function xform(input)
    if input == "" then return "" end
    input = input:gsub('%[', '〈')
    input = input:gsub('%]', '〉')
    input = input:gsub('※', ' ')
    input = input:gsub('_', ' ')
    input = input:gsub(',', '·')
    return input
end

-- 数据库查询包装函数
local function lookup(db)
    return function (str)
        return db:lookup(str)
    end
end

-- 解析字根拆分结果（移除额外信息）
local function parse_spll(str)
    local s = string.gsub(str, ',.*', '')
    return string.gsub(s, '^%[', '')
end

-- 解析编码结果（提取第二个字段）
local function parse_encode(str)
    local s = string.gsub(str, '%[(.-),(.-),(.-),(.-)%]', '[%2]')
    return string.gsub(s, '^%[', '')
end

-- 字根拆分字符串处理（提取指定位置的部件）
local function subspelling(str, first, last)
    if not first then return str end
    local radicals = {}
    local s = str
    s = s:gsub('{', ' {')
    s = s:gsub('}', '} ')
    for seg in s:gmatch('%S+') do
        if seg:find('^{.+}$') then
            table.insert(radicals, seg)
        else
            for pos, code in utf8.codes(seg) do
                table.insert(radicals, utf8.char(code))
            end
        end
    end
    return table.concat{ table.unpack(radicals, first, last) }
end

-- =================================================================
-- == 核心功能函数 ==
-- =================================================================

-- 词组字根拆分处理（用于"隐声"模式下的词组注释）
local function spell_phrase(s, spll_rvdb)
    local chars = utf8chars(s)
    local rvlk_results

    if #chars == 2 or #chars == 3 then
        rvlk_results = map(chars, lookup(spll_rvdb))
    else
        rvlk_results = map({chars[1], chars[2], chars[3], chars[#chars]}, lookup(spll_rvdb))
    end

    if index(rvlk_results, '') then return '' end

    local spellings = map(rvlk_results, parse_spll)
    local sup = '◇'

    if #chars == 2 then
        return subspelling(spellings[1] .. sup, 2, 2) ..
               subspelling(spellings[1] .. sup, 4, 4) ..
               subspelling(spellings[2] .. sup, 2, 2) ..
               subspelling(spellings[2] .. sup, 4, 4)
    elseif #chars == 3 then
        return subspelling(spellings[1], 2, 2) ..
               subspelling(spellings[2], 2, 2) ..
               subspelling(spellings[3] .. sup, 2, 2) ..
               subspelling(spellings[3] .. sup, 4, 4)
    else
        return subspelling(spellings[1], 2, 2) ..
               subspelling(spellings[2], 2, 2) ..
               subspelling(spellings[3], 2, 2) ..
               subspelling(spellings[4], 2, 2)
    end
end

-- GB2312字符集过滤
local function isgb2312(cand, env)
    local ctext = cand.text
    if string.find(ctext, "〇") then
        return 1
    end
    if utf8.len(ctext) == 1 then
        local spll_raw = env.spll_rvdb:lookup(ctext)
        if spll_raw ~= '' then
            local chars = xform(spll_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '[%4]'))
            return chars:find("GB2312") and 1 or 0
        else
            return 1
        end
    elseif utf8.len(ctext) > 1 then
        local arr = utf8chars(ctext)
        for i = 1, #arr do
            local spll_raw = env.spll_rvdb:lookup(arr[i])
            if spll_raw ~= '' then
                local chars = xform(spll_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '[%4]'))
                if chars:find("GBK") then return 0 end
            end
        end
        return 1
    end
end

-- 获取英文编码（用于 prompt 提示）
local function get_en_code(s, spll_rvdb)
    local chars = utf8chars(s)
    local rvlk_results

    if #chars == 2 or #chars == 3 or #chars == 1 then
        rvlk_results = map(chars, lookup(spll_rvdb))
    else
        rvlk_results = map({chars[1], chars[2], chars[3], chars[#chars]}, lookup(spll_rvdb))
    end

    if index(rvlk_results, '') then return '' end

    local spellings = map(rvlk_results, parse_encode)

    if #chars == 1 then
        return spellings[1]:gsub('[^%a]+','')
    elseif #chars == 2 then
        return spellings[1]:gsub('[^%a]+',''):sub(1,2) ..
               spellings[2]:gsub('[^%a]+',''):sub(1,2)
    elseif #chars == 3 then
        return spellings[1]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[2]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[3]:gsub('[^%a]+',''):sub(1,2)
    else
        return spellings[1]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[2]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[3]:gsub('[^%a]+',''):sub(1,1) ..
               spellings[4]:gsub('[^%a]+',''):sub(1,1)
    end
end

-- 三重注解获取函数（根据方案类型和开关组合生成注释）
local function get_tricomment(cand, env)
    local ctext = cand.text
    local show_spelling = env.engine.context:get_option(spelling_keyword)      -- 显根/隐根
    local hide_pinyin = env.engine.context:get_option("new_hide_pinyin")      -- 显拼/隐拼
    local hide_code = env.engine.context:get_option("new_hide_code")          -- 显码/隐码
    local show_phrase_pinyin = env.is_mixed and env.engine.context:get_option(phrase_pinyin_keyword) or false  -- 显声/隐声（仅混输有效）

    local spll_raw = env.spll_rvdb:lookup(ctext)
    if spll_raw == '' then return '' end

    local spelling = xform(spll_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '[%1]'))      -- 字根
    local pinyin = xform(spll_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '[%3]'))        -- 拼音
    local code = xform(spll_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '[%2]'))           -- 编码

    -- 单字处理
    if utf8.len(ctext) == 1 then
        if env.is_mixed and show_phrase_pinyin then
            return pinyin   -- 混输"显声"模式单字只显拼音
        end

        if show_spelling then   -- 显根：包含字根
            local parts = {spelling}
            if not hide_pinyin then table.insert(parts, pinyin) end
            if not hide_code then table.insert(parts, code) end
            return table.concat(parts, ' · ')
        else                    -- 隐根：不包含字根
            local parts = {}
            if not hide_pinyin then table.insert(parts, pinyin) end
            if not hide_code then table.insert(parts, code) end
            if #parts > 0 then return table.concat(parts, ' · ') else return '' end
        end
    -- 词组处理
    else
        -- 混输且显声模式：显示词组拼音
        if env.is_mixed and show_phrase_pinyin then
            local chars = utf8chars(ctext)
            local pinyins = {}
            local has_valid_pinyin = false
            for i = 1, #chars do
                local char_raw = env.spll_rvdb:lookup(chars[i])
                if char_raw ~= '' then
                    local char_pinyin = xform(char_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '[%3]'))
                    table.insert(pinyins, char_pinyin)
                    has_valid_pinyin = true
                end
            end
            if has_valid_pinyin then
                local pinyin_str = table.concat(pinyins, ' · ')
                return '〈 ' .. pinyin_str .. ' 〉'
            end
        end

        -- 纯五笔 或 混输隐声模式：显示词组字根拆分
        local phrase_spelling = spell_phrase(ctext, env.spll_rvdb)
        if phrase_spelling ~= '' then
            phrase_spelling = phrase_spelling:gsub('{(.-)}', '<%1>')
            return '〈 ' .. phrase_spelling .. ' 〉'
        end
    end

    return ''
end

-- 检查是否通过GB2312字符集过滤
local function pass_gb2312_filter(cand, env)
    return isgb2312(cand, env) == 1 and env.engine.context:get_option("GB2312") or not env.engine.context:get_option("GB2312")
end

-- =================================================================
-- == 配置读取函数（用于获取水平样式配置）==
-- =================================================================

local function formatDir(path, filename)
    if path:find("\\") then
        return path .. "\\" .. filename
    elseif path:find("/") then
        return path .. "/" .. filename
    else
        return path .. "\\" .. filename
    end
end

local function get_item(filepath, item)
    local file = io.open(filepath, "rb")
    if file then
        local isexist = nil
        for line in file:lines() do
            if line:find(item) and not line:find("(%#)") then
                isexist = line:gsub('(.-):%s*(.-)', '%2')
            end
        end
        file:close()
        return isexist
    end
end

local function get_horizontal_style(filename, item)
    local shared_data_dir = rime_api.get_shared_data_dir()
    local user_data_dir = rime_api.get_user_data_dir()

    local flag = get_item(formatDir(user_data_dir, filename), item)
    if flag ~= nil then return flag end

    flag = get_item(formatDir(user_data_dir, "weasel.custom.yaml"), item)
    if flag ~= nil then return flag end

    return get_item(formatDir(shared_data_dir, filename), item)
end

-- =================================================================
-- == 主过滤器函数 ==
-- =================================================================

local function filter(input, env)
    local script_text = env.engine.context:get_script_text()
    local hide_pinyin = env.engine.context:get_option("new_hide_pinyin")
    local hide_code = env.engine.context:get_option("new_hide_code")
    local schema_id = env.engine.schema.schema_id or ""
    local spelling_states = env.engine.context:get_option(spelling_keyword)
    local composition = env.engine.context.composition
    local segment = composition:back()

    local horizontal = get_horizontal_style(schema_id .. ".custom.yaml", "style/horizontal") or ""

    -- 检测是否为纯拼音输入（仅混输时有效）
    local is_pinyin_input = env.is_mixed and
        script_text:match("^[a-z]+$") and
        not script_text:match("^[zvw][a-z]+$") and
        not script_text:match("^[%`%~z/]") and
        not script_text:match(".*[`].*")

    -- 显根模式（spelling_states = true）时的处理
    if spelling_states then
        for cand in input:iter() do
            if pass_gb2312_filter(cand, env) then
                -- 不含汉字的候选项（如日程命令、统计数字）直接输出
                if env.is_mixed and not has_chinese(cand.text) then
                    yield(cand)
                else
                    -- 混输 + 纯拼音输入模式：为候选项添加注释
                    if env.is_mixed and is_pinyin_input then
                        local add_comment = get_tricomment(cand, env)
                        if add_comment ~= nil and add_comment ~= "" then
                            yield(Candidate("pinyin_spelling", cand.start, cand._end, cand.text, add_comment))
                        else
                            yield(cand)
                        end
                    -- 简繁转换器特殊命名空间处理
                    elseif cand.type == 'simplifier' and env.name_space == 'new_for_rvlk' then
                        if cand.comment == "" then
                            local comment = get_tricomment(cand, env)
                            yield(Candidate(spelling_keyword, cand.start, cand._end, cand.text, comment))
                        end
                    -- 普通候选项处理
                    else
                        -- z键或/键引导的反查/命令输入
                        if script_text:find("^z[a-z]*") and not script_text:find("%p$") or
                           script_text:find("^([%/])[a-z]*") and not script_text:find("%p$") then
                            local add_comment = get_tricomment(cand, env)
                            local code_comment = env.code_rvdb:lookup(cand.text)

                            if add_comment ~= nil and add_comment ~= "" then
                                if cand.comment == "" then
                                    yield(Candidate(spelling_keyword, cand.start, cand._end, cand.text, add_comment))
                                else
                                    if cand.comment:find("(☯)") then
                                        segment.prompt = "〈编码：" .. get_en_code(cand.text, env.spll_rvdb) .. "〉"
                                        yield(cand)
                                    else
                                        if utf8.len(cand.text) == 1 and code_comment and not hide_pinyin then
                                            -- [修复] 恢复完整三重注解：字根 · 编码 · 拼音
                                            yield(Candidate(spelling_keyword, cand.start, cand._end, cand.text,
                                                xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '[%1'..' · '..'%2'..' · '..'%3]'))))
                                        else
                                            yield(Candidate(spelling_keyword, cand.start, cand._end, cand.text,
                                                add_comment:gsub("〉"," · ") .. cand.comment .. " 〉"))
                                        end
                                    end
                                end
                            else
                                yield(cand)
                            end
                        -- ~键引导的注音查询
                        elseif script_text:find("^([%~])[a-z]*") and not script_text:find("%p$") and
                               env.engine.context:get_option("rvl_zhuyin") then
                            local code_comment = env.code_rvdb:lookup(cand.text)
                            if code_comment ~= "" then
                                code_comment = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '[%3'..' · '..'%1]'))
                                yield(Candidate("rvl_zhuyin", cand.start, cand._end, cand.text, code_comment))
                            else
                                yield(cand)
                            end
                        -- 其他普通输入
                        else
                            local add_comment = ''
                            local code_comment = env.code_rvdb:lookup(cand.text)

                            if cand.comment:find("(☯)") and script_text:find("^%`*(%l+%`%l+)") then
                                segment.prompt = "〈编码：" .. get_en_code(cand.text, env.spll_rvdb) .. "〉"
                            end

                            if cand.type == 'punct' then
                                add_comment = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '[%1'..' · '..'%2'..' · '..'%3]'))
                            elseif cand.type ~= 'sentence' then
                                if cand.comment == "" then
                                    add_comment = get_tricomment(cand, env)
                                end
                            end

                            if add_comment ~= '' then
                                cand.comment = add_comment
                            end

                            yield(cand)
                        end
                    end
                end
            end
        end
    -- 隐根模式（spelling_states = false）时的处理
    else
        -- z键引导的查询（隐根模式下仍可显示拼音/编码）
        if script_text:find("^z") then
            for cand in input:iter() do
                if pass_gb2312_filter(cand, env) then
                    local show_phrase_pinyin = env.is_mixed and env.engine.context:get_option(phrase_pinyin_keyword) or false

                    if env.is_mixed and show_phrase_pinyin and utf8.len(cand.text) > 1 then
                        -- 混输显声：词组拼音
                        local chars = utf8chars(cand.text)
                        local pinyins = {}
                        local has_valid_pinyin = false
                        for i = 1, #chars do
                            local char_raw = env.spll_rvdb:lookup(chars[i])
                            if char_raw ~= '' then
                                local char_pinyin = xform(char_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '[%3]'))
                                table.insert(pinyins, char_pinyin)
                                has_valid_pinyin = true
                            end
                        end
                        if has_valid_pinyin then
                            cand.comment = '〈 ' .. table.concat(pinyins, ' · ') .. ' 〉'
                        else
                            cand.comment = ""
                        end
                        yield(cand)
                    elseif env.is_mixed and show_phrase_pinyin and utf8.len(cand.text) == 1 then
                        -- 混输显声：单字拼音
                        local code_comment = env.code_rvdb:lookup(cand.text)
                        if code_comment ~= "" then
                            cand.comment = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '[%3]'))
                        else
                            cand.comment = ""
                        end
                        yield(cand)
                    else
                        local parts = {}
                        -- 显拼
                        if not hide_pinyin and utf8.len(cand.text) == 1 then
                            local code_comment = env.code_rvdb:lookup(cand.text)
                            if code_comment ~= "" then
                                table.insert(parts, xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '[%3]')))
                            end
                        end
                        -- 显码
                        if not hide_code and utf8.len(cand.text) == 1 then
                            local code_comment = env.code_rvdb:lookup(cand.text)
                            if code_comment ~= "" then
                                table.insert(parts, xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '[%2]')))
                            end
                        end
                        if #parts > 0 then
                            cand.comment = table.concat(parts, ' · ')
                        else
                            cand.comment = ""
                        end
                        yield(cand)
                    end
                end
            end
        -- ~键引导的注音查询（隐根模式）
        elseif script_text:find("^([%~])[a-z]*") and not script_text:find("%p$") and
               env.engine.context:get_option("rvl_zhuyin") then
            for cand in input:iter() do
                if pass_gb2312_filter(cand, env) then
                    local code_comment = env.code_rvdb:lookup(cand.text)
                    if code_comment ~= "" then
                        code_comment = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '%3')):gsub("^%s+",""):gsub("%s+$","")
                        if code_comment:find("%s") then
                            code_comment = code_comment:gsub("%s+"," · ")
                        end
                        yield(Candidate("zhuyin_rvlk", cand.start, cand._end, cand.text, " " .. code_comment))
                    end
                end
            end
        -- 其他普通输入（隐根模式）
        else
            for cand in input:iter() do
                if pass_gb2312_filter(cand, env) then
                    local parts = {}
                    local show_phrase_pinyin = env.is_mixed and env.engine.context:get_option(phrase_pinyin_keyword) or false

                    if env.is_mixed and show_phrase_pinyin and utf8.len(cand.text) > 1 then
                        -- 混输显声：词组拼音
                        local chars = utf8chars(cand.text)
                        local pinyins = {}
                        local has_valid_pinyin = false
                        for i = 1, #chars do
                            local char_raw = env.spll_rvdb:lookup(chars[i])
                            if char_raw ~= '' then
                                local char_pinyin = xform(char_raw:gsub('%[(.-),(.-),(.-),(.-)%]', '[%3]'))
                                table.insert(pinyins, char_pinyin)
                                has_valid_pinyin = true
                            end
                        end
                        if has_valid_pinyin then
                            cand.comment = '〈 ' .. table.concat(pinyins, ' · ') .. ' 〉'
                        end
                        yield(cand)
                    elseif env.is_mixed and show_phrase_pinyin and utf8.len(cand.text) == 1 then
                        -- 混输显声：单字拼音
                        local code_comment = env.code_rvdb:lookup(cand.text)
                        if code_comment ~= "" then
                            cand.comment = xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '[%3]'))
                        else
                            cand.comment = ""
                        end
                        yield(cand)
                    else
                        -- 纯五笔或混输隐声模式
                        if not hide_pinyin and utf8.len(cand.text) == 1 then
                            local code_comment = env.code_rvdb:lookup(cand.text)
                            if code_comment ~= "" then
                                table.insert(parts, xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '[%3]')))
                            end
                        end
                        if not hide_code and utf8.len(cand.text) == 1 then
                            local code_comment = env.code_rvdb:lookup(cand.text)
                            if code_comment ~= "" then
                                table.insert(parts, xform(code_comment:gsub('%[(.-),(.-),(.-),(.-)%]', '[%2]')))
                            end
                        end
                        if #parts > 0 then
                            cand.comment = table.concat(parts, ' · ')
                        else
                            cand.comment = ""
                        end

                        -- 特殊符号提示
                        if cand.comment:find("(☯)") and script_text:find("^%`*(%l+%`%l+)") then
                            segment.prompt = "〈编码：" .. get_en_code(cand.text, env.spll_rvdb) .. "〉"
                        end

                        yield(cand)
                    end
                end
            end
        end
    end
end

-- =================================================================
-- == 初始化函数 ==
-- =================================================================

local function init(env)
    local config = env.engine.schema.config
    page_size = env.engine.schema.page_size
    local spll_rvdb = config:get_string('lua_reverse_db/spelling')
    local code_rvdb = config:get_string('lua_reverse_db/code')
    local abc_extags_size = config:get_list_size('abc_segmentor/extra_tags')

    env.spll_rvdb = ReverseDb('build/' .. spll_rvdb .. '.reverse.bin')
    env.code_rvdb = ReverseDb('build/' .. code_rvdb .. '.reverse.bin')
    env.is_mixtyping = abc_extags_size > 0

    -- 判断是否为混输方案：通过 schema 中的 custom 开关或 schema_id 特征
    -- 优先读取 engine/mixed_input 配置（需在 schema 中定义）
    local mixed_input = config:get_bool('engine/mixed_input')
    if mixed_input == nil then
        -- 备选：根据 schema_id 是否包含 "mix" 或 "pinyin" 判断
        local schema_id = env.engine.schema.schema_id or ""
        mixed_input = schema_id:find("mix") ~= nil or schema_id:find("pinyin") ~= nil
    end
    env.is_mixed = mixed_input
end

-- =================================================================
-- == 模块导出 ==
-- =================================================================

return { init = init, func = filter }
