-- ShopOS - машина, на которой нет ничего, кроме магазина.
--
-- Этот файл штатный Lua BIOS находит на диске и вызывает. OpenOS нет:
-- ни оболочки, ни терминала, ни Ctrl+C. Ядро делает три вещи - берёт
-- видеокарту, даёт модулям require, и держит магазин запущенным: если он
-- упал, причина пишется в /var/crash.log и он поднимается снова.

local component, computer = component, computer

_G._OSVERSION = "ShopOS 2"

-- ------------------------------------------------------------------ экран

local gpu, W, H
do
	local screen = component.list("screen", true)()
	local addr = screen and component.list("gpu", true)()
	if addr then
		gpu = component.proxy(addr)
		pcall(gpu.bind, screen)
		W, H = gpu.maxResolution()
		gpu.setResolution(W, H)
		-- Палитру помнит монитор, а не машина: её переживает и перезагрузка,
		-- и смена диска. Серые магазина - это ровно штатная палитра (15, 30,
		-- ... 240), так что чужая - от ролика или игры на этом же экране -
		-- перекрашивает весь интерфейс. Возвращаем штатную, трогая только
		-- то, что разошлось: setPaletteColor стоит машине паузы.
		for i = 0, 15 do
			local s = math.floor(255 * (i + 1) / 17) * 0x010101
			local ok, cur = pcall(gpu.getPaletteColor, i)
			if ok and cur ~= s then pcall(gpu.setPaletteColor, i, s) end
		end
	end
end

local line = 0
local function say(text, colour)
	if not gpu then return end
	if line == 0 or line >= H then
		gpu.setBackground(0x000000)
		gpu.fill(1, 1, W, H, " ")
		line = 1
	end
	gpu.setBackground(0x000000)
	gpu.setForeground(colour or 0xA5A5A5)
	gpu.set(2, line, unicode.sub(tostring(text), 1, W - 2))
	line = line + 1
end

-- ------------------------------------------------------------------ диск

local root
do
	local addr = computer.getBootAddress()
	local p = component.proxy(addr)
	local h = assert(p.open("/sys/disk.lua", "r"), "нет /sys/disk.lua")
	local parts = {}
	while true do
		local s = p.read(h, 2048)
		if not s or #s == 0 then break end
		parts[#parts + 1] = s
	end
	p.close(h)
	local disk = assert(load(table.concat(parts), "=/sys/disk.lua", "t", _ENV))()
	root = disk.new(p)
end

-- ------------------------------------------------------------------ require

-- component.<тип> - сахар OpenOS, модулям он нужен: component.pim,
-- component.me_interface. Адрес ищется на каждое обращение заново, чтобы
-- переставленное железо находилось без перезагрузки.
local raw = component
_G.component = setmetatable({}, {
	__index = function(_, k)
		local v = raw[k]
		if v ~= nil then return v end
		local addr = raw.list(k, true)()
		return addr and raw.proxy(addr) or nil
	end,
})

local loaded = { root = root, gpu = gpu }
function _G.require(name)
	local m = loaded[name]
	if m ~= nil then return m end
	local f, why = root:load("/sys/" .. name .. ".lua", _ENV)
	if not f then error("нет модуля " .. name .. ": " .. tostring(why), 2) end
	m = f()
	if m == nil then m = true end
	loaded[name] = m
	return m
end

-- ------------------------------------------------------------------ присмотр

root:mkdir("/var")
say("ShopOS 2   память " .. math.floor(computer.freeMemory() / 1024) .. " КБ")

local delay = 1
while true do
	-- модули перечитываются заново: свежая копия после падения лучше, чем
	-- состояние, в котором магазин только что сломался
	for k in pairs(loaded) do
		if k ~= "root" and k ~= "gpu" then loaded[k] = nil end
	end
	local ok, err = xpcall(function() require("shop").run() end, function(m)
		return debug.traceback(tostring(m), 2)
	end)
	if not ok then
		if root:size("/var/crash.log") > 65536 then root:remove("/var/crash.log") end
		root:append("/var/crash.log", ("[%d] %s\n"):format(math.floor(computer.uptime()), err))
		line = 0
		say("магазин упал, перезапуск через " .. delay .. " с", 0xFF4940)
		for l in tostring(err):gmatch("[^\n]+") do say(l) end
	end
	local t = computer.uptime() + delay
	repeat computer.pullSignal(t - computer.uptime()) until computer.uptime() >= t
	delay = math.min(delay * 2, 30)
end
