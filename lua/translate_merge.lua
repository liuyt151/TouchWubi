-- translate_merge.lua
-- 功能：合并OpenCC拆分的翻译候选项，使翻译结果在一行完整显示
-- 作者：Shaw
-- 日期：2025-01-13
--
-- 【方案配置说明】
-- 本脚本为过滤器，需在 schema.yaml 中添加以下配置：
--
-- engine:
--   filters:
--     - lua_filter@*translate_merge           # 翻译合并过滤器
--
-- switches:                                    # 添加开关控制
--   - name: ce_trans
--     reset: 0
--     states: [ 关译, 开译 ]
--
-- 建议配置位置：在 simplifier@ce_en_conversion 之后，uniquifier 之前
--
-- 依赖文件：
--   - opencc/ce.json                          # 中英转换配置
--   - opencc/chinese_english.txt              # 中英字典
--   - opencc/english_chinese.txt              # 英中字典
--
-- 无需识别器配置，脚本通过 context:get_option("ce_trans") 开关控制

-- 【内存优化】记录开关状态，避免重复检查
local last_ce_trans_state = nil
local is_translation_enabled = nil  -- 缓存翻译开关状态，避免每次都查询

-- 【内存优化】缓存是否已清空标记，避免重复清空操作
local has_cleared_cache = false

local function is_chinese_text(text)
	-- 检查是否包含中文字符（UTF-8编码）
	return text:match("[\228-\233][\128-\191]")
end

local function is_pure_english(text)
	-- 检查是否为纯英文单词（用于ENGLISH_CHINESE）
	return text:match("^[a-zA-Z'-]+$") and #text > 0
end

local function is_chinese_translation(text)
	-- 检查是否为中文翻译部分（用于英文→中文）
	-- 特征：包含词性标记
	-- 常见词性标记：n.（名词）、v.（动词）、vi.（不及物动词）、vt.（及物动词）
	-- a./adj.（形容词）、ad./adv.（副词）、prep.（介词）、conj.（连词）
	-- int.（感叹词）、pron.（代词）、num.（数词）、art.（冠词）、abbr.（缩写）
	if text:match("^n%.") or text:match("^v%.") or text:match("^vi%.") or text:match("^vt%.") or
	   text:match("^a%.") or text:match("^adj%.") or text:match("^ad%.") or text:match("^adv%.") or
	   text:match("^prep%.") or text:match("^conj%.") or text:match("^int%.") or
	   text:match("^pron%.") or text:match("^num%.") or text:match("^art%.") or
	   text:match("^abbr%.") then
		return true
	end
	if text:match("；") or text:match("、") then
		return true
	end
	-- 注释：只有包含词性标记或中文标点的内容才认为是翻译
	-- 纯粹的中文文本（如拼音注释）不会被识别为翻译内容
	return false
end

local function is_english_translation(text)
	-- 检查是否为英文翻译部分（用于中文→英文）
	-- 特征：纯英文或以英文为主
	return text:match("^[a-zA-Z]+$") or (text:match("^%s*[a-zA-Z]") and not is_chinese_text(text))
end

local function format_translation_with_linebreak(parts)
	-- 格式化翻译内容，在词性标记前换行（包括第一个词性标记）
	if #parts == 0 then
		return ""
	end
	
	-- 检查每个部分，在词性标记前添加换行符
	-- 常见词性标记：n. v. vi. vt. a. adj. ad. adv. prep. conj. int. pron. num. art. abbr.
	local formatted = {}
	local pos_count = 0  -- 统计词性标记数量
	
	for _, part in ipairs(parts) do
		-- 如果是词性标记开头，先添加换行符
		if part:match("^n%.") or part:match("^v%.") or part:match("^vi%.") or part:match("^vt%.") or 
		   part:match("^a%.") or part:match("^adj%.") or part:match("^ad%.") or part:match("^adv%.") or 
		   part:match("^prep%.") or part:match("^conj%.") or part:match("^int%.") or 
		   part:match("^pron%.") or part:match("^num%.") or part:match("^art%.") or 
		   part:match("^abbr%.") then
			pos_count = pos_count + 1
			if pos_count > 1 then
				-- 不是第一个词性标记，添加换行符
				table.insert(formatted, "\n" .. part)
			else
				-- 第一个词性标记，不添加换行符
				table.insert(formatted, part)
			end
		else
			table.insert(formatted, part)
		end
	end
	
	-- 如果有多个词性标记，在第一个词性标记前也添加换行
	if pos_count > 1 then
		-- 找到第一个词性标记的索引
		for i, part in ipairs(formatted) do
			if part:match("^n%.") or part:match("^v%.") or part:match("^vi%.") or part:match("^vt%.") or 
			   part:match("^a%.") or part:match("^adj%.") or part:match("^ad%.") or part:match("^adv%.") or 
			   part:match("^prep%.") or part:match("^conj%.") or part:match("^int%.") or 
			   part:match("^pron%.") or part:match("^num%.") or part:match("^art%.") or 
			   part:match("^abbr%.") then
				formatted[i] = "\n" .. part
				break
			end
		end
	end
	
	return table.concat(formatted, " ")
end

