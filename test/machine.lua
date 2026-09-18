-- Машина OpenComputers без OpenOS: песочница, BIOS и поддельные компоненты.
--
--   lua shopos/test/machine.lua <выход.json> "<события>" [видеопамять]
--
-- Это не эмулятор мода, а проверка того, что ShopOS поднимается на голой
-- песочнице. Смысл в том, чего тут НЕТ: окружение собирается ровно по списку
-- из machine.lua самого OpenComputers, поэтому любое обращение к io, require,
-- filesystem, print или package мимо ядра падает прямо здесь, а не в игре.
--
-- Чего нарочно нет сверх песочницы:
--   * utf8 - в Lua 5.2 его не бывает, а архитектура машины может быть любой;
--   * dofile, loadfile - в машине они сразу ошибка, пока их не заменит ОС;
--   * io, require, package - их обязано выдать ядро ShopOS, а не хозяин.
--
-- Файловая система - настоящий каталог shopos/ на диске ПК, смонтированный
-- как корень. Чтение режется до 2048 байт за вызов, как maxReadBuffer в
-- конфиге сборки: код, который считает, что read отдаёт сколько попросили,
-- сломается здесь, а не на игровом сервере.

local OUT     = arg[1] or "machine.json"
local EVENTS  = arg[2]
local VRAM    = tonumber(arg[3]) or 24000
local DISK    = arg[4] or "shopos"

local MAXREAD = 2048

--------------------------------------------------------------- экран

local scr = { w = 160, h = 50, cells = {} }
local function clearCells()
	scr.cells = {}
	for y = 1, scr.h do
		scr.cells[y] = {}
		for x = 1, scr.w do scr.cells[y][x] = { " ", 0xFFFFFF, 0x000000 } end
	end
end
clearCells()

local stats = { set = 0, fill = 0, copy = 0, bitblt = 0, color = 0,
                alloc = 0, free = 0, scr = 0, buf = 0 }
local buffers = { [0] = scr }
local active, nextId, vramFree = 0, 1, VRAM

local function target() return buffers[active] end
local function count(kind)
	stats[kind] = stats[kind] + 1
	if active == 0 then stats.scr = stats.scr + 1 else stats.buf = stats.buf + 1 end
