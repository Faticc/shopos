-- Проверка торговли без игры: shopcore и meio на поддельных МЭ, PIM и базе.
--
--   lua test/shoptest.lua
--
-- Экран тут не участвует вообще - в этом и смысл разделения: логика магазина
-- не знает про gpu, значит её можно прогнать на обычном Lua и поймать то,
-- что раньше ловилось только в игре и только жалобой игрока.

package.path = "shopos/os/?.lua;" .. package.path

local meio     = require("meio")
local shopcore = require("shopcore")

-- ------------------------------------------------------------------ счётчик

local ok, fail = 0, 0
local function check(name, cond, got)
	if cond then ok = ok + 1
	else
		fail = fail + 1
		print("  ПРОВАЛ: " .. name .. (got ~= nil and ("  -> " .. tostring(got)) or ""))
	end
end
local function eq(name, a, b) check(name, a == b, tostring(a) .. " вместо " .. tostring(b)) end

-- ------------------------------------------------------------------ железо

local SLOTS = 40

--- Поддельный мир: сеть МЭ, инвентарь игрока и счётчик вызовов к компонентам.
--- Счётчик и есть главная проверка оптимизации - он показывает, сколько раз
--- магазин полез в мод за одну операцию.
local world = { net = {}, inv = {}, calls = {} }

local function bump(name) world.calls[name] = (world.calls[name] or 0) + 1 end

local function netKey(id, dmg, nbt) return id .. "/" .. dmg .. "/" .. (nbt or "") end

local function netAdd(id, dmg, size, nbt)
	local k = netKey(id, dmg, nbt)
	local e = world.net[k]
	if e then e.size = e.size + size
	else world.net[k] = { id = id, dmg = dmg, nbt = nbt, size = size } end
end

local function netTake(id, dmg, nbt, want)
	local e = world.net[netKey(id, dmg, nbt)]
	if not e or e.size <= 0 then return 0 end
	local n = math.min(want, e.size)
	e.size = e.size - n
	return n
end

local function invPut(id, dmg, count, nbt)
	while count > 0 do
		local put = math.min(64, count)
		local slot
		for i = 1, SLOTS do
			local s = world.inv[i]
			if s and s.id == id and s.dmg == dmg and s.nbt_hash == nbt and s.count < 64 then
				slot = i break
			end
		end
		if slot then
			local room = 64 - world.inv[slot].count
			local add = math.min(room, put)
			world.inv[slot].count = world.inv[slot].count + add
			count = count - add
		else
			for i = 1, SLOTS do
				if not world.inv[i] then slot = i break end
			end
			if not slot then return count end          -- инвентарь полон
			world.inv[slot] = { id = id, dmg = dmg, count = put, nbt_hash = nbt }
			count = count - put
		end
	end
	return 0
end

local function invCount(id, dmg)
	local n = 0
	for i = 1, SLOTS do
		local s = world.inv[i]
		if s and s.id == id and s.dmg == dmg then n = n + s.count end
	end
	return n
end

local function invClear() world.inv = {} end

local component = {
	me_interface = {
		getAvailableItems = function()
			bump("getAvailableItems")
			local out = {}
			for _, e in pairs(world.net) do
				out[#out + 1] = {
					size = e.size,
					fingerprint = { id = e.id, dmg = e.dmg, nbt_hash = e.nbt },
				}
			end
			return out
		end,
		exportItem = function(fp, _, count)
			bump("exportItem")
			local moved = netTake(fp.id, fp.dmg, fp.nbt_hash, count)
			if moved > 0 then
				local back = invPut(fp.id, fp.dmg, moved, fp.nbt_hash)
				if back > 0 then                              -- места не хватило
					netAdd(fp.id, fp.dmg, back, fp.nbt_hash)
					moved = moved - back
				end
			end
			return { size = moved }
		end,
	},
	pim = {
		getStackInSlot = function(i)
			bump("getStackInSlot")
			local s = world.inv[i]
			if not s then return nil end
			return { id = s.id, dmg = s.dmg, count = s.count, nbt_hash = s.nbt_hash }
		end,
		getAllStacks = function()
			bump("getAllStacks")
			local out = {}
			for i = 1, SLOTS do
				local s = world.inv[i]
				if s then
					out[i] = { all = function()
						bump("all")
						return { id = s.id, dmg = s.dmg, qty = s.count }
					end }
				end
			end
			return out
		end,
		pushItem = function(_, slot, count)
			bump("pushItem")
			local s = world.inv[slot]
			if not s then return 0 end
			local n = math.min(count, s.count)
			s.count = s.count - n
			if s.count <= 0 then world.inv[slot] = nil end
			netAdd(s.id, s.dmg, n, s.nbt_hash)
			return n
		end,
	},
	database = {
		get = function(i)
			local coins = {
				{ name = "coin", damage = 0 }, { name = "coin", damage = 1 },
				{ name = "coin", damage = 2 }, { name = "coin", damage = 3 },
			}
			return coins[i]
		end,
	},
}

