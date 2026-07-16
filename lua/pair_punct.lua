--[[
    pair_punct.lua - 配对符号自动补全模块
    作者: kuroame, boomker, shawx
    授权: MIT
    日期: 2026-06
]]

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
	["quotedbl"] = { "“", "”" },
    ["apostrophe"] = { "‘", "’" },
}

local symbol_whitelist = {
    "`", "```", "“", "”", "‘", "’", "(", ")", "[", "]", "{", "}", "<", ">",
    "（", "）", "【", "】", "〔", "〕", "〚", "〛", "〘", "〙", "「", "」",
    "［", "］", "｛", "｝", "『", "』", "〖", "〗", "《", "》", "〈", "〉"
}

local direct_punct_map = {
    [","] = "，",
    ["."] = "。",
    ["!"] = "！",
    ["?"] = "？",
    [":"] = "：",
    ['"'] = "”",
    ["("] = "（",
    [")"] = "）",
    ["-"] = "-",
    ["#"] = "#",
    ["$"] = "￥",
    ["%"] = "%",
    ["&"] = "&",
    ["*"] = "*",
    ["~"] = "~",
    ["|"] = "·",
}

local pool_punct_first_map = {
    ["/"] = "、",
    ["\\"] = "、",
    ["="] = "=",
    ["["] = "「",
    ["]"] = "」",
    ["{"] = "『",
    ["}"] = "』",
    ["<"] = "《",
    [">"] = "》",
    ["*"] = "*",
    ["#"] = "#",
    ["$"] = "￥",
    ["%"] = "%",
    ["&"] = "&",
    ["~"] = "~",
    ["|"] = "·",
    ["!"] = "！",
    ["("] = "（",
    [")"] = "）",
}

local pool_punct_set = {
    ["/"] = true,
    ["\\"] = true,
    ["="] = true,
    ["["] = true,
    ["]"] = true,
    ["{"] = true,
    ["}"] = true,
    ["<"] = true,
    [">"] = true,
    ["*"] = true,
    ["#"] = true,
    ["$"] = true,
    ["%"] = true,
    ["&"] = true,
    ["~"] = true,
    ["|"] = true,
    ["!"] = true,
    ["("] = true,
    [")"] = true,
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
    env.last_processed_key = nil
    env.last_processed_time = 0
end

function processor.func(key, env)
    local context = env.engine.context
    local composition = context.composition
    local current_time = os.clock()
    
    local base_key_value = key:repr():gsub("^Shift%+", ""):gsub("^Release%+", "")
    
    if key:release() then
        return 2
    end
    
    local input = context.input or ""
    if string.sub(input, 1, 1) == "=" then
        return 2
    end
    
    if (base_key_value == "quotedbl" or base_key_value == "apostrophe") and 
       env.last_processed_key == base_key_value and 
       (current_time - env.last_processed_time < 0.2) then
        return 2
    end

    local is_ascii_mode = context:get_option("ascii_mode")
    local is_ascii_punct = context:get_option("ascii_punct")
    
    local key_char = base_key_value
    if key_char == "comma" then key_char = "," end
    if key_char == "period" then key_char = "." end
    if key_char == "question" then key_char = "?" end
    if key_char == "exclam" then key_char = "!" end
    if key_char == "semicolon" then key_char = ";" end
    if key_char == "colon" then key_char = ":" end
    if key_char == "slash" then key_char = "/" end
    if key_char == "backslash" then key_char = "\\" end
    if key_char == "caret" then key_char = "^" end
    if key_char == "tilde" then key_char = "~" end
    if key_char == "asterisk" then key_char = "*" end
    if key_char == "at" then key_char = "@" end
    if key_char == "numbersign" then key_char = "#" end
    if key_char == "dollar" then key_char = "$" end
    if key_char == "percent" then key_char = "%" end
    if key_char == "ampersand" then key_char = "&" end
    if key_char == "bar" then key_char = "|" end
    if key_char == "grave" then key_char = "`" end
    if key_char == "equal" then key_char = "=" end
    if key_char == "bracketleft" then key_char = "[" end
    if key_char == "bracketright" then key_char = "]" end
    if key_char == "braceleft" then key_char = "{" end
    if key_char == "braceright" then key_char = "}" end
    if key_char == "less" then key_char = "<" end
    if key_char == "greater" then key_char = ">" end
    if key_char == "parenleft" then key_char = "(" end
    if key_char == "parenright" then key_char = ")" end
    if key_char == "quotedbl" then key_char = "\"" end
    if key_char == "apostrophe" then key_char = "'" end
    if key_char == "minus" then key_char = "-" end
    
    local has_candidate_menu = context:has_menu()
    
    local top_candidate_text = ""
    if has_candidate_menu then
        local selected_cand = context:get_selected_candidate()
        if selected_cand and selected_cand.text then
            top_candidate_text = selected_cand.text
        end
    end
    
    local is_direct_punct = direct_punct_map[key_char] ~= nil
    
    if base_key_value == "BackSpace" then
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

    if not context:get_option("pair_symbol") then
        return 2
    end

    if has_candidate_menu then
        if base_key_value == "plus" or base_key_value == "minus" or
           base_key_value == "bracketleft" or base_key_value == "bracketright" or
           base_key_value == "Left" or base_key_value == "Right" then
            return 2
        end
        
        if is_direct_punct and not is_ascii_mode and not is_ascii_punct then
            local punct_symbol = direct_punct_map[key_char] or ""
            env.engine:commit_text(top_candidate_text .. punct_symbol)
            context:clear()
            return 1
        end
        
        if key_char == ";" then
            return 2
        end
        
        if base_key_value == "apostrophe" then
            return 1
        end
        
        if pool_punct_set[key_char] then
            local punct_symbol = pool_punct_first_map[key_char] or ""
            context:clear()
            env.engine:commit_text(top_candidate_text .. punct_symbol)
            return 1
        end
        
        return 2
    else
        if composition:empty() then
            if base_key_value == "apostrophe" then
                env.engine:commit_text(pairTable["apostrophe"][1] .. pairTable["apostrophe"][2])
                env.last_processed_key = base_key_value
                env.last_processed_time = current_time
                context:clear()
                return 1
            end
            
            if base_key_value == "quotedbl" then
                env.engine:commit_text(pairTable["quotedbl"][1] .. pairTable["quotedbl"][2])
                env.last_processed_key = base_key_value
                env.last_processed_time = current_time
                context:clear()
                return 1
            end
            
            if is_direct_punct and not is_ascii_mode and not is_ascii_punct then
                local is_pair_symbol = pairTable[key_char] ~= nil
                if is_pair_symbol then
                    return 2
                else
                    local punct_symbol = direct_punct_map[key_char] or ""
                    env.engine:commit_text(punct_symbol)
                    return 1
                end
            end
            
            return 2
        else
            if is_direct_punct and not is_ascii_mode and not is_ascii_punct then
                local is_pair_symbol = pairTable[key_char] ~= nil
                if is_pair_symbol then
                    context:clear()
                    return 2
                else
                    local punct_symbol = direct_punct_map[key_char] or ""
                    env.engine:commit_text(punct_symbol)
                    context:clear()
                    return 1
                end
            end
            
            return 2
        end
    end
end

function segmentor.func(segmentation, env)
    local symkey = nil
    local context = env.engine.context

    if not context:get_option("pair_symbol") or segmentation:empty() then
        return true
    end

    local input_text = context.input or ""
    if not is_pure_symbol(input_text) then
        return true
    end
    
    if #input_text > 0 and #input_text <= 1 and string.byte(input_text) < 128 then
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
