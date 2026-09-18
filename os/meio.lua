-- meio - выдача и приём предметов: МЭ-сеть с одной стороны, PIM с другой.
--
-- Заменяет прежний ItemUtils. Вызовы к компонентам оставлены ровно те же - проверить
-- их можно только в игре, и менять работающее обращение к моду ради красоты
-- смысла нет. Переделано то, сколько раз они зовутся:
--
--   * getAvailableItems() отдаёт весь состав сети, на большой базе это
--     тысячи записей. Раньше он вызывался внутри цикла повторов выдачи -
--     на каждую неудачную попытку заново. Теперь один раз на операцию;
--   * сверка наличия шла вложенным перебором: каждый предмет витрины против
--     каждой записи сети. 50 x 10000 это полмиллиона сравнений на открытие
--     категории. Теперь состав сети раскладывается в таблицу по ключу, и
--     витрина проходится один раз;
--   * getAllStacks() отдаёт слоты PIM обёртками, и у каждой надо звать
--     all(). Раньше all() звался трижды на слот внутри цикла по витрине,
--     то есть #витрины x #слотов x 3 вызова. Теперь по разу на слот;
--   * состав сети кешируется на несколько секунд: переход между категориями
--     магазина больше не опрашивает МЭ заново.
--
-- Деньги - четыре предмета из компонента database, номиналы 1к, 10к, 100к
-- и 1кк. Раньше на каждый номинал был свой кусок кода, теперь это таблица
-- и один проход по ней.

local meio = {}

local floor, min = math.floor, math.min

local M = {}
M.__index = M

--- SLOTS - сколько слотов у PIM, CACHE - на сколько секунд держать состав
--- сети. Кеш нужен, чтобы открытие категорий не било в МЭ каждый раз, но
--- после любой своей операции он сбрасывается: показанное количество должно
--- сойтись с тем, что действительно выдалось.
function meio.new(component, computer, opt)
	opt = opt or {}
	return setmetatable({
		component = component,
		computer = computer,
		slots = opt.slots or 40,
		ttl = opt.cacheSeconds or 5,
		side = opt.side or "UP",
		into = opt.into or "DOWN",
		cash = {},          -- номиналы, по убыванию
		netAt = -1,
	}, M)
end

function M:me() return self.component.me_interface end
function M:pim() return self.component.pim end

-- ------------------------------------------------------------------ ключи

local function keyOf(id, dmg) return id .. "\0" .. floor(tonumber(dmg) or 0) end
local function nbtKeyOf(id, nbt) return id .. "\1" .. nbt end
meio.keyOf, meio.nbtKeyOf = keyOf, nbtKeyOf

-- ------------------------------------------------------------------ деньги