local clock = 1000
local computer = { uptime = function() return clock end }

-- ------------------------------------------------------------------ сборка

local rows = {}
local db = {
	select = function(_, cl)
		local key = cl and cl[1] and cl[1].value
		local r = key and rows[key]
		return r and { r } or {}
	end,
	insert = function(_, key, value) rows[key] = value bump("dbInsert") end,
}

local cfg = {
	sell = {
		{ id = "iron", dmg = 0, price = 50, label = "Железо", category = "Руда" },
		{ id = "gold", dmg = 0, price = 75, label = "Золото", category = "Руда" },
		{ id = "book", dmg = 0, price = 1000, label = "Книга", category = "Книги",
		  nbt = "deadbeef" },
	},
	buy = {
		{ id = "iron", dmg = 0, price = 40, label = "Железо" },
	},
	ore = {
		{ fromId = "ironOre", fromDmg = 0, toId = "iron", toDmg = 0,
		  fromCount = 1, toCount = 2, fromLabel = "Жел. руда", toLabel = "Железо" },
		{ fromId = "goldOre", fromDmg = 0, toId = "gold", toDmg = 0,
		  fromCount = 1, toCount = 2, fromLabel = "Зол. руда", toLabel = "Золото" },
	},
	exchange = {
		{ fromId = "ironOre", fromDmg = 0, toId = "matter", toDmg = 0,
		  fromCount = 120, toCount = 1, fromLabel = "Жел. руда", toLabel = "Материя" },
	},
}

local IO = meio.new(component, computer, { slots = SLOTS, cacheSeconds = 5 })
IO:setCurrency({
	{ item = component.database.get(1), money = 1000 },
	{ item = component.database.get(2), money = 10000 },
	{ item = component.database.get(3), money = 100000 },
	{ item = component.database.get(4), money = 1000000 },
})
local core = shopcore.new({ db = db, io = IO, name = "Test", cfg = cfg })

local function reset()
	world.net, world.inv, world.calls = {}, {}, {}
	rows = {}
	core:forget()
	IO:invalidate()
	clock = clock + 100
end

local NICK = "Tester"

-- ------------------------------------------------------------- 1. номиналы

reset()
eq("шаг денег", core:moneyUnit(), 1000)

netAdd("coin", 0, 100)    -- 1к
netAdd("coin", 1, 100)    -- 10к
netAdd("coin", 2, 100)    -- 100к
netAdd("coin", 3, 100)    -- 1кк

-- ------------------------------------------------- 2. пополнение и снятие

reset()
netAdd("coin", 0, 100) netAdd("coin", 1, 100) netAdd("coin", 2, 100) netAdd("coin", 3, 100)
invPut("coin", 0, 5)                                        -- 5к монетками по 1к
invPut("coin", 1, 3)                                        -- 30к монетками по 10к

local n, msg = core:deposit(NICK, 35000)
eq("пополнение: сумма", n, 35000)
eq("пополнение: баланс", core:balance(NICK), 35000)
eq("пополнение: монеты ушли из инвентаря", invCount("coin", 0) + invCount("coin", 1), 0)

-- кратность проверяется ДО того, как трогать инвентарь
reset()
netAdd("coin", 0, 100)
invPut("coin", 0, 5)
n, msg = core:deposit(NICK, 1500)
eq("некратное пополнение: ничего не взято", n, 0)
eq("некратное пополнение: монеты на месте", invCount("coin", 0), 5)
check("некратное пополнение: сообщение", msg:find("кратн") ~= nil, msg)
eq("некратное пополнение: баланс не тронут", core:balance(NICK), 0)

-- отрицательное и дробное не доезжают до логики
reset()
invPut("coin", 0, 5)
eq("отрицательное пополнение", (core:deposit(NICK, -5000)), 0)
eq("дробное пополнение округляется вниз", (core:deposit(NICK, 1000.7)), 1000)
eq("после дробного ушла ровно одна монета", invCount("coin", 0), 4)

-- снятие
reset()
netAdd("coin", 0, 100) netAdd("coin", 1, 100) netAdd("coin", 2, 100)
rows[NICK] = { balance = 250000, items = {} }
n, msg = core:withdraw(NICK, 120000)
eq("снятие: сумма", n, 120000)
eq("снятие: баланс", core:balance(NICK), 130000)
eq("снятие: выдано монет по 100к", invCount("coin", 2), 1)
eq("снятие: выдано монет по 10к", invCount("coin", 1), 2)

