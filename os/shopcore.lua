-- shopcore - вся торговля: баланс, покупка, продажа, обмен, корзина.
--
-- Заменяет прежний shopService. Ни одного обращения к экрану: сюда приходит ник
-- и количество, отсюда уходит число и строка для показа. Поэтому логику
-- можно гонять без игры - чем и занят test/shoptest.lua.
--
-- Что изменилось против прежнего кода:
--
--   * данные игрока читаются из базы один раз за вход и пишутся один раз за
--     операцию. Раньше getPlayerData() шёл в базу на каждый чих, а exchange()
--     писал одну и ту же запись дважды подряд;
--   * обмен руд и обменник были двумя почти одинаковыми кусками по сорок
--     строк - теперь одна функция: у них разные конфиги, а не разная логика;
--   * складывание в корзину было выписано четыре раза - теперь basketAdd();
--   * количество проверяется на входе: целое, больше нуля. Раньше в логику
--     доезжало всё, что вернул tonumber, включая отрицательное и дробное;
--   * пополнение проверяло кратность ПОСЛЕ того, как забирало монеты из
--     инвентаря, и сообщало об ошибке уже постфактум. Теперь до;
--   * при обмене остаток, не влезший в целый курс, возвращается игроку в
--     корзину - раньше это делал только обменник, а обмен руд молча ронял
--     дробную часть в количество предмета.
--
-- Возврат у всех операций одинаковый: count, message, second. count равен
-- нулю, если ничего не произошло.

local shopcore = {}

local floor = math.floor

local C = {}
C.__index = C

-- ------------------------------------------------------------------ сборка

--- opt.db     - объект с select(clauses) и insert(key, value), как база
---              игрового компьютера
--- opt.io     - meio
--- opt.cfg    - таблица со списками: sell, buy, ore, exchange
--- opt.log    - функция записи в журнал (printD), необязательна
--- opt.name   - имя терминала для журнала
function shopcore.new(opt)
	local self = setmetatable({
		db   = opt.db,
		io   = opt.io,
		log  = opt.log or function() end,
		name = opt.name or "Shop",
		-- имена полей не должны совпадать с именами методов: self.buyCfg
		-- перекрыл бы C:buy, и покупка перестала бы вызываться
		sellCfg = opt.cfg.sell or {},
		buyCfg  = opt.cfg.buy or {},
		oreCfg  = opt.cfg.ore or {},
		exchCfg = opt.cfg.exchange or {},
	}, C)
	self:indexCategories()
	self:indexOres()
	return self
end

--- Конфиг из файла: тот же вид, что читал utils.readObjectFromFile.
function shopcore.readConfig(path)
	local fh = io.open(path, "rb")
	if not fh then return nil, "нет файла " .. path end
	local text = fh:read("*a")
	fh:close()
	local loader = rawget(_G, "loadstring") or load
	local chunk, err = loader("return " .. text, path)
	if not chunk then return nil, err end
	local ok, value = pcall(chunk)
	if not ok or type(value) ~= "table" then return nil, tostring(value) end
	return value
end

-- --------------------------------------------------------------- категории