local function translate_merge_filter(input, env)
	-- 【内存优化】检查中英转换开关状态，切换到译关时释放内存缓存
	-- 避免在译关状态下执行所有复杂的正则匹配、文本分析和合并逻辑
	-- 译关状态：english_translator 不生成翻译候选项，但 translate_merge 仍然会处理所有候选项
	local context = env.engine.context
	local ce_trans_state = context:get_option("ce_trans") or 0

	-- 【极致优化】只在状态变化时才查询开关状态
	if last_ce_trans_state == nil or last_ce_trans_state ~= ce_trans_state then
		-- 状态发生了变化，更新缓存
		is_translation_enabled = (ce_trans_state == 1 or ce_trans_state == true)
		last_ce_trans_state = ce_trans_state

		-- 【极致优化】同步全局开关状态标记，供 english_translator 使用
		_G.ce_translation_enabled = is_translation_enabled

		-- 检测状态变化：从译开(1)切换到译关(0)时，清空缓存释放内存
		if not is_translation_enabled then
			-- 调用全局清空缓存函数，释放 english_translator 的内存
			if not has_cleared_cache and _G.clear_english_translator_cache then
				_G.clear_english_translator_cache()
				has_cleared_cache = true  -- 标记已清空，避免重复操作
			end
			return  -- 直接返回，不做任何处理
		else
			-- 切换到译开状态，重置清空标记
			has_cleared_cache = false
		end
	end

	-- 【极致优化】如果已确认译关状态，直接通过，零开销
	if not is_translation_enabled then
		for cand in input:iter() do
			yield(cand)
		end
		return
	end

	-- 收集所有候选项
	local candidates = {}

	for cand in input:iter() do
		table.insert(candidates, cand)
	end

	-- 如果候选项太少，直接返回
	if #candidates < 2 then
		for _, cand in ipairs(candidates) do
			yield(cand)
		end
		return
	end
	
	-- 尝试检测并合并翻译候选项
	local i = 1
	
	while i <= #candidates do
		local cand = candidates[i]
		local text = cand.text
		
		-- 情况1：英文→中文翻译（英文单词开头）
		if is_pure_english(text) then
			local english_word = text
			local chinese_parts = {}
			
			-- 收集后面连续的中文翻译候选项
			local j = i + 1
			while j <= #candidates do
				local next_cand = candidates[j]
				local next_text = next_cand.text
				
				-- 检查是否为中文翻译内容
				if is_chinese_translation(next_text) then
					table.insert(chinese_parts, next_text)
					j = j + 1
				else
					break
				end
			end
			
			-- 如果收集到了翻译内容，则合并
			if #chinese_parts > 0 then
				-- 格式化翻译内容，在词性标记前换行
				local translation_comment = format_translation_with_linebreak(chinese_parts)
				
				-- 创建合并后的候选项
				-- text参数为英文单词（上屏内容）
				-- comment参数为翻译内容（显示但不影响上屏）
				local merged_cand = Candidate(
					cand.type,
					cand.start,
					cand._end,
					english_word,         -- 上屏：只输出英文单词
					translation_comment,   -- 显示：翻译内容作为注释（带换行）
					cand.preedit
				)
				yield(merged_cand)
				i = j  -- 跳过已合并的候选项
			else
				-- 没有翻译内容，直接输出
				yield(cand)
				i = i + 1
			end
			
		-- 情况2：中文→英文翻译（以中文开头，包含英文）
		elseif is_chinese_text(text) and text:match("[a-zA-Z]") then
			-- 分析文本格式：可能是"中文 英文"或只是中文
			local parts = {}
			for part in string.gmatch(text, "%S+") do
				table.insert(parts, part)
			end
			
			-- 检查第一个部分是否为中文
			if #parts >= 2 and is_chinese_text(parts[1]) then
				-- 提取所有英文部分
				local english_parts = {}
				for k = 2, #parts do
					if parts[k]:match("^[a-zA-Z%-]+$") then
						table.insert(english_parts, parts[k])
					end
				end
				
				-- 收集后续的英文单词候选项
				local j = i + 1
				while j <= #candidates do
					local next_cand = candidates[j]
					local next_text = next_cand.text
					
					-- 检查是否为英文单词
					if is_english_translation(next_text) then
						table.insert(english_parts, next_text)
						j = j + 1
					else
						break
					end
				end
				
				-- 如果收集到了英文翻译，则合并
				if #english_parts > 0 then
					local merged_text = table.concat(english_parts, " ")
					
					-- 创建合并后的候选项
					-- text参数为合并后的英文翻译（上屏内容）
					-- comment参数为空
					local merged_cand = Candidate(
						cand.type,
						cand.start,
						cand._end,
						merged_text,      -- 上屏：输出完整的英文翻译
						"",               -- 不需要注释
						cand.preedit
					)
					yield(merged_cand)
					i = j  -- 跳过已合并的候选项
				else
					-- 没有英文翻译，直接输出原候选项
					yield(cand)
					i = i + 1
				end
			else
				-- 不是翻译格式，直接输出
				yield(cand)
				i = i + 1
			end
		else
			-- 其他情况，直接输出
			yield(cand)
			i = i + 1
		end
	end
end

return translate_merge_filter
