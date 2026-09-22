-- inflate: распаковка deflate (RFC 1951) и gzip (RFC 1952) по кускам.
--
--   local inflate = require("inflate")
--   local z = inflate.new(function(s) file:write(s) end, "gzip")
--   z:feed(кусок)        -- сколько угодно раз, в каком угодно дроблении
--   if z.done then ... end
--
-- Второй довод - обёртка: "gzip" (по умолчанию), "zlib" или "raw".
-- Выход приходит в sink кусками по 1 КБ (последний - короче), как только
-- они готовы, поэтому распаковывать можно прямо из сети, не держа ни
-- сжатое, ни распакованное целиком. z.done - поток кончился; z.size -
-- сколько байт вышло; z.rest - что пришло после конца потока. Битый поток
-- - ошибка из feed.
--
-- Процессор бывает и на Lua 5.2, поэтому битовых операторов тут нет:
-- биты снимаются делением и остатком. Окно на 32 КБ назад хранится
-- строками по 1 КБ, а не таблицей чисел: таблица на 32768 чисел съела бы
-- полмегабайта памяти машины.

local floor, char, byte, unpack = math.floor, string.char, string.byte, table.unpack or unpack
local yield, create, resume, status = coroutine.yield, coroutine.create, coroutine.resume, coroutine.status

local P = { [0] = 1 }
for i = 1, 32 do P[i] = P[i - 1] * 2 end

-- длины 257..285 и расстояния: основание и сколько бит добавки
local LBASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
  35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEXT = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
  3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DBASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
  257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DEXT = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
  7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
-- порядок длин в заголовке динамического блока
local ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local W = 1024       -- размер куска окна и выхода
local RING = 33      -- 32 куска окна + текущий

--- Канонический код Хаффмана по длинам: сколько кодов каждой длины и
--- символы по порядку кодов.
local function huffman(lens, n)
  local count, offs, sym = {}, {}, {}
  for l = 0, 15 do count[l] = 0 end
  for s = 0, n - 1 do
    local l = lens[s] or 0
    count[l] = count[l] + 1
  end
  offs[1] = 0
  for l = 1, 14 do offs[l + 1] = offs[l] + count[l] end
  for s = 0, n - 1 do
    local l = lens[s] or 0
    if l ~= 0 then
      sym[offs[l]] = s
      offs[l] = offs[l] + 1
    end
  end
  return { count = count, sym = sym }
end

local FIXED_L, FIXED_D
do
  local l = {}
  for s = 0, 143 do l[s] = 8 end
  for s = 144, 255 do l[s] = 9 end
  for s = 256, 279 do l[s] = 7 end
  for s = 280, 287 do l[s] = 8 end
  FIXED_L = huffman(l, 288)
  local d = {}
  for s = 0, 29 do d[s] = 5 end
  FIXED_D = huffman(d, 30)
end