reset()
rows[NICK] = { balance = 500, items = {} }
n, msg = core:withdraw(NICK, 1000)
eq("снятие больше баланса", n, 0)
check("снятие больше баланса: сообщение", msg:find("хватает") ~= nil, msg)

-- ------------------------------------------------------------- 3. покупка

reset()
netAdd("iron", 0, 500)
rows[NICK] = { balance = 1000, items = {} }
n, msg = core:buy(NICK, cfg.sell[1], 100)
eq("покупка урезана по деньгам", n, 20)              -- 1000 / 50
eq("покупка: баланс", core:balance(NICK), 0)
eq("покупка: предметы у игрока", invCount("iron", 0), 20)

reset()
netAdd("iron", 0, 5)
rows[NICK] = { balance = 100000, items = {} }
n = core:buy(NICK, cfg.sell[1], 100)
eq("покупка урезана по наличию", n, 5)
eq("покупка по наличию: списано ровно за выданное", core:balance(NICK), 100000 - 5 * 50)

reset()
netAdd("iron", 0, 500)
rows[NICK] = { balance = 10, items = {} }
n, msg = core:buy(NICK, cfg.sell[1], 1)
eq("покупка без денег", n, 0)
check("покупка без денег: сообщение", msg:find("хватает") ~= nil, msg)

-- зачарованная книга: экспорт только по полному отпечатку с nbt
reset()
netAdd("book", 0, 3, "deadbeef")
rows[NICK] = { balance = 100000, items = {} }
n = core:buy(NICK, cfg.sell[3], 2)
eq("покупка книги по nbt", n, 2)

-- ------------------------------------------------------------- 4. продажа

reset()
invPut("iron", 0, 70)
rows[NICK] = { balance = 0, items = {} }
n, msg = core:sell(NICK, cfg.buy[1], 70)
eq("продажа: количество", n, 70)
eq("продажа: баланс", core:balance(NICK), 70 * 40)
eq("продажа: инвентарь опустел", invCount("iron", 0), 0)

reset()
rows[NICK] = { balance = 0, items = {} }
n, msg = core:sell(NICK, cfg.buy[1], 10)
eq("продажа без товара", n, 0)
check("продажа без товара: сообщение", msg:find("инвентаре") ~= nil, msg)

-- ------------------------------------------------------------- 5. обмен

-- курс 1 к 2, ровно
reset()
invPut("ironOre", 0, 10)
n, msg = core:exchange(NICK, cfg.ore[1], 10)
eq("обмен руды: выход", n, 20)
eq("обмен руды: в корзине железо", core:basket(NICK)[1].count, 20)
eq("обмен руды: руда забрана", invCount("ironOre", 0), 0)

-- курс 120 к 1, с остатком: остаток обязан вернуться игроку
reset()
invPut("ironOre", 0, 200)
n, msg = core:exchange(NICK, cfg.exchange[1], 1)
eq("обменник: выход", n, 1)
local basket = core:basket(NICK)
local matter, restOre = 0, 0
for _, it in ipairs(basket) do
	if it.id == "matter" then matter = it.count end
	if it.id == "ironOre" then restOre = it.count end
end
eq("обменник: получена материя", matter, 1)
eq("обменник: остаток не пропал", restOre, 0)      -- взято ровно 120, остатка нет
eq("обменник: лишнее не тронуто", invCount("ironOre", 0), 80)

-- просят два курса, а руды хватает на один с хвостом
reset()
invPut("ironOre", 0, 150)
n, msg = core:exchange(NICK, cfg.exchange[1], 2)
basket = core:basket(NICK)
matter, restOre = 0, 0
for _, it in ipairs(basket) do
	if it.id == "matter" then matter = it.count end
	if it.id == "ironOre" then restOre = it.count end
end
eq("обменник с хвостом: материя", matter, 1)
eq("обменник с хвостом: хвост вернулся в корзину", restOre, 30)
eq("обменник с хвостом: сумма сошлась", matter * 120 + restOre, 150)

-- обмен всех руд разом: один проход по слотам на все виды
reset()
invPut("ironOre", 0, 30)
invPut("goldOre", 0, 7)
invPut("iron", 0, 5)                                 -- не руда, трогать нельзя
world.calls = {}
n, msg = core:exchangeAllOres(NICK)
eq("обмен всех руд: сколько руд ушло", n, 37)
eq("обмен всех руд: слоты обойдены один раз", world.calls.getStackInSlot, SLOTS)
eq("обмен всех руд: чужое не тронуто", invCount("iron", 0), 5)
local gotIron, gotGold = 0, 0
for _, it in ipairs(core:basket(NICK)) do
	if it.id == "iron" then gotIron = it.count end
	if it.id == "gold" then gotGold = it.count end
