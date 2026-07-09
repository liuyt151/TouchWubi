-- 增强版邮箱后缀翻译器（修复模糊匹配 + 性能优化）
-- 作者：Liuyt151
-- 日期：2025-10-25（修订：2026-05-24）
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

local all_domains = {
    "gmail.com", "qq.com", "163.com", "126.com", "sina.com",
    "sohu.com", "outlook.com", "hotmail.com", "yahoo.com",
    "foxmail.com", "aliyun.com", "139.com", "189.cn", "yeah.net",
    "live.com", "icloud.com", "msn.com", "aol.com", "mail.com",
    "tom.com", "21cn.com", "188.com", "wo.cn", "vip.qq.com"
}

local domain_set = {}
for _, domain in ipairs(all_domains) do
    domain_set[domain] = true
end

local function email_suffix_translator(input, seg)
    -- 纯 @ 输入：显示最常用的邮箱后缀（可自定义顺序）
    if input == "@" then
        local popular_emails = {
            "@qq.com", "@163.com", "@gmail.com", "@outlook.com",
            "@126.com", "@live.com", "@hotmail.com", "@sina.com",
            "@139.com", "@foxmail.com", "@aliyun.com", "@icloud.com"
        }
        for _, email in ipairs(popular_emails) do
            yield(Candidate("email", seg.start, seg._end, email, ""))
        end
        return
    end

    -- @ 后跟了内容：智能补全
    if string.sub(input, 1, 1) == "@" then
        local search = string.sub(input, 2):lower()
        if search == "" then return end

        local matched = {}
        local seen = {}

        -- 精确匹配（以 search 开头）
        for _, domain in ipairs(all_domains) do
            if string.find(domain, search, 1, true) == 1 then
                if not seen[domain] then
                    seen[domain] = true
                    table.insert(matched, domain)
                end
            end
        end

        -- 模糊匹配（包含 search 但不在开头），仅在精确匹配少于 3 个时执行
        if #matched < 3 then
            for _, domain in ipairs(all_domains) do
                if string.find(domain, search, 1, true) and not seen[domain] then
                    seen[domain] = true
                    table.insert(matched, domain)
                end
            end
        end

        -- 输出候选（最多 8 个）
        local max_results = 8
        for i = 1, math.min(#matched, max_results) do
            yield(Candidate("email", seg.start, seg._end, "@" .. matched[i], ""))
        end

        -- 无匹配时不输出任何候选（保持候选栏干净）
    end
end

return email_suffix_translator