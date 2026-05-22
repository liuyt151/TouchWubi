-- english_translator.lua
-- 功能：英文→中文翻译器，直接读取 english_chinese.txt 字典
-- 作者：Shaw
-- 日期：2025-01-13
-- 优化：2025-01-16 添加缓存机制，避免每次都读取文件
--
-- 【方案配置说明】
-- 本脚本为翻译器，需在 schema.yaml 中添加以下配置：
--
-- engine:
--   translators:
--     - lua_translator@*english_translator    # 英文翻译器
--
-- switches:                                    # 添加开关控制
--   - name: ce_trans
--     reset: 0
--     states: [ 关译, 开译 ]
--
-- 无需识别器配置，脚本通过以下方式判断：
--   - _G.ce_translation_enabled 全局开关控制
--   - input:match("^[a-zA-Z]+$") 正则匹配纯英文输入

-- 全局字典缓存（使用 _G 使其可被其他模块访问）
local dict_cache = nil
local dict_loaded = false
local prefix_cache = {}  -- 前缀索引缓存

-- 【极致优化】全局共享的翻译开关状态，避免重复查询
_G.ce_translation_enabled = false

-- 清空字典缓存函数（导出到全局命名空间，供 translate_merge 调用）
function clear_english_translator_cache()
	dict_cache = nil
	dict_loaded = false
	prefix_cache = {}
	-- 重置全局开关状态标记
	_G.ce_translation_enabled = false
end

-- 将清空函数注册到全局命名空间
_G.clear_english_translator_cache = clear_english_translator_cache

-- 加载字典到缓存
local function load_dict()
	if dict_loaded then
		return dict_cache
	end

	local dict_path = rime_api.get_user_data_dir() .. "/opencc/english_chinese.txt"
	local file = io.open(dict_path, "r")

	if not file then
		dict_loaded = true
		return nil
	end

	local cache = {}

	for line in file:lines() do
		-- 跳过空行和注释
		if line ~= "" and line:sub(1, 1) ~= "#" then
			-- 按制表符分割
			local parts = {}
			for part in line:gmatch("[^\t]+") do
				table.insert(parts, part)
			end

			-- 至少需要2部分：英文和中文翻译
			if #parts >= 2 then
				local english = parts[1]
				cache[english] = parts

				-- 添加小写索引（支持大小写不敏感查询）
				local english_lower = english:lower()
				if not cache[english_lower] then
					cache[english_lower] = parts
				end

				-- 构建前缀索引（支持模糊匹配）
				for i = 1, math.min(6, #english_lower) do
					local prefix = english_lower:sub(1, i)
					if not prefix_cache[prefix] then
						prefix_cache[prefix] = {}
					end
				table.insert(prefix_cache[prefix], english)
			end
			end
		end
	end

	file:close()

	dict_cache = cache
	dict_loaded = true

	return cache
end

local function english_translator(input, seg, env)
  -- 【极致优化】使用全局共享的开关状态，避免每次都查询 context
  -- 只在全局标记为 false 时才需要检查开关状态
  if not _G.ce_translation_enabled then
    return  -- 译关状态，直接返回，零开销
  end

  -- 【性能优化2】提前检查输入长度，避免对短输入进行正则匹配
  -- 至少需要2个字母才可能是英文单词
  if #input < 2 then
    return
  end

  -- 只处理纯英文输入（包含字母）
  if not input:match("^[a-zA-Z]+$") then
    return
  end

  -- 从缓存获取字典（首次调用时会加载）
  local dict = load_dict()
  if not dict then
    return
  end

  -- 在缓存字典中查找匹配（大小写不敏感）
  local input_lower = input:lower()
  local entry = dict[input_lower] or dict[input] or dict[input:upper()]

  -- 如果找到精确匹配
  if entry then
    local english = entry[1]

    -- 提取所有中文翻译
    local translations = {}
    for i = 2, #entry do
      table.insert(translations, entry[i])
    end

    -- 合并翻译内容，在词性标记前换行
    local formatted_translation = ""
    local pos_count = 0

    for _, part in ipairs(translations) do
      -- 检测词性标记：n. v. vi. vt. a. adj. ad. adv. prep. conj. int. pron. num. art. abbr.
      if part:match("^n%.") or part:match("^v%.") or part:match("^vi%.") or part:match("^vt%.") or
         part:match("^a%.") or part:match("^adj%.") or part:match("^ad%.") or part:match("^adv%.") or
         part:match("^prep%.") or part:match("^conj%.") or part:match("^int%.") or
         part:match("^pron%.") or part:match("^num%.") or part:match("^art%.") or
         part:match("^abbr%.") then
        pos_count = pos_count + 1
        if pos_count > 1 then
          formatted_translation = formatted_translation .. "\n" .. part
        else
          formatted_translation = formatted_translation .. part
        end
      else
        formatted_translation = formatted_translation .. " " .. part
      end
    end

    -- 如果有多个词性标记，在第一个词性标记前也添加换行
    if pos_count > 1 and #translations > 0 then
      local first_part = translations[1]
      if first_part:match("^n%.") or first_part:match("^v%.") or first_part:match("^vi%.") or first_part:match("^vt%.") or
         first_part:match("^a%.") or first_part:match("^adj%.") or first_part:match("^ad%.") or first_part:match("^adv%.") or
         first_part:match("^prep%.") or first_part:match("^conj%.") or first_part:match("^int%.") or
         first_part:match("^pron%.") or first_part:match("^num%.") or first_part:match("^art%.") or
         first_part:match("^abbr%.") then
        formatted_translation = "\n" .. formatted_translation
      end
    end

    -- 去除首尾空格
    formatted_translation = formatted_translation:gsub("^%s+", "")
    formatted_translation = formatted_translation:gsub("%s+$", "")

    -- 生成候选项：英文作为文本，中文翻译作为注释
    -- 设置最高质量值，确保精确匹配排在最前
    local cand = Candidate("english", seg.start, seg._end, english, formatted_translation, "")
    cand.quality = 966
    yield(cand)
  end

  -- 前缀匹配：显示以输入开头的单词（模糊匹配）
  local matched_words = prefix_cache[input_lower]

  if matched_words then
    -- 不限制匹配数量，全部列出
    for _, word in ipairs(matched_words) do
      -- 跳过与输入完全相同的单词（已经在上面处理过了）
      if word:lower() ~= input_lower then
        -- 获取该单词的翻译作为注释
        local word_entry = dict[word] or dict[word:lower()]
        local comment = word_entry and (word_entry[2] or "") or ""

        -- 生成候选项，设置质量值，确保英文翻译排在合适位置（同步调整）
        local cand = Candidate("english", seg.start, seg._end, word, comment, "")
        cand.quality = 800
        yield(cand)
      end
    end
  end
end

return english_translator