end
eq("обмен всех руд: железо", gotIron, 60)
eq("обмен всех руд: золото", gotGold, 14)

reset()
n, msg = core:exchangeAllOres(NICK)
eq("обмен всех руд впустую", n, 0)
check("обмен всех руд впустую: сообщение", msg:find("Нет руд") ~= nil, msg)

-- ------------------------------------------------------------- 6. корзина

reset()
netAdd("iron", 0, 1000)
rows[NICK] = { balance = 0, items = { { id = "iron", dmg = 0, label = "Железо", count = 50 } } }
eq("корзина: счётчик", core:basketCount(NICK), 50)
n, msg = core:takeFromBasket(NICK, "iron", 0, 20)
eq("забрать часть", n, 20)
eq("забрать часть: осталось", core:basket(NICK)[1].count, 30)
eq("забрать часть: пришло игроку", invCount("iron", 0), 20)

n, msg = core:takeFromBasket(NICK, "iron", 0, 999)
eq("забрать больше, чем есть", n, 30)
eq("корзина опустела", #core:basket(NICK), 0)

reset()
netAdd("iron", 0, 100) netAdd("gold", 0, 100)
rows[NICK] = { balance = 0, items = {
	{ id = "iron", dmg = 0, label = "Железо", count = 10 },
	{ id = "gold", dmg = 0, label = "Золото", count = 5 },
} }
n, msg = core:takeAll(NICK)
eq("забрать всё", n, 15)
eq("забрать всё: корзина пуста", #core:basket(NICK), 0)

reset()
n, msg = core:takeAll(NICK)
eq("забрать всё из пустой", n, 0)

-- --------------------------------------------------- 7. сколько стоит опрос

-- Наличие витрины: один опрос сети на всю категорию, а не по опросу на строку
reset()
netAdd("iron", 0, 300) netAdd("gold", 0, 40)
for i = 1, 300 do netAdd("musor" .. i, 0, i) end        -- сеть побольше
world.calls = {}
local list = core:sellList("Руда")
eq("витрина: опрос сети один", world.calls.getAvailableItems, 1)
eq("витрина: наличие железа", list[1].count, 300)
eq("витрина: наличие золота", list[2].count, 40)

-- вторая категория попадает в кеш и в МЭ не ходит
world.calls = {}
core:sellList("Книги")
eq("вторая категория: сети не касались", world.calls.getAvailableItems, nil)

-- после операции кеш сброшен: показанное должно сойтись с настоящим
rows[NICK] = { balance = 100000, items = {} }
core:buy(NICK, cfg.sell[1], 10)
world.calls = {}
list = core:sellList("Руда")
eq("после покупки опрос заново", world.calls.getAvailableItems, 1)
eq("после покупки наличие обновилось", list[1].count, 290)

-- Скупка: all() ровно по разу на занятый слот
reset()
invPut("iron", 0, 64) invPut("iron", 0, 64) invPut("gold", 0, 10)
world.calls = {}
core:buyList()
eq("скупка: getAllStacks один раз", world.calls.getAllStacks, 1)
eq("скупка: all() по разу на слот", world.calls.all, 3)
eq("скупка: количество у игрока", cfg.buy[1].count, 128)

-- Выдача: экспорт партиями по 64, лишних опросов сети нет
reset()
netAdd("iron", 0, 200)
rows[NICK] = { balance = 1000000, items = {} }
world.calls = {}
n = core:buy(NICK, cfg.sell[1], 130)
eq("выдача 130 штук", n, 130)
eq("выдача: партий по 64", world.calls.exportItem, 3)
eq("выдача: сеть заново не опрашивалась", world.calls.getAvailableItems, nil)

-- Одна операция - одна запись в базу
reset()
netAdd("iron", 0, 200)
rows[NICK] = { balance = 1000000, items = {} }
world.calls = {}
core:buy(NICK, cfg.sell[1], 5)
eq("покупка: одна запись в базу", world.calls.dbInsert, 1)

reset()
invPut("ironOre", 0, 150)
world.calls = {}
core:exchange(NICK, cfg.exchange[1], 2)
eq("обмен с остатком: одна запись в базу", world.calls.dbInsert, 1)

-- ------------------------------------------------- 8. чужие данные не текут

reset()
rows["Alice"] = { balance = 111, items = {} }
rows["Bob"] = { balance = 222, items = {} }
eq("баланс Алисы", core:balance("Alice"), 111)
eq("баланс Боба", core:balance("Bob"), 222)
core:forget()
eq("после forget данные перечитаны", core:balance("Alice"), 111)

-- ------------------------------------------------------------------ итог

print(string.format("Итого: %d ок, %d провалов", ok, fail))
os.exit(fail == 0 and 0 or 1)
