-- ShopOS - операционная система из одной программы.
--
-- Это /init.lua: то, что штатный BIOS из EEPROM находит на диске, читает
-- целиком и вызывает. Дальше OpenOS обычно поднимает процессы, потоки,
-- терминал, оболочку и разбор командной строки. Тут ничего этого нет и быть
-- не должно: на машине живёт магазин, и выйти из него некуда.
--
-- Что даёт песочница OpenComputers сама: component, computer, unicode,
-- урезанные string/table/math/os/coroutine/debug и checkArg. Чего не даёт:
-- require, io, filesystem, event, print на экран. Всё это - тут, ровно в том
-- объёме, который нужен магазину.
--
-- Почему это быстрее и меньше OpenOS:
--
--   * загрузка не сканирует каталоги. OpenOS проходит boot/*.lua, lib/*,
--     /etc/rc.d, поднимает devfs, term, shell и историю команд. Здесь -
--     семь модулей по требованию и ни одного лишнего чтения;
--   * нет процессов и сопрограмм. Магазин - один цикл событий, поэтому не
--     нужны ни планировщик, ни стеки сопрограмм, ни обвязка вокруг них;
--   * нет терминала. Экран рисует сам магазин через gpu, а буфер терминала
--     на 160x50 - это 8000 ячеек в памяти, которые никому не нужны;
--   * нет оболочки, а значит, нет и способа из магазина выйти. Сигнал
--     interrupted, который в OpenOS ловит Ctrl+C, придумывает сама OpenOS в
--     lib/event.lua - здесь его некому создать.
--
-- Порядок: собрать окружение, поднять магазин, приглядывать за ним.

local component, computer, unicode = component, computer, unicode
local pcall, xpcall, load, setmetatable = pcall, xpcall, load, setmetatable

_G._OSVERSION = "ShopOS 1.0"

-- ------------------------------------------------------------------ экран

-- BIOS уже привязал видеокарту к монитору, но если экранов несколько,
-- привязка могла достаться не тому. Делаем сами и явно.
local gpu, W, H
do
	local screen = component.list("screen", true)()
	local addr = screen and component.list("gpu", true)()
	if addr then
		gpu = component.proxy(addr)
		if gpu.getScreen and not gpu.getScreen() then pcall(gpu.bind, screen) end
		W, H = gpu.maxResolution()
		gpu.setResolution(W, H)
		gpu.setBackground(0x000000)
		gpu.setForeground(0xFFFFFF)
		gpu.fill(1, 1, W, H, " ")
	end
end

--- Единственный вывод текста, какой есть у системы: строки загрузки и
--- сообщения об ошибке. Магазин рисует сам и этим не пользуется.
local logY = 1
local function say(text, colour)
	if not gpu then return end
	if logY > H then
		gpu.setBackground(0x000000)
		gpu.fill(1, 1, W, H, " ")
		logY = 1
	end
	gpu.setForeground(colour or 0x787878)
	gpu.set(2, logY, unicode.sub(tostring(text), 1, W - 2))
	logY = logY + 1
end

say("ShopOS: запуск")

-- ------------------------------------------------------------ файловая система

local root, bootAddr
do
	-- fs.lua ещё нельзя потребовать через require - его самого неоткуда
	-- взять. Поэтому первый модуль грузится вручную, а остальные уже им.
	local addr = computer.getBootAddress and computer.getBootAddress()
	if not addr then
		for a in component.list("filesystem") do
			local ok, has = pcall(component.invoke, a, "exists", "/os/fs.lua")
			if ok and has then addr = a break end
		end
	end
	if not addr then
		say("нет загрузочного диска", 0xFF2440)
		while true do computer.pullSignal() end
	end
	bootAddr = addr
	local p = component.proxy(addr)
	local h = assert(p.open("/os/fs.lua", "r"))
	local parts = {}
	while true do
		local part = p.read(h, 2048)
		if not part or #part == 0 then break end
		parts[#parts + 1] = part
	end
	p.close(h)
	local fs = assert(load(table.concat(parts), "=/os/fs.lua", "bt", _ENV))()
	root = fs.new(p)
	_G.__fs = fs
end

-- --------------------------------------------------------------- компоненты

-- В песочнице component умеет только list, invoke и proxy. Обращение вида
-- component.gpu - это сахар OpenOS: там lib/component.lua ищет основной
-- компонент такого типа и отдаёт его proxy. Магазин пишет component.pim и
-- component.me_interface, значит сахар нужен и тут.
--
-- Найденное кешируется: proxy собирает таблицу методов, а обращений к
-- component.pim за одну покупку десятки. Кеш сбрасывается при перезапуске
-- магазина - если железо поменяли, присмотр поднимет его заново и всё
-- найдётся снова.
local rawComponent = component
local primary = {}

local function findPrimary(name)
	local addr = rawComponent.list(name, true)()
	if not addr then return nil end
	local p = rawComponent.proxy(addr)
	primary[name] = p
	return p
end

component = setmetatable({}, {
	__index = function(_, k)
		local v = rawComponent[k]
		if v ~= nil then return v end
		local hit = primary[k]
		if hit ~= nil then return hit end
		return findPrimary(k)
	end,
})

--- Забыть найденное. Зовётся перед каждым запуском магазина.
local function forgetComponents() primary = {} end

-- ------------------------------------------------------------------ io

-- Магазину нужен io.open ровно для трёх вещей: прочитать конфиг целиком,
-- прочитать файл подстановок и читать каталог иконок по смещению. Полный
-- io из OpenOS (буферизация, потоки, режимы) для этого избыточен.
local Handle = {}
Handle.__index = Handle

function Handle:read(fmt)
	fmt = fmt or "*a"
	if type(fmt) == "number" then
		local s = self.h.read(fmt)
		return (s and #s > 0) and s or nil
	end
	fmt = tostring(fmt):gsub("^%*", "")
	if fmt:sub(1, 1) == "a" then
		local parts, n = {}, 0
		while true do
			local part = self.h.read(4096)
			if not part or #part == 0 then break end
			n = n + 1
			parts[n] = part
		end
		return table.concat(parts)
	end
	return nil
end

function Handle:seek(whence, offset) return self.h.seek(whence, offset) end
function Handle:write(s) self.h.write(s) return self end
function Handle:close() return self.h.close() end
function Handle:lines() error("io: lines не поддержан", 2) end

local ioShim = {
	open = function(path, mode)
		mode = (mode or "r"):gsub("b", "")
		local h, why = root:open(path, mode)
		if not h then return nil, why end
		return setmetatable({ h = h }, Handle)
	end,
	-- всё, что кто-то попробует напечатать, идёт в журнал загрузки: на
	-- работающем магазине это видно только при падении
	stderr = setmetatable({}, { __index = { write = function(_, s)
		say(tostring(s):gsub("\n$", ""), 0xFF2440)
	end } }),
}
ioShim.stdout = ioShim.stderr
ioShim.write = function(s) ioShim.stderr:write(s) end
_G.io = ioShim

-- ------------------------------------------------------------------ require

-- Модули лежат в /os. Каталог выбран так, чтобы не пересечься с OpenOS:
-- у неё заняты /bin, /boot, /etc, /home, /lib, /usr, и установка ShopOS на
-- тот же диск не должна ломать работающую систему на полпути. Ни путей
-- поиска, ни package.path с подстановками - один каталог и таблица
-- уже загруженного.
local loaded = {
	component = component,
	computer = computer,
	unicode = unicode,
	fs = _G.__fs,
	io = ioShim,
}
loaded.root = root

local loading = {}

local function requireModule(name)
	local m = loaded[name]
	if m ~= nil then return m end
	if loading[name] then error("круговая зависимость: " .. name, 2) end
	loading[name] = true
	local path = "/os/" .. name .. ".lua"
	local chunk, why = root:load(path, path, _ENV)
	if not chunk then
		loading[name] = nil
		error("нет модуля " .. name .. (why and (": " .. why) or ""), 2)
	end
	local value = chunk()
	if value == nil then value = true end
	loaded[name] = value
	loading[name] = nil
	return value
end

_G.require = requireModule
-- некоторые модули правят package.path; пусть правят, лишь бы не падали
_G.package = { path = "", loaded = loaded }

-- ------------------------------------------------------------------ старт

local free0 = computer.freeMemory()
say("диск " .. bootAddr:sub(1, 8) .. "   память " .. math.floor(free0 / 1024) .. " КБ")

root:mkdir("/var")

local event = requireModule("event")
loaded.event = event

--- Журнал покупок и выдач. Имя printD - то же, что у логгера прежней
--- машины, чтобы логика магазина не знала, где она работает.
---
--- Пишется сразу, без накопления в памяти. Накопить и сбросить пачкой было
--- бы дешевле по вызовам, но это журнал сделок: после выключения питания
--- никто не должен гадать, прошла последняя покупка или нет. Строка стоит
--- три вызова к диску против восьмидесяти на перерисовку экрана.
local logPath = "/var/shop.log"
local logLimit = 64 * 1024

local function printD(line)
	local text = ("[%d] %s\n"):format(math.floor(computer.uptime()), tostring(line))
	-- журнал не должен сожрать диск: раз в сколько-то выросший файл
	-- уезжает в .old, и на диске всегда не больше двух таких
	if root:exists(logPath) and root:size(logPath) > logLimit then
		root:remove(logPath .. ".old")
		root:rename(logPath, logPath .. ".old")
	end
	local h = root:open(logPath, "a")
	if not h then return end
	h.write(text)
	h.close()
end
_G.printD = printD

--- Раньше журнал копился в памяти, и это был способ его дописать. Теперь
--- писать нечего, но вызов остался: магазин зовёт его перед показом ошибки.
local function flushLog() end
_G.flushLog = flushLog

-- ------------------------------------------------------------- присмотр

--- Магазин не должен уметь завершиться. Если он всё-таки упал - пишем
--- причину в журнал, показываем её на экране и поднимаем заново. Задержка
--- растёт, чтобы падение на старте не крутило диск без остановки.
local function supervise()
	local delay = 1
	while true do
		forgetComponents()
		local ok, err = xpcall(function()
			local shop = root:load("/os/shop.lua", "shop", _ENV)
			if not shop then error("нет /os/shop.lua") end
			return shop()
		end, function(msg)
			local tb = debug and debug.traceback and debug.traceback(tostring(msg), 2)
			return tb or tostring(msg)
		end)

		if ok then
			-- магазин вернул управление сам: такого быть не должно,
			-- но перезапуск всё равно правильнее, чем пустой экран
			printD("магазин завершился сам, поднимаю заново")
			delay = 1
		else
			printD("ПАДЕНИЕ: " .. tostring(err))
			flushLog()
			if gpu then
				gpu.setBackground(0x000000)
				gpu.setForeground(0xFFFFFF)
				gpu.fill(1, 1, W, H, " ")
				logY = 1
				say("ShopOS: магазин упал, поднимаю заново", 0xFF2440)
				for line in tostring(err):gmatch("[^\n]+") do say(line) end
				say("")
				say("причина записана в " .. logPath)
			end
		end

		local until_ = computer.uptime() + delay
		repeat computer.pullSignal(until_ - computer.uptime()) until computer.uptime() >= until_
		delay = delay < 30 and delay * 2 or 30
	end
end

supervise()
