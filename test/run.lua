-- Стенд ShopOS без игры: песочница OpenComputers, gpu с буферами, диск из
-- каталога shopos/, поддельные МЭ-интерфейс и PIM.
--
--   lua test/run.lua <папка-вывода> "<события>"   (или @файл-со-сценарием)
--
-- Запускать из каталога shopos/. События через запятую:
--   on:Ник            игрок встал на PIM       off     ушёл
--   touch:X:Y[:Ник]   клик                     scroll:X:Y:±1
--   type:текст        набрать на клавиатуре    key:код  нажать клавишу
--   coins:N           положить игроку N монет  shot:имя  снять кадр
--   junk:N            занять N слотов камнем   wait:сек  подождать
--   evil              подменять монеты алмазами в момент pushItem
--   ghost:Ник         на PIM другой игрок, сигналы потерялись
--   give:мод:имя:мета:N   положить игроку N штук предмета
--   old:Ник:сотые     счёт прежнего формата в /var/wallet до запуска
--   nodata            без третьего диска: данные на загрузочном
--
-- Кадры пишутся в <папка>/<имя>.json - их рисует tools/renderscreen.py.
-- /var машины ложится в <папка>/var, диск данных - в <папка>/data3, чтобы
-- не пачкать репозиторий. У PIM, как в игре, 40 слотов: 36 и 4 брони.

local OUT = arg[1] or "out"
local SCRIPT = arg[2] or ""
-- "@файл": сценарий из файла - кириллица в командной строке Windows
-- приходит не в utf-8
if SCRIPT:sub(1, 1) == "@" then SCRIPT = assert(io.open(SCRIPT:sub(2), "rb")):read("a"):gsub("%s+$", "") end
local MAXREAD = 2048
local NODATA = SCRIPT:find("nodata", 1, true) ~= nil

local function sh(cmd) return os.execute(cmd) end
local function win(p) return (p:gsub("/", "\\")) end
sh('mkdir "' .. win(OUT) .. '\\var" 2>nul')
if not NODATA then sh('mkdir "' .. win(OUT) .. '\\data3" 2>nul') end
-- счета прежнего формата - до загрузки: их должен подхватить переезд
for n, c in SCRIPT:gmatch("old:([%w_]+):(%d+)") do
	sh('mkdir "' .. win(OUT) .. '\\var\\wallet" 2>nul')
	local f = assert(io.open(OUT .. "/var/wallet/" .. n, "wb"))
	f:write(c)
	f:close()
end

-- ------------------------------------------------------------------ unicode

