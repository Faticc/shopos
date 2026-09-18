-- catalog - цена, название и иконка предмета по его ключу.
--
-- Файл DWSC собирает tools/shopcat.py, формат расписан там. Крупные иконки
-- не влезают на один диск, и тогда каталог лежит двумя частями: основная
-- на загрузочном диске, catalog.2.bin с остальными иконками - на любом
-- другом диске машины, он ищется сам. В памяти лежит
-- только индекс хешей (8 байт на предмет); запись предмета читается с диска
-- при первой встрече и дальше живёт в кеше. Предметы, которых нет в МЭ, в
-- память не попадают вовсе.

local root = require("root")
local disk = require("disk")

local byte, sub, floor = string.byte, string.sub, math.floor

local catalog = {}

local function u24(s, i) local a, b, c = byte(s, i, i + 2) return (a * 256 + b) * 256 + c end
local function u32(s, i) return u24(s, i) * 256 + byte(s, i + 3) end

--- Тот же хеш, что в упаковщике: h = (h * 31 + байт) mod 2^32. Числа
--- остаются меньше 2^37, поэтому одинаково точны в Lua 5.2 и 5.3.
local function hash(s)
	local h = 0
	for i = 1, #s do h = (h * 31 + byte(s, i)) % 4294967296 end
	return h
end

--- Ключ предмета: "modid:name", мета дописывается, если не ноль.
function catalog.key(id, dmg)
	dmg = floor(tonumber(dmg) or 0)
	return dmg == 0 and id or (id .. ":" .. dmg)
end

local C = {}
C.__index = C

function catalog.open(path)
	local r = root:reader(path)
	if not r then return nil, "нет файла " .. path end
	local h = r.at(0, 32)
	if #h < 32 or sub(h, 1, 4) ~= "DWSC" or byte(h, 5) ~= 1 then
		r.close()
		return nil, path .. ": не каталог DWSC v1"
	end
	local self = setmetatable({
		r = r,
		iw = byte(h, 6), ih = byte(h, 7),
		count = u32(h, 9),
		recOff = u32(h, 21),
		stamp = u32(h, 17),
		split = u32(h, 29),
		known = {},      -- ключ -> запись или false
		icons = {}, iconN = 0,
	}, C)
	if self.split > 0 then
		self.path2 = path:gsub("%.bin$", "") .. ".2.bin"
		self.r2 = catalog.findSecond(self.path2)
	end
	self.idx = r.at(u32(h, 13), self.count * 8)
	if #self.idx ~= self.count * 8 then
		r.close()
		return nil, path .. ": файл обрезан"
	end
	return self
end

--- Вторая часть каталога: тот же путь на любом диске машины. Порядок
--- дисков не важен - какой вставлен, на том и найдётся.
function catalog.findSecond(path)
	for addr in component.list("filesystem") do
		local p = component.proxy(addr)
		local ok, has = pcall(p.exists, path)
		if ok and has then
			local r = disk.new(p):reader(path)
			if r then return r end
		end
	end
	return nil
end

--- Нет второго диска: иконки с него не покажутся, но торговать можно.
function C:missing()
	return self.split > 0 and not self.r2
end

--- Номера позиций индекса с этим хешем: двоичный поиск первой, дальше
--- подряд, пока хеш тот же.
function C:slots(h)
	local idx, lo, hi = self.idx, 1, self.count
	while lo < hi do
		local mid = floor((lo + hi) / 2)
		if u32(idx, (mid - 1) * 8 + 1) < h then lo = mid + 1 else hi = mid end
	end
	local out = {}
	while lo <= self.count and u32(idx, (lo - 1) * 8 + 1) == h do
		local p = (lo - 1) * 8
		out[#out + 1] = { u24(idx, p + 5), byte(idx, p + 8) }
		lo = lo + 1
	end
	return out
end

local function parse(s, i)
	local kl = byte(s, i)
	local key = sub(s, i + 1, i + kl)
	i = i + 1 + kl
	local ll = byte(s, i)
	local label = sub(s, i + 1, i + ll)
	i = i + 1 + ll
	local price = 0
	for k = 0, 5 do price = price * 256 + byte(s, i + k) end
	local flags = byte(s, i + 10)
	return {
		key = key,
		label = label,
		price = price / 1e6,         -- в единицах выгрузки цен
		icon = u32(s, i + 6),
		braille = flags % 2 == 1,
	}
end

--- Найти записи для списка ключей. Позиции сортируются и читаются
--- пачками: соседние предметы одного мода лежат в файле рядом, и сотня
--- новых ключей стоит несколько чтений, а не сотню.
function C:resolve(keys)
	local want = {}
	for i = 1, #keys do
		local k = keys[i]
		if self.known[k] == nil then
			self.known[k] = false
			for _, s in ipairs(self:slots(hash(k))) do
				want[#want + 1] = { pos = s[1], len = s[2], key = k }
			end
		end
	end
	table.sort(want, function(a, b) return a.pos < b.pos end)
	local i = 1
	while i <= #want do
		local from, to, j = want[i].pos, want[i].pos + want[i].len, i
		while j < #want and want[j + 1].pos + want[j + 1].len - from <= 2048 do
			j = j + 1
			to = want[j].pos + want[j].len
		end
		local blob = self.r.at(self.recOff + from, to - from)
		for n = i, j do
			local w = want[n]
			if #blob >= w.pos - from + w.len then
				local rec = parse(blob, w.pos - from + 1)
				if rec.key == w.key then self.known[w.key] = rec end
			end
		end
		i = j + 1
	end
end

--- Запись по ключу или nil, если такого предмета в выгрузке цен нет.
function C:get(key)
	local v = self.known[key]
	if v == nil then
		self:resolve({ key })
		v = self.known[key]
	end
	return v or nil
end

--- Ячейки иконки. Кеш держит несколько страниц витрины; переполнился -
--- сбрасывается целиком.
function C:cells(rec)
	if not rec or rec.icon == 0 then return nil end
	local hit = self.icons[rec.icon]
	if hit then return hit end
	local n = self.iw * self.ih * (rec.braille and 3 or 2)
	local data
	if self.split > 0 and rec.icon >= self.split then
		if not self.r2 then return nil end
		data = self.r2.at(rec.icon - self.split, n)
	else
		data = self.r.at(rec.icon, n)
	end
	if #data == 0 then return nil end
	-- 60 иконок 32x32 это 60 КБ: три страницы витрины
	if self.iconN >= 60 then self.icons, self.iconN = {}, 0 end
	self.icons[rec.icon] = data
	self.iconN = self.iconN + 1
	return data
end

function C:close()
	self.r.close()
	if self.r2 then self.r2.close() end
end

return catalog
