-- Rime Calculator - Full Functionality Version
-- 簡易計算器（執行任何Lua表達式）
-- 格式：<exp>
-- Lambda語法糖：\<arg>.<exp>|
--
-- 例子：
-- =1+1 輸出 2
-- =floor(9^(8/7)*cos(deg(6))) 輸出 -3
-- =e^pi>pi^e 輸出 true
-- =max({1,7,2}) 輸出 7
-- =map({1,2,3},\x.x^2|) 輸出 {1, 4, 9}
-- =map(range(-5,5),\x.x*pi/4|,deriv(sin)) 輸出 {-0.7071, -1, -0.7071, 0, 0.7071, 1, 0.7071, 0, -0.7071, -1}
-- =$(range(-5,5,0.01))(map,\x.-60*x^2-16*x+20|)(max)() 輸出 21.066
-- =test(\x.trunc(sin(x),1e-3)==trunc(deriv(cos)(x),1e-3)|,range(-2,2,0.1)) 輸出 true

-- 完整的数学函数库（安全环境管理）
local full_math_env = {
  -- 三角函数
  sin = math.sin,
  cos = math.cos,
  tan = math.tan,
  asin = math.asin,
  acos = math.acos,
  atan = math.atan,
  rad = math.rad,
  deg = math.deg,
  
  -- 基础数学
  abs = math.abs,
  floor = math.floor,
  ceil = math.ceil,
  mod = math.fmod,
  sqrt = math.sqrt,
  exp = math.exp,
  ln = math.log,
  random = math.random,
  randomseed = math.randomseed,
  
  -- 数学常量
  inf = math.huge,
  MAX_INT = math.maxinteger,
  MIN_INT = math.mininteger,
  pi = math.pi,
  e = math.exp(1),
  
  -- 扩展函数
  trunc = function (x, dc)
    if dc == nil then
      return math.modf(x)
    end
    return x - math.fmod(x, dc)
  end,
  
  round = function (x, dc)
    dc = dc or 1
    local dif = math.fmod(x, dc)
    if math.abs(dif) > dc / 2 then
      return x < 0 and x - dif - dc or x - dif + dc
    end
    return x - dif
  end,
  
  log = function (x, base)
    base = base or 10
    return math.log(x)/math.log(base)
  end,
  
  min = function (arr)
    local m = math.huge
    for k, x in ipairs(arr) do
     m = x < m and x or m
    end
    return m
  end,
  
  max = function (arr)
    local m = -math.huge
    for k, x in ipairs(arr) do
     m = x > m and x or m
    end
    return m
  end,
  
  sum = function (t)
    local acc = 0
    for k,v in ipairs(t) do
      acc = acc + v
    end
    return acc
  end,
  
  avg = function (t)
    return sum(t) / #t
  end,
  
  isinteger = function (x)
    return math.fmod(x, 1) == 0
  end,
  
  -- 数组操作
  array = function (...)
    local arr = {}
    for v in ... do
      arr[#arr + 1] = v
    end
    return arr
  end,
  
  irange = function (from, to, step)
    if to == nil then
      to = from
      from = 0
    end
    step = step or 1
    local i = from - step
    to = to - step
    return function()
      if i < to then
        i = i + step
        return i
      end
    end
  end,
  
  range = function (from, to, step)
    return full_math_env.array(full_math_env.irange(from, to, step))
  end,
  
  irev = function (arr)
    local i = #arr + 1
    return function()
      if i > 1 then
        i = i - 1
        return arr[i]
      end
    end
  end,
  
  arev = function (arr)
    return full_math_env.array(full_math_env.irev(arr))
  end,
  
  test = function (f, t)
    for k,v in ipairs(t) do
      if not f(v) then
        return false
      end
    end
    return true
  end,
  
  -- 函数式编程
  map = function (t, ...)
    local ta = {}
    for k,v in pairs(t) do
      local tmp = v
      for _,f in pairs({...}) do tmp = f(tmp) end
      ta[k] = tmp
    end
    return ta
  end,
  
  filter = function (t, ...)
    local ta = {}
    local i = 1
    for k,v in pairs(t) do
      local erase = false
      for _,f in pairs({...}) do
        if not f(v) then
          erase = true
          break
        end
      end
      if not erase then
        ta[i] = v
        i = i + 1
      end
    end
    return ta
  end,
  
  foldr = function (t, f, acc)
    for k,v in pairs(t) do
      acc = f(acc, v)
    end
    return acc
  end,
  
  foldl = function (t, f, acc)
    for v in full_math_env.irev(t) do
      acc = f(acc, v)
    end
    return acc
  end,
  
  chain = function (t)
    local ta = t
    local function cf(f, ...)
      if f ~= nil then
        ta = f(ta, ...)
        return cf
      else
        return ta
      end
    end
    return cf
  end,
  
  -- 统计算法
  fac = function (n)
    local acc = 1
    for i = 2,n do
      acc = acc * i
    end
    return acc
  end,
  
  nPr = function (n, r)
    return full_math_env.fac(n) / full_math_env.fac(n - r)
  end,
  
  nCr = function (n, r)
    return full_math_env.nPr(n,r) / full_math_env.fac(r)
  end,
  
  MSE = function (t)
    local ss = 0
    local s = 0
    local n = #t
    for k,v in ipairs(t) do
      ss = ss + v*v
      s = s + v
    end
    return math.sqrt((n*ss - s*s) / (n*n))
  end,
  
  -- 微积分算法
  lapproxd = function (f, delta)
    local delta = delta or 1e-8
    return function (x)
           return (f(x+delta) - f(x)) / delta
         end
  end,
  
  sapproxd = function (f, delta)
    local delta = delta or 1e-8
    return function (x)
           return (f(x+delta) - f(x-delta)) / delta / 2
         end
  end,
  
  deriv = function (f, delta, dc)
    dc = dc or 1e-4
    local fd = full_math_env.sapproxd(f, delta)
    return function (x)
           return full_math_env.round(fd(x), dc)
         end
  end,
  
  trapzo = function (f, a, b, n)
    local dif = b - a
    local acc = 0
    for i = 1, n-1 do
      acc = acc + f(a + dif * (i/n))
    end
    acc = acc * 2 + f(a) + f(b)
    acc = acc * dif / n / 2
    return acc
  end,
  
  integ = function (f, delta, dc)
    delta = delta or 1e-4
    dc = dc or 1e-4
    return function (a, b)
           if b == nil then
             b = a
             a = 0
           end
           local n = full_math_env.round(math.abs(b - a) / delta)
           return full_math_env.round(full_math_env.trapzo(f, a, b, n), dc)
         end
  end,
  
  rk4 = function (f, timestep)
    local timestep = timestep or 0.01
    return function (start_x, start_y, time)
           local x = start_x
           local y = start_y
           local t = time
           for i = 0, t, timestep do
             local k1 = f(x, y)
             local k2 = f(x + (timestep/2), y + (timestep/2)*k1)
             local k3 = f(x + (timestep/2), y + (timestep/2)*k2)
             local k4 = f(x + timestep, y + timestep*k3)
             y = y + (timestep/6)*(k1 + 2*k2 + 2*k3 + k4)
             x = x + timestep
           end
           return y
         end
  end,
}

-- 系统函数（安全版本）
local system_env = {
  date = function(format_string)
    if format_string and type(format_string) == "string" then
      return os.date(format_string)
    end
    return os.date()
  end,
  
  time = function(table_time)
    if table_time and type(table_time) == "table" then
      return os.time(table_time)
    end
    return os.time()
  end,
}

-- 中文数字转换函数
local function speakLiterally(str, valMap)
  valMap = valMap or {
    [0]="零"; "一"; "二"; "三"; "四"; "五"; "六"; "七"; "八"; "九"; "十";
    ["+"]="+"; ["-"]="负"; ["."]="点"; [""]=""
  }

  local tbOut = {}
  for k = 1, #str do
    local v = string.sub(str, k, k)
    v = tonumber(v) or v
    tbOut[k] = valMap[v]
  end
  return table.concat(tbOut)
end

local function speakMillitary(str)
  return speakLiterally(str, {[0]="洞"; "幺"; "两"; "三"; "四"; "五"; "六"; "拐"; "八"; "勾"; "十";["+"]="正"; ["-"]="负"; ["."]="点"; [""]=""})
end

local function splitNumStr(str)
  local part = {}
  part.sym, part.int, part.dig, part.dec = string.match(str, "^([%+%-]?)(%d*)(%.?)(%d*)")
  return part
end

local function speakBar(str, posMap, valMap)
  posMap = posMap or {[1]="仟"; [2]="佰"; [3]="拾"; [4]=""}
  valMap = valMap or {[0]="零"; "一"; "二"; "三" ;"四"; "五"; "六"; "七"; "八"; "九"}

  local out = ""
  local bar = string.sub("****" .. str, -4, -1)
  for pos = 1, 4 do
    local val = tonumber(string.sub(bar, pos, pos))
    if val == nil then
      goto continue
    end
    if val > 0 then
      out = out .. valMap[val] .. posMap[pos]
      goto continue
    end
    local valNext = tonumber(string.sub(bar, pos+1, pos+1))
    if ( valNext==nil or valNext==0 )then
      goto continue
    else
      out = out .. valMap[0]
      goto continue
    end
  ::continue::
  end
  if out == "" then out = valMap[0] end
  return out
end

local function speakIntOfficially(str, posMap, valMap)
  posMap = posMap or {[1]="千"; [2]="百"; [3]="十"; [4]=""}
  valMap = valMap or {[0]="零"; "一"; "二"; "三" ;"四"; "五"; "六"; "七"; "八"; "九"}

  local int = string.match(str, "^0*(%d+)$")
  if int=="" then int = "0" end
  local remain = #int % 4
  if remain==0 then remain = 4 end
  local tbBar = {[1] = string.sub(int, 1, remain)}
  for pos = remain+1, #int, 4 do
    local bar = string.sub(int, pos, pos+3)
    table.insert(tbBar, bar)
  end
  
  local tbSpeakBarSuffix = {[1]=""}
  for iBar = 2, #tbBar do
    local suffix = (iBar % 2 == 0) and ("万"..tbSpeakBarSuffix[1]) or ("亿"..tbSpeakBarSuffix[2])
    table.insert(tbSpeakBarSuffix, 1, suffix)
  end
  
  local tbSpeakBar = {}
  for k = 1, #tbBar do
    tbSpeakBar[k] = speakBar(tbBar[k], posMap, valMap)
  end
  
  local out = ""
  for k = 1, #tbBar do
    local speakBar = tbSpeakBar[k]
    if speakBar ~= valMap[0] then
      out = out .. speakBar .. tbSpeakBarSuffix[k]
    end
  end
  if out == "" then out = valMap[0] end
  return out
end

local function speakDecMoney(str, posMap, valMap)
  posMap = posMap or {[1]="角"; [2]="分"; [3]="厘"; [4]="毫"}
  valMap = valMap or {[0]="零"; "壹"; "贰"; "叁" ;"肆"; "伍"; "陆"; "柒"; "捌"; "玖"}

  local dec = string.sub(str, 1, 4)
  dec = string.gsub(dec, "0*$", "")
  if dec == "" then
    return "整"
  end

  local out = ""
  for pos = 1, #dec do
    local val = tonumber(string.sub(dec, pos, pos))
    out = out .. valMap[val] .. posMap[pos]
  end
  return out
end

local function speakOfficiallyLower(str)
  local part = splitNumStr(str)
  local speakSym = speakLiterally(part.sym)
  local speakInt = speakIntOfficially(part.int)
  local speakDig = speakLiterally(part.dig)
  local speakDec = speakLiterally(part.dec)
  local out = speakSym .. speakInt .. speakDig .. speakDec
  return out
end

local function speakOfficiallyUpper(str)
  local part = splitNumStr(str)
  local speakSym = speakLiterally(part.sym)
  local speakInt = speakIntOfficially(part.int, {[1]="仟"; [2]="佰"; [3]="拾"; [4]=""}, {[0]="零"; "壹"; "贰"; "叁" ;"肆"; "伍"; "陆"; "柒"; "捌"; "玖"})
  local speakDig = speakLiterally(part.dig)
  local speakDec = speakLiterally(part.dec)
  local out = speakSym .. speakInt .. speakDig .. speakDec
  return out
end

local function speakMoneyUpper(str)
  local part = splitNumStr(str)
  local speakSym = speakLiterally(part.sym)
  local speakInt = speakIntOfficially(part.int, {[1]="仟"; [2]="佰"; [3]="拾"; [4]=""}, {[0]="零"; "壹"; "贰"; "叁" ;"肆"; "伍"; "陆"; "柒"; "捌"; "玖"}) .. "元"
  local speakDec = speakDecMoney(part.dec)
  local out = speakSym .. speakInt .. speakDec
  return out
end

local function speakMoneyLower(str)
  local part = splitNumStr(str)
  local speakSym = speakLiterally(part.sym)
  local speakInt = speakIntOfficially(part.int, {[1]="千"; [2]="百"; [3]="十"; [4]=""}, {[0]="零"; "一"; "二"; "三" ;"四"; "五"; "六"; "七"; "八"; "九"}) .. "元"
  local speakDec = speakDecMoney(part.dec)
  local out = speakSym .. speakInt .. speakDec
  return out
end

local function baseConverse(str, from, to)
  local str10 = str
  if from == 16 then
    str10 = string.format("%d", str)
  end
  local strout = str10
  if to == 16 then
    strout = string.format("%#x", str10)
  end
  return strout
end

-- 序列化函数
local function serialize(obj)
  local type = type(obj)
  if type == "number" then
    return full_math_env.isinteger(obj) and math.floor(obj) or obj
  elseif type == "boolean" then
    return tostring(obj)
  elseif type == "string" then
    return '"'..obj..'"'
  elseif type == "table" then
    local str = "{"
    local i = 1
    for k, v in pairs(obj) do
      if i ~= k then  
        str = str.."["..serialize(k).."]="
      end
      str = str..serialize(v)..", "  
      i = i + 1
    end
    str = str:len() > 3 and str:sub(0,-3) or str
    return str.."}"
  elseif pcall(obj) then
    return "callable"
  end
  return obj
end

-- 贪婪模式设置
local greedy = true

-- 主calculator函数
local function calculator(input, seg)
  if string.sub(input, 1, 1) ~= "=" then return end
  
  local expfin = greedy or string.sub(input, -1, -1) == ";"
  local exp = (greedy or not expfin) and string.sub(input, 2, -1) or string.sub(input, 2, -2)
  
  -- 空格处理
  exp = exp:gsub("#", " ")
       
  if not expfin then return end
  
  local expe = exp
  -- 链式调用语法糖
  expe = expe:gsub("%$", " chain ")
  -- lambda语法糖
  do
    local count
    repeat
      expe, count = expe:gsub("\\%s*([%a%d%s,_]-)%s*%.(.-)|", " (function (%1) return %2 end) ")
    until count == 0
  end

  -- 安全检查：防止危险操作
  if expe:find("i?os?%.") or expe:find("io%.") then return end
  
  -- 创建完整的执行环境
  local env = {}
  -- 添加数学函数
  for k, v in pairs(full_math_env) do
    env[k] = v
  end
  -- 添加系统函数
  for k, v in pairs(system_env) do
    env[k] = v
  end
  -- 添加链式调用别名
  env.chain = full_math_env.chain
  -- 添加中文转换函数
  env.speakLiterally = speakLiterally
  env.speakMillitary = speakMillitary
  env.speakOfficiallyLower = speakOfficiallyLower
  env.speakOfficiallyUpper = speakOfficiallyUpper
  env.speakMoneyUpper = speakMoneyUpper
  env.speakMoneyLower = speakMoneyLower
  env.baseConverse = baseConverse
  
  -- 执行表达式
  local func = load("return "..expe, "calculator", "t", env)
  if not func then return end
  
  local result = func()
  if result == nil then return end
  
  result = serialize(result)
  yield(Candidate("number", seg.start, seg._end, result, "〈计算结果〉"))

  -- 数字特殊处理
  if string.match(result, "^[%+%-]?%d*%.?%d*$") then
    yield(Candidate("number", seg.start, seg._end, exp.."="..result, "〈计算等式〉", "123"))
    yield(Candidate("number", seg.start, seg._end, speakMoneyUpper(result), "〈大写金额〉"))
    yield(Candidate("number", seg.start, seg._end, speakMoneyLower(result), "〈小写金额〉"))
    yield(Candidate("number", seg.start, seg._end, speakOfficiallyUpper(result), "〈大写数字〉"))
    yield(Candidate("number", seg.start, seg._end, speakOfficiallyLower(result), "〈小写数字〉"))
  end
end

return calculator
