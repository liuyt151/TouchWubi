local log = {}
package.loaded[...] = log

local basic = require("lib.basic")

local LOG_LEVEL = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4
}

local current_level = LOG_LEVEL.DEBUG

function log.set_level(level)
    if LOG_LEVEL[level] then
        current_level = LOG_LEVEL[level]
    end
end

function log.set_level_by_num(level_num)
    if level_num >= 1 and level_num <= 4 then
        current_level = level_num
    end
end

local function should_log(level)
    return level >= current_level
end

local function format_message(level_str, ...)
    local args = {...}
    local msg = ""
    for i, v in ipairs(args) do
        if i > 1 then msg = msg .. "\t" end
        if type(v) == "table" then
            local t = {}
            for k, val in pairs(v) do
                t[#t + 1] = tostring(k) .. "=" .. tostring(val)
            end
            msg = msg .. "{" .. table.concat(t, ", ") .. "}"
        else
            msg = msg .. tostring(v)
        end
    end
    return os.date("%Y-%m-%d %H:%M:%S") .. " [" .. level_str .. "] " .. msg .. "\n"
end

local function write_log(level, level_str, ...)
    if not should_log(level) then return end
    local file_path = basic.get_log_file_path("rime.log")
    local f = io.open(file_path, "a")
    if f then
        f:write(format_message(level_str, ...))
        f:close()
    end
end

function log.debug(...)
    write_log(LOG_LEVEL.DEBUG, "DEBUG", ...)
end

function log.info(...)
    write_log(LOG_LEVEL.INFO, "INFO", ...)
end

function log.warn(...)
    write_log(LOG_LEVEL.WARN, "WARN", ...)
end

function log.error(...)
    write_log(LOG_LEVEL.ERROR, "ERROR", ...)
end

function log.debug_file(filename, ...)
    if not should_log(LOG_LEVEL.DEBUG) then return end
    local file_path = basic.get_log_file_path(filename)
    local f = io.open(file_path, "a")
    if f then
        f:write(format_message("DEBUG", ...))
        f:close()
    end
end

function log.info_file(filename, ...)
    if not should_log(LOG_LEVEL.INFO) then return end
    local file_path = basic.get_log_file_path(filename)
    local f = io.open(file_path, "a")
    if f then
        f:write(format_message("INFO", ...))
        f:close()
    end
end

return log