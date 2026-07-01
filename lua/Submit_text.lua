--[[
    Submit_text.lua - 自造词管理与辅助输入处理器
    功能：自造词、手动造词、反查、标点快捷输入
    作者: 空山明月、shawx、liuyt151
    日期: 2026-06-06
    优化: 统一26键和14键的造词编码生成逻辑，优先从字典查询标准五笔编码
    优化: 修复翻译器场景下 is_14key_layout 函数调用问题
    优化: 14键造词时支持模糊输入，保存时自动生成标准五笔编码
    优化: 清理冗余代码，统一文件路径，移除移动设备检测

    【主要功能】
    1. 自造词手动模式：输入"词条`编码"后按空格键，自动追加到 user_coined_ext.txt
    2. 自造词即时查询：实时读取用户词库，高优先级显示用户自定义词条
    3. 反查功能：按单引号键快速上屏第三候选项（table/reverse_lookup类型）
    4. 快捷上屏：分号键上屏第二候选，单引号键上屏第三候选
    5. 智能编码生成：无论26键还是14键，保存时自动查询标准五笔编码

    【编码规则】
    - 2字词：每字取前2位
    - 3字词：第1字1位，第2字1位，第3字2位
    - 4字及以上：前3字各1位，最后1字1位
    - 单字：取前4位

    【14键双键布局支持】
    按键映射关系（右边字母 → 左边字母）：
    - W → Q, R → E, Y → T, I → U, P → O
    - S → A, F → D, H → G, K → J
    - C → X, B → V, M → N

    自造词支持16种组合：左左左左、左左左右、左左右左、左左右右、
                         左右左左、左右左右、左右右左、左右右右、
                         右左左左、右左左右、右左右左、右左右右、
                         右右左左、右右左右、右右右左、右右右右

    【使用说明】
    1. 手动造词：输入编码（可模糊）+ 反引号 + 编码（可模糊）... → 选择候选词后按空格键确认
    2. 智能编码：无论输入模糊编码还是精确编码，保存时自动从字典查询生成标准五笔编码
    3. 快捷上屏：分号键上屏第二候选，单引号键上屏第三候选（反查/表格模式）
    4. 用户词库路径：{user_data_dir}/user_coined_ext.txt，即时生效无需重部署
    5. 格式：词条<Tab>编码
    6. 支持跨平台：Windows/macOS/Linux/Android(HarmonyOS)，实现跨平台自造词共享
]]

local basic = require('lib/basic')
local utf8chars = basic.utf8chars

-- =================================================================
-- == 14键双键布局映射模块 ==
-- =================================================================

local key_mapping = {
    w = 'q', r = 'e', y = 't', i = 'u', p = 'o',
    s = 'a', f = 'd', h = 'g', k = 'j',
    c = 'x', b = 'v', m = 'n'
}

local function get_key_pair(c)
    local left = key_mapping[c]
    if left then
        return left, c
    end
    for right, left_char in pairs(key_mapping) do
        if left_char == c then
            return c, right
        end
    end
    return c, nil
end

-- 将任意14键编码标准化为"左字母形式"（例如 ws → qa）
-- 使用 table.concat 提高字符串拼接效率
local function normalize_14key(code)
    if not code or code == "" then
        return code
    end
    local norm = {}
    for i = 1, #code do
        local c = code:sub(i, i)
        local left = key_mapping[c] or c
        table.insert(norm, left)
    end
    return table.concat(norm)
end

local function match_encoding(input_code, stored_code)
    if input_code == stored_code then
        return true
    end
    
    local normalized_input = normalize_14key(input_code)
    local normalized_stored = normalize_14key(stored_code)
    
    return normalized_input == normalized_stored
end

-- 判断当前是否为14键布局
local function is_14key_layout(env)
    local engine = env and env.engine
    if not engine then
        -- 尝试从上下文获取（翻译器场景）
        local ctx = env and env._context
        if ctx and ctx.engine then
            engine = ctx.engine
        end
    end
    if not engine or not engine.schema then
        return false
    end
    local schema_id = engine.schema.schema_id
    return schema_id and (schema_id == "wubi_14" or schema_id == "wubi_pinyin_mix_14")
end

-- =================================================================
-- == 标准五笔编码查询模块 ==
-- =================================================================

-- 单字编码缓存，避免重复读取字典
local char_code_cache = {}

