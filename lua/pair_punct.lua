-- pair_punct.lua - 配对符号输入功能
-- author: kuroame, boomker, shawx
-- license: MIT
-- 雙符成形
--
-- 【方案配置说明】
-- 本脚本包含处理器和分段器，需在 schema.yaml 中添加以下配置：
--
-- engine:
--   processors:
--     - lua_processor@*pair_punct*processor   # 配对标点处理器
--   segmentors:
--     - lua_segmentor@*pair_punct*segmentor   # 配对标点分段器
--
-- switches:                                    # 添加开关控制
--   - name: pair_symbol
--     reset: 0
--     states: [ "关配", "开配" ]
--
-- 无需识别器配置，脚本通过符号白名单和配对表判断：
--   - pairTable 定义了所有支持配对的符号
--   - is_pure_symbol() 函数检查候选是否为配对符号

local M = {}
local processor = {}
local segmentor = {}

function get_selected_candidate_index(key_value, selected_index, page_size)
	local key_name = key_value
	local selected_cand_idx = -1
	local page_cand_size = page_size or 7
	
	if key_name == "space" then
		key_name = 0
	elseif key_name == "Return" then
		key_name = -1
	elseif key_name == "semicolon" then
		key_name = 1
	elseif key_name == "apostrophe" then
		key_name = 2
	elseif key_name:match("^[1-9]$") then
		key_name = tonumber(key_name) - 1
	elseif key_name == "0" then
		key_name = 9
	else
		return -1
	end

	local page_pos = math.floor(selected_index / page_cand_size) + 1
	local idx = key_name
	selected_cand_idx = ((type(key_name) == "number") and (page_pos > 1))
		and (key_name + (page_pos - 1) * page_cand_size) or idx
	return selected_cand_idx
end

local tag_prefix = "pair_punct_"

-- 确保单双引号映射精准（成对配置无误）
local pairTable = {
    ["`"] = { "`" },
    ["```"] = { "```" },
    ["“"] = { "“", "”" },
    ["”"] = { "“", "”" },
    ["‘"] = { "‘", "’" },
    ["’"] = { "‘", "’" },
    ["("] = { "(", ")" },
    ["["] = { "[", "]" },
    ["{"] = { "{", "}" },
    ["<"] = { "<", ">" },
    ["（"] = { "（", "）" },
    ["【"] = { "【", "】" },
    ["〔"] = { "〔", "〕" },
    ["〚"] = { "〚", "〛" },
    ["〘"] = { "〘", "〙" },
    ["「"] = { "「", "」" },
    ["」"] = { "「", "」" },
    ["［"] = { "［", "］" },
    ["｛"] = { "｛", "｝" },
    ["『"] = { "『", "』" },
    ["』"] = { "『", "』" },
    ["〖"] = { "〖", "〗" },
    ["《"] = { "《", "》" },
    ["》"] = { "《", "》" },
    ["〈"] = { "〈", "〉" },
    ["〉"] = { "〈", "〉" },
	["quotedbl"] = { "“", "”" },  -- 双引号成对配置
    ["apostrophe"] = { "‘", "’" }, -- 单引号成对配置
}

-- 纯符号候选白名单
local symbol_whitelist = {
    "`", "```", "“", "”", "‘", "’", "(", ")", "[", "]", "{", "}", "<", ">",
    "（", "）", "【", "】", "〔", "〕", "〚", "〛", "〘", "〙", "「", "」",
    "［", "］", "｛", "｝", "『", "』", "〖", "〗", "《", "》", "〈", "〉"
}

local function is_pure_symbol(txt)
    for _, sym in ipairs(symbol_whitelist) do
        if txt == sym then
            return true
        end
    end
    return false
end

