-- icons - иконки предметов магазина: ключ -> ячейки для paint:icon.
--
-- Магазин знает весь свой список заранее: 185 разных предметов в конфигах и
-- ничего сверх того. Это меняет всю работу с каталогом против просмотрщика
-- МЭ, которому ключи приходят на ходу.
--
-- Поэтому старт выглядит так:
--   1. поднять индекс каталога (записи и ключи, около 430 КБ);
--   2. найти в нём все ключи магазина - в памяти, без единого чтения;
--   3. прочитать ячейки найденных иконок и оставить их в памяти;
--   4. отпустить индекс и закрыть файл.
--
-- После этого магазин не трогает диск вообще: 185 иконок 16x8 это 71 КБ, а
-- пик памяти на старте (индекс плюс ячейки) держится секунду. Для сравнения,
-- поиск по ключу с диска стоит около 14 чтений на предмет, и это на каждую
-- перерисовку сетки.
--
-- Каталог собран с другой сборки, чем та, под которую писан магазин: часть
-- модов там зовётся иначе (gendustry -> jgendustry), часть предметов лежит
-- под другим мета. Поэтому ключ ищется не как есть, а по цепочке подстановок
-- из icons.cfg - см. resolve().

local oci3 = require("oci3")

local icons = {}

local byte, sub, floor = string.byte, string.sub, math.floor

-- --------------------------------------------------------------- ключ

--- Ключ каталога для предмета конфига. Ровно тот же вид, в каком ключи
--- пишет упаковщик и отдаёт МЭ: "modid:name" для мета 0, иначе с мета.
function icons.key(id, dmg)
	dmg = floor(tonumber(dmg) or 0)
	if dmg == 0 then return id end
	return id .. ":" .. dmg
end

--- Разобрать ключ обратно на id и мета.
function icons.split(key)
	local id, dmg = key:match("^(.*):(%d+)$")
	if id then return id, tonumber(dmg) end
	return key, 0
end

-- ------------------------------------------------------------- подстановки

--- Файл подстановок: две таблицы.
---   key  - точное соответствие ключ -> ключ каталога;
---   id   - замена только id, мета остаётся ("a:5" -> "b:5");
---   flat - замена id, мета отбрасывается (в каталоге одна иконка на всё).
--- Пустые таблицы, если файла нет: магазин работает и без него, просто часть
--- предметов останется без иконки.
local function readAliases(path)
	local empty = { key = {}, id = {}, flat = {} }
	if not path then return empty end
	local fh = io.open(path, "rb")
	if not fh then return empty end
	local text = fh:read("*a")
	fh:close()
	local loader = rawget(_G, "loadstring") or load
	local chunk = loader("return " .. text, "icons.cfg")
	if not chunk then return empty end
	local ok, t = pcall(chunk)
	if not ok or type(t) ~= "table" then return empty end
	t.key, t.id, t.flat = t.key or {}, t.id or {}, t.flat or {}
	return t
end

-- ------------------------------------------------------------- пустой набор

-- Каталога нет - магазин обязан подняться всё равно, только без картинок.
local Null = {}
Null.__index = Null
Null.w, Null.h, Null.ok = 0, 0, false
function Null:resolve() return 0, 0 end
function Null:has() return false end
function Null:cells() return nil end
function Null:stats() return { total = 0, found = 0, missing = {} } end

-- ------------------------------------------------------------------ набор

local Set = {}
Set.__index = Set

--- Открыть каталог. Вернёт пустой набор, если файла нет или он не читается:
--- магазин без иконок хуже, но живой.
--- opt.labels - тащить из каталога ещё и подписи. Магазину они не нужны:
--- названия у него свои, из конфига. Нужны они только сборщику урезанного
--- каталога, а стоят по чтению на иконку.
function icons.open(path, aliasPath, opt)
	local ok, cat, fh = pcall(oci3.fromfile, path)
	if not ok or not cat then return setmetatable({}, Null) end
	return setmetatable({
		labels  = (opt and opt.labels) and {} or nil,
		cat     = cat,
		fh      = fh,
		alias   = readAliases(aliasPath),
		w       = cat.w,
		h       = cat.h,
		ok      = true,
		cell    = {},   -- ключ каталога -> строка ячеек
		mode    = {},   -- ключ каталога -> режим (0 полублок, 1 брайль)
		at      = {},   -- ключ магазина -> ключ каталога
		missing = {},
	}, Set)