local unicode = {}
function unicode.char(...) return utf8.char(...) end
function unicode.len(s) return utf8.len(s) or #s end
function unicode.sub(s, i, j)
	local n = utf8.len(s)
	j = j or -1
	if i < 0 then i = n + i + 1 end
	if j < 0 then j = n + j + 1 end
	if i < 1 then i = 1 end
	if j > n then j = n end
	if i > j then return "" end
	local a = utf8.offset(s, i)
	local b = utf8.offset(s, j + 1)
	return s:sub(a, (b or #s + 1) - 1)
end
local function mapcase(s, up)
	local out = {}
	for _, c in utf8.codes(s) do
		if up then
			if c >= 0x61 and c <= 0x7A then c = c - 32
			elseif c >= 0x430 and c <= 0x44F then c = c - 32
			elseif c == 0x451 then c = 0x401 end
		else
			if c >= 0x41 and c <= 0x5A then c = c + 32
			elseif c >= 0x410 and c <= 0x42F then c = c + 32
			elseif c == 0x401 then c = 0x451 end
		end
		out[#out + 1] = utf8.char(c)
	end
	return table.concat(out)
end
function unicode.lower(s) return mapcase(s, false) end
function unicode.upper(s) return mapcase(s, true) end

-- ------------------------------------------------------------------ время и сигналы

local now = 0
local queue = {}
local stats = { set = 0, fill = 0, bitblt = 0, colour = 0, scr = 0 }

-- ------------------------------------------------------------------ gpu

local W, H = 160, 50
local function blank(w, h)
	local b = { w = w, h = h }
	for y = 1, h do
		b[y] = {}
		for x = 1, w do b[y][x] = { " ", 0xFFFFFF, 0 } end
	end
	return b
end
local bufs = { [0] = blank(W, H) }
local active, nextBuf = 0, 1
local fgc, bgc = 0xFFFFFF, 0

local gpu = { type = "gpu", address = "gpu-0" }
function gpu.bind() return true end
function gpu.getScreen() return "screen-0" end
function gpu.maxResolution() return W, H end
function gpu.getResolution() return W, H end
function gpu.setResolution() return true end
function gpu.setForeground(c) stats.colour = stats.colour + 1 fgc = c end
function gpu.setBackground(c) stats.colour = stats.colour + 1 bgc = c end
local function tick(kind)
	stats[kind] = stats[kind] + 1
	if active == 0 then stats.scr = stats.scr + 1 end
end
function gpu.set(x, y, s)
	tick("set")
	assert(utf8.len(s), "битая utf-8 строка в gpu.set")
	local b = bufs[active]
	local i = 0
	for _, c in utf8.codes(s) do
		local xx = x + i
		if b[y] and xx >= 1 and xx <= b.w then b[y][xx] = { utf8.char(c), fgc, bgc } end
		i = i + 1
	end
end
function gpu.fill(x, y, w, h, ch)
	tick("fill")
	local b = bufs[active]
	for yy = y, y + h - 1 do
		for xx = x, x + w - 1 do
			if b[yy] and xx >= 1 and xx <= b.w then b[yy][xx] = { ch, fgc, bgc } end
		end
	end
end
function gpu.allocateBuffer(w, h)
	local id = nextBuf
	nextBuf = nextBuf + 1
	bufs[id] = blank(w, h)
	return id
end
function gpu.freeBuffer(id) bufs[id] = nil return true end
function gpu.setActiveBuffer(id) active = id return true end
function gpu.getActiveBuffer() return active end
function gpu.bitblt(dst, x, y, w, h, src, fx, fy)
	stats.bitblt = stats.bitblt + 1
	if dst == 0 then stats.scr = stats.scr + 1 end
	local d, s = bufs[dst], bufs[src]
	for yy = 0, h - 1 do
		for xx = 0, w - 1 do
			local c = s[fy + yy] and s[fy + yy][fx + xx]
			if c and d[y + yy] and x + xx <= d.w then d[y + yy][x + xx] = c end
		end
	end
	return true
end

local function shot(name)
	local b = bufs[0]
	local cells = {}
	for y = 1, H do
		for x = 1, W do
			local c = b[y][x]
			cells[#cells + 1] = ('[%q,%d,%d]'):format(c[1], c[2], c[3])
		end
	end
	local f = assert(io.open(OUT .. "/" .. name .. ".json", "wb"))
	f:write(('{"w":%d,"h":%d,"stats":{"set":%d,"bitblt":%d,"scr":%d},"cells":[%s]}')
		:format(W, H, stats.set, stats.bitblt, stats.scr, table.concat(cells, ",")))
	f:close()
	print(("кадр %-10s  set=%d fill=%d bitblt=%d  вызовов на экран=%d")
		:format(name, stats.set, stats.fill, stats.bitblt, stats.scr))
	for k in pairs(stats) do stats[k] = 0 end
end

-- ------------------------------------------------------------------ диск

local function mkfs(addr, real)
	local fs = { type = "filesystem", address = addr }
	local handles, nextH = {}, 1
	function fs.exists(p)
		local f = io.open(real(p), "rb")
		if f then f:close() return true end
		return os.rename(real(p), real(p)) and true or false
	end
	function fs.size(p)
		local f = io.open(real(p), "rb")
		if not f then return 0 end
		local n = f:seek("end")
		f:close()
		return n
	end
	function fs.makeDirectory(p) sh('mkdir "' .. win(real(p)) .. '" 2>nul') return true end
	function fs.remove(p) return os.remove(real(p)) and true or false end
	function fs.rename(a, b) return os.rename(real(a), real(b)) and true or false end
	function fs.list(p)
		local out = {}
		for _, kind in ipairs({ "/ad", "/a-d" }) do
			local h = io.popen('dir /b ' .. kind .. ' "' .. win(real(p)) .. '" 2>nul')
			for l in h:lines() do out[#out + 1] = kind == "/ad" and l .. "/" or l end
			h:close()
		end
		return out
	end
	function fs.lastModified() return os.time() * 1000 end
	function fs.spaceTotal() return 4096 * 1024 end
	function fs.spaceUsed() return 0 end
	function fs.isReadOnly() return false end
	function fs.open(p, mode)
		local m = ({ r = "rb", w = "wb", a = "ab" })[mode or "r"]
		local f = io.open(real(p), m)
		if not f then return nil, p end
		local h = nextH
		nextH = nextH + 1
		handles[h] = { f = f, path = p }
		return h
	end
	function fs.read(h, n)
		local s = handles[h].f:read(math.min(n, MAXREAD))
		return s
	end
	function fs.seek(h, whence, off) return handles[h].f:seek(whence, off) end
	function fs.write(h, s)
		if handles[h].path:find("crash") then io.stderr:write("\n!!! ПАДЕНИЕ:\n" .. s .. "\n") end
		handles[h].f:write(s)
		return true
	end
	function fs.close(h) handles[h].f:close() handles[h] = nil end
	return fs
end

-- загрузочный: сам каталог shopos/, только /var - в папку вывода
local fs = mkfs("disk-0", function(path)
	path = path:gsub("^/+", "")
	if path == "var" or path:match("^var/") then return OUT .. "/" .. path end
	return path == "" and "." or path
end)
-- диск данных: пустой жёсткий диск, вся его ФС - в <папка>/data3
local data3 = not NODATA and mkfs("disk-3", function(path)
	return OUT .. "/data3/" .. path:gsub("^/+", "")
end)

-- ------------------------------------------------------------------ МЭ и PIM

local function readCatalogKeys(every)
	local d = assert(io.open("data/catalog.bin", "rb")):read("a")
	local function u32(i) return string.unpack(">I4", d, i) end
	local count, recOff, iconOff = u32(9), u32(21), u32(25)
	local keys, pos, n = {}, recOff + 1, 0
	while pos < iconOff + 1 do
		local kl = d:byte(pos)
		local key = d:sub(pos + 1, pos + kl)
		local ll = d:byte(pos + 1 + kl)
		pos = pos + 1 + kl + 1 + ll + 11
		n = n + 1
		if n % every == 0 then keys[#keys + 1] = key end
	end
	return keys, count
end

local net = {}
local function addNet(id, dmg, size, nbt)
	net[#net + 1] = { fingerprint = { id = id, dmg = dmg, nbt_hash = nbt }, size = size }
end
addNet("IC2:itemIngot", 0, 500)
addNet("IC2:itemIngot", 1, 320)
addNet("IC2:itemIngot", 3, 64)
addNet("minecraft:diamond", 0, 40)
addNet("minecraft:dirt", 0, 5000)
addNet("AdvancedSolarPanel:BlockAdvSolarPanel", 4, 2)
addNet("customnpcs:npcMoney", 0, 1000)
addNet("nobody:unknownThing", 0, 10)
addNet("minecraft:enchanted_book", 0, 3, "abc123")
-- броня и инструменты Draconic лежат в МЭ только с NBT (энергия, настройки)
addNet("DraconicEvolution:draconicChest", 0, 1, "e1f00d")
addNet("DraconicEvolution:wyvernPickaxe", 0, 2, "77aa01")
addNet("DraconicEvolution:wyvernPickaxe", 0, 1, "77aa02")
-- IC2: заряд и в мете (полоска 1..26), и в NBT; инструмент с износом в мете
addNet("IC2:itemArmorNanoChestplate", 12, 1, "c12")
addNet("IC2:itemArmorNanoChestplate", 3, 1, "c03")
addNet("IC2:itemArmorNanoChestplate", 26, 2, "c26")
addNet("IC2:itemBatCrystal", 1, 3, "b01")
addNet("minecraft:diamond_pickaxe", 700, 1)
-- крайние меты: у выгрузки на них свои записи (кванты :27 - разряжен,
-- кирка :1561 - сломана), товар всё равно один с остальными
addNet("IC2:itemArmorQuantumChestplate", 1, 2, "q01")
addNet("IC2:itemArmorQuantumChestplate", 27, 2, "q27")
addNet("minecraft:diamond_pickaxe", 1561, 1)
-- за ресурсы не продаётся - только за деньги
addNet("IC2:itemOreIridium", 0, 5)
for _, key in ipairs((readCatalogKeys(40))) do
	local id, dmg = key:match("^(.+):(%d+)$")
	if not id or not id:find(":") then id, dmg = key, 0 end
	addNet(id, tonumber(dmg), math.random(1, 300))
end

local player
local evil = false         -- игрок подменяет стак монет между проверкой и pushItem
local inv = {}             -- слот -> { id, dmg, qty }
local SLOTS = 40          -- 36 инвентаря и 4 брони, как у PIM в игре

local function slotData(s)
	return s and { id = s.id, dmg = s.dmg, qty = s.qty, name = s.id, max_size = 64 } or nil
end

local me = { type = "me_interface", address = "me-0" }
function me.getAvailableItems()
	local out = {}
	for i, it in ipairs(net) do
		if it.size > 0 then out[#out + 1] = { fingerprint = it.fingerprint, size = it.size } end
	end
	return out
end
function me.exportItem(fp, side, n, into)
	assert(side == "UP", "выдача не в ту сторону: " .. tostring(side))
	-- как в игре: без номера слота МЭ кладёт куда влезет, и в броню тоже
	local lo, hi = 1, SLOTS
	if into then lo, hi = into, into end
	for _, it in ipairs(net) do
		local f = it.fingerprint
		if f.id == fp.id and f.dmg == fp.dmg and f.nbt_hash == fp.nbt_hash and it.size > 0 then
			local want = math.min(n, it.size, 64)
			-- докладываем в неполные стопки, потом в пустые слоты
			local moved = 0
			for s = lo, hi do
				local st = inv[s]
				if st and st.id == f.id and st.dmg == f.dmg and st.qty < 64 then
					local k = math.min(64 - st.qty, want - moved)
					st.qty = st.qty + k
					moved = moved + k
				end
				if moved >= want then break end
			end
			for s = lo, hi do
				if moved >= want then break end
				if not inv[s] then
					local k = math.min(64, want - moved)
					inv[s] = { id = f.id, dmg = f.dmg, qty = k }
					moved = moved + k
				end
			end
			it.size = it.size - moved
			return { size = moved }
		end
	end
	return { size = 0 }
end

local pim = { type = "pim", address = "pim-0" }
function pim.getInventoryName() return player or "pim" end
function pim.getAllStacks(proxy)
	assert(proxy == false, "getAllStacks без false")
	local out = {}
	for s = 1, SLOTS do out[s] = slotData(inv[s]) end
	return out
end
function pim.getStackInSlot(s) return slotData(inv[s]) end
function pim.pushItem(dir, s, n)
	assert(dir == "DOWN", "приём не в ту сторону: " .. tostring(dir))
	local st = inv[s]
	if not st then return 0 end
	-- обман: в миг приёма в слоте уже алмазы - вместо монет или ресурса
	if evil and st.id ~= "minecraft:diamond" then
		st = { id = "minecraft:diamond", dmg = 0, qty = st.qty }
		inv[s] = st
	end
	local k = math.min(n, st.qty)
	st.qty = st.qty - k
	if st.qty == 0 then inv[s] = nil end
	local found
	for _, it in ipairs(net) do
		local f = it.fingerprint
		if f.id == st.id and f.dmg == st.dmg and not f.nbt_hash then found = it end
	end
	if found then found.size = found.size + k else addNet(st.id, st.dmg, k) end
	return k
end

-- ------------------------------------------------------------------ машина

local comps = { ["gpu-0"] = gpu, ["screen-0"] = { type = "screen" }, ["disk-0"] = fs,
                ["me-0"] = me, ["pim-0"] = pim }
if data3 then comps["disk-3"] = data3 end

local component = {}
function component.list(kind)
	local keys = {}
	for a, c in pairs(comps) do if not kind or c.type == kind then keys[#keys + 1] = a end end
	local i = 0
	return function() i = i + 1 return keys[i] end
end
function component.proxy(a) return comps[a] end
function component.invoke(a, m, ...) return comps[a][m](...) end

local function report()
	local st, armor = {}, {}
	for s = 1, SLOTS do
		if inv[s] then
			local t = s > 36 and armor or st
			t[#t + 1] = inv[s].id .. ":" .. inv[s].dmg .. "x" .. inv[s].qty
		end
	end
	print("инвентарь: " .. (#st > 0 and table.concat(st, "  ") or "пусто"))
	if #armor > 0 then print("СЛОТЫ БРОНИ: " .. table.concat(armor, "  ")) end
	for _, n in ipairs({ "Steve", "Alex", "Fatic" }) do
		local f = io.open((NODATA and OUT .. "/var/wallet/" or OUT .. "/data3/wallet/") .. n, "rb")
		if f then
			print(("счёт %s: %s (сотых: деньги ресурсы)"):format(n, f:read("a")))
			f:close()
		end
	end
end

local computer = {}
function computer.uptime() return now end
function computer.freeMemory() return 512 * 1024 end
function computer.totalMemory() return 1024 * 1024 end
function computer.getBootAddress() return "disk-0" end
function computer.tmpAddress() return "tmp-0" end
function computer.pushSignal(...) table.insert(queue, 1, table.pack(...)) end
function computer.pullSignal(timeout)
	now = now + 0.05
	local ev = table.remove(queue, 1)
	if not ev then
		report()
		os.exit(0)
	end
	if ev.wait then
		now = now + ev.wait
		return nil
	end
	if ev.shot then
		shot(ev.shot)
		return nil
	end
	if ev.fn then ev.fn() return nil end
	return table.unpack(ev, 1, ev.n)
end

local cur = "Steve"        -- кто сейчас на PIM: от него клики и клавиши
for part in SCRIPT:gmatch("[^,]+") do
	local a = {}
	for x in part:gmatch("[^:]+") do a[#a + 1] = x end
	local k = a[1]
	if k == "on" then
		cur = a[2]
		queue[#queue + 1] = { fn = function() player = a[2] end }
		queue[#queue + 1] = table.pack("player_on", a[2])
	elseif k == "off" then
		queue[#queue + 1] = { fn = function() player = nil end }
		queue[#queue + 1] = table.pack("player_off", "pim-0")
	elseif k == "touch" then
		queue[#queue + 1] = table.pack("touch", "screen-0", tonumber(a[2]), tonumber(a[3]), 0, a[4] or cur)
	elseif k == "scroll" then
		queue[#queue + 1] = table.pack("scroll", "screen-0", tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), cur)
	elseif k == "type" then
		for _, c in utf8.codes(a[2]) do queue[#queue + 1] = table.pack("key_down", "kb-0", c, 0, cur) end
	elseif k == "key" then
		queue[#queue + 1] = table.pack("key_down", "kb-0", 0, tonumber(a[2]), cur)
	elseif k == "coins" then
		queue[#queue + 1] = { fn = function()
			local left = tonumber(a[2])
			for s = 1, 36 do
				if left <= 0 then break end
				if not inv[s] then
					inv[s] = { id = "customnpcs:npcMoney", dmg = 0, qty = math.min(64, left) }
					left = left - inv[s].qty
				end
			end
		end }
	elseif k == "give" then
		-- give:мод:имя:мета:N - в свободные слоты инвентаря стопками по 64
		queue[#queue + 1] = { fn = function()
			local id, dmg, left = a[2] .. ":" .. a[3], tonumber(a[4]), tonumber(a[5])
			for s = 1, 36 do
				if left <= 0 then break end
				if not inv[s] then
					inv[s] = { id = id, dmg = dmg, qty = math.min(64, left) }
					left = left - inv[s].qty
				end
			end
		end }
	elseif k == "evil" then
		queue[#queue + 1] = { fn = function() evil = true end }
	elseif k == "ghost" then
		-- на PIM уже другой, а player_off/player_on потерялись
		queue[#queue + 1] = { fn = function() player = a[2] end }
	elseif k == "junk" then
		-- занять N слотов чем попало: проверка выдачи в тесный инвентарь
		queue[#queue + 1] = { fn = function()
			local left = tonumber(a[2])
			for s = 1, 36 do
				if left <= 0 then break end
				if not inv[s] then inv[s] = { id = "minecraft:stone", dmg = 0, qty = 64 } left = left - 1 end
			end
		end }
	elseif k == "shot" then
		queue[#queue + 1] = { shot = a[2] }
	elseif k == "wait" then
		queue[#queue + 1] = { wait = tonumber(a[2]) }
	end
end

-- песочница: ровно то, что даёт машина OpenComputers, и ничего сверх
local env = {
	_VERSION = "Lua 5.3", assert = assert, error = error, getmetatable = getmetatable,
	ipairs = ipairs, load = load, next = next, pairs = pairs, pcall = pcall,
	rawequal = rawequal, rawget = rawget, rawlen = rawlen, rawset = rawset,
	select = select, setmetatable = setmetatable, tonumber = tonumber,
	tostring = tostring, type = type, xpcall = xpcall,
	coroutine = coroutine, string = string, table = table, math = math,
	os = { clock = os.clock, date = os.date, difftime = os.difftime, time = os.time },
	debug = { traceback = debug.traceback, getinfo = debug.getinfo },
	checkArg = function() end,
	component = component, computer = computer, unicode = unicode,
}
env._G = env

local src = assert(io.open("init.lua", "rb")):read("a")
local boot = assert(load(src, "=init.lua", "t", env))
boot()
