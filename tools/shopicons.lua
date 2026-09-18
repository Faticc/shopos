-- shopicons - собрать каталог иконок под конкретный магазин.
--
--   lua tools/shopicons.lua assets/shop16.bin test/shopcfg shop/icons.cfg out.bin
--
-- Полный каталог это 10618 иконок и 4.3 МБ - на диск третьего уровня (4096 КБ)
-- он не влезает, нужен RAID из трёх. А магазину из всего каталога нужны 185
-- иконок: список товаров закрыт и известен заранее.
--
-- Тут из большого каталога вынимаются ровно те записи, что упомянуты в
-- конфигах магазина (с учётом подстановок из icons.cfg), и пишутся отдельным
-- файлом того же формата OCI3 v2. Получается около 70 КБ: влезает на любой
-- диск, читается мгновенно, и на старте больше не поднимается индекс на
-- 430 КБ - его теперь всего пара килобайт.
--
-- Формат выхода тот же, что у tools/packshop.py, так что урезанный каталог
-- читают и shop.lua, и browse.lua, и shop/oci3_test.lua.

package.path = "shopos/os/?.lua;" .. package.path

local oci3 = require("oci3")
local icons = require("icons")

local BIG   = arg[1] or "assets/shop16.bin"
local CFG   = arg[2] or "shopos/cfg"
local ALIAS = arg[3] or "shopos/cfg/icons.cfg"
local OUT   = arg[4] or "shopos/data/icons.bin"

-- ------------------------------------------------------------------ конфиги

local function readcfg(name)
	local fh = io.open(CFG .. "/" .. name, "rb")
	if not fh then return {} end
	local text = fh:read("*a")
	fh:close()
	local loader = rawget(_G, "loadstring") or load
	local ok, v = pcall(loader("return " .. text, name))
	return (ok and type(v) == "table") and v or {}
end

local keys, seen = {}, {}
local function add(id, dmg)
	if not id then return end
	local k = icons.key(id, dmg)
	if not seen[k] then seen[k] = true keys[#keys + 1] = k end
end

for _, it in ipairs(readcfg("sellShop.cfg")) do add(it.id, it.dmg) end
for _, it in ipairs(readcfg("buyShop.cfg")) do add(it.id, it.dmg) end
for _, f in ipairs({ "oreExchanger.cfg", "exchanger.cfg" }) do
	for _, it in ipairs(readcfg(f)) do add(it.fromId, it.fromDmg) add(it.toId, it.toDmg) end
end

if #keys == 0 then
	io.stderr:write("в конфигах " .. CFG .. " нет ни одного предмета\n")
	os.exit(1)
end

-- ------------------------------------------------------------------ выборка

local IC = icons.open(BIG, ALIAS, { labels = true })
if not IC.ok then
	io.stderr:write("не открылся каталог " .. BIG .. "\n")
	os.exit(1)
end
local found, total = IC:resolve(keys)

-- Одна запись на иконку каталога: разные предметы магазина могут указывать
-- на одну и ту же картинку через подстановки, дважды её писать незачем.
local recs, byKey = {}, {}
for _, shopKey in ipairs(keys) do
	local catKey = IC:resolved(shopKey)
	if catKey and not byKey[catKey] then
		byKey[catKey] = true
		local cells, mode = IC:cells(shopKey)
		recs[#recs + 1] = {
			key = catKey,
			label = IC:label(shopKey) or catKey,
			cells = cells,
			mode = mode,
		}
	end
end

-- Ключи в файле строго по возрастанию: на них опирается двоичный поиск.
table.sort(recs, function(a, b) return a.key < b.key end)

-- ------------------------------------------------------------------ запись

local HEAD, REC = 48, 16
local sfmt, rep = string.format, string.rep

local function be(n, width)
	local out = {}
	for i = width, 1, -1 do
		out[i] = string.char(n % 256)
		n = (n - n % 256) / 256
	end
	return table.concat(out)
end

-- Разделы идут подряд: индекс, ключи, подписи, ячейки, порядок по подписи.
local keyBuf, labBuf, cellBuf = {}, {}, {}
local keyLen, labLen, cellLen = 0, 0, 0
for i = 1, #recs do
	local r = recs[i]
	r.keyPos, r.labPos = keyLen, labLen
	keyBuf[i], labBuf[i], cellBuf[i] = r.key, r.label, r.cells
	keyLen = keyLen + #r.key
	labLen = labLen + #r.label
	r.cellPos = cellLen
	cellLen = cellLen + #r.cells
end

local recOff  = HEAD
local keyOff  = recOff + #recs * REC
local labOff  = keyOff + keyLen
local cellOff = labOff + labLen
local ordOff  = cellOff + cellLen

for i = 1, #recs do recs[i].cellPos = recs[i].cellPos + cellOff end

-- Порядок по подписи: им пользуется просмотрщик каталога.
local order = {}
for i = 1, #recs do order[i] = i end
table.sort(order, function(a, b)
	local la, lb = oci3.fold(recs[a].label), oci3.fold(recs[b].label)
	if la ~= lb then return la < lb end
	return recs[a].key < recs[b].key
end)

local out = assert(io.open(OUT, "wb"))
out:write("OCI3", string.char(2), string.char(IC.w), string.char(IC.h), string.char(0))
out:write(be(#recs, 4), be(recOff, 4), be(keyOff, 4), be(keyLen, 4),
          be(labOff, 4), be(labLen, 4), be(cellOff, 4), be(cellLen, 4), be(ordOff, 4))
out:write(rep("\0", HEAD - 44))

for i = 1, #recs do
	local r = recs[i]
	out:write(be(r.keyPos, 3), string.char(#r.key),
	          be(r.labPos, 3), string.char(#r.label),
	          be(r.cellPos, 4), string.char(r.mode), "\0\0\0")
end
out:write(table.concat(keyBuf))
out:write(table.concat(labBuf))
out:write(table.concat(cellBuf))
for i = 1, #order do out:write(be(order[i] - 1, 4)) end
out:close()

local size = ordOff + #order * 4
print(sfmt("ключей магазина: %d, найдено иконок: %d", total, found))
print(sfmt("записей в каталоге: %d (одна картинка на несколько ключей - одна запись)", #recs))
print(sfmt("%s: %.0f КБ вместо %.1f МБ", OUT, size / 1024,
	(function() local f = io.open(BIG, "rb") local n = f:seek("end") f:close() return n / 1048576 end)()))
if found < total then
	print("без иконки осталось " .. (total - found) .. " - см. shop/icons.cfg")
end
