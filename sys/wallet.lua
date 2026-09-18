-- wallet - счета игроков и журнал операций.
--
-- У игрока два счёта, оба в сотых долях целым числом (дешёвые предметы
-- стоят доли монеты, а дробные числа при сложении копят ошибку):
--   деньги  - пополняются монетами и снимаются монетами обратно;
--   ресурсы - пополняются тем, что игрок сдал в скупку; снять их нельзя,
--             только потратить на покупки.
-- Файл на игрока - wallet/<ник> на диске данных (см. vault), в нём
-- "деньги ресурсы". Прежний формат - одно число - читается как деньги.
-- Каждое изменение пишется сразу и через подмену файла, так что обрыв
-- питания не теряет и не удваивает деньги.
--
-- Журнал - log/ledger.log там же, с настоящими датой и временем. Часов у
-- машины нет, но диск помнит, когда файл менялся: после каждой записи
-- поправка к uptime уточняется по времени изменения журнала. Разросся
-- журнал - уходит в ledger-NNNN.log; старые части удаляются, только когда
-- на диске кончается место.

local vault = require("vault")
local computer = computer

local floor, max = math.floor, math.max

local wallet = {}

local disk = vault.fs
local DIR = vault.path("/wallet")
local LOGDIR = vault.path("/log")
local LOG = LOGDIR .. "/ledger.log"
local ROTATE = 256 * 1024       -- размер части журнала
local RESERVE = 512 * 1024      -- столько места на диске держать свободным

if disk then
	disk:mkdir(DIR)
	disk:mkdir(LOGDIR)
end

--- Можно ли трогать деньги: false и почему - если диска данных нет.
function wallet.ok()
	if disk then return true end
	return false, vault.err
end

local function path(nick) return DIR .. "/" .. nick end

local function parse(s)
	if not s then return nil end
	local m, r = s:match("^%s*(%-?%d+)%s*(%-?%d*)")
	if not m then return nil end
	return floor(tonumber(m)), floor(tonumber(r) or 0)
end

--- Счета игрока в сотых: деньги, ресурсы.
--- Если питание пропало между удалением старого файла и переименованием
--- нового, остаётся только <ник>.new - он и есть последний баланс.
function wallet.get(nick)
	if not disk then return 0, 0 end
	local m, r = parse(disk:readAll(path(nick)))
	if not m then m, r = parse(disk:readAll(path(nick) .. ".new")) end
	return m or 0, r or 0
end

function wallet.set(nick, money, res)
	if not disk then return false end
	money, res = max(0, floor(money)), max(0, floor(res))
	return disk:writeAll(path(nick), ("%.0f %.0f"):format(money, res))
end

--- Изменить счета на dm и dr. Возвращает новые деньги и ресурсы или nil,
--- если какого-то счёта не хватило или запись не удалась.
function wallet.add(nick, dm, dr)
	local m, r = wallet.get(nick)
	m, r = m + floor(dm or 0), r + floor(dr or 0)
	if m < 0 or r < 0 then return nil end
	if not wallet.set(nick, m, r) then return nil end
	return m, r
end

--- Пишется ли счёт. Пополнение сначала забирает вещи и только потом пишет
--- счёт - проверяется до того, как что-то забрать.
function wallet.writable(nick)
	local m, r = wallet.get(nick)
	return wallet.set(nick, m, r)
end

--- Все, у кого есть счёт, по алфавиту.
function wallet.list()
	if not disk then return {} end
	local seen, out = {}, {}
	for _, name in ipairs(disk:list(DIR)) do
		if not name:find("/$") then
			local nick = name:gsub("%.new$", "")
			if not seen[nick] then
				seen[nick] = true
				out[#out + 1] = nick
			end
		end
	end
	table.sort(out, function(a, b) return a:lower() < b:lower() end)
	return out
end

-- ------------------------------------------------------------------ журнал

local shift                 -- настоящее время минус uptime, секунд
local zone = 0              -- часовой пояс журнала, секунд от UTC

local function sync(file)
	local t = disk and disk:modified(file)
	if t then shift = t - computer.uptime() end
end

if disk then
	disk:writeAll(LOGDIR .. "/clock", "")
	sync(LOGDIR .. "/clock")
end

function wallet.zone(hours) zone = floor((tonumber(hours) or 0) * 3600) end

--- Сейчас: "2026-09-18 22:09:15" или, если часов нет, "+123 с" от старта.
function wallet.now()
	if shift then
		local ok, s = pcall(os.date, "!%Y-%m-%d %H:%M:%S", floor(computer.uptime() + shift + zone))
		if ok and s then return s end
	end
	return ("+%d с"):format(floor(computer.uptime()))
end

--- Части журнала по порядку: имена ledger-NNNN.log.
local function parts()
	local out = {}
	for _, name in ipairs(disk:list(LOGDIR)) do
		if name:match("^ledger%-%d+%.log$") then out[#out + 1] = name end
	end
	table.sort(out)
	return out
end

local function rotate()
	if disk:size(LOG) <= ROTATE then return end
	local old = parts()
	local n = #old > 0 and tonumber(old[#old]:match("(%d+)")) or 0
	disk:rename(LOG, ("%s/ledger-%04d.log"):format(LOGDIR, n + 1))
	-- диск кончается - уходят самые старые части
	for i = 1, #old do
		if disk:free() >= RESERVE then break end
		disk:remove(LOGDIR .. "/" .. old[i])
	end
end

function wallet.log(text)
	if not disk then return end
	rotate()
	disk:append(LOG, ("%s  %s\n"):format(wallet.now(), text))
	sync(LOG)
end

--- Последние строки журнала, новые первыми: хвост нынешней части и, если
--- она короче bytes, предыдущей.
function wallet.tail(bytes)
	local out = {}
	if not disk then return out end
	local function take(file, n)
		local size = disk:size(file)
		if size == 0 then return 0 end
		local r = disk:reader(file)
		if not r then return 0 end
		local from = max(0, size - n)
		local s = r.at(from, size - from)
		r.close()
		local lines = {}
		for l in s:gmatch("[^\n]+") do lines[#lines + 1] = l end
		-- читали с середины - первая строка обрезана
		if from > 0 then table.remove(lines, 1) end
		for i = #lines, 1, -1 do out[#out + 1] = lines[i] end
		return size - from
	end
	local got = take(LOG, bytes)
	if got < bytes then
		local old = parts()
		if #old > 0 then take(LOGDIR .. "/" .. old[#old], bytes - got) end
	end
	return out
end

--- Где журнал - для подсказки в админке.
wallet.logPath = LOG

--- Сотые монеты в строку "1 234.50".
function wallet.format(cents)
	cents = floor(cents or 0)
	local whole, part = floor(cents / 100), cents % 100
	local s = ("%.0f"):format(whole):reverse():gsub("(%d%d%d)", "%1 "):reverse()
	s = s:gsub("^ ", "")
	return ("%s.%02d"):format(s, part)
end

return wallet