end

--- Ключ записи номер i прямо из поднятого индекса, без таблиц-обёрток.
local function keyAt(self, i)
	local recs, keys = self.cat.recs, self.cat.keys
	local p = (i - 1) * 16
	local a, b, c = byte(recs, p + 1, p + 3)
	local kp = (a * 256 + b) * 256 + c
	return sub(keys, kp + 1, kp + byte(recs, p + 4))
end

--- Первая запись, чей ключ начинается с pref. Записи отсортированы по ключу,
--- так что это обычный lower_bound по индексу в памяти.
local function lowerBound(self, pref)
	local lo, hi, n = 1, self.cat.count + 1, #pref
	while lo < hi do
		local mid = (lo + hi - (lo + hi) % 2) / 2
		if keyAt(self, mid) < pref then lo = mid + 1 else hi = mid end
	end
	if lo <= self.cat.count and sub(keyAt(self, lo), 1, n) == pref then return lo end
	return nil
end

--- Цепочка кандидатов для ключа магазина, по убыванию точности.
local function candidates(self, key)
	local a = self.alias
	local out, n = {}, 0
	local function add(k) if k then n = n + 1 out[n] = k end end

	add(key)
	add(a.key[key])
	local id, dmg = icons.split(key)
	if a.id[id] then add(icons.key(a.id[id], dmg)) end
	if a.flat[id] then add(a.flat[id]) end
	return out, n
end

--- Найти все ключи, прочитать их ячейки, отпустить индекс.
--- keys - массив ключей магазина; повторы не мешают, каждый разбирается раз.
--- Возвращает сколько нашлось и сколько всего.
function Set:resolve(keys)
	local cat = self.cat
	if not cat.recs and not cat:preload() then
		-- индекс не поднялся (мало памяти) - работаем с диска, медленнее,
		-- но ячейки всё равно осядут в кэше и диск дальше не понадобится
		cat.recs, cat.keys = nil, nil
	end

	local total, found = 0, 0
	local seen = {}
	for i = 1, #keys do
		local key = keys[i]
		if not seen[key] then
			seen[key] = true
			total = total + 1
			local list, n = candidates(self, key)
			local hit
			for j = 1, n do
				local c = list[j]
				local rec = cat:find(c)
				if rec then hit = c break end
				-- последний шанс: тот же предмет под другим мета. Пригодно
				-- для брони и батареек, у которых в dmg лежит износ, а не
				-- разновидность; для настоящих разновидностей это дало бы
				-- чужую картинку, поэтому только на прямых подстановках.
				if j > 1 then
					local cid = icons.split(c)
					local lb = cat.recs and lowerBound(self, cid .. ":")
					if lb then hit = keyAt(self, lb) break end
				end
			end
			if hit then
				found = found + 1
				self.at[key] = hit
				if not self.cell[hit] then
					local j = cat:find(hit)
					local r = cat:raw(j)
					self.cell[hit] = cat:cells(r)
					self.mode[hit] = r.mode
					if self.labels then self.labels[hit] = cat:label(j, r) end
				end
			else
				self.missing[#self.missing + 1] = key
			end
		end
	end

	-- индекс больше не нужен: всё, что магазин покажет, уже в памяти
	cat.recs, cat.keys = nil, nil
	if self.fh then pcall(self.fh.close, self.fh) self.fh = nil end
	self.cat = setmetatable({}, { __index = function() error("каталог закрыт", 2) end })
	self.found, self.total = found, total
	return found, total
end

function Set:has(key) return self.at[key] ~= nil end

--- Ключ каталога, под которым нашлась иконка: может отличаться от ключа
--- магазина, если сработала подстановка.
function Set:resolved(key) return self.at[key] end

function Set:label(key)
	local at = self.at[key]
	return (at and self.labels) and self.labels[at] or nil
end

--- Ячейки и режим иконки. Обе величины уже в памяти, чтения нет.
function Set:cells(key)
	local at = self.at[key]
	if not at then return nil end
	return self.cell[at], self.mode[at]
end

function Set:stats()
	return { total = self.total or 0, found = self.found or 0, missing = self.missing }
end

return icons
