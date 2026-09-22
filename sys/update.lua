-- update - обновление ShopOS с гита прямо из панели владельца.
--
-- Установщик ставит систему из OpenOS, и ради пары изменившихся файлов
-- поднимать OpenOS заново незачем. Здесь магазин сам качает manifest.lua,
-- сверяет его с записью /var/installed.lua (что и какой версии положили в
-- прошлый раз) и берёт с гита только то, у чего разошёлся CRC32.
--
-- Чего обновление не трогает никогда: диск данных (счета, журнал,
-- rules.cfg) и /cfg/shop.cfg - он помечен keep в манифесте.
--
-- Порядок важен. Сперва все мелкие файлы качаются во временные .part и лишь
-- потом подменяются разом: оборванная сеть не оставит половину системы от
-- одной версии, половину от другой. Каталог идёт последним - он в мегабайты,
-- двух копий диск не вмещает, поэтому старая стирается до загрузки. Обрыв
-- на нём оставит магазин без цен, но с рабочей панелью, из которой
-- обновление повторяется.

local root = require("root")
local disk = require("disk")

local computer, component = computer, component

local update = {}

local cfg = root:table("/cfg/shop.cfg") or {}
local REPO = cfg.repo or "Faticc/shopos"
local BRANCH = cfg.branch or "main"

update.where = REPO .. "@" .. BRANCH

local RECORD = "/var/installed.lua"
local MARK = "/shopos.data"        -- метка диска данных: на него не пишем

-- ------------------------------------------------------------------ CRC32

--- Процессор бывает и на Lua 5.3 (операторы & ~ >>), и на 5.2 (bit32):
--- код под 5.3 в 5.2 даже не разберётся, поэтому собирается через load.
local crc32
do
	local f = load([[
		local T = {}
		for i = 0, 255 do
			local c = i
			for _ = 1, 8 do
				if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
			end
			T[i] = c
		end
		local byte = string.byte
		return function(crc, s)
			crc = ~crc & 0xFFFFFFFF
			for i = 1, #s do crc = T[(crc ~ byte(s, i)) & 0xFF] ~ (crc >> 8) end
			return ~crc & 0xFFFFFFFF
		end]])
	if f then
		crc32 = f()
	elseif bit32 then
		local band, bxor, rshift, bnot = bit32.band, bit32.bxor, bit32.rshift, bit32.bnot
		local T = {}
		for i = 0, 255 do
			local c = i
			for _ = 1, 8 do
				if band(c, 1) == 1 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
			end
			T[i] = c
		end
		local byte = string.byte
		crc32 = function(crc, s)
			crc = bnot(crc)
			for i = 1, #s do crc = bxor(T[band(bxor(crc, byte(s, i)), 0xFF)], rshift(crc, 8)) end
			return bnot(crc)
		end
	end
end

local function hex(crc) return ("%08x"):format(crc) end

--- Машина, которая слишком долго не уступает управление, падает: хэш и
--- запись считаются кусками, между ними отдаём тик.
local lastYield = computer.uptime()
local function breathe()
	if computer.uptime() - lastYield > 1 then
		computer.pullSignal(0)
		lastYield = computer.uptime()
	end
end

-- ------------------------------------------------------------------ диски

local function writable(p)
	local ok, ro = pcall(p.isReadOnly)
	return ok and not ro
end

local function isData(p)
	local ok, has = pcall(p.exists, MARK)
	return ok and has
end

--- Диск под вторую часть каталога: тот, где она уже лежит, иначе самый
--- свободный записываемый - не загрузочный, не tmpfs и не диск данных.
function update.second(path)
	local boot = computer.getBootAddress()
	local tmp = computer.tmpAddress and computer.tmpAddress()
	local best, free
	for addr in component.list("filesystem") do
		if addr ~= boot and addr ~= tmp then
			local p = component.proxy(addr)
			if writable(p) and not isData(p) then
				local ok, has = pcall(p.exists, path)
				if ok and has then return disk.new(p) end
				local d = disk.new(p)
				local f = d:free()
				if not best or f > free then best, free = d, f end
			end
		end
	end
	return best
end

local function deviceFor(e) return e.disk2 and update.second(e.to) or root end

-- ------------------------------------------------------------------ сеть

--- Интернет-карта: она нужна только на время обновления, в обычной работе
--- магазина её в машине может и не быть.
function update.card()
	local c = component.internet
	if not c then return nil, "нет интернет-карты - вставьте её в машину и проверьте снова" end
	local ok, on = pcall(c.isHttpEnabled)
	if ok and on == false then return nil, "интернет-карта не разрешает HTTP" end
	return c
