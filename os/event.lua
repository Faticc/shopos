-- event - сигналы машины.
--
-- В OpenOS это двести строк: очередь обработчиков, таймеры, сопрограммы,
-- ловушка Ctrl+C и разбор фильтров. Здесь - обёртка вокруг
-- computer.pullSignal, потому что магазин держит свой цикл событий сам, а
-- таймеры считает по времени ближайшего дела.
--
-- Сигнала interrupted тут нет и не будет. В OpenOS его придумывает сама
-- lib/event.lua: смотрит, зажаты ли Ctrl и C, и толкает его в очередь. Раз
-- этого кода нет, Ctrl+C в ShopOS ничего не делает, и выйти из магазина
-- нечем - это не побочный эффект, а требование.

local computer = require("computer")

local event = {}

local pullSignal = computer.pullSignal

--- Ждать сигнал. timeout в секундах, nil - ждать сколько угодно.
--- Возвращает имя и всё, что к нему приложено, или nil по истечении времени.
function event.pull(timeout)
	if timeout then return pullSignal(timeout) end
	return pullSignal()
end

--- Ждать сигнал с определённым именем, пропуская все прочие. Магазину не
--- нужно, но пригождается в обслуживании: дождаться player_on и выйти.
function event.pullFiltered(name, timeout)
	local deadline = timeout and (computer.uptime() + timeout) or nil
	while true do
		local left = deadline and (deadline - computer.uptime()) or nil
		if left and left <= 0 then return nil end
		local sig = table.pack(left and pullSignal(left) or pullSignal())
		if sig[1] == nil then return nil end
		if sig[1] == name then return table.unpack(sig, 1, sig.n) end
	end
end

event.push = computer.pushSignal

--- Заглушка под привычку прежнего кода: на той машине магазин отключал
--- прерывание, выставляя event.shouldInterrupt. Тут прерывать нечему,
--- но пусть присвоение не падает.
event.shouldInterrupt = function() return false end

return event