-- 从字典文件中查询单个汉字的标准五笔编码
local function get_char_wubi_code(char)
    -- 优先从缓存中获取
    if char_code_cache[char] then
        return char_code_cache[char]
    end
    
    -- 获取可能的字典文件路径
    local dict_paths = {}
    
    -- 1. 尝试用户数据目录
    local user_dir = ""
    if rime_api and rime_api.get_user_data_dir then
        user_dir = rime_api.get_user_data_dir() or ""
    end
    if user_dir ~= "" then
        user_dir = user_dir:gsub("\\", "/")
        if user_dir:sub(-1) ~= "/" then
            user_dir = user_dir .. "/"
        end
        table.insert(dict_paths, user_dir .. "wubi.dict.yaml")
        table.insert(dict_paths, user_dir .. "wubi.extended.dict.yaml")
    end
    
    -- 2. 尝试方案数据目录
    local schema_dir = ""
    if rime_api and rime_api.get_schema_data_dir then
        schema_dir = rime_api.get_schema_data_dir() or ""
    end
    if schema_dir ~= "" then
        schema_dir = schema_dir:gsub("\\", "/")
        if schema_dir:sub(-1) ~= "/" then
            schema_dir = schema_dir .. "/"
        end
        table.insert(dict_paths, schema_dir .. "wubi.dict.yaml")
        table.insert(dict_paths, schema_dir .. "wubi.extended.dict.yaml")
    end
    
    -- 3. 尝试共享数据目录（某些发行版可能在这里）
    if rime_api and rime_api.get_shared_data_dir then
        local shared_dir = rime_api.get_shared_data_dir() or ""
        if shared_dir ~= "" then
            shared_dir = shared_dir:gsub("\\", "/")
            if shared_dir:sub(-1) ~= "/" then
                shared_dir = shared_dir .. "/"
            end
            table.insert(dict_paths, shared_dir .. "wubi.dict.yaml")
            table.insert(dict_paths, shared_dir .. "wubi.extended.dict.yaml")
        end
    end
    
    local code = ""
    local max_weight = 0
    local found_file = ""
    
    for _, dict_path in ipairs(dict_paths) do
        local f = io.open(dict_path, "r")
        if f then
            local in_data = false
            local line_num = 0
            for line in f:lines() do
                line_num = line_num + 1
                -- 去除行尾空白字符（处理不同平台的行尾符）
                local trimmed_line = line:gsub("%s+$", "")
                -- 跳过注释和元数据部分
                if trimmed_line == "..." then
                    in_data = true
                elseif trimmed_line == "---" then
                    in_data = false
                elseif in_data and not line:match("^#") then
                    -- 尝试匹配字典条目格式（支持制表符或空格分隔）
                    -- 格式：字符 编码 权重
                    local text, code_part, weight = line:match("^([^\t%s]+)[\t%s]+([a-z]+)[\t%s]+(%d+)")
                    if text and code_part then
                        -- 检查是否找到目标字符
                        if text == char then
                            local w = tonumber(weight) or 0
                            -- 选择权重最高的编码（通常是最常用的）
                            if w > max_weight then
                                max_weight = w
                                code = code_part
                                found_file = dict_path
                            end
                        end
                    else
                        -- 尝试更宽松的匹配
                        local text2, code_part2 = line:match("^([^\t%s]+)[\t%s]+([a-z]+)")
                        if text2 and code_part2 and text2 == char then
                            -- 如果没有权重字段，使用默认权重
                            if max_weight == 0 then
                                code = code_part2
                                found_file = dict_path
                            end
                        end
                    end
                end
            end
            f:close()
            if code ~= "" then
                break  -- 找到编码后就不再尝试其他文件
            end
        end
    end
    
    -- 缓存结果（包括空结果，避免重复查询）
    char_code_cache[char] = code
    return code
end

-- 根据词条内容生成标准五笔词组编码
local function generate_standard_code(text)
    if not text or text == "" then
        return ""
    end
    
    local len = utf8.len(text)
    if len == 0 then
        return ""
    end
    
    -- 获取每个字的标准编码
    local char_codes = {}
    for i, char in ipairs(utf8chars(text)) do
        local code = get_char_wubi_code(char)
        table.insert(char_codes, code)
    end
    
    -- 按五笔规则生成词组编码
    local result = ""
    
    if len == 1 then
        -- 单字：取前4位
        result = (char_codes[1] or ""):sub(1, 4)
    elseif len == 2 then
        -- 2字词：每字取前2位
        result = (char_codes[1] or ""):sub(1, 2) .. (char_codes[2] or ""):sub(1, 2)
    elseif len == 3 then
        -- 3字词：第1字1位，第2字1位，第3字2位
        result = (char_codes[1] or ""):sub(1, 1) ..
                 (char_codes[2] or ""):sub(1, 1) ..
                 (char_codes[3] or ""):sub(1, 2)
    elseif len >= 4 then
        -- 4字及以上：前3字各1位，最后1字1位
        result = (char_codes[1] or ""):sub(1, 1) ..
                 (char_codes[2] or ""):sub(1, 1) ..
                 (char_codes[3] or ""):sub(1, 1) ..
                 (char_codes[len] or ""):sub(1, 1)
    end
    
    return result
