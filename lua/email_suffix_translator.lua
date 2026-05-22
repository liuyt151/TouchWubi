-- 增强版邮箱后缀翻译器
-- 作者：Liuyt151
-- 日期：2025-10-25
-- 输入@后在候选栏进行常用邮箱后缀智能补全，快速完整的进行邮箱输入
--
-- 【方案配置说明】
-- 本脚本为翻译器，需在 schema.yaml 中添加以下配置：
--
-- engine:
--   translators:
--     - lua_translator@*email_suffix_translator  # 邮箱后缀翻译器
--
-- speller:                                        # 必须配置引导符
--   alphabet: zyxwvutsrqponmlkjihgfedcba`/@=     # 必须包含 @（at符号）
--   initials: zyxwvutsrqponmlkjihgfedcba`/@=     # 必须包含 @（at符号）
--
-- 可选识别器配置（用于 matcher 优化调度，非必须）：
-- recognizer:
--   patterns:
--     email: "^[A-Za-z][-_.0-9A-Za-z]*@.*$"      # 邮箱识别模式（可选）
--
-- 脚本内部通过 input == "@" 或 string.sub(input, 1, 1) == "@" 判断，
-- 无需识别器也能工作。识别器模式与脚本判断逻辑不完全相同，仅供参考。

local function email_suffix_translator(input, seg)
    -- 纯@输入，显示所有常用邮箱
    if input == "@" then
        local popular_emails = {
            "@qq.com",
            "@163.com", 
            "@gmail.com",
            "@live.com",
            "@126.com",
            "@outlook.com",
            "@hotmail.com",
            "@sina.com",
            "@sohu.com",
            "@yahoo.com",
            "@foxmail.com",
            "@aliyun.com",
            "@139.com",
            "@189.cn",
            "@yeah.net",
            "@icloud.com"
        }
        
        for i, email in ipairs(popular_emails) do
            yield(Candidate("email", seg.start, seg._end, email, ""))
        end
        return
    end
    
    -- @后输入内容，进行智能补全
    if string.sub(input, 1, 1) == "@" then
        local search_text = string.sub(input, 2):lower()  -- 转换为小写进行匹配
        local all_domains = {
            "gmail.com", "qq.com", "163.com", "126.com", "sina.com", 
            "sohu.com", "outlook.com", "hotmail.com", "yahoo.com", 
            "foxmail.com", "aliyun.com", "139.com", "189.cn", "yeah.net",
            "live.com", "icloud.com", "msn.com", "aol.com", "mail.com",
            "tom.com", "21cn.com", "188.com", "wo.cn", "vip.qq.com"
        }
        
        local matched = {}
        
        -- 精确匹配开头
        for _, domain in ipairs(all_domains) do
            if string.find(domain, search_text) == 1 then
                table.insert(matched, domain)
            end
        end
        
        -- 模糊匹配（如果精确匹配结果较少）
        if #matched < 3 and search_text ~= "" then
            for _, domain in ipairs(all_domains) do
                if string.find(domain, search_text) and not string.find(domain, search_text) == 1 then
                    table.insert(matched, domain)
                end
            end
        end
        
        -- 限制结果数量
        local max_results = 8
        for i = 1, math.min(#matched, max_results) do
            yield(Candidate("email", seg.start, seg._end, "@" .. matched[i], ""))
        end
        
        -- 如果没有匹配结果，显示提示
        if #matched == 0 and search_text ~= "" then
            yield(Candidate("email", seg.start, seg._end, "继续输入域名...", ""))
        end
    end
end

return email_suffix_translator