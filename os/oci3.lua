-- oci3 - чтение каталога иконок (формат v2, см. tools/packshop.py).
--
-- Каталог целиком в память не влезает: 10.6 тысяч иконок это 1.8 МБ мелким
-- набором и 4.4 МБ крупным, а потолок RAM - 4 МБ на четырёх планках. Зато
-- влезает его индекс: таблица записей и область ключей, вместе около 480 КБ.
-- Поэтому preload() поднимает их разом, и дальше поиск иконки по ключу идёт
-- вообще без обращений к диску - читаются только сами ячейки, и только те,
-- что сейчас на экране: 96 байт на иконку 8x4, 384 на 16x8.
--
-- Подписи предметов лежат отдельной областью и магазином не читаются: имена
-- приходят из самой МЭ-сети уже локализованными. Подписи читает только
-- демо-режим магазина, который показывает каталог без МЭ.
--
-- Источник спрятан за функцией read(pos, len), так что один код работает и с
-- файлом на диске, и со строкой в памяти.

local oci3 = {}

local byte, sub, char, find = string.byte, string.sub, string.char, string.find

local HEAD, REC = 48, 16

local function be24(s, i) local a, b, c = byte(s, i, i + 2) return (a * 256 + b) * 256 + c end
local function be32(s, i) local a, b, c, d = byte(s, i, i + 3) return ((a * 256 + b) * 256 + c) * 256 + d end

-- Регистр: string.lower знает только латиницу, а названия русские. Кириллица
-- в utf-8 это D0 90..AF (А-Я) и D0 81 (Ё) - сворачиваем их байтами.
local function fold(s)
	s = s:lower()
	s = s:gsub("\208\129", "\209\145")
	s = s:gsub("\208([\144-\159])", function(c) return "\208" .. char(byte(c) + 32) end)
	s = s:gsub("\208([\160-\175])", function(c) return "\209" .. char(byte(c) - 32) end)
	return s
end
oci3.fold = fold

-- Названия из модов приходят с цветовыми кодами Minecraft: "§dКвантовый".
-- На экране OC это мусор, а в поиске - лишние байты посреди слова.
local function plain(s) return (s:gsub("\194\167.", "")) end
oci3.plain = plain

-- ---------------------------------------------------------------- источники

--- Каталог целиком в памяти.
function oci3.fromstring(data)
	return oci3.new(function(pos, len) return sub(data, pos + 1, pos + len) end)
end

--- Файл через обычный io: так же работает и в OpenOS, и в проверке на ПК.
function oci3.fromfile(path)
	local fh = assert(io.open(path, "rb"))
	return oci3.new(function(pos, len)
		fh:seek("set", pos)
		return fh:read(len) or ""
	end), fh
end