local function get_key_char(segment)
    for tag in pairs(segment.tags) do
        if tag:sub(1, #tag_prefix) == tag_prefix then
            return tag:sub(#tag_prefix + 1)
        end
    end
    return nil
end

local function get_pp_seg(segmentation)
    for i = 0, segmentation.size - 1 do
        local seg = segmentation:get_at(i)
        if seg and get_key_char(seg) then
            return seg
        end
    end
    return nil
end

local function on_update_or_select(env)
    return function(ctx)
        local segmentation = ctx.composition:toSegmentation()
        local pp_seg = get_pp_seg(segmentation)
        if not pp_seg then return end
        
        local selected_cand = ctx.composition:back():get_selected_candidate()
        if not selected_cand or not is_pure_symbol(selected_cand.text) then
            return
        end
        
        local target_txt = selected_cand.text
        local punct_pair = pairTable[target_txt]
        if not punct_pair or (#punct_pair < 1) then return end
        
        ctx.composition:back().prompt = (#punct_pair == 2) and punct_pair[2] or ""
    end
end

function segmentor.init(env)
    env.closing_punct = nil
    local config = env.engine.schema.config
    local schema_id = config:get_string("schema/schema_id")
    local schema = Schema(schema_id)
    env.echo_translator = Component.Translator(env.engine, schema, "", "echo_translator")
    env.update_notifier = env.engine.context.update_notifier:connect(on_update_or_select(env))
    env.select_notifier = env.engine.context.select_notifier:connect(on_update_or_select(env))
end

function processor.init(env)
    env.dist_code = rime_api:get_distribution_code_name()
    -- 精确的防重复状态
    env.last_processed_key = nil
    env.last_processed_time = 0
end

function processor.func(key, env)
    local key_value = key:repr()
    local schema = env.engine.schema
    local context = env.engine.context
    local page_size = schema.page_size
    local composition = context.composition
    local current_time = os.clock()
    
    -- 防重复：同一按键在短时间内只处理一次
    if (key.keycode == 34 or key.keycode == 39) and 
       env.last_processed_key == key.keycode and 
       (current_time - env.last_processed_time < 0.2) then
        return 2
    end

    -- 非配对符号开启状态，直接放行
    if not context:get_option("pair_symbol") then
        return 2
    end

    -- 处理退格
    if key_value == "BackSpace" then
        local input = context.input or ""
        local is_pair_punct = false
        for _, pair in pairs(pairTable) do
            if #pair == 2 and (input == pair[1] or input == pair[2]) then
                is_pair_punct = true
                break
            end
        end
        if is_pair_punct then
            context:clear()
        end
        return 2
    end

    -- 核心修复：单双引号成对输出（简化触发逻辑，确保必执行）
    -- 处理双引号键（quotedbl）：无论左/右，直接触发成对输出
    if key.keycode == 34 then 
        -- 直接提交成对双引号，无需先输入左引号
        if composition:empty() then
            env.engine:commit_text(pairTable["quotedbl"][1] .. pairTable["quotedbl"][2])
            env.last_processed_key = key.keycode  -- 更新按键码
            env.last_processed_time = current_time  -- 更新处理时间
            context:clear()
            return 1
        end
    end

    -- 处理单引号键（apostrophe）：无论左/右，直接触发成对输出
    if key.keycode == 39 then 
        -- 直接提交成对单引号，无需先输入左引号
        if composition:empty() then
            env.engine:commit_text(pairTable["apostrophe"][1] .. pairTable["apostrophe"][2])
            env.last_processed_key = key.keycode  -- 更新按键码
            env.last_processed_time = current_time  -- 更新处理时间
            context:clear()
            return 1
        end
    end

    -- 区分文字/符号场景
    local is_symbol_scene = false
    local selected_cand = composition:back() and composition:back():get_selected_candidate()
    if context:has_menu() and selected_cand and is_pure_symbol(selected_cand.text) then
        is_symbol_scene = true
    elseif not context:has_menu() and context.input ~= "" and is_pure_symbol(context.input) then
        is_symbol_scene = true
    else
        return 2
    end

    -- 符号场景处理空格/回车
    if (key_value == "space" or key_value == "Return") and is_symbol_scene then
        local target_txt = selected_cand and selected_cand.text or context.input
        local pair = pairTable[target_txt]
        if pair then
            local commit_content = (#pair == 2) and (pair[1] .. pair[2]) or pair[1]
            context:clear()
            env.engine:commit_text(commit_content)
            return 1
        end
    end

    -- 处理候选选择
    if composition:empty() then
        return 2
    end
    
    local segment = composition:back()
    local idx = segment.selected_index
    local selected_cand_index = get_selected_candidate_index(key_value, idx, page_size)
    
    if context:has_menu() and (selected_cand_index >= 0) then
        segment.selected_index = selected_cand_index
        return 1
    end

    return 2
end

function segmentor.func(segmentation, env)
    local symkey = nil
    local context = env.engine.context

    if not context:get_option("pair_symbol") or segmentation:empty() then
        return true
    end

    local selected_cand = context:get_selected_candidate()
    if not selected_cand or not is_pure_symbol(selected_cand.text) then
        return true
    end
    local target_txt = selected_cand.text

    if pairTable[target_txt] then
        symkey = target_txt
    end
    
    if not symkey then return true end
    
    local match_len = #target_txt
    local match_start = segmentation:get_current_start_position()
    local match_end = match_start + match_len
    local seg = Segment(match_start, match_end)
    seg.tags = Set({ tag_prefix .. symkey })
    segmentation:add_segment(seg)
    segmentation:forward()
    return true
end

function M.fini(env)
    if env.echo_translator then env.echo_translator = nil end
    if env.update_notifier then env.update_notifier:disconnect() end
    if env.select_notifier then env.select_notifier:disconnect() end
end

return {
    processor = { init = processor.init, func = processor.func, fini = M.fini },
    segmentor = { init = segmentor.init, func = segmentor.func, fini = M.fini },
}