end

-- =================================================================
-- == 自造词路径管理模块 ==
-- =================================================================

local function get_rime_user_dir()
    if rime_api and rime_api.get_user_data_dir then
        return rime_api.get_user_data_dir() or ""
    end
    return ""
end

local function init_userphrase_path()
    local rime_dir = get_rime_user_dir()
    if rime_dir == "" then
        return ""
    end
    
    -- 统一使用正斜杠，跨平台兼容（Windows/macOS/Linux/Android）
    rime_dir = rime_dir:gsub("\\", "/")
    if rime_dir:sub(-1) ~= "/" then
        rime_dir = rime_dir .. "/"
    end
    
    return rime_dir .. "user_coined_ext.txt"
end

local userphrasepath = init_userphrase_path()

function get_userphrase_path()
    return userphrasepath
end

local function ensure_userphrase_file()
    if not userphrasepath or userphrasepath == "" then
        return
    end
    
    local f = io.open(userphrasepath, "r")
    if not f then
        f = io.open(userphrasepath, "w")
        if f then
            f:write("# 自造词文件\n")
            f:write("# 格式：词条<Tab>编码\n")
            f:write("# 即时生效，无需重新部署\n")
            f:close()
        end
    else
        f:close()
    end
end

-- =================================================================
-- == 辅助函数 ==
-- =================================================================

function splitinput(input, len)
    if not input or input == "" then
        return ""
    end
    
    -- 按反引号分割编码
    local codes = {}
    for code in input:gmatch("([^`]+)") do
        table.insert(codes, code)
    end

    local result = ""

    if len == 2 then
        -- 2字词：每字取前2位
        if #codes >= 2 then
            result = (codes[1] or ""):sub(1, 2) .. (codes[2] or ""):sub(1, 2)
        else
            result = input:sub(1, 4)
        end
    elseif len == 3 then
        -- 3字词：第1字1位，第2字1位，第3字2位
        if #codes >= 3 then
            result = (codes[1] or ""):sub(1, 1) ..
                     (codes[2] or ""):sub(1, 1) ..
                     (codes[3] or ""):sub(1, 2)
        else
            result = input:sub(1, 4)
        end
    elseif len >= 4 then
        -- 4字及以上：前3字各1位，最后1字1位
        if #codes >= len then
            result = (codes[1] or ""):sub(1, 1) ..
                     (codes[2] or ""):sub(1, 1) ..
                     (codes[3] or ""):sub(1, 1) ..
                     (codes[len] or ""):sub(1, 1)
        else
            result = input:sub(1, 4)
        end
    else
        -- 单字：直接返回原编码
        result = input:sub(1, 4)
    end

    return result
end

function fileappendtext(filepath, context, input, env)
    if not context or context == "" or context:find("%a") then
        return
    end
    
    local len = utf8.len(context)
    local clean_input = ""
    
    -- 统一使用 generate_standard_code 从字典查询标准五笔编码
    -- 这种方式无论26键还是14键都更加可靠，不依赖用户输入的编码
    clean_input = generate_standard_code(context)
    
    -- 如果字典查询失败（可能是生僻字），降级使用用户输入的编码
    if not clean_input or clean_input == "" then
        clean_input = splitinput(input, len)
    end
    
    if not clean_input or clean_input == "" then
        return
    end
    
    -- 检查是否已存在，避免重复写入相同词条和编码
    local normalized = context .. "\t" .. clean_input
    local f = io.open(filepath, "r")
    local exists = false
    if f then
        for line in f:lines() do
            if line == normalized then
                exists = true
                break
            end
        end
        f:close()
    end
    
    if not exists then
        f = io.open(filepath, "a")
        if f then
            f:write("\n" .. normalized)
            f:close()
        end
    end
end

-- =================================================================
-- == 处理器：自造词记录 ==
-- =================================================================