end
local function chars(s)
	local t = {}
	if not utf8.len(s) then error("битая utf-8 строка от gpu.set", 2) end
	for _, c in utf8.codes(s) do t[#t + 1] = utf8.char(c) end
	return t
end

local fg, bg = 0xFFFFFF, 0x000000
local gpu = { type = "gpu" }
local SCREEN = "screen-0000"

function gpu.getScreen() return gpu.bound end
function gpu.bind(a) gpu.bound = a return true end
function gpu.getResolution() return scr.w, scr.h end
function gpu.maxResolution() return 160, 50 end
function gpu.setResolution(w, h) scr.w, scr.h = w, h clearCells() end
function gpu.setForeground(c) count("color") fg = c end
function gpu.setBackground(c) count("color") bg = c end
function gpu.getForeground() return fg end
function gpu.getBackground() return bg end

function gpu.set(x, y, s)
	count("set")
	local t, cs = target(), chars(s)
	for i = 1, #cs do
		local xx = x + i - 1
		if t.cells[y] and xx >= 1 and xx <= t.w then t.cells[y][xx] = { cs[i], fg, bg } end
	end
end

function gpu.fill(x, y, w, h, ch)
	count("fill")
	local t = target()
	for yy = y, y + h - 1 do
		for xx = x, x + w - 1 do
			if t.cells[yy] and xx >= 1 and xx <= t.w then t.cells[yy][xx] = { ch, fg, bg } end
		end
	end
end

function gpu.copy(x, y, w, h, tx, ty)
	count("copy")
	local t, tmp = target(), {}
	for yy = 0, h - 1 do
		tmp[yy] = {}
		for xx = 0, w - 1 do
			local row = t.cells[y + yy]
			tmp[yy][xx] = row and row[x + xx] or nil
		end
	end
	for yy = 0, h - 1 do
		for xx = 0, w - 1 do
			local c = tmp[yy][xx]
			local row = t.cells[y + yy + ty]
			local dx = x + xx + tx
			if c and row and dx >= 1 and dx <= t.w then row[dx] = { c[1], c[2], c[3] } end
		end
	end
end

function gpu.totalMemory() return VRAM end
function gpu.freeMemory() return vramFree end

function gpu.allocateBuffer(w, h)
	if w * h > vramFree then error("not enough video memory") end
	stats.alloc = stats.alloc + 1
	vramFree = vramFree - w * h
	local b = { w = w, h = h, cells = {} }
	for y = 1, h do
		b.cells[y] = {}
		for x = 1, w do b.cells[y][x] = { " ", 0xFFFFFF, 0x000000 } end
	end
	local id = nextId
	buffers[id] = b
	nextId = nextId + 1
	return id
end

function gpu.freeBuffer(i)
	local b = buffers[i]
	if not b or i == 0 then return false end
	stats.free = stats.free + 1
	vramFree = vramFree + b.w * b.h
	buffers[i] = nil
	if active == i then active = 0 end
	return true
end

function gpu.bitblt(dst, col, row, w, h, src, fc, fr)
	stats.bitblt = stats.bitblt + 1
	if (dst or 0) == 0 then stats.scr = stats.scr + 1 else stats.buf = stats.buf + 1 end
	local d, s = buffers[dst or 0], buffers[src or 0]
	if not d or not s then return false end
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local sc = s.cells[(fr or 1) + y]
			if sc and sc[(fc or 1) + x] and d.cells[row + y] then
				local c = sc[(fc or 1) + x]
				d.cells[row + y][col + x] = { c[1], c[2], c[3] }
			end
		end
	end
	return true
end

function gpu.getActiveBuffer() return active end
function gpu.setActiveBuffer(i) active = i return true end

--------------------------------------------------------------- файловая система

-- Настоящий каталог ПК, смонтированный как корень диска. Пути внутри
-- начинаются с косой черты и к нему приклеиваются.
local disk = { type = "filesystem", handles = {}, nextH = 1 }

local function real(path)
	path = tostring(path or "/"):gsub("^/+", "")
	return DISK .. "/" .. path
end

local function shell(cmd)
	local h = io.popen(cmd .. " 2>nul")
	if not h then return "" end
	local out = h:read("a") or ""
	h:close()
	return out
end

function disk.exists(path)
	local f = io.open(real(path), "rb")
	if f then f:close() return true end
	-- каталог: открыть нельзя, но список получить можно
	return shell('if exist "' .. real(path):gsub("/", "\\") .. '" echo yes'):find("yes") ~= nil
end

function disk.isDirectory(path)
	local f = io.open(real(path), "rb")
	if f then
		local ok = f:read(0)
		f:close()
		if ok ~= nil then return false end
	end
	return disk.exists(path)
end

function disk.size(path)
	local f = io.open(real(path), "rb")
	if not f then return 0 end
	local n = f:seek("end")
	f:close()
	return n
end

function disk.list(path)
	local dir = real(path):gsub("/", "\\")
	local out = {}
	for line in shell('dir /b "' .. dir .. '"'):gmatch("[^\r\n]+") do out[#out + 1] = line end
	return out
end

function disk.makeDirectory(path)
	shell('mkdir "' .. real(path):gsub("/", "\\") .. '"')
	return true
end

function disk.remove(path)
	os.remove(real(path))
	return true
end

function disk.rename(a, b)
	os.remove(real(b))
	return os.rename(real(a), real(b)) and true or false
end

function disk.spaceUsed() return 400 * 1024 end
function disk.spaceTotal() return 4096 * 1024 end
function disk.isReadOnly() return false end
function disk.getLabel() return "shopos" end
function disk.setLabel(l) return l end

function disk.open(path, mode)
	mode = (mode or "r"):gsub("b", "")
	local f = io.open(real(path), mode == "r" and "rb" or (mode == "a" and "ab" or "wb"))
	if not f then return nil, "file not found" end
	local id = disk.nextH
	disk.nextH = id + 1
	disk.handles[id] = f
	return id
end

--- Ровно как в моде: за раз отдаётся не больше maxReadBuffer байт, сколько
--- бы ни попросили. Код, который этого не учитывает, обрывается здесь.
function disk.read(h, n)
	local f = disk.handles[h]
	if not f then return nil, "bad file descriptor" end
	if n > MAXREAD then n = MAXREAD end
	local s = f:read(n)
	if not s or #s == 0 then return nil end
	return s
end

function disk.write(h, data)
	local f = disk.handles[h]
	if not f then return nil, "bad file descriptor" end
	f:write(data)
	return true
end

function disk.seek(h, whence, off)
	local f = disk.handles[h]
	if not f then return nil, "bad file descriptor" end
	return f:seek(whence or "set", off or 0)
end

function disk.close(h)
	local f = disk.handles[h]
	if f then f:close() disk.handles[h] = nil end
	return true
end

--------------------------------------------------------------- мир магазина

local SLOTS = 40
local net, inv = {}, {}
local function nkey(id, dmg, nbt) return id .. "/" .. (dmg or 0) .. "/" .. (nbt or "") end
local function netAdd(id, dmg, size, nbt)
	local k = nkey(id, dmg, nbt)
	local e = net[k]
	if e then e.size = e.size + size
	else net[k] = { id = id, dmg = dmg or 0, nbt = nbt, size = size } end
end
local function invPut(id, dmg, n, nbt)
	while n > 0 do
		local put = math.min(64, n)
		local slot
		for i = 1, SLOTS do if not inv[i] then slot = i break end end
		if not slot then return end
		inv[slot] = { id = id, dmg = dmg or 0, count = put, nbt_hash = nbt }
		n = n - put
	end
end

local me = {
	type = "me_interface",
	getAvailableItems = function()
		local out = {}
		for _, e in pairs(net) do
			out[#out + 1] = { size = e.size,
				fingerprint = { id = e.id, dmg = e.dmg, nbt_hash = e.nbt } }
		end
		return out
	end,
	exportItem = function(fp, _, n)
		local e = net[nkey(fp.id, fp.dmg, fp.nbt_hash)]
		if not e or e.size <= 0 then return { size = 0 } end
		local moved = math.min(n, e.size)
		e.size = e.size - moved
		invPut(fp.id, fp.dmg, moved, fp.nbt_hash)
		return { size = moved }
	end,
}

local pim = {
	type = "pim",
	getStackInSlot = function(i)
		local s = inv[i]
		if not s then return nil end
		return { id = s.id, dmg = s.dmg, count = s.count, nbt_hash = s.nbt_hash }
	end,
	getAllStacks = function()
		local out = {}
		for i = 1, SLOTS do
			local s = inv[i]
			if s then
				out[i] = { all = function() return { id = s.id, dmg = s.dmg, qty = s.count } end }
			end
		end
		return out
	end,
	pushItem = function(_, slot, n)
		local s = inv[slot]
		if not s then return 0 end
		local moved = math.min(n, s.count)
		s.count = s.count - moved
		if s.count <= 0 then inv[slot] = nil end
		netAdd(s.id, s.dmg, moved, s.nbt_hash)
		return moved
	end,
}

local dbc = {
	type = "database",
	get = function(i)
		local c = { { name = "coin", damage = 0 }, { name = "coin", damage = 1 },
		            { name = "coin", damage = 2 }, { name = "coin", damage = 3 } }
		return c[i]
	end,
}

--------------------------------------------------------------- компоненты

local devices = {
	["gpu-0000000000000000000000000000000"] = gpu,
	[SCREEN] = { type = "screen" },
	["fs-00000000000000000000000000000000"] = disk,
	["me-00000000000000000000000000000000"] = me,
	["pim-0000000000000000000000000000000"] = pim,
	["db-00000000000000000000000000000000"] = dbc,
}
local BOOTFS = "fs-00000000000000000000000000000000"

local libcomponent = {
	list = function(filter, exact)
		local keys = {}
		for a, d in pairs(devices) do
			if not filter or (exact and d.type == filter) or (not exact and d.type:find(filter, 1, true)) then
				keys[#keys + 1] = a
			end
		end
		table.sort(keys)
		local i = 0
		return setmetatable({}, { __call = function()
			i = i + 1
			if keys[i] then return keys[i], devices[keys[i]].type end
		end, __pairs = function(t)
			local j = 0
			return function()
				j = j + 1
				if keys[j] then return keys[j], devices[keys[j]].type end
			end, t, nil
		end })
	end,
	invoke = function(address, method, ...)
		local d = devices[address]
		if not d then error("no such component", 2) end
		return d[method](...)
	end,
	proxy = function(address)
		local d = devices[address]
		if not d then return nil, "no such component" end
		local p = { address = address, type = d.type }
		for k, v in pairs(d) do if type(v) == "function" then p[k] = v end end
		return p
	end,
	type = function(address) return devices[address] and devices[address].type end,
	slot = function() return -1 end,
	methods = function() return {} end,
	fields = function() return {} end,
	doc = function() return "" end,
}

local clock = 0
local bootAddress = BOOTFS

local libcomputer = {
	address = function() return "computer-000" end,
	tmpAddress = function() return nil end,
	freeMemory = function() return 1024 * 1024 end,
	totalMemory = function() return 2048 * 1024 end,
	uptime = function() clock = clock + 0.005 return clock end,
	energy = function() return 5000 end,
	maxEnergy = function() return 5000 end,
	getBootAddress = function() return bootAddress end,
	setBootAddress = function(a) bootAddress = a return true end,
	users = function() return end,
	addUser = function() return true end,
	removeUser = function() return true end,
	shutdown = function() error("computer.shutdown вызван", 0) end,
	beep = function() end,
	isRobot = function() return false end,
	getDeviceInfo = function() return {} end,
	getProgramLocations = function() return {} end,
	getArchitectures = function() return { "Lua 5.3" } end,
	getArchitecture = function() return "Lua 5.3" end,
	setArchitecture = function() end,
}

local libunicode = {
	char = function(...) return utf8.char(...) end,
	len = function(s) return utf8.len(s) or #s end,
	lower = function(s) return s:lower() end,
	upper = function(s) return s:upper() end,
	reverse = function(s) return s:reverse() end,
	sub = function(s, i, j)
		local n = utf8.len(s) or #s
		if i < 0 then i = n + i + 1 end
		if j == nil then j = n elseif j < 0 then j = n + j + 1 end
		if i < 1 then i = 1 end
		if j > n then j = n end
		if i > j then return "" end
		local a = utf8.offset(s, i)
		local b = (j < n) and (utf8.offset(s, j + 1) - 1) or #s
		return s:sub(a, b)
	end,
	isWide = function() return false end,
	charWidth = function() return 1 end,
	wlen = function(s) return utf8.len(s) or #s end,
	wtrunc = function(s) return s end,
}

--------------------------------------------------------------- события

local queue, shots = {}, {}
if EVENTS then
	for part in EVENTS:gmatch("[^,]+") do
		local f = {}
		for pcs in part:gmatch("[^:]+") do f[#f + 1] = pcs end
		local kind = f[1]
		if kind == "scroll" then queue[#queue + 1] = { "scroll", SCREEN, 1, 1, tonumber(f[2]) }
		elseif kind == "touch" then queue[#queue + 1] = { "touch", SCREEN, tonumber(f[2]), tonumber(f[3]), 0 }
		elseif kind == "drag" then queue[#queue + 1] = { "drag", SCREEN, tonumber(f[2]), tonumber(f[3]), 0 }
		elseif kind == "key" then queue[#queue + 1] = { "key_down", SCREEN, tonumber(f[2]), tonumber(f[3] or 0) }
		elseif kind == "on" then queue[#queue + 1] = { "player_on", SCREEN, f[2] }
		elseif kind == "off" then queue[#queue + 1] = { "player_off", SCREEN }
		elseif kind == "shot" then queue[#queue + 1] = { "__shot", f[2] }
		end
	end
end

local function snap()
	local c = {}
	for y = 1, scr.h do
		c[y] = {}
		for x = 1, scr.w do
			local s = scr.cells[y][x]
			c[y][x] = { s[1], s[2], s[3] }
		end
	end
	return { w = scr.w, h = scr.h, cells = c }
end

local function dump(shot, path)
	local out = assert(io.open(path, "wb"))
	out:write(string.format('{"w":%d,"h":%d,"stats":{"set":%d,"fill":%d,"copy":%d,'
		.. '"bitblt":%d,"color":%d,"alloc":%d,"free":%d,"screen":%d,"buffer":%d},"cells":[',
		shot.w, shot.h, stats.set, stats.fill, stats.copy, stats.bitblt,
		stats.color, stats.alloc, stats.free, stats.scr, stats.buf))
	local first = true
	for y = 1, shot.h do
		for x = 1, shot.w do
			local c = shot.cells[y][x]
			if not first then out:write(",") end
			first = false
			local ch = c[1]
			if ch == '"' then ch = '\\"' elseif ch == "\\" then ch = "\\\\" end
			-- управляющие символы в json нельзя класть как есть: из сообщения
			-- об ошибке в ячейку может попасть перевод строки или табуляция
			if #ch == 1 and ch:byte() < 32 then ch = "?" end
			out:write(string.format('["%s",%d,%d]', ch, c[2], c[3]))
		end
	end
	out:write("]}")
	out:close()
end

local base = OUT:gsub("%.json$", "")
local qi, log = 0, {}
local finish
local prev = { scr = 0, buf = 0, bitblt = 0, copy = 0 }
local lastWas = "загрузка"

libcomputer.pullSignal = function()
	do
		local d = stats.scr - prev.scr
		log[#log + 1] = string.format("%-20s экран +%-5d буферы +%-6d bitblt +%-4d copy +%d",
			lastWas, d, stats.buf - prev.buf, stats.bitblt - prev.bitblt, stats.copy - prev.copy)
		prev.scr, prev.buf = stats.scr, stats.buf
		prev.bitblt, prev.copy = stats.bitblt, stats.copy
	end
	while true do
		qi = qi + 1
		local e = queue[qi]
		if not e then finish() end
		if e[1] == "__shot" then
			local path = base .. "-" .. (e[2] or tostring(qi)) .. ".json"
			dump(snap(), path)
			shots[#shots + 1] = path
		else
			lastWas = string.format("%d %s", qi, e[1])
			return table.unpack(e)
		end
	end
end
libcomputer.pushSignal = function(...) queue[#queue + 1] = { ... } return true end

--------------------------------------------------------------- песочница

-- Ровно то, что перечислено в machine.lua мода, и ничего сверх. utf8 не
-- выдаём нарочно: в Lua 5.2 его нет, а код обязан работать на обеих версиях.
local env
env = {
	assert = assert, error = error, getmetatable = getmetatable, ipairs = ipairs,
	next = next, pairs = pairs, pcall = pcall, rawequal = rawequal, rawget = rawget,
	rawlen = rawlen, rawset = rawset, select = select, setmetatable = setmetatable,
	tonumber = tonumber, tostring = tostring, type = type, xpcall = xpcall,
	_VERSION = _VERSION,
	load = function(chunk, name, mode, e) return load(chunk, name, mode or "bt", e or env) end,
	dofile = function() error("dofile недоступен в машине", 2) end,
	loadfile = function() error("loadfile недоступен в машине", 2) end,
	print = function() end,
	checkArg = function(n, have, ...)
		have = type(have)
		for i = 1, select("#", ...) do
			if have == select(i, ...) then return end
		end
		error(("bad argument #%d (%s expected, got %s)"):format(n, table.concat({ ... }, " or "), have), 3)
	end,
	coroutine = coroutine,
	string = string,
	table = table,
	math = math,
	os = { clock = os.clock, date = os.date, time = os.time,
	       difftime = function(a, b) return a - b end },
	debug = { traceback = debug.traceback, getinfo = debug.getinfo },
	component = libcomponent,
	computer = libcomputer,
	unicode = libunicode,
}
env._G = env

--------------------------------------------------------------- наполнение мира

do
	local f = io.open(DISK .. "/cfg/sellShop.cfg", "rb")
	if f then
		local text = f:read("a")
		f:close()
		local items = load("return " .. text)()
		local seed = 7
		for _, it in ipairs(items) do
			seed = (seed * 1103515245 + 12345) % 2147483648
			local n = seed % 900
			if n > 0 then netAdd(it.id, it.dmg, n, it.nbt) end
		end
	end
	netAdd("coin", 0, 500) netAdd("coin", 1, 500)
	netAdd("coin", 2, 500) netAdd("coin", 3, 500)
	invPut("minecraft:iron_ore", 0, 64)
	invPut("IC2:blockOreTin", 0, 32)
	invPut("minecraft:iron_ingot", 0, 48)
	invPut("coin", 0, 12)
end

--------------------------------------------------------------- BIOS

-- Ровно то, что делает штатный EEPROM: привязать экран, прочитать /init.lua
-- с загрузочного диска и выполнить. Ни строчкой больше.
local function bios()
	local screen = libcomponent.list("screen")()
	local g = libcomponent.list("gpu")()
	if g and screen then libcomponent.invoke(g, "bind", screen) end

	local h = assert(libcomponent.invoke(bootAddress, "open", "/init.lua"))
	local buffer = ""
	while true do
		local data = libcomponent.invoke(bootAddress, "read", h, math.huge)
		if not data then break end
		buffer = buffer .. data
	end
	libcomponent.invoke(bootAddress, "close", h)
	local init = assert(load(buffer, "=init", "bt", env))
	return init()
end

--- Конец прогона: выгрузить экран, напечатать счётчики и выйти. Зовётся из
--- pullSignal, когда события кончились, - магазин остановиться сам не умеет
--- и не должен.
function finish(code)
	dump(snap(), OUT)
	for _, l in ipairs(log) do io.write("  " .. l .. "\n") end
	io.write(string.format("экран %dx%d   вызовов gpu: экран=%d буферы=%d   "
		.. "set=%d fill=%d copy=%d bitblt=%d цвет=%d\n",
		scr.w, scr.h, stats.scr, stats.buf, stats.set, stats.fill,
		stats.copy, stats.bitblt, stats.color))
	io.write(string.format("буферов выделено=%d освобождено=%d  видеопамять %d/%d\n",
		stats.alloc, stats.free, vramFree, VRAM))
	for _, sh in ipairs(shots) do io.write("кадр: " .. sh .. "\n") end
	os.exit(code or 0)
end

local ok, err = pcall(bios)
if not ok then
	io.stderr:write("МАШИНА ОСТАНОВИЛАСЬ: " .. tostring(err) .. "\n")
	finish(1)
end
finish(0)
