--[
--modify: 空山明月、shawx
--date: 2025-12-09
--fix: 将用户输入的中文词条和对应的五笔编码追加记录到文件中的简单日志函数	
--update: 2025-12-18 模块化重构，独立管理自造词路径
--update: 2025-12-20 合并自造词翻译器，实现即时生效
--
-- 【方案配置说明】
-- 本脚本包含处理器和翻译器两部分，需在 schema.yaml 中添加以下配置：
--
-- engine:
--   processors:
--     - lua_processor@*Submit_text          # 自造词记录处理器（必须）
--   translators:
--     - lua_translator@user_coined_translator # 自造词翻译器（必须，注意无*号）
--
-- speller:                                     # 必须配置引导符
--   alphabet: zyxwvutsrqponmlkjihgfedcba`/@=  # 必须包含 `（反引号）
--   initials: zyxwvutsrqponmlkjihgfedcba`/@=  # 必须包含 `（反引号）
--   delimiter: "`"                            # 分隔符设为反引号
--
-- 无需识别器配置，脚本通过内部正则判断输入模式：
--   - `aa`bb 格式识别为自造词输入
--   - [ / ] \ 识别为标点选择
--]
local basic = require('lib/basic')
local map = basic.map
local index = basic.index
local utf8chars = basic.utf8chars
local matchstr = basic.matchstr

-- =================================================================
-- == 自造词路径管理模块 ==
-- =================================================================

-- 获取 Rime 用户数据目录（兼容不同平台）
local function get_rime_user_dir()
    -- 尝试使用 rime_api（如果可用）
    if rime_api and rime_api.get_user_data_dir then
        return rime_api.get_user_data_dir()
    end
    
    -- 备用方案：从模块路径推导
    local debug_info = debug.getinfo(1, "S")
    local source_path = debug_info.source:sub(2)  -- 去掉开头的 "@"
    
    -- 如果是 @ 开头的路径（相对路径），则推导上级目录
    if source_path then
        local module_dir = source_path:match("^(.*[/\\])") or ""
        -- 从 lua 目录返回到 Rime 根目录
        local rime_root = module_dir:match("^(.*)[/\\]lua[/\\]$")
        if rime_root then
            return rime_root
        else
            -- 进一步推导：假设在用户目录下的某个位置
            return module_dir:match("^(.*)[/\\].*$") or module_dir
        end
    end
    
    return ""
end

-- 初始化自造词文件路径
local function init_userphrase_path()
    local rime_dir = get_rime_user_dir()
    local userphrase_path = ""

    if rime_dir ~= "" then
        if rime_dir:find("\\") then
            userphrase_path = rime_dir .. "\\user_coined_ext.txt"
        else
            userphrase_path = rime_dir .. "/user_coined_ext.txt"
        end
    end

    return userphrase_path
end

-- 模块级变量：自造词文件路径
local userphrasepath = init_userphrase_path()

-- 导出路径获取函数供外部使用
function get_userphrase_path()
    return userphrasepath
end