--- Категории в том порядке, в каком они впервые встречаются в конфиге -
--- порядок задаёт тот, кто правит sellShop.cfg, а не сортировка.
function C:indexCategories()
	local order, byName = {}, {}
	for i = 1, #self.sellCfg do
		local it = self.sellCfg[i]
		local cat = it.category or "Прочее"
		local bucket = byName[cat]
		if not bucket then
			bucket = {}
			byName[cat] = bucket
			order[#order + 1] = cat
		end
		bucket[#bucket + 1] = it
	end
	self.catOrder, self.catItems = order, byName
end

--- Конфиги обмена по ключу предмета-источника: обмен всех руд разом искал
--- нужную строку вложенным перебором по всему списку.
function C:indexOres()
	local by = {}
	for i = 1, #self.oreCfg do
		local c = self.oreCfg[i]
		by[c.fromId .. "\0" .. floor(c.fromDmg or 0)] = c
	end
	self.oreByKey = by
end

function C:categories() return self.catOrder end

-- ------------------------------------------------------------------ витрины

--- Что магазин продаёт в этой категории, с наличием в МЭ.
function C:sellList(category)
	local list = self.catItems[category] or {}
	self.io:fillStock(list)
	return list
end

--- Что магазин скупает, с количеством у игрока в руках.
function C:buyList()
	self.io:fillUserStock(self.buyCfg)
	return self.buyCfg
end

function C:oreList() return self.oreCfg end
function C:exchangeList() return self.exchCfg end

-- ------------------------------------------------------------------ игрок

local function blank()
	return { balance = 0, items = {} }
end

--- Данные игрока. Держатся в памяти на время сеанса: база отвечает
--- перебором по всем записям, а за одну покупку данные нужны трижды.
function C:player(nick)
	if self.cachedNick == nick and self.cached then return self.cached end
	local ok, rows = pcall(self.db.select, self.db,
		{ { column = "ID", value = nick, operation = "=" } })
	local data = (ok and rows and rows[1]) or blank()
	data.balance = tonumber(data.balance) or 0
	data.items = data.items or {}
	self.cachedNick, self.cached = nick, data
	return data
end

function C:save(nick, data)
	self.cachedNick, self.cached = nick, data
	return pcall(self.db.insert, self.db, nick, data)
end

--- Забыть игрока: зовётся при уходе с PIM, чтобы следующий не увидел чужое.
function C:forget()
	self.cachedNick, self.cached = nil, nil
end

function C:balance(nick) return self:player(nick).balance end
function C:basket(nick) return self:player(nick).items end

function C:basketCount(nick)
	local items = self:player(nick).items
	local n = 0
	for i = 1, #items do n = n + (items[i].count or 0) end
	return n
end

--- Положить в корзину. Одинаковые предметы складываются в одну строку.
local function basketAdd(items, id, dmg, label, count)
	if count <= 0 then return end
	for i = 1, #items do
		local it = items[i]
		if it.id == id and it.dmg == dmg then
			it.count = it.count + count
			return
		end
	end
	items[#items + 1] = { id = id, dmg = dmg, label = label, count = count }
end

--- Количество на входе: целое больше нуля, иначе операции не было.
local function amount(n)
	n = tonumber(n)
	if not n then return 0 end
	n = floor(n)
	if n < 1 then return 0 end
	return n
end

-- ------------------------------------------------------------------ деньги

function C:moneyUnit() return self.io:unitOfMoney() end

function C:deposit(nick, sum)
	sum = amount(sum)
	local unit = self:moneyUnit()
	-- проверка до того, как трогать инвентарь: раньше монеты уже уходили,
	-- а сообщение об ошибке приходило следом
	if sum == 0 or sum % unit ~= 0 then
		return 0, "Ввод и вывод кратны " .. unit
	end
	local got = self.io:takeMoney(sum)
	if got <= 0 then return 0, "Нет монеток в инвентаре" end
	local p = self:player(nick)
	p.balance = p.balance + got
	self:save(nick, p)
	self.log(("%s: %s пополнил баланс на %d, стало %d"):format(self.name, nick, got, p.balance))
	return got, "Баланс пополнен на " .. got
end

function C:withdraw(nick, sum)
	sum = amount(sum)
	local unit = self:moneyUnit()
	if sum == 0 or sum % unit ~= 0 then
		return 0, "Ввод и вывод кратны " .. unit
	end
	local p = self:player(nick)
	if p.balance < sum then return 0, "Не хватает денег на счету" end
	local gave = self.io:giveMoney(sum)
	if gave <= 0 then
		if self.io:freeSlots() > 0 then return 0, "Нет монеток в магазине"
		else return 0, "Освободите инвентарь" end
	end
	p.balance = p.balance - gave
	self:save(nick, p)
	self.log(("%s: %s снял с баланса %d, стало %d"):format(self.name, nick, gave, p.balance))
	return gave, "С баланса списано " .. gave
end

-- ------------------------------------------------------------- купля-продажа

--- Игрок покупает у магазина. Списывается ровно за то, что удалось выдать.
function C:buy(nick, cfg, count)
	count = amount(count)
	if count == 0 then return 0, "Неверное количество" end
	local p = self:player(nick)
	local price = tonumber(cfg.price) or 0
	local afford = price > 0 and floor(p.balance / price) or count
	if afford < 1 then return 0, "Не хватает денег на счету" end
	if count > afford then count = afford end

	local got = self.io:give(cfg.id, cfg.dmg, count, cfg.nbt)
	if got <= 0 then
		if self.io:freeSlots() > 0 then return 0, "Товара нет в наличии"
		else return 0, "Освободите инвентарь" end
	end
	p.balance = p.balance - got * price
	self:save(nick, p)
	self.log(("%s: %s купил %s:%s x%d по %s, баланс %d")
		:format(self.name, nick, cfg.id, tostring(cfg.dmg), got, tostring(price), p.balance))
	return got, "Куплено " .. got .. " шт", "Списано " .. got * price
end

--- Игрок продаёт магазину.
function C:sell(nick, cfg, count)
	count = amount(count)
	if count == 0 then return 0, "Неверное количество" end
	local got = self.io:take(cfg.id, cfg.dmg, count)
	if got <= 0 then return 0, "Этого нет в инвентаре" end
	local price = tonumber(cfg.price) or 0
	local p = self:player(nick)
	p.balance = p.balance + got * price
	self:save(nick, p)
	self.log(("%s: %s продал %s:%s x%d по %s, баланс %d")
		:format(self.name, nick, cfg.id, tostring(cfg.dmg), got, tostring(price), p.balance))
	return got, "Продано " .. got .. " шт", "Начислено " .. got * price
end

-- ------------------------------------------------------------------ корзина

function C:takeFromBasket(nick, id, dmg, count)
	count = amount(count)
	if count == 0 then return 0, "Неверное количество" end
	local p = self:player(nick)
	for i = 1, #p.items do
		local it = p.items[i]
		if it.id == id and it.dmg == dmg then
			local want = count < it.count and count or it.count
			local gave = self.io:give(id, dmg, want)
			if gave <= 0 then
				if self.io:freeSlots() > 0 then return 0, "Этого нет в наличии"
				else return 0, "Освободите инвентарь" end
			end
			it.count = it.count - gave
			if it.count <= 0 then table.remove(p.items, i) end
			self:save(nick, p)
			self.log(("%s: %s забрал %s:%s x%d"):format(self.name, nick, id, tostring(dmg), gave))
			return gave, "Выдано " .. gave .. " шт"
		end
	end
	return 0, "Этого нет в корзине"
end

function C:takeAll(nick)
	local p = self:player(nick)
	local left, sum = {}, 0
	for i = 1, #p.items do
		local it = p.items[i]
		local gave = self.io:give(it.id, it.dmg, it.count)
		sum = sum + gave
		if gave > 0 then
			self.log(("%s: %s забрал %s:%s x%d")
				:format(self.name, nick, it.id, tostring(it.dmg), gave))
		end
		it.count = it.count - gave
		if it.count > 0 then left[#left + 1] = it end
	end
	p.items = left
	self:save(nick, p)
	if sum == 0 then
		if self.io:freeSlots() > 0 then return 0, "Корзина пуста"
		else return 0, "Освободите инвентарь" end
	end
	return sum, "Выдано " .. sum .. " шт"
end

-- ------------------------------------------------------------------ обмен

--- Один обмен по строке конфига. Работает и для обмена руд, и для обменника:
--- у них отличаются только конфиги, а счёт один и тот же.
---
--- count - сколько раз обменять, то есть сколько получить курсов. Берётся
--- count * fromCount предметов; остаток, не составивший целый курс, уходит
--- игроку в корзину, а не пропадает.
function C:exchange(nick, cfg, count)
	count = amount(count)
	if count == 0 then return 0, "Неверное количество" end
	local per = floor(tonumber(cfg.fromCount) or 1)
	if per < 1 then per = 1 end
	local toPer = floor(tonumber(cfg.toCount) or 1)

	local took = self.io:take(cfg.fromId, cfg.fromDmg, count * per)
	if took <= 0 then return 0, "Этого нет в инвентаре" end

	local deals = floor(took / per)
	local rest = took - deals * per

	local p = self:player(nick)
	if deals > 0 then
		basketAdd(p.items, cfg.toId, cfg.toDmg, cfg.toLabel, deals * toPer)
	end
	if rest > 0 then
		-- остаток возвращаем, чтобы обмен не съедал предметы без выхлопа
		basketAdd(p.items, cfg.fromId, cfg.fromDmg, cfg.fromLabel, rest)
	end
	self:save(nick, p)

	if deals == 0 then
		return 0, "Мало предметов: курс " .. per .. " к " .. toPer, "Остаток в корзине"
	end
	self.log(("%s: %s обменял %s:%s x%d на %s:%s x%d")
		:format(self.name, nick, cfg.fromId, tostring(cfg.fromDmg), deals * per,
		        cfg.toId, tostring(cfg.toDmg), deals * toPer))
	return deals * toPer,
	       "Получено " .. deals * toPer .. " шт",
	       rest > 0 and ("Остаток " .. rest .. " и товар в корзине") or "Заберите из корзины"
end

--- Обменять все руды из инвентаря разом. Слоты обходятся один раз на все
--- виды сразу, а не по разу на вид.
function C:exchangeAllOres(nick)
	local kinds = {}
	for i = 1, #self.oreCfg do
		local c = self.oreCfg[i]
		kinds[i] = { id = c.fromId, dmg = c.fromDmg }
	end
	local taken = self.io:takeAny(kinds)
	if #taken == 0 then return 0, "Нет руд в инвентаре" end

	local p = self:player(nick)
	local sum = 0
	for i = 1, #taken do
		local got = taken[i]
		local cfg = self.oreByKey[got.id .. "\0" .. floor(got.dmg or 0)]
		if cfg then
			local per = floor(tonumber(cfg.fromCount) or 1)
			if per < 1 then per = 1 end
			local toPer = floor(tonumber(cfg.toCount) or 1)
			local deals = floor(got.count / per)
			local rest = got.count - deals * per
			sum = sum + deals * per
			if deals > 0 then
				basketAdd(p.items, cfg.toId, cfg.toDmg, cfg.toLabel, deals * toPer)
				self.log(("%s: %s обменял %s:%s x%d по курсу %d к %d")
					:format(self.name, nick, cfg.fromId, tostring(cfg.fromDmg),
					        deals * per, per, toPer))
			end
			if rest > 0 then
				basketAdd(p.items, cfg.fromId, cfg.fromDmg, cfg.fromLabel, rest)
			end
		else
			-- конфиг успели поменять между опросом и обменом: вернём как есть
			basketAdd(p.items, got.id, got.dmg, got.id, got.count)
		end
	end
	self:save(nick, p)
	if sum == 0 then return 0, "Нет руд в инвентаре" end
	return sum, "Обменяно " .. sum .. " руд", "Заберите из корзины"
end

return shopcore
