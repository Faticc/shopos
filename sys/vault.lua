-- vault - диск данных: счета, журнал, настройки скупки.
--
-- Всё, что нельзя терять, лежит на отдельном жёстком диске с меткой
-- /shopos.data. Установщик такой диск не трогает никогда: ни переустановка,
-- ни --clean его не задевают. Диск находится по метке, а не по слоту - его
-- можно переставить.
--
-- Первый запуск: диска с меткой нет - берётся свободный записываемый диск
-- (не загрузочный, не tmpfs, не дискета, не тот, где часть каталога). На
-- него ставится метка, адрес запоминается в /var/datadisk загрузочного
-- диска, и туда переезжают прежние /var/wallet и журнал. Если адрес
-- запомнен, а диска с меткой нет, деньги не трогаются вовсе: иначе магазин
-- завёл бы пустые счета на другом диске, и все балансы стали бы нулями.
--
-- Третьего диска нет и не было - данные живут на загрузочном в /var, как
-- раньше.

local root = require("root")
local disk = require("disk")

local computer = computer

local vault = {}

local MARK, REG = "/shopos.data", "/var/datadisk"
local MIN = 1024 * 1024        -- дискета (512 КБ) диском данных не станет

local function boot() return computer.getBootAddress() end
local function tmp() return computer.tmpAddress and computer.tmpAddress() end

local function try(p, method, ...)
	local ok, v = pcall(p[method], ...)
	if ok then return v end
	return nil
end

--- Годится ли диск под данные, когда метки ещё нет нигде.
local function spare(addr, p)
	if addr == boot() or addr == tmp() then return false end
	if try(p, "isReadOnly") ~= false then return false end
	if (try(p, "spaceTotal") or 0) < MIN then return false end
	return not try(p, "exists", "/data/catalog.2.bin")
end

--- Прежние счета и журнал с загрузочного диска - на диск данных.
--- Оригиналы не стираются, а переименовываются: второй переезд не
--- затрёт то, что уже изменилось на новом месте.
local function migrate(dst)
	if root:exists("/var/wallet") then
		dst:mkdir("/wallet")
		local names = root:list("/var/wallet")
		table.sort(names)                  -- ник раньше своего ник.new
		for _, name in ipairs(names) do
			if not name:find("/$") then
				local nick = name:gsub("%.new$", "")
				if not dst:exists("/wallet/" .. nick) then
					local s = root:readAll("/var/wallet/" .. name)
					if s then dst:writeAll("/wallet/" .. nick, s) end
				end
			end
		end
		root:rename("/var/wallet", "/var/wallet.moved")
	end
	if root:exists("/var/rules.cfg") and not dst:exists("/rules.cfg") then
		local s = root:readAll("/var/rules.cfg")
		if s then dst:writeAll("/rules.cfg", s) end
	end
	-- журналы: прежнего ShopOS и тех дней, когда третьего диска не было
	local parts = {}
	for _, f in ipairs({ "/var/ledger.log.old", "/var/ledger.log", "/var/log/ledger.log" }) do
		if root:exists(f) then
			local s = root:readAll(f)
			if s then parts[#parts + 1] = s end
			root:rename(f, f .. ".moved")
		end
	end
	if #parts > 0 then
		dst:mkdir("/log")
		local s = table.concat(parts)
		if dst:exists("/log/ledger-0000.log") then dst:append("/log/ledger-0000.log", s)
		else dst:writeAll("/log/ledger-0000.log", s) end
	end
end

local function use(p, where)
	vault.fs, vault.base, vault.where = disk.new(p), "", where
	vault.address = p.address
	if root:readAll(REG) ~= p.address then root:writeAll(REG, p.address) end
	migrate(vault.fs)
end

function vault.open()
	vault.fs, vault.base, vault.err, vault.warn = nil, "", nil, nil
	local reg = root:readAll(REG)
	for addr in component.list("filesystem") do
		local p = component.proxy(addr)
		if addr ~= boot() and try(p, "exists", MARK) then
			use(p, "диск данных " .. addr:sub(1, 8))
			return
		end
	end
	if reg and reg ~= "" then
		vault.err = "нет диска данных " .. reg:sub(1, 8) .. " - на нём счета, торговля остановлена"
		return
	end
	local best, free
	for addr in component.list("filesystem") do
		local p = component.proxy(addr)
		if spare(addr, p) then
			local f = (try(p, "spaceTotal") or 0) - (try(p, "spaceUsed") or 0)
			if not best or f > free then best, free = p, f end
		end
	end
	if best then
		local d = disk.new(best)
		if d:writeAll(MARK, "ShopOS: счета и журнал магазина. Не стирать.\n") then
			use(best, "диск данных " .. best.address:sub(1, 8))
			return
		end
	end
	-- как раньше: всё на загрузочном
	vault.fs, vault.base, vault.where = root, "/var", "загрузочный диск /var"
	vault.warn = "нет третьего диска - счета лежат на загрузочном"
end

--- Путь на диске данных.
function vault.path(p) return vault.base .. p end

vault.open()

return vault