-- 检查并确保自造词文件存在
local function ensure_userphrase_file()
    if userphrasepath and userphrasepath ~= "" then
        local f = io.open(userphrasepath, "r")
        if not f then
            -- 文件不存在，创建并写入头部
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
	local schema_name=env.engine.schema.schema_name or ""
	local page_size = env.engine.schema.page_size
	local schema_id=env.engine.schema.schema_id or ""
	local candidate_count =0

	if input_text:find("^%p*(%a+%d*)$") then
		if context:has_menu() then
			candidate_count = segment.menu:candidate_count()
		end
		env.last_1th_text=context:get_commit_text() or ""
		env.last_2th_text={text="",type=""}
		env.last_3th_text={text="",type=""}
		if candidate_count>1 then
			env.last_2th_text=segment:get_candidate_at(1)
			if candidate_count>2 then
				env.last_3th_text=segment:get_candidate_at(2)
			end
		end
	end

	-- `引导自造词记录保存
	-- 0x20空格，0x31大键盘数字1
	if input_text:find("^%`*(%l+%`%l+)") then
		local commit_text=context:get_commit_text() or ""
		if commit_text~="" and not commit_text:find("(%a)") and utf8.len(commit_text)>1 then
			env.userphrase=commit_text
			if segment.prompt:find('(%a+)') then
				env.inputtext=segment.prompt:gsub('[^%a]','')
			else
				env.inputtext=input_text
			end
		end
	else
		if key.keycode==0x20 or key.keycode>0x30 and key.keycode<0x39 then
			if env.userphrase~="" and env.userphrase~=nil and userphrasepath~="" then
				-- 确保文件存在
				ensure_userphrase_file()
				fileappendtext(userphrasepath,env.userphrase,env.inputtext,schema_name)
				env.userphrase=""
				env.inputtext=""
			end
		end
	end

	if key.keycode==0x27 and context:is_composing() and env.last_3th_text.text~="" then
		if env.last_3th_text.type=="reverse_lookup" or env.last_3th_text.type=="table" then
			context:clear()
			engine:commit_text(env.last_3th_text.text)
			return 1
		end
	end

	local m,n=input_text:find("^(%a+%d*)([%[%/%]\\])")
	if n~=nil and m~=nil then
		if (context:is_composing()) then
			context:clear()
			if input_text:find("^%u+%l*%d*") then   -- 大写字母引导的日期反查与转换功能，[ 和 ] 分别对应二选三选
				if input_text:find("%[") then
					engine:commit_text(env.last_2th_text.text)
				elseif input_text:find("%]") then
					engine:commit_text(env.last_3th_text.text)
				end
			else
				engine:commit_text(env.last_1th_text..CandidateText[1])  -- 第1个候选标点符号
			end
			return 1
		end
	end
	return 2
end

-- =================================================================
-- == 翻译器：自造词即时查询 ==
-- =================================================================

local function user_coined_translator(input, seg, env)
    -- 只处理纯字母输入（五笔编码）
    if not input:match("^[a-y]+$") then
        return
    end
    
    -- 使用全局路径变量
    if not userphrasepath or userphrasepath == "" then
        return
    end
    
    -- 读取文件
    local file = io.open(userphrasepath, "r")
    if not file then
        return
    end
    
    -- 逐行匹配
    for line in file:lines() do
        -- 跳过注释行
        if not line:match("^#") and line ~= "" then
            -- 解析格式：词条\t编码
            local text, code = line:match("^([^\t]+)\t([a-y]+)")
            if text and code then
                -- 匹配输入编码
                if code == input or code:find("^" .. input) then
                    local cand = Candidate("user_coined", seg.start, seg._end, text, "")
                    cand.quality = 850  -- 与fixed一致，确保用户词典学习优先
                    yield(cand)
                end
            end
        end
    end
    
    file:close()
end

-- =================================================================
-- == 辅助函数 ==
-- =================================================================

-- 记录自造词到文本文件（即时生效）
function fileappendtext(filepath,context,input)
	-- 使用 splitinput 函数生成简化的4位编码
	if context and context~="" and not context:find('%a') then
		-- 获取词条长度
		local len = utf8.len(context)
		-- 调用 splitinput 简化编码
		local clean_input = splitinput(input, len)
		if clean_input and clean_input~="" then
			-- 检查是否已存在
			local f=io.open(filepath,"r")
			local exists = false
			if f then
				for line in f:lines() do
					if line:find(context, 1, true) then
						exists = true
						break
					end
				end
				f:close()
			end
			-- 不存在则追加（简单txt格式：词条\t编码）
			if not exists then
				f=io.open(filepath,"a")
				if f then
					f:write("\n"..context.."\t"..clean_input)
					f:close()
				end
			end
		end
	end
end

-- 格式化五笔组合编码（支持1位编码）
function splitinput(input, len)
    -- 先清理输入，按反引号分割
    input = input:gsub("^%`+", ""):gsub("%`+$", "")

    -- 分割每个字的编码
    local codes = {}
    for code in input:gmatch("([^`]+)") do
        table.insert(codes, code)
    end

    -- 根据字数生成4位编码
    local result = ""

    if len == 2 then
        -- 2字词：每字取前2位
        result = (codes[1] or ""):sub(1, 2) .. (codes[2] or ""):sub(1, 2)
    elseif len == 3 then
        -- 3字词：第1字1位，第2字1位，第3字2位
        result = (codes[1] or ""):sub(1, 1) ..
                 (codes[2] or ""):sub(1, 1) ..
                 (codes[3] or ""):sub(1, 2)
    elseif len >= 4 then
        -- 4字及以上：前3字各1位，最后1字1位
        result = (codes[1] or ""):sub(1, 1) ..
                 (codes[2] or ""):sub(1, 1) ..
                 (codes[3] or ""):sub(1, 1) ..
                 (codes[len] or ""):sub(1, 1)
    end

    return result
end

-- =================================================================
-- == 模块导出 ==
-- =================================================================

-- 将翻译器注册到全局环境（供 lua_translator 使用）
-- 使用 rawset 确保正确注册到全局表
rawset(_G, "user_coined_translator", user_coined_translator)

-- 返回处理器函数（供 lua_processor 使用）
return commit_text_processor
