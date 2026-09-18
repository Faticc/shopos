-- wallet - счета игроков и журнал операций.
--
-- Счёт хранится в сотых долях монеты целым числом: дешёвые предметы стоят
-- доли монеты, а дробные числа при сложении копят ошибку. Файл на игрока -
-- /var/wallet/<ник>; каждое изменение пишется сразу и через подмену файла,
-- так что обрыв питания не теряет и не удваивает деньги.

local root = require("root")
local computer = computer

local floor = math.floor

local wallet = {}

local DIR, LOG = "/var/wallet", "/var/ledger.log"
root:mkdir(DIR)

local function path(nick) return DIR .. "/" .. nick end

--- Баланс игрока в сотых монеты.
function wallet.get(nick)
	local s = root:readAll(path(nick))
	return floor(tonumber(s or "") or 0)
end

function wallet.set(nick, cents)
	cents = floor(cents)
	if cents < 0 then cents = 0 end
	return root:writeAll(path(nick), ("%.0f"):format(cents))
end

--- Изменить баланс на delta. Возвращает новый баланс или nil, если на
--- счету не хватило.
function wallet.add(nick, delta)
	local now = wallet.get(nick) + floor(delta)
	if now < 0 then return nil end
	if not wallet.set(nick, now) then return nil end
	return now
end

function wallet.log(text)
	if root:size(LOG) > 128 * 1024 then
		root:remove(LOG .. ".old")
		root:rename(LOG, LOG .. ".old")
	end
	root:append(LOG, ("[%d] %s\n"):format(floor(computer.uptime()), text))
end

--- Сотые монеты в строку "1 234.50".
function wallet.format(cents)
	cents = floor(cents or 0)
	local whole, part = floor(cents / 100), cents % 100
	local s = ("%.0f"):format(whole):reverse():gsub("(%d%d%d)", "%1 "):reverse()
	s = s:gsub("^ ", "")
	return ("%s.%02d"):format(s, part)
end

return wallet