end

--- Скачать файл репозитория; sink(chunk) получает его кусками. Возвращает
--- размер и CRC32 пришедшего или nil и причину.
local function fetch(path, sink)
	local c, why = update.card()
	if not c then return nil, why end
	local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, BRANCH, path)
	local ok, req = pcall(c.request, url, nil, { ["user-agent"] = "ShopOS" })
	if not ok or not req then return nil, "не открыть " .. path .. ": " .. tostring(req) end

	local deadline = computer.uptime() + 20
	while true do
		local done, err = req.finishConnect()
		if done then break end
		if done == nil and err then pcall(req.close) return nil, tostring(err) end
		if computer.uptime() > deadline then pcall(req.close) return nil, "сервер не отвечает" end
		computer.pullSignal(0.05)
	end
	local gotCode, code = pcall(req.response)
	if gotCode and code and code ~= 200 then
		pcall(req.close)
		return nil, "HTTP " .. tostring(code) .. " (" .. path .. ")"
	end

	local size, crc, err = 0, 0
	while true do
		local chunk, why2 = req.read(8192)
		if chunk == nil then
			err = why2
			break
		elseif #chunk == 0 then
			computer.pullSignal(0.05)
		else
			size = size + #chunk
			crc = crc32(crc, chunk)
			local wrote, werr = sink(chunk)
			if wrote == false then
				pcall(req.close)
				return nil, werr or "не пишется на диск"
			end
		end
		breathe()
	end
	pcall(req.close)
	if err then return nil, tostring(err) end
	return size, hex(crc)
end