--- Файл напрямую через компонент filesystem. За раз он отдаёт не больше
--- maxReadBuffer байт (в этой сборке 2048), поэтому читаем циклом.
function oci3.fromproxy(fs, path, chunk)
	chunk = chunk or 2048
	local h = assert(fs.open(path, "r"))
	return oci3.new(function(pos, len)
		fs.seek(h, "set", pos)
		local parts, got = {}, 0
		while got < len do
			local part = fs.read(h, chunk < len - got and chunk or len - got)
			if not part or #part == 0 then break end
			parts[#parts + 1] = part
			got = got + #part
		end
		return #parts == 1 and parts[1] or table.concat(parts)
	end), h
end

-- ------------------------------------------------------------------ каталог

local Cat = {}
Cat.__index = Cat

function oci3.new(read)
	local h = read(0, HEAD)
	if #h < HEAD or sub(h, 1, 4) ~= "OCI3" then error("не каталог OCI3", 2) end
	if byte(h, 5) ~= 2 then error("каталог версии " .. byte(h, 5) .. ", нужна 2", 2) end
	local self = setmetatable({
		read    = read,
		ver     = byte(h, 5),
		w       = byte(h, 6),
		h       = byte(h, 7),
		flags   = byte(h, 8),
		count   = be32(h, 9),
		recOff  = be32(h, 13),
		keyOff  = be32(h, 17),
		keyLen  = be32(h, 21),
		labOff  = be32(h, 25),
		labLen  = be32(h, 29),
		cellOff = be32(h, 33),
		cellLen = be32(h, 37),
		ordOff  = be32(h, 41),
	}, Cat)
	self.cellsHalf = self.w * self.h * 2
	self.cellsFull = self.w * self.h * 3
	return self
end

--- Поднять индекс в память: таблицу записей и все ключи. После этого find()
--- не трогает диск вообще. Стоит около 480 КБ на каталог из 10.6к иконок и
--- окупается на первом же обходе содержимого МЭ.
function Cat:preload()
	self.recs = self.read(self.recOff, self.count * REC)
	self.keys = self.read(self.keyOff, self.keyLen)
	return #self.recs == self.count * REC and #self.keys == self.keyLen
end

--- Сырая запись номер i (1..count).
function Cat:raw(i)
	local p
	if self.recs then
		p = (i - 1) * REC
		local r = self.recs
		return {
			keyPos = be24(r, p + 1), keyLen = byte(r, p + 4),
			labPos = be24(r, p + 5), labLen = byte(r, p + 8),
			cellPos = be32(r, p + 9), mode = byte(r, p + 13),
		}
	end
	local r = self.read(self.recOff + (i - 1) * REC, REC)
	return {
		keyPos = be24(r, 1), keyLen = byte(r, 4),
		labPos = be24(r, 5), labLen = byte(r, 8),
		cellPos = be32(r, 9), mode = byte(r, 13),
	}
end

--- Ключ записи. С поднятым индексом - обычная вырезка из строки в памяти.
function Cat:key(i, r)
	r = r or self:raw(i)
	if self.keys then return sub(self.keys, r.keyPos + 1, r.keyPos + r.keyLen) end
	return self.read(self.keyOff + r.keyPos, r.keyLen)
end

--- Подпись из каталога. Магазину не нужна, читает её только просмотрщик.
function Cat:label(i, r)
	r = r or self:raw(i)
	return plain(self.read(self.labOff + r.labPos, r.labLen))
end

function Cat:get(i)
	local r = self:raw(i)
	r.key = self:key(i, r)
	r.label = self:label(i, r)
	return r
end

--- Пачка записей подряд, одним чтением индекса и одним чтением подписей.
function Cat:range(i, n)
	if n > self.count - i + 1 then n = self.count - i + 1 end
	if n <= 0 then return {} end
	local out = {}
	for k = 1, n do out[k] = self:raw(i + k - 1) end
	local first, last = out[1].labPos, out[n].labPos + out[n].labLen
	local labs = self.read(self.labOff + first, last - first)
	for k = 1, n do
		local r = out[k]
		r.key = self:key(i + k - 1, r)
		r.label = plain(sub(labs, r.labPos - first + 1, r.labPos - first + r.labLen))
	end
	return out
end

--- Ячейки иконки: строка из w*h*(2 или 3) байт.
function Cat:cells(r)
	if type(r) == "number" then r = self:raw(r) end
	return self.read(r.cellPos, r.mode == 0 and self.cellsHalf or self.cellsFull), r.mode
end

--- Номер записи по ключу "modid:name[:meta]". Записи отсортированы по ключу,
--- поиск двоичный; с поднятым индексом это чистая работа в памяти.
function Cat:find(key)
	local lo, hi = 1, self.count
	local recs, keys = self.recs, self.keys
	if recs and keys then
		while lo <= hi do
			local mid = (lo + hi - (lo + hi) % 2) / 2
			local p = (mid - 1) * REC
			local kp, kl = be24(recs, p + 1), byte(recs, p + 4)
			local k = sub(keys, kp + 1, kp + kl)
			if k == key then return mid
			elseif k < key then lo = mid + 1
			else hi = mid - 1 end
		end
		return nil
	end
	while lo <= hi do
		local mid = (lo + hi - (lo + hi) % 2) / 2
		local r = self:raw(mid)
		local k = self.read(self.keyOff + r.keyPos, r.keyLen)
		if k == key then return mid
		elseif k < key then lo = mid + 1
		else hi = mid - 1 end
	end
	return nil
end

--- Номер записи, стоящей j-й по алфавиту подписи.
function Cat:byLabel(j)
	return be32(self.read(self.ordOff + (j - 1) * 4, 4), 1) + 1
end

-- Подписи лежат в порядке записей, значит labPos растёт вместе с номером -
-- по найденному смещению номер ищется двоичным поиском.
function Cat:atLabPos(pos)
	local lo, hi, best = 1, self.count, 1
	while lo <= hi do
		local mid = (lo + hi - (lo + hi) % 2) / 2
		if self:raw(mid).labPos <= pos then best, lo = mid, mid + 1 else hi = mid - 1 end
	end
	return best
end

--- Поиск подстроки по подписям каталога. Нужен просмотрщику; магазин ищет
--- по названиям из МЭ, у него всё уже в памяти.
function Cat:search(query, limit, chunk)
	limit, chunk = limit or 64, chunk or 8192
	local q = fold(query)
	if #q == 0 then return {} end
	local over, out, seen, pos = 256, {}, {}, 0
	while pos < self.labLen do
		local len = chunk < self.labLen - pos and chunk or self.labLen - pos
		-- на байт назад: кусок может начаться с середины двухбайтовой буквы,
		-- и без ведущего байта регистр у неё не свернётся
		local back = pos > 0 and 1 or 0
		local tail = len + over
		if tail > self.labLen - pos then tail = self.labLen - pos end
		local buf = fold(self.read(self.labOff + pos - back, back + tail))
		local at = 1 + back
		while true do
			local s = find(buf, q, at, true)
			if not s or s - back > len then break end
			local i = self:atLabPos(pos + s - 1 - back)
			if not seen[i] then
				seen[i] = true
				out[#out + 1] = i
				if #out >= limit then return out end
			end
			at = s + 1
		end
		pos = pos + len
	end
	return out
end

return oci3
