-- 检测输入法 distribution_code_name 和其他环境信息
-- 使用方法：
-- 1. 将此文件放入 lua 目录
-- 2. 在 schema.yaml 中添加配置：
--    engine:
--      translators:
--        - lua_translator@*check_dist_name
-- 3. 输入 /dist 即可查看信息

local function translator(input, seg, env)
    if input == "/dist" then
        -- 获取 distribution_code_name
        local dist = rime_api.get_distribution_code_name() or "nil"
        local dist_name = rime_api.get_distribution_name() or "nil"
        local dist_version = rime_api.get_distribution_version() or "nil"

        -- 获取路径信息
        local user_data_dir = rime_api.get_user_data_dir() or "nil"
        local shared_data_dir = rime_api.get_shared_data_dir() or "nil"

        -- 获取 schema 信息
        local schema_id = env.engine.schema.schema_id or "nil"
        local schema_name = env.engine.schema.schema_name or "nil"

        -- 获取 JIT 信息
        local jit_info = "nil"
        if jit then
            jit_info = jit.os or "nil"
        end

        -- 获取 HOME 环境变量
        local home = os.getenv("HOME") or "nil"

        -- 构建输出信息
        local info = string.format(
            "=== 输入法环境信息 ===\n" ..
            "distribution_code_name: %s\n" ..
            "distribution_name: %s\n" ..
            "distribution_version: %s\n" ..
            "schema_id: %s\n" ..
            "schema_name: %s\n" ..
            "jit.os: %s\n" ..
            "HOME: %s\n" ..
            "user_data_dir: %s\n" ..
            "shared_data_dir: %s",
            dist, dist_name, dist_version,
            schema_id, schema_name,
            jit_info, home,
            user_data_dir, shared_data_dir
        )

        -- 输出到候选
        yield(Candidate("info", seg.start, seg._end, info, ""))
    end
end

return { func = translator }