--- Номиналы из компонента database: слот i несёт предмет, стоящий money[i].
--- Порядок по убыванию, чтобы размен шёл с крупных.
function M:setCurrency(list)
	local cash = {}
	for i = 1, #list do
		local c = list[i]
		if c.item and c.item.name then
			cash[#cash + 1] = { name = c.item.name, damage = c.item.damage or 0, money = c.money }
		end
	end
	table.sort(cash, function(a, b) return a.money > b.money end)
	self.cash = cash
	self.unit = #cash > 0 and cash[#cash].money or 1000
	return self
end

--- Шаг, кратно которому идёт ввод и вывод денег: самый мелкий номинал.
function M:unitOfMoney() return self.unit or 1000 end

-- --------------------------------------------------------------- состав сети

--- Состав МЭ одним запросом, разложенный по ключам. Держится ttl секунд:
--- переключение категорий в магазине попадает в кеш, любая своя операция
--- его сбрасывает.
function M:network(force)
	local now = self.computer.uptime()
	if not force and self.net and (now - self.netAt) < self.ttl then return self.net end
	local ok, raw = pcall(self:me().getAvailableItems)
	if not ok or type(raw) ~= "table" then
		self.net, self.netAt = self.net or { byKey = {}, byNbt = {}, n = 0 }, now
		self.netError = ok and "МЭ вернула не список" or tostring(raw)
		return self.net
	end
	self.netError = nil
	local byKey, byNbt, n = {}, {}, 0
	for i = 1, #raw do
		local it = raw[i]
		local f = it.fingerprint
		if f and f.id then
			n = n + 1
			local size = it.size or 0
			local k = keyOf(f.id, f.dmg)
			byKey[k] = (byKey[k] or 0) + size
			if f.nbt_hash then
				local nk = nbtKeyOf(f.id, f.nbt_hash)
				byNbt[nk] = (byNbt[nk] or 0) + size
				-- отпечаток с nbt нужен целиком: экспорт по id и dmg такой
				-- предмет не находит
				byNbt[nk .. "\2fp"] = f
			end
		end
	end
	self.net, self.netAt = { byKey = byKey, byNbt = byNbt, n = n }, now
	return self.net
end

function M:invalidate() self.netAt = -1 end

--- Сколько такого предмета лежит в сети. nbt задан - считается по нему.
function M:stock(id, dmg, nbt, net)
	net = net or self:network()
	if nbt then return net.byNbt[nbtKeyOf(id, nbt)] or 0 end
	return net.byKey[keyOf(id, dmg)] or 0
end

--- Проставить count всем предметам списка одним проходом по составу сети.
function M:fillStock(items, force)
	local net = self:network(force)
	for i = 1, #items do
		local it = items[i]
		it.count = self:stock(it.id, it.dmg, it.nbt, net)
	end
	return items
end

-- ------------------------------------------------------------------ PIM

--- Слоты игрока одним запросом: all() зовётся по разу на слот, а не по разу
--- на каждое сравнение. Возвращает массив по номерам слотов.
function M:stacks()
	local ok, all = pcall(self:pim().getAllStacks)
	if not ok or type(all) ~= "table" then return {} end
	local out = {}
	for i = 1, self.slots do
		local s = all[i]
		if s then
			local got, data = pcall(s.all, s)
			if got and type(data) == "table" and data.id then out[i] = data end
		end
	end
	return out
end

--- Сколько такого предмета у игрока в руках, одним проходом по слотам.
function M:fillUserStock(items)
	local st = self:stacks()
	local byKey = {}
	for _, d in pairs(st) do
		local k = keyOf(d.id, d.dmg)
		byKey[k] = (byKey[k] or 0) + (d.qty or 0)
	end
	for i = 1, #items do
		local it = items[i]
		it.count = byKey[keyOf(it.id, it.dmg)] or 0
	end
	return items
end

function M:freeSlots()
	local st = self:stacks()
	local n = 0
	for i = 1, self.slots do if not st[i] then n = n + 1 end end
	return n
end

-- ------------------------------------------------------------------ выдача

--- Выдать предмет игроку. Возвращает сколько реально ушло.
---
--- Экспорт идёт партиями по 64: столько влезает в стопку, а мод отдаёт
--- размер каждой партии. Если прямой экспорт по id и dmg ничего не дал,
--- один раз берём состав сети и ищем полный отпечаток - у предметов с nbt
--- короткий отпечаток не срабатывает.
function M:give(id, dmg, count, nbt)
	count = floor(count or 0)
	if count < 1 then return 0 end
	local me = self:me()
	local side = self.side
	local sum = 0
	local fp = nbt and { id = id, dmg = dmg, nbt_hash = nbt } or { id = id, dmg = dmg }
	local looked = false

	while sum < count do
		local batch = min(64, count - sum)
		local ok, res = pcall(me.exportItem, fp, side, batch)
		local moved = (ok and type(res) == "table") and (res.size or 0) or 0
		if moved > 0 then
			sum = sum + moved
		elseif not looked and not nbt then
			-- один раз: найти настоящий отпечаток в составе сети
			looked = true
			local found = self:lookupFingerprint(id, dmg)
			if not found then break end
			fp = found
		else
			break
		end
	end
	if sum > 0 then self:invalidate() end
	return sum
end

--- Полный отпечаток предмета из состава сети. Дороже прямого экспорта,
--- поэтому зовётся только когда тот не сработал.
function M:lookupFingerprint(id, dmg)
	local ok, raw = pcall(self:me().getAvailableItems)
	if not ok or type(raw) ~= "table" then return nil end
	dmg = floor(tonumber(dmg) or 0)
	for i = 1, #raw do
		local it = raw[i]
		local f = it.fingerprint
		if f and f.id == id and (f.dmg or 0) == dmg and (it.size or 0) > 0 then return f end
	end
	return nil
end

--- Забрать предмет у игрока. Предметы с nbt не берутся: их цену магазин не
--- знает, а по id и dmg зачарованная книга неотличима от пустой.
function M:take(id, dmg, count)
	count = floor(count or 0)
	if count < 1 then return 0 end
	local pim = self:pim()
	local sum = 0
	for i = 1, self.slots do
		local ok, item = pcall(pim.getStackInSlot, i)
		if ok and item and not item.nbt_hash and item.id == id and item.dmg == dmg then
			local ok2, moved = pcall(pim.pushItem, self.into, i, count - sum)
			sum = sum + ((ok2 and moved) or 0)
			if sum >= count then break end
		end
	end
	if sum > 0 then self:invalidate() end
	return sum
end

--- Забрать всё, что подходит под любой из списка. Слоты обходятся один раз
--- на все виды, а не по разу на вид.
function M:takeAny(kinds)
	local want = {}
	for i = 1, #kinds do want[keyOf(kinds[i].id, kinds[i].dmg)] = true end
	local pim = self:pim()
	local got, out = {}, {}
	for i = 1, self.slots do
		local ok, item = pcall(pim.getStackInSlot, i)
		if ok and item and not item.nbt_hash then
			local k = keyOf(item.id, item.dmg)
			if want[k] then
				local ok2, moved = pcall(pim.pushItem, self.into, i, item.count or 64)
				moved = (ok2 and moved) or 0
				if moved > 0 then
					local e = got[k]
					if e then e.count = e.count + moved
					else
						e = { id = item.id, dmg = item.dmg, count = moved }
						got[k] = e
						out[#out + 1] = e
					end
				end
			end
		end
	end
	if #out > 0 then self:invalidate() end
	return out
end

-- ------------------------------------------------------------ деньги туда-сюда

--- Выдать денег на сумму money. Размен с крупных номиналов; если крупного
--- в сети нет, остаток добирается мелким. Возвращает выданную сумму.
function M:giveMoney(money)
	money = floor(money or 0)
	local unit = self:unitOfMoney()
	if money < unit or money % unit ~= 0 then return 0 end
	local left, sum = money, 0
	for i = 1, #self.cash do
		local c = self.cash[i]
		local want = floor(left / c.money)
		if want > 0 then
			local gave = self:give(c.name, c.damage, want)
			sum = sum + gave * c.money
			left = left - gave * c.money
		end
	end
	return sum
end

--- Забрать у игрока денег на сумму money. Возвращает принятую сумму.
function M:takeMoney(money)
	money = floor(money or 0)
	local unit = self:unitOfMoney()
	if money < unit or money % unit ~= 0 then return 0 end
	local left, sum = money, 0
	for i = 1, #self.cash do
		local c = self.cash[i]
		local want = floor(left / c.money)
		if want > 0 then
			local took = self:take(c.name, c.damage, want)
			sum = sum + took * c.money
			left = left - took * c.money
		end
	end
	return sum
end

--- Сколько монет номинала лежит в сети - для отчёта администратору.
function M:cashInStorage()
	local net = self:network()
	local out = {}
	for i = 1, #self.cash do
		local c = self.cash[i]
		out[i] = { money = c.money, count = net.byKey[keyOf(c.name, c.damage)] or 0 }
	end
	return out
end

return meio