--- Манифест с гита: что куда ложится, размеры и хэши.
function update.manifest()
	local parts = {}
	local size, why = fetch("manifest.lua", function(c) parts[#parts + 1] = c end)
	if not size then return nil, why end
	local f = load("return " .. table.concat(parts), "=manifest", "t", {})
	if not f then return nil, "manifest.lua не разбирается" end
	local ok, t = pcall(f)
	if not ok or type(t) ~= "table" or type(t.files) ~= "table" then
		return nil, "manifest.lua не того вида"
	end
	return t
end

-- ------------------------------------------------------------------ запись

--- Что лежит на диске по прошлому обновлению: путь -> CRC32.
function update.record()
	local t = root:table(RECORD)
	if type(t) ~= "table" or type(t.files) ~= "table" then return { files = {} } end
	return t
end

local function saveRecord(files)
	local keys = {}
	for k in pairs(files) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = { "-- что и какой версии лежит на диске: пишет обновление", "{", "\tfiles = {" }
	for _, k in ipairs(keys) do out[#out + 1] = ("\t\t[%q] = %q,"):format(k, files[k]) end
	out[#out + 1] = "\t},"
	out[#out + 1] = "}"
	return root:writeAll(RECORD, table.concat(out, "\n") .. "\n")
end

--- Хэш файла на диске. Считается только для мелких: мегабайты каталога
--- машина хэшировала бы полминуты, для него хватает размера.
local function hashOf(dev, path)
	local data = dev:readAll(path)
	if not data then return nil end
	breathe()
	return hex(crc32(0, data))
end

-- ------------------------------------------------------------------ сверка

--- Что изменилось. Возвращает список записей манифеста с пометкой need и
--- человеческим объяснением why.
function update.check()
	local man, why = update.manifest()
	if not man then return nil, why end
	local rec = update.record()
	local list = {}
	for _, f in ipairs(man.files) do
		local e = {
			from = f[1], to = f[2], size = f.size or 0, crc = f.crc,
			big = f.big, disk2 = f.disk == 2, keep = f.keep,
		}
		local dev = deviceFor(e)
		local have = rec.files[e.to]
		if e.keep then
			e.why = "своё, не трогаю"
		elseif not dev then
			e.need, e.why = true, "нет диска под него"
		elseif not dev:exists(e.to) then
			e.need, e.why = true, "нет на диске"
		elseif not e.crc then
			e.need, e.why = true, "в манифесте без хэша"
		elseif have == e.crc then
			e.why = "то же самое"
		elseif have then
			e.need, e.why = true, "другая версия"
		elseif e.big then
			-- записи ещё нет (ставили прежним установщиком), а мегабайты
			-- хэшировать долго: сверяем размер, а кому мало - «скачать всё»
			if dev:size(e.to) == e.size then e.why = "тот же размер" else e.need, e.why = true, "другой размер" end
		elseif hashOf(dev, e.to) == e.crc then
			e.why = "то же самое"
		else
			e.need, e.why = true, "другая версия"
		end
		list[#list + 1] = e
	end
	return list
end

--- Скачать заново вообще всё, кроме своего конфига: на случай, когда файл
--- сошёлся размером, а на деле не тот.
function update.forceAll(list)
	for _, e in ipairs(list) do
		if not e.keep then e.need, e.why = true, "качаю заново" end
	end
	return list
end

function update.pending(list)
	local n, bytes = 0, 0
	for _, e in ipairs(list or {}) do
		if e.need then n, bytes = n + 1, bytes + e.size end
	end
	return n, bytes
end

-- ------------------------------------------------------------------ загрузка

--- Скачать во временный файл рядом и проверить, что пришло целым.
local function download(dev, e, tmp)
	local dir = e.to:match("^(.*)/[^/]*$")
	if dir and dir ~= "" and not dev:exists(dir) then dev:mkdir(dir) end
	dev:remove(tmp)
	local w = dev:writer(tmp)
	if not w then return nil, "не открыть " .. tmp end
	local full
	local size, crc = fetch(e.from, function(chunk)
		if not w.put(chunk) then full = "нет места на диске" return false end
	end)
	w.close()
	if not size then
		dev:remove(tmp)
		return nil, full or crc
	end
	if e.size > 0 and size ~= e.size then
		dev:remove(tmp)
		return nil, ("%s: пришло %d Б вместо %d"):format(e.from, size, e.size)
	end
	if e.crc and crc ~= e.crc then
		dev:remove(tmp)
		return nil, e.from .. ": хэш не сошёлся, файл побился по дороге"
	end
	return true
end

--- Скачать и подменить всё помеченное. note(строка) показывает ход дела.
--- Возвращает сколько файлов положено или nil и причину.
function update.apply(list, note)
	note = note or function() end
	if not crc32 then return nil, "нет ни битовых операций, ни bit32 - хэш считать нечем" end
	local small, big = {}, {}
	for _, e in ipairs(list) do
		if e.need then
			if e.big then big[#big + 1] = e else small[#small + 1] = e end
		end
	end
	if #small + #big == 0 then return 0 end

	-- 1. мелкие - все во временные: оборвётся на последнем, и ни один из
	-- уже скачанных не подменён
	for _, e in ipairs(small) do
		e.dev = deviceFor(e)
		if not e.dev then return nil, "некуда класть " .. e.to end
		note(("качаю %s (%d Б)"):format(e.to, e.size))
		local ok, why = download(e.dev, e, e.to .. ".part")
		if not ok then
			for _, d in ipairs(small) do if d.dev then d.dev:remove(d.to .. ".part") end end
			return nil, why
		end
	end
	for _, e in ipairs(small) do
		e.dev:remove(e.to)
		if not e.dev:rename(e.to .. ".part", e.to) then return nil, "не подменить " .. e.to end
		note("положен " .. e.to)
	end

	-- 2. каталог: двух копий диск не вмещает, поэтому старая уходит раньше
	for _, e in ipairs(big) do
		local dev = deviceFor(e)
		if not dev then return nil, "некуда класть " .. e.to end
		local tmp = e.to .. ".part"
		dev:remove(tmp)
		local room = dev:free() + (dev:exists(e.to) and dev:size(e.to) or 0)
		if room < e.size + 4096 then
			return nil, ("на диске мало места под %s: нужно %d КБ, есть %d КБ")
				:format(e.to, math.ceil(e.size / 1024), math.floor(room / 1024))
		end
		if dev:free() < e.size + 4096 then
			note("стираю старый " .. e.to .. " - две копии на диск не влезут")
			dev:remove(e.to)
		end
		note(("качаю %s (%d КБ), это долго"):format(e.to, math.ceil(e.size / 1024)))
		local ok, why = download(dev, e, tmp)
		if not ok then return nil, why end
		dev:remove(e.to)
		if not dev:rename(tmp, e.to) then return nil, "не подменить " .. e.to end
		note("положен " .. e.to)
	end

	-- 3. запись о том, что теперь лежит. Файлы, сошедшиеся размером,
	-- записываются хэшем манифеста - с этого момента сверка по нему точная
	local rec = update.record()
	for _, e in ipairs(list) do
		if not e.keep and e.crc then rec.files[e.to] = e.crc end
	end
	if not saveRecord(rec.files) then
		return #small + #big, "файлы положены, но запись /var/installed.lua не сохранилась"
	end
	return #small + #big
end

return update