local function decoder(wrap)
  local inp, ip, bb, bc = "", 1, 0, 0
  local total = 0

  -- следующий байт входа: кончился кусок - ждём новый
  local function nextByte()
    while ip > #inp do
      inp = yield()
      if inp == nil then error("inflate: поток оборвался", 0) end
      ip = 1
    end
    local b = byte(inp, ip)
    ip = ip + 1
    return b
  end

  local function bits(n)
    while bc < n do
      bb = bb + nextByte() * P[bc]
      bc = bc + 8
    end
    local v = bb % P[n]
    bb = floor(bb / P[n])
    bc = bc - n
    return v
  end

  local function decode(h)
    local count, code, first, index = h.count, 0, 0, 0
    for len = 1, 15 do
      if bc == 0 then bb, bc = nextByte(), 8 end
      local b = bb % 2
      bb, bc = floor(bb / 2), bc - 1
      code = code + b
      local c = count[len]
      if code - c < first then return h.sym[index + code - first] end
      index, first = index + c, (first + c) * 2
      code = code * 2
    end
    error("inflate: битый код", 0)
  end

  -- окно: ring[номер куска % RING] - готовые куски, cur - текущий
  local ring, cur, cl, cb = {}, {}, 0, 0

  local function put(v)
    cl = cl + 1
    cur[cl] = v
    if cl == W then
      local s = char(unpack(cur, 1, W))
      ring[cb % RING] = s
      cb, cl = cb + 1, 0
      total = total + W
      yield(s)
    end
  end

  local function copy(len, dist)
    for _ = 1, len do
      local p = cb * W + cl - dist
      local b = floor(p / W)
      if b == cb then
        put(cur[p - b * W + 1])
      else
        put(byte(ring[b % RING], p - b * W + 1))
      end
    end
  end

  local function codes(lh, dh)
    while true do
      local s = decode(lh)
      if s < 256 then
        put(s)
      elseif s == 256 then
        return
      else
        s = s - 256
        if s > 29 then error("inflate: битая длина", 0) end
        local len = LBASE[s] + bits(LEXT[s])
        local d = decode(dh) + 1
        if d > 30 then error("inflate: битое расстояние", 0) end
        local dist = DBASE[d] + bits(DEXT[d])
        if dist > cb * W + cl then error("inflate: расстояние за началом", 0) end
        copy(len, dist)
      end
    end
  end

  local function dynamic()
    local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
    local lens = {}
    for i = 1, ncode do lens[ORDER[i]] = bits(3) end
    local ch = huffman(lens, 19)
    lens = {}
    local i = 0
    while i < nlen + ndist do
      local s = decode(ch)
      if s < 16 then
        lens[i] = s
        i = i + 1
      else
        local rep, v = 0, 0
        if s == 16 then
          if i == 0 then error("inflate: повтор без длины", 0) end
          v, rep = lens[i - 1], 3 + bits(2)
        elseif s == 17 then
          rep = 3 + bits(3)
        else
          rep = 11 + bits(7)
        end
        if i + rep > nlen + ndist then error("inflate: лишние длины", 0) end
        for _ = 1, rep do lens[i] = v i = i + 1 end
      end
    end
    local dl = {}
    for k = 0, ndist - 1 do dl[k] = lens[nlen + k] end
    return huffman(lens, nlen), huffman(dl, ndist)
  end

  local function stored()
    bits(bc % 8)                     -- до границы байта
    local len = bits(16)
    local nlen = bits(16)
    if len + nlen ~= 65535 then error("inflate: битый несжатый блок", 0) end
    for _ = 1, len do put(bits(8)) end
  end

  local function skipZ()             -- строка до нуля в заголовке gzip
    repeat until bits(8) == 0
  end

  return function()
    if wrap == "gzip" then
      if bits(8) ~= 31 or bits(8) ~= 139 then error("inflate: это не gzip", 0) end
      if bits(8) ~= 8 then error("inflate: не deflate", 0) end
      local flg = bits(8)
      bits(16) bits(16) bits(16)     -- время, флаги сжатия, ОС
      if floor(flg / 4) % 2 == 1 then
        local n = bits(16)
        for _ = 1, n do bits(8) end
      end
      if floor(flg / 8) % 2 == 1 then skipZ() end
      if floor(flg / 16) % 2 == 1 then skipZ() end
      if floor(flg / 2) % 2 == 1 then bits(16) end
    elseif wrap == "zlib" then
      local cmf, flg = bits(8), bits(8)
      if cmf % 16 ~= 8 or (cmf * 256 + flg) % 31 ~= 0 then error("inflate: это не zlib", 0) end
      if floor(flg / 32) % 2 == 1 then error("inflate: zlib со словарём не поддержан", 0) end
    end
    repeat
      local last = bits(1)
      local kind = bits(2)
      if kind == 0 then stored()
      elseif kind == 1 then codes(FIXED_L, FIXED_D)
      elseif kind == 2 then codes(dynamic())
      else error("inflate: неизвестный тип блока", 0) end
    until last == 1
    -- хвост: несобранный кусок наружу, дальше - концевик обёртки
    if cl > 0 then
      local s = char(unpack(cur, 1, cl))
      total = total + cl
      cl = 0
      yield(s)
    end
    bits(bc % 8)
    if wrap == "gzip" then
      bits(16) bits(16)              -- CRC32: файлы сверяет вызывающий
      local isize = bits(16) + bits(16) * 65536
      if isize ~= total % 4294967296 then error("inflate: размер не сошёлся", 0) end
    elseif wrap == "zlib" then
      bits(16) bits(16)              -- Adler-32
    end
    -- лишнее после конца: целые байты из битового буфера и остаток куска
    local rest = {}
    while bc >= 8 do rest[#rest + 1] = char(bits(8)) end
    return table.concat(rest) .. inp:sub(ip), total
  end
end

local Z = {}
Z.__index = Z

--- Подать очередной кусок сжатого. Возвращает true, когда поток кончился.
function Z:feed(chunk)
  if self.done then
    self.rest = self.rest .. chunk
    return true
  end
  local ok, a, b = resume(self.co, chunk)
  while true do
    if not ok then error(a, 0) end
    if status(self.co) == "dead" then
      self.done, self.rest, self.size = true, a or "", b
      return true
    end
    if a == nil then return false end  -- ждёт следующего куска
    self.sink(a)
    ok, a, b = resume(self.co)
  end
end

local inflate = {}

function inflate.new(sink, wrap)
  wrap = wrap or "gzip"
  local z = setmetatable({ sink = sink, done = false, rest = "", size = 0 }, Z)
  z.co = create(decoder(wrap))
  resume(z.co)                       -- до первого запроса входа
  return z
end

--- Распаковать строку целиком.
function inflate.string(data, wrap)
  local out = {}
  local z = inflate.new(function(s) out[#out + 1] = s end, wrap)
  if not z:feed(data) then error("inflate: поток оборвался", 0) end
  return table.concat(out), z.rest
end

return inflate