local function commit_text_processor(key, env)
    local engine = env.engine
    local context = engine.context
    local composition = context.composition
    local segment = composition:back()
    local input_text = context.input
    local candidate_count = 0

    -- 记录候选词（用于反查等功能）
    if input_text and input_text:find("^%p*(%a+%d*)$") then
        if context:has_menu() then
            candidate_count = segment.menu:candidate_count()
        end
        env.last_1th_text = context:get_commit_text() or ""
        env.last_2th_text = {text="", type=""}
        env.last_3th_text = {text="", type=""}
        if candidate_count > 1 then
            env.last_2th_text = segment:get_candidate_at(1)
            if candidate_count > 2 then
                env.last_3th_text = segment:get_candidate_at(2)
            end
        end
    end

    local key_code_num = tonumber(key.keycode) or key.keycode
    local is_space_key = (key_code_num == 0x20) or (key_code_num == 32)
    
    -- 手动造词：直接使用原始输入字符串（保留反引号）
    local function update_manual_userphrase()
        if input_text and input_text:find("`") then
            local commit_text = context:get_commit_text() or ""
            if commit_text ~= "" and not commit_text:find("%a") and utf8.len(commit_text) > 1 then
                env.userphrase = commit_text
                env.inputtext = input_text   -- 使用原始输入，保留反引号
                return
            end
        end
        env.userphrase = ""
        env.inputtext = ""
    end

    -- 处理手动造词：保存并上屏
    local function handle_manual_coin()
        if env.userphrase and env.userphrase ~= "" then
            ensure_userphrase_file()
            fileappendtext(userphrasepath, env.userphrase, env.inputtext, env)
            engine:commit_text(env.userphrase)  -- 上屏
            context:clear()                     -- 清空输入状态
            env.userphrase = ""
            env.inputtext = ""
            return true
        end
        return false
    end

    update_manual_userphrase()
    
    -- 一次空格立即提交当前候选（有候选菜单时），但保留反引号手动造词场景
    if is_space_key and context:has_menu() and not (input_text and input_text:find("`")) then
        local sel = nil
        if segment then sel = segment:get_selected_candidate() end
        if not sel then
            sel = context:get_selected_candidate()
        end
        if sel and sel.text and sel.text ~= "" then
            context:clear()
            engine:commit_text(sel.text)
            return 1
        end
    end

    -- 空格键触发手动造词保存
    if is_space_key and handle_manual_coin() then
        return 1
    end

    -- 反查功能（单引号键）
    if key.keycode == 0x27 and context:is_composing() and env.last_3th_text and env.last_3th_text.text ~= "" then
        if env.last_3th_text.type == "reverse_lookup" or env.last_3th_text.type == "table" then
            context:clear()
            engine:commit_text(env.last_3th_text.text)
            return 1
        end
    end

    -- 分号上屏第二候选
    if key.keycode == 0x3B and context:is_composing() and env.last_2th_text and env.last_2th_text.text ~= "" then
        context:clear()
        engine:commit_text(env.last_2th_text.text)
        return 1
    end
    
    return 2
end

-- =================================================================
-- == 翻译器：自造词即时查询 ==
-- =================================================================

local function user_coined_translator(input, seg, env)
    if not input or not input:match("^[a-z]+$") then
        return
    end
    
    if not userphrasepath or userphrasepath == "" then
        return
    end
    
    -- 限制：输入少于2个字母时不显示自造词，优先一级简码
    if #input < 2 then
        return
    end
    
    local file = io.open(userphrasepath, "r")
    if not file then
        return
    end
    
    -- 判断是否为14键布局
    local use_dual_key = is_14key_layout(env)
    
    -- 在循环外先标准化输入编码，避免重复计算
    local norm_input = use_dual_key and normalize_14key(input) or input
    
    local seen = {}
    local function yield_user_coined(text, quality)
        if seen[text] then
            return
        end
        seen[text] = true
        local cand = Candidate("user_coined", seg.start, seg._end, text, "")
        cand.quality = quality
        yield(cand)
    end

    for line in file:lines() do
        if not line:match("^#") and line ~= "" then
            local text, code = line:match("^([^\t]+)\t([a-z]+)")
            if text and code then
                local code_prefix = code:sub(1, #input)
                local exact_match = (code == input)
                local prefix_match = (#input >= 2 and code:find("^" .. input) == 1)
                
                -- 仅在14键布局时启用双键模糊匹配
                local dual_exact_match = false
                local dual_prefix_match = false
                if use_dual_key then
                    local norm_stored = normalize_14key(code)
                    local norm_stored_prefix = normalize_14key(code_prefix)
                    
                    dual_exact_match = (not exact_match and #input == #code and norm_input == norm_stored)
                    dual_prefix_match = (not exact_match and not prefix_match and #input >= 2 and #code >= #input and norm_input == norm_stored_prefix)
                end

                if exact_match then
                    yield_user_coined(text, 650)   -- 精确匹配：略高于主词典(500)和用户词典(510)
                elseif dual_exact_match then
                    yield_user_coined(text, 580)   -- 14键模糊精确匹配：低于精确匹配
                elseif prefix_match then
                    yield_user_coined(text, 550)   -- 前缀匹配：低于精确匹配
                elseif dual_prefix_match then
                    yield_user_coined(text, 480)   -- 14键模糊前缀匹配：最低优先级
                end
            end
        end
    end
    
    file:close()
end

-- =================================================================
-- == 模块导出 ==
-- =================================================================

rawset(_G, "user_coined_translator", user_coined_translator)

return commit_text_processor