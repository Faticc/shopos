-- storage - МЭ-сеть магазина и PIM игрока.
--
-- Вызовы к модам те же, что работали на прежней машине: МЭ-интерфейс
-- отдаёт состав через getAvailableItems и выгружает через exportItem в
-- сторону PIM, PIM отдаёт слоты через getStackInSlot и сталкивает стопку в
-- МЭ через pushItem. PIM стоит на МЭ-интерфейсе: выдача идёт вверх,
-- приём - вниз. Стороны настраиваются в cfg/shop.cfg.

local component = component

local floor, min = math.floor, math.min

local storage = {}

local S = {}
S.__index = S

function storage.new(cfg)
	return setmetatable({
		up = cfg.exportSide or "UP",
		down = cfg.pushSide or "DOWN",
		slots = cfg.slots or 36,
	}, S)
end

function S:me() return component.me_interface end
function S:pim() return component.pim end

--- Что есть в МЭ: список { id, dmg, size, nbt }. Стопки с NBT (броня и
--- инструменты с зарядом, зачарованное) идут отдельными записями со своим
--- nbt_hash: короткий отпечаток id+dmg их из МЭ не достаёт, выдавать их
--- можно только по полному.
function S:scan()
	local me = self:me()
	if not me then return nil, "нет МЭ-интерфейса" end
	local ok, raw = pcall(me.getAvailableItems)
	if not ok or type(raw) ~= "table" then return nil, "МЭ не отвечает" end
	local byKey, out = {}, {}
	for i = 1, #raw do
		local it = raw[i]
		local f = it.fingerprint
		if f and f.id and (it.size or 0) > 0 then
			local dmg = floor(f.dmg or 0)
			local k = f.id .. "\0" .. dmg .. "\0" .. (f.nbt_hash or "")
			local e = byKey[k]
			if e then e.size = e.size + it.size
			else
				e = { id = f.id, dmg = dmg, size = it.size, nbt = f.nbt_hash }
				byKey[k] = e
				out[#out + 1] = e
			end
		end
	end
	return out
end

local function slot(it)
	if type(it) ~= "table" then return nil end
	-- getAllStacks по умолчанию отдаёт обёртки, данные у них в all()
	if not it.id and type(it.all) == "function" then
		local ok, d = pcall(it.all, it)
		it = ok and d or nil
	end
	if type(it) ~= "table" or not it.id then return nil end
	return { id = it.id, dmg = floor(it.dmg or 0), qty = it.qty or it.count or 0, nbt = it.nbt_hash }
end

--- Ключ предмета без NBT для counts.
function storage.tag(id, dmg) return id .. "\0" .. floor(dmg or 0) end

--- Сколько чего без NBT лежит в МЭ: tag -> штук; nil - МЭ не ответила.
--- Этим пополнение проверяет, что в сеть пришло именно то, что ушло из
--- инвентаря: между взглядом на слот и pushItem проходит тик, и игрок
--- успевает подложить в слот другой стак.
function S:counts()
	local me = self:me()
	if not me then return nil end
	local ok, raw = pcall(me.getAvailableItems)
	if not ok or type(raw) ~= "table" then return nil end
	local out = {}
	for i = 1, #raw do
		local f = raw[i].fingerprint
		if f and f.id and not f.nbt_hash then
			local k = storage.tag(f.id, f.dmg)
			out[k] = (out[k] or 0) + (raw[i].size or 0)
		end
	end
	return out
end

--- Слоты игрока: номер -> { id, dmg, qty, nbt }. Весь инвентарь одним
--- вызовом getAllStacks(false) - вызов к PIM стоит тик, и по слоту на
--- вызов это почти две секунды на 36 слотов. Не вышло - по одному.
function S:slotsOfPlayer()
	local pim = self:pim()
	if not pim then return {} end
	local out = {}
	local ok, all = pcall(pim.getAllStacks, false)
	if ok and type(all) == "table" then
		for i = 1, self.slots do out[i] = slot(all[i]) end
		return out
	end
	for i = 1, self.slots do
		local got, it = pcall(pim.getStackInSlot, i)
		if got then out[i] = slot(it) end
	end
	return out
end

function S:freeSlots()
	local st, n = self:slotsOfPlayer(), 0
	for i = 1, self.slots do if not st[i] then n = n + 1 end end
	return n
end

--- Выдать count штук из МЭ в PIM. Возвращает, сколько ушло на самом деле:
--- инвентарь может кончиться посреди выдачи. nbt - hash из состава сети:
--- тогда уходит ровно этот экземпляр.
---
--- Выдача идёт в слоты по номерам (intoSlot у exportItem): без номера МЭ
--- кладёт куда влезет, и лишнее уезжает в слоты брони - PIM отдаёт весь
--- инвентарь игрока, 36 слотов и ещё 4 брони. Сначала докладываются
--- неполные стопки того же предмета, потом пустые слоты.
function S:give(id, dmg, count, nbt)
	local me = self:me()
	if not me then return 0 end
	local fp = { id = id, dmg = dmg, nbt_hash = nbt }
	local slots = self:slotsOfPlayer()
	local order = {}
	if not nbt then
		for s = 1, self.slots do
			local it = slots[s]
			if it and it.id == id and it.dmg == dmg and not it.nbt and it.qty < 64 then order[#order + 1] = s end
		end
	end
	for s = 1, self.slots do
		if not slots[s] then order[#order + 1] = s end
	end
	local sent = 0
	for _, s in ipairs(order) do
		if sent >= count then break end
		local ok, res = pcall(me.exportItem, fp, self.up, min(64, count - sent), s)
		local n = (ok and type(res) == "table") and (res.size or 0) or 0
		sent = sent + n
		-- в пустой слот не легло ничего - товар в МЭ кончился
		if n <= 0 and not slots[s] then break end
	end
	return sent
end

--- Столкнуть стопку из слота игрока в МЭ. Возвращает, сколько ушло.
function S:push(slot, n)
	local pim = self:pim()
	if not pim then return 0 end
	local ok, got = pcall(pim.pushItem, self.down, slot, n)
	if ok and type(got) == "number" and got > 0 then return got end
	return 0
end

return storage
