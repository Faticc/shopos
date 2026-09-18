-- shop - Legend Shop: витрина с иконками поверх МЭ-сети и PIM.
--
--   shop [каталог] [--demo] [--config путь] [--name имя]
--
-- Переписанная версия прежнего магазина. Было: forms.lua, список строк
-- 80x25, форма пересоздавалась на каждое нажатие. Стало: иконки предметов,
-- экраны живут, перерисовывается только изменившееся.
--
-- Раскладка файлов:
--   oci3.lua      чтение каталога иконок
--   paint.lua     рисование иконок и текста, склейка вызовов gpu
--   icons.lua     ключ предмета -> иконка, кэш ячеек в памяти
--   ui.lua        экраны, сетка, кнопки, диалоги, цикл событий
--   meio.lua      МЭ и PIM: выдача, приём, деньги
--   shopcore.lua  баланс, покупка, продажа, обмен, корзина
--   shop.lua      этот файл: экраны и запуск
--
-- Всё, что стоит дорого, делается один раз на старте: каталог иконок
-- разбирается, нужные 185 иконок оседают в памяти, индекс отпускается.
-- Дальше магазин не читает диск вообще.
--
-- Оформление. Экран поделён на три полосы: шапка в две строки, поле с
-- иконками на чёрном и подвал в четыре. Всё, что не иконка, живёт на сером,
-- всё, что иконка, - на чёрном: так картинки читаются как в инвентаре, а
-- обвязка не спорит с ними за внимание. Цветом помечено только значимое -
-- деньги золотым, наличие зелёным, отказ красным.

local component = require("component")
local computer = require("computer")
local event = require("event")
local unicode = require("unicode")

-- Под ShopOS require ищет в /os и на package.path не смотрит вовсе. Строка
-- нужна двум другим случаям: запуску под OpenOS и прогону на ПК.
package.path = "/os/?.lua;/home/?.lua;shopos/os/?.lua;./?.lua;" .. package.path

local ui       = require("ui")
local icons    = require("icons")
local meio     = require("meio")
local shopcore = require("shopcore")

local T = ui.theme

-- ------------------------------------------------------------------ разбор

local DEMO = false
local ARGS = { ... }

-- Пути зависят от того, где магазин запущен. Под ShopOS всё лежит в корне
-- диска, под OpenOS - в /home. Определяем по наличию своей файловой системы,
-- а не по флагу: один и тот же файл должен работать там и там без правок.
local SHOPOS = false
do
	local ok, rootfs = pcall(require, "root")
	SHOPOS = ok and rootfs ~= nil
end

local CATALOG  = SHOPOS and "/data/icons.bin" or "/home/shop16.bin"
local CFGDIR   = SHOPOS and "/cfg" or "/home/config"
local ICONCFG  = CFGDIR .. "/icons.cfg"
local SHOPNAME = "Shop1"
local TITLE    = "LEGEND SHOP"

-- Ники, которые не убирать из списка доступа к компьютеру при выходе с PIM.
-- Пусто по умолчанию; заполняется из /cfg/shop.cfg.
local KEEP_USER = {}

do
	local a = ARGS
	local i = 1
	while a[i] do
		local v = tostring(a[i])
		if v == "--demo" then DEMO = true
		elseif v == "--config" then i = i + 1 CFGDIR = a[i] or CFGDIR ICONCFG = CFGDIR .. "/icons.cfg"
		elseif v == "--icons" then i = i + 1 ICONCFG = a[i] or ICONCFG
		elseif v == "--name" then i = i + 1 SHOPNAME = a[i] or SHOPNAME
		elseif v:sub(1, 2) ~= "--" then CATALOG = v end
		i = i + 1
	end
end

-- Ctrl+C в магазине ни к чему: программа живёт под лаунчером и должна
-- переживать всё, кроме выключения. В демо-режиме оставляем выход.
if not DEMO then event.shouldInterrupt = function() return false end end

-- ----------------------------------------------------------- окружение сборки

--- Библиотеки игрового компьютера подключаются мягко: без них магазин
--- должен хотя бы сказать, чего не хватает, а не упасть на первой строке.
local function soft(name)
	local ok, m = pcall(require, name)
	if ok then return m end
	return nil
end

soft("dlog")
soft("database")

local printD = rawget(_G, "printD") or function() end
local utils = soft("utils")

local function readConfig(name)
	local path = CFGDIR .. "/" .. name
	if utils and utils.readObjectFromFile then
		local ok, v = pcall(utils.readObjectFromFile, path)
		if ok and type(v) == "table" then return v end
	end
	return shopcore.readConfig(path)
end

--- База игроков. На машине её даёт библиотека компьютера глобальным
--- классом (имя класса - её, менять нельзя), в прогоне без игры - заглушка
--- в памяти: логику торговли она обслуживает полностью.
local function openDatabase()
	-- под ShopOS база своя: файл на игрока, чтение и запись не зависят от
	-- того, сколько игроков накопилось
	local okdb, dbmod = pcall(require, "db")
	local okroot, rootfs = pcall(require, "root")
	if okdb and okroot and dbmod and rootfs then
		local ok, store = pcall(dbmod.open, rootfs, "/var/players")
		if ok and store then return store, false end
	end
	-- под OpenOS - та, что стоит на машине
	local DB = rawget(_G, "DurexDatabase")
	if DB then
		local ok, store = pcall(DB.new, DB, "USERS")
		if ok and store then return store, false end
	end
	-- совсем без базы магазин тоже должен подняться и сказать об этом
	local mem = {}
	return {
		select = function(_, clauses)
			local key = clauses and clauses[1] and clauses[1].value
			local row = key and mem[key]
			return row and { row } or {}
		end,
		insert = function(_, key, value) mem[key] = value end,
		forget = function() end,
	}, true
end

-- ------------------------------------------------------------------ сборка

local gpu = component.gpu
local U = ui.new(gpu, unicode, event, computer)

--- Ранняя надпись на чёрном: разбор каталога занимает пару секунд, и всё
--- это время экран не должен стоять пустым.
local function boot(line)
	U.p:text(3, 2, U.p:pad(line, U.W - 4), T.dim, T.bg)
end
U:clear()
boot(TITLE .. ": подъём каталога иконок...")

-- Настройки магазина: название, имя терминала, каталог иконок, кому
-- оставлять доступ к машине. Файла нет - работают значения по умолчанию.
do
	local st = readConfig("shop.cfg")
	if type(st) == "table" then
		TITLE = st.title or TITLE
		SHOPNAME = st.terminal or SHOPNAME
		if st.catalog and #ARGS == 0 then CATALOG = st.catalog end
		if type(st.keepUsers) == "table" then
			for _, who in ipairs(st.keepUsers) do KEEP_USER[who] = true end
		end
	end
end

local cfg = {
	sell     = readConfig("sellShop.cfg") or {},
	buy      = readConfig("buyShop.cfg") or {},
	ore      = readConfig("oreExchanger.cfg") or {},
	exchange = readConfig("exchanger.cfg") or {},
}

local IC = icons.open(CATALOG, ICONCFG)

--- Все ключи, какие магазин вообще может показать: витрины, скупка, оба
--- обменника с обеих сторон. Список закрытый, поэтому иконки поднимаются
--- разом и больше не ищутся.
local function allKeys()
	local keys, seen = {}, {}
	local function add(id, dmg)
		if not id then return end
		local k = icons.key(id, dmg)
		if not seen[k] then seen[k] = true keys[#keys + 1] = k end
	end
	for _, it in ipairs(cfg.sell) do add(it.id, it.dmg) end
	for _, it in ipairs(cfg.buy) do add(it.id, it.dmg) end
	for _, list in ipairs({ cfg.ore, cfg.exchange }) do
		for _, it in ipairs(list) do add(it.fromId, it.fromDmg) add(it.toId, it.toDmg) end
	end
	return keys
end

local iconFound, iconTotal = 0, 0
if IC.ok then
	iconFound, iconTotal = IC:resolve(allKeys())
	boot(("каталог: %d иконок из %d, %dx%d ячеек"):format(iconFound, iconTotal, IC.w, IC.h))
else
	boot("каталога иконок нет, работаю без картинок")
end

local db, dbFake = openDatabase()
local IO = meio.new(component, computer)
local core = shopcore.new({ db = db, io = IO, log = printD, name = SHOPNAME, cfg = cfg })

--- Деньги: четыре предмета из компонента database, слоты 1..4.
do
	local list = {}
	local ok, dbc = pcall(function() return component.database end)
	if ok and dbc then
		local money = { 1000, 10000, 100000, 1000000 }
		for i = 1, 4 do
			local got, item = pcall(dbc.get, i)
			if got and item then list[#list + 1] = { item = item, money = money[i] } end
		end
	end
	IO:setCurrency(list)
end

-- ------------------------------------------------------------------ состояние

local nick = nil
local screens = {}
local short, money = ui.short, ui.money

local function icoKey(id, dmg) return icons.key(id, dmg) end

-- --------------------------------------------------------------- оформление

local BAR = "\226\150\140"            -- ▌ метка раздела

--- Разрядка: между буквами вставляется пробел. Другого способа выделить
--- строку на текстовом экране нет - ни жирного, ни кегля тут не бывает.
--- Считается через unicode, а не по байтам: заголовки русские.
local function spaced(text, gap)
	local out = {}
	for i = 1, unicode.len(text) do out[i] = unicode.sub(text, i, i) end
	return table.concat(out, gap or " ")
end

--- Заголовок раздела: цветная метка и слово в разрядку.
local function section(s, x, y, w, text, colour)
	return s:label(x, y, w, BAR .. " " .. spaced(text),
	               { fg = colour or T.accent, bg = T.bg })
end

--- Шапка и подвал у всех торговых экранов одинаковы. Шапка - две строки:
--- название магазина с разделом, справа игрок с балансом. Подвал - четыре:
--- что выбрано, подробности, кнопки, подсказки клавиш.
local function chrome(s, title)
	local w, h = U.W, U.H
	s.bg = T.bg

	s:panel(1, 1, w, 2, { bg = T.surface })
	s:label(3, 1, 18, BAR .. " " .. TITLE, { fg = T.accent, bg = T.surface })
	s.titleLabel = s:label(24, 1, w - 60, title, { fg = T.white, bg = T.surface })
	s.whoLabel = s:label(w - 42, 1, 40, "", { align = "right", fg = T.text, bg = T.surface })
	s.moneyLabel = s:label(w - 42, 2, 40, "", { align = "right", fg = T.gold, bg = T.surface })

	s.nameLabel = s:label(3, h - 3, w - 26, "", { fg = T.white, bg = T.bg })
	s.infoLabel = s:label(3, h - 2, w - 26, "", { fg = T.dim, bg = T.bg })
	s.tagLabel = s:label(w - 24, h - 3, 22, "", { align = "right", fg = T.gold, bg = T.bg })

	s:panel(1, h - 1, w, 2, { bg = T.surface })
	s.hintLabel = s:label(3, h, w - 4, "", { fg = T.mute, bg = T.surface })

	--- Обновить игрока и баланс в шапке. Зовётся после каждой операции и
	--- трогает две строки, а не экран.
	function s:refreshWho()
		if not nick then
			self.whoLabel:set("")
			self.moneyLabel:set("")
			return
		end
		self.whoLabel:set(nick .. "  ")
		self.moneyLabel:set(money(core:balance(nick)) .. " $  ")
	end
	function s:say(name, info, tag)
		self.nameLabel:set(name or "")
		self.infoLabel:set(info or "")
		self.tagLabel:set(tag or "")
	end
	return s
end

--- Кнопки подвала: слева направо, главное действие первым и бирюзовым.
local function bar(s, list)
	local y, x = U.H - 1, 3
	local out = {}
	for i = 1, #list do
		local b = list[i]
		local wide = b.w or 16
		out[i] = s:button(x, y, wide, 1, b.text, b.onClick, { kind = b.kind or "normal" })
		x = x + wide + 2
	end
	return out
end

-- ------------------------------------------------------------------ диалоги

local function note(text, second, after, bad)
	U:note(text, second, after, 4, bad)
end

--- Показать исход операции и обновить экран, с которого её позвали.
--- count равен нулю - значит, не вышло, и полоса диалога будет красной.
local function result(s, count, message, second)
	note(message, second, function()
		if s.reload then s:reload() end
		s:refreshWho()
		s:flush()
	end, (count or 0) == 0)
end

--- Несколько товаров вразбивку - для полосы-витрины на пустых местах.
--- Берётся каждый девятый с иконкой, чтобы в полосе не оказался один ряд
--- одинаковых станков.
local function showcaseTiles(n)
	local out, seen = {}, 0
	for _, it in ipairs(cfg.sell) do
		local key = icoKey(it.id, it.dmg)
		if IC:has(key) then
			seen = seen + 1
			if seen % 9 == 1 then
				out[#out + 1] = { key = key, title = it.label,
				                  sub = money(it.price) .. " $", subFg = T.gold }
				if #out >= n then break end
			end
		end
	end
	return out
end

-- --------------------------------------------------------------- экран блока

--- Экран ожидания. Пока на PIM никто не встал, магазин ничего не показывает
--- и ничего не спрашивает. Полоса иконок из каталога внизу - чтобы витрина
--- была видна ещё до входа и было понятно, куда попал.
local function lockScreen()
	local s = U:screen("lock")
	local w, h = U.W, U.H
	s.bg = T.bg

	-- весь блок ставится по середине экрана целиком, а не каждая часть
	-- по отдельности: полоса названия, приглашение и витрина считаются
	-- одним куском высотой blockH
	local stripH = (IC.ok and h >= 30) and (IC.h + 2 + 2) or 0
	local blockH = 3 + 2 + 2 + stripH
	local mid = math.floor((h - blockH) / 2) + 4

	local wordmark = spaced(TITLE, "  ")
	s:panel(1, mid - 4, w, 3, { bg = T.accent })
	s:label(2, mid - 3, w - 2, wordmark, { align = "center", fg = T.ink, bg = T.accent })
	s:label(2, mid, w - 2, "Встаньте на PIM, чтобы войти",
	        { align = "center", fg = T.white, bg = T.bg })
	s:label(2, mid + 1, w - 2, "покупка · продажа · обмен · корзина",
	        { align = "center", fg = T.dim, bg = T.bg })

	-- витрина одной полосой: несколько иконок из тех, что уже в памяти
	local strip
	if IC.ok and h >= 30 then
		strip = s:grid(2, mid + 3, w - 2, IC.h + 2, IC, { center = true })
		strip.rows = 1
		strip.h = strip.th
	end

	s:panel(1, h - 1, w, 2, { bg = T.surface })
	local st = s:label(3, h, w - 4, "", { fg = T.mute, bg = T.surface })

	function s:onShow()
		if strip then
			strip:setItems(showcaseTiles(strip.cols))
			strip.sel = 0
		end
		local parts = {}
		parts[#parts + 1] = ("товаров %d"):format(#cfg.sell)
		if IC.ok then parts[#parts + 1] = ("иконок %d из %d"):format(iconFound, iconTotal)
		else parts[#parts + 1] = "каталога иконок нет" end
		if dbFake then parts[#parts + 1] = "БАЗА НЕ ПОДКЛЮЧЕНА" end
		st:set(table.concat(parts, "   " .. BAR .. "   "))
	end
	return s
end

-- ---------------------------------------------------------------- витрина

--- Общий торговый экран: вкладки под шапкой, поле иконок, подробности и
--- кнопки снизу. Витрина, скупка, оба обменника и корзина - это он с разными
--- поставщиками данных, а не пять разных экранов.
local function gridScreen(spec)
	local s = U:screen(spec.name)
	chrome(s, spec.title)
	local w, h = U.W, U.H

	local gridTop = 4
	local tabs
	if spec.tabs then
		tabs = {}
		local x = 3
		for i = 1, #spec.tabs do
			local name = spec.tabs[i]
			local wide = unicode.len(name) + 4
			tabs[i] = s:button(x, 3, wide, 1, name, function() s:setTab(i) end,
			                   { kind = "tabOff" })
			x = x + wide + 1
		end
	else
		gridTop = 3
	end

	local grid = s:grid(2, gridTop, w - 2, (h - 4) - gridTop + 1, IC.ok and IC or nil,
	                    { center = true })
	s.grid = grid
	s.focus = grid

	grid.onSelect = function(it)
		if not it then s:say("", "", "") s:flush() return end
		s:say(it.name or it.title or "", it.info or "", it.tag)
		s:flush()
	end
	if spec.onActivate then
		grid.onActivate = function(it) if it then spec.onActivate(s, it) end end
	end

	function s:setTab(i)
		if tabs then
			for k = 1, #tabs do tabs[k]:setKind(k == i and "tabOn" or "tabOff") end
		end
		self.tab = i
		self.query = nil
		self:reload()
	end

	--- Перечитать данные и отдать сетке. Дорого - значит, зовётся только по
	--- делу: вход на экран, смена вкладки, поиск, завершённая операция.
	function s:reload()
		local list = spec.load(self, spec.tabs and spec.tabs[self.tab or 1] or nil) or {}
		if self.query and self.query ~= "" then
			local q = unicode.lower(self.query)
			local keep = {}
			for i = 1, #list do
				local it = list[i]
				if unicode.lower(it.name or it.title or ""):find(q, 1, true) then
					keep[#keep + 1] = it
				end
			end
			list = keep
		end
		self.grid:setItems(list)
		self:refreshWho()
		local found = self.query and self.query ~= ""
			and ("поиск «" .. self.query .. "»: " .. #list .. "   " .. BAR .. "   Esc сбросить")
			or nil
		self.hintLabel:set(found or spec.hint or
			"стрелки и колесо  выбрать    Enter  действие    /  поиск    Esc  назад")
		self:markAll()
	end

	function s:onShow() self:reload() end
	function s:sel() return self.grid:selected() end

	local actions = {}
	for i = 1, #(spec.actions or {}) do
		local a = spec.actions[i]
		actions[i] = { text = a.text, w = a.w, kind = a.kind,
		               onClick = function() a.onClick(s) end }
	end
	actions[#actions + 1] = { text = "Назад", w = 12, kind = "ghost",
	                          onClick = function() U:pop() end }
	bar(s, actions)

	s.onKey = function(self2, ch, code)
		if code == 1 then
			if self2.query and self2.query ~= "" then
				self2.query = nil
				self2:reload()
				self2:draw()
			else U:pop() end
			return true
		elseif ch == 47 then                                    -- /
			U:askText("Поиск по названию", function(q)
				self2.query = q
				self2:reload()
				self2:draw()
			end, self2.query)
			return true
		end
		return false
	end
	return s
end

-- ---------------------------------------------------------------- плитки

--- Значок количества поверх иконки. Цвет несёт смысл: зелёный - бери
--- сколько надо, золотой - осталось мало, красный - нет совсем.
local function stockBadge(n)
	if n <= 0 then return "нет", T.red end
	if n < 10 then return tostring(n), T.gold end
	return short(n), T.green
end

local function tileForSale(it)
	local stock = it.count or 0
	local badge, colour = stockBadge(stock)
	return {
		key = icoKey(it.id, it.dmg),
		title = it.label,
		sub = money(it.price) .. " $",
		subFg = T.gold,
		badge = badge, badgeFg = colour,
		name = it.label,
		info = ("в наличии %s   %s   %s"):format(money(stock), BAR, it.id),
		tag = money(it.price) .. " $ / шт",
		cfg = it,
	}
end

local function tileForBuyback(it)
	local mine = it.count or 0
	return {
		key = icoKey(it.id, it.dmg),
		title = it.label,
		sub = money(it.price) .. " $",
		subFg = T.gold,
		badge = mine > 0 and short(mine) or "", badgeFg = T.green,
		name = it.label,
		info = ("у вас в руках %s   %s   %s"):format(money(mine), BAR, it.id),
		tag = money(it.price) .. " $ / шт",
		cfg = it,
	}
end

local function tileForSwap(it)
	return {
		key = icoKey(it.fromId, it.fromDmg),
		title = it.fromLabel,
		sub = it.fromCount .. " \226\134\146 " .. it.toCount,
		subFg = T.green,
		name = it.fromLabel .. "  \226\134\146  " .. (it.toLabel or ""),
		info = ("за %s получите %s %s"):format(it.fromCount, it.toCount, it.toLabel or "?"),
		tag = it.fromCount .. " к " .. it.toCount,
		cfg = it,
	}
end

local function tileForBasket(it)
	return {
		key = icoKey(it.id, it.dmg),
		title = it.label or it.id,
		sub = money(it.count) .. " шт",
		subFg = T.green,
		badge = short(it.count), badgeFg = T.green,
		name = it.label or it.id,
		info = ("лежит %s шт   %s   %s"):format(money(it.count), BAR, it.id),
		tag = money(it.count) .. " шт",
		cfg = it,
	}
end

-- ------------------------------------------------------------------ экраны

local function buyScreen()
	local s = gridScreen({
		name = "buy",
		title = "Купить",
		tabs = core:categories(),
		load = function(_, cat)
			local out = {}
			for _, it in ipairs(core:sellList(cat)) do out[#out + 1] = tileForSale(it) end
			return out
		end,
		onActivate = function(self2, tile) self2.doBuy(tile) end,
		actions = {
			{ text = "Купить", w = 14, kind = "primary",
			  onClick = function(self2) self2.doBuy(self2:sel()) end },
			{ text = "Обновить", w = 14,
			  onClick = function(self2) IO:invalidate() self2:reload() self2:draw() end },
		},
	})

	function s.doBuy(tile)
		if not tile or not nick then return end
		local it = tile.cfg
		local price = tonumber(it.price) or 0
		local afford = price > 0 and math.floor(core:balance(nick) / price) or 0
		if afford < 1 then
			note("Не хватает денег на счету", "цена " .. money(price) .. " $ за штуку", nil, true)
			return
		end
		local cap = math.min(afford, tile.cfg.count or 0)
		if cap < 1 then note("Товара нет в наличии", nil, nil, true) return end
		U:askNumber("ПОКУПКА", it.label, function(n)
			result(s, core:buy(nick, it, n))
		end, { max = cap, okText = "Купить" })
	end
	s.tab = 1
	s.onShow = function(self2) self2:setTab(self2.tab or 1) end
	return s
end

local function sellScreen()
	local s = gridScreen({
		name = "sell",
		title = "Продать магазину",
		load = function()
			local out = {}
			for _, it in ipairs(core:buyList()) do out[#out + 1] = tileForBuyback(it) end
			return out
		end,
		onActivate = function(self2, tile) self2.doSell(tile) end,
		actions = {
			{ text = "Продать", w = 14, kind = "primary",
			  onClick = function(self2) self2.doSell(self2:sel()) end },
			{ text = "Обновить", w = 14,
			  onClick = function(self2) self2:reload() self2:draw() end },
		},
		hint = "магазин скупает то, что держите в руках",
	})
	function s.doSell(tile)
		if not tile or not nick then return end
		local have = tile.cfg.count or 0
		if have < 1 then note("Этого нет в инвентаре", nil, nil, true) return end
		U:askNumber("ПРОДАЖА", tile.cfg.label, function(n)
			result(s, core:sell(nick, tile.cfg, n))
		end, { max = have, okText = "Продать" })
	end
	return s
end

--- Обменник и обмен руд - один экран с разными конфигами. Отличается только
--- заголовок, источник строк и наличие кнопки «обменять всё».
local function swapScreen(kind)
	local isOre = (kind == "ore")
	local actions = {
		{ text = "Обменять", w = 14, kind = "primary",
		  onClick = function(self2) self2.doSwap(self2:sel()) end },
	}
	if isOre then
		actions[#actions + 1] = { text = "Обменять всё", w = 16, onClick = function(self2)
			result(self2, core:exchangeAllOres(nick))
		end }
	end
	local s = gridScreen({
		name = kind,
		title = isOre and "Обмен руд" or "Обменник",
		load = function()
			local out = {}
			local list = isOre and core:oreList() or core:exchangeList()
			for _, it in ipairs(list) do out[#out + 1] = tileForSwap(it) end
			return out
		end,
		onActivate = function(self2, tile) self2.doSwap(tile) end,
		actions = actions,
		hint = "обменянное падает в корзину, заберите его на главном экране",
	})
	function s.doSwap(tile)
		if not tile or not nick then return end
		local it = tile.cfg
		U:askNumber(isOre and "ОБМЕН РУДЫ" or "ОБМЕН",
			("%s \226\134\146 %s, курс %s к %s"):format(it.fromLabel, it.toLabel or "?",
			                                            it.fromCount, it.toCount),
			function(n) result(s, core:exchange(nick, it, n)) end,
			{ okText = "Обменять", hint = "сколько раз обменять" })
	end
	return s
end

local function basketScreen()
	local s = gridScreen({
		name = "basket",
		title = "Корзина",
		load = function()
			local out = {}
			for _, it in ipairs(core:basket(nick)) do out[#out + 1] = tileForBasket(it) end
			return out
		end,
		onActivate = function(self2, tile) self2.doTake(tile) end,
		actions = {
			{ text = "Забрать", w = 14, kind = "primary",
			  onClick = function(self2) self2.doTake(self2:sel()) end },
			{ text = "Забрать всё", w = 16,
			  onClick = function(self2) result(self2, core:takeAll(nick)) end },
		},
		hint = "здесь лежит всё, что пришло с обмена или не влезло в инвентарь",
	})
	function s.doTake(tile)
		if not tile or not nick then return end
		local it = tile.cfg
		U:askNumber("ВЫДАЧА", it.label or it.id, function(n)
			result(s, core:takeFromBasket(nick, it.id, it.dmg, n))
		end, { max = it.count, okText = "Забрать" })
	end
	return s
end

local function rulesScreen()
	local s = U:screen("rules")
	chrome(s, "Как это работает")
	local w, h = U.W, U.H
	local cardW = math.min(96, w - 8)
	local cx = math.floor((w - cardW) / 2) + 1
	s:panel(cx, 4, cardW, h - 9, { bg = T.surface })

	local list = s:list(cx + 3, 6, cardW - 6, h - 12, { bg = T.surface, plain = true })
	local function line(text, fg) return { text = text, fg = fg } end
	list:setRows({
		line("Баланс", T.accent),
		line("  Счёт у каждого компьютера свой. Держитесь одного магазина,"),
		line("  иначе деньги разойдутся по терминалам."),
		line("  Ввод и вывод идут суммами, кратными " .. core:moneyUnit() .. ".", T.dim),
		line(""),
		line("Покупка и продажа", T.accent),
		line("  Покупка списывает со счёта ровно за то, что удалось выдать."),
		line("  Продать можно то, что держите в руках, - магазин видит PIM."),
		line(""),
		line("Обмен", T.accent),
		line("  Всё, что приходит с обмена, попадает в корзину."),
		line("  Остаток, не составивший целый курс, возвращается туда же."),
		line(""),
		line("Корзина", T.accent),
		line("  Забрать её можно с главного экрана, целиком или по частям."),
		line("  Если выдача не идёт - в инвентаре нет свободных слотов.", T.dim),
		line(""),
		line("Вопросы - к администрации сервера.", T.dim),
	})
	s.focus = list
	bar(s, { { text = "Назад", w = 12, kind = "ghost", onClick = function() U:pop() end } })
	s.onKey = function(_, _, code) if code == 1 then U:pop() return true end end
	function s:onShow()
		self:refreshWho()
		self:say("", "", "")
		self.hintLabel:set("стрелки и колесо  листать    Esc  назад")
	end
	return s
end

-- ------------------------------------------------------------- главный экран

--- Главный экран - сводка счёта и вход во всё остальное. Внизу полоса
--- иконок корзины: если там что-то лежит, это видно сразу, а не после
--- захода в раздел.
local function mainScreen()
	local s = U:screen("main")
	chrome(s, "Главная")
	local w, h = U.W, U.H
	local big = h >= 40

	local cardW = math.min(96, w - 8)
	local cx = math.floor((w - cardW) / 2) + 1
	local y = 4

	-- Карточка счёта в две колонки: слева кто и сколько, справа что ждёт в
	-- корзине и каким шагом ходят деньги. Одной колонкой карточка на 96
	-- ячеек наполовину пустовала.
	local cardH = big and 9 or 5
	local colW = math.floor((cardW - 6) / 2)
	local lx, rx = cx + 3, cx + 3 + colW
	s:panel(cx, y, cardW, cardH, { bg = T.surface })
	s:label(lx, y + 1, 20, BAR .. " " .. spaced("СЧЁТ"), { fg = T.accent, bg = T.surface })

	local row1 = y + 3
	local row2 = y + (big and 5 or 4)
	s:label(lx, row1, 12, "Игрок", { fg = T.dim, bg = T.surface })
	local nameL = s:label(lx + 13, row1, colW - 15, "", { fg = T.white, bg = T.surface })
	s:label(lx, row2, 12, "Баланс", { fg = T.dim, bg = T.surface })
	-- сумма на чёрной врезке и по правому краю: то же поле, что в диалогах,
	-- и читается как табло, а не как ещё одна строчка на карточке
	s:panel(lx + 13, row2, colW - 15, 1, { bg = T.bg })
	local balL = s:label(lx + 14, row2, colW - 18, "",
	                     { align = "right", fg = T.gold, bg = T.bg })

	s:label(rx, row1, 14, "В корзине", { fg = T.dim, bg = T.surface })
	local basketL = s:label(rx + 15, row1, colW - 17, "", { fg = T.white, bg = T.surface })
	s:label(rx, row2, 14, "Ввод и вывод", { fg = T.dim, bg = T.surface })
	s:label(rx + 15, row2, colW - 17, "кратно " .. core:moneyUnit(),
	        { fg = T.dim, bg = T.surface })

	y = y + cardH + 1

	-- плитки действий
	section(s, cx, y, cardW, "РАЗДЕЛЫ")
	y = y + 1
	local tileH = big and 5 or 3
	local bw = math.floor((cardW - 4) / 3)
	local function tile(col, row, text, sub, onClick, kind)
		return s:button(cx + (col - 1) * (bw + 2), y + (row - 1) * (tileH + 1), bw, tileH,
		                text, onClick, { kind = kind or "normal", sub = big and sub or nil })
	end
	tile(1, 1, "Купить", "товары магазина", function() U:push(screens.buy) end, "primary")
	tile(2, 1, "Продать", "магазин скупает", function() U:push(screens.sell) end, "primary")
	tile(3, 1, "Корзина", "забрать своё", function() U:push(screens.basket) end)
	tile(1, 2, "Обмен руд", "руда в слитки", function() U:push(screens.ore) end)
	tile(2, 2, "Обменник", "предмет в предмет", function() U:push(screens.swap) end)
	tile(3, 2, "Справка", "как это работает", function() U:push(screens.rules) end)
	y = y + tileH * 2 + 2

	-- деньги: кнопки обычные, золотом только надпись. Золото на экране
	-- значит «сумма», и большие заливки им забивают само табло баланса
	section(s, cx, y, cardW, "ДЕНЬГИ")
	y = y + 1
	local mh = big and 3 or 1
	s:button(cx, y, bw, mh, "Пополнить", function()
		U:askNumber("ПОПОЛНЕНИЕ", "Сколько положить на счёт", function(n)
			local c, m, sec = core:deposit(nick, n)
			result(s, c, m, sec)
		end, { hint = "кратно " .. core:moneyUnit() })
	end, { fg = T.gold, sub = big and "монеты из рук на счёт" or nil })
	s:button(cx + bw + 2, y, bw, mh, "Снять", function()
		local unit = core:moneyUnit()
		local cap = math.floor(core:balance(nick) / unit) * unit
		if cap < unit then
			note("На счету меньше " .. unit, nil, nil, true)
			return
		end
		U:askNumber("СНЯТИЕ", "Сколько снять со счёта", function(n)
			local c, m, sec = core:withdraw(nick, n - n % unit)
			result(s, c, m, sec)
		end, { max = cap, hint = "кратно " .. unit })
	end, { fg = T.gold, sub = big and "со счёта монетами в руки" or nil })
	s:button(cx + (bw + 2) * 2, y, bw, mh, "Выход", function()
		core:forget()
		nick = nil
		U:home()
	end, { kind = "ghost", sub = big and "закрыть сеанс" or nil })
	y = y + mh + 1

	-- Нижняя полоса. Если в корзине что-то лежит - показываем её, и это
	-- видно сразу, без захода в раздел. Пусто - показываем витрину: экран
	-- не должен наполовину пустовать, а иконки тут и есть содержание.
	local strip, stripHead
	if IC.ok and (h - 4) - (y + 1) + 1 >= IC.h + 2 then
		strip = s:grid(2, y + 1, w - 2, (h - 4) - (y + 1) + 1, IC, { center = true })
		stripHead = section(s, strip.x, y, cardW, "В КОРЗИНЕ")
		strip.rows = 1
		strip.h = strip.th
		strip.showing = "basket"
		strip.onTouch = function(self2)
			U:push(self2.showing == "basket" and screens.basket or screens.buy)
		end
	end

	function s:reload()
		nameL:set(nick or "-")
		balL:set(nick and (money(core:balance(nick)) .. " $") or "-")
		local n = nick and core:basketCount(nick) or 0
		basketL:set(n > 0 and (money(n) .. " предметов") or "пусто")
		if strip then
			local tiles = {}
			if nick then
				for _, it in ipairs(core:basket(nick)) do
					if #tiles >= strip.cols then break end
					tiles[#tiles + 1] = tileForBasket(it)
				end
			end
			if #tiles > 0 then
				strip.showing = "basket"
				stripHead:set(BAR .. " " .. spaced("В КОРЗИНЕ"))
			else
				strip.showing = "shop"
				stripHead:set(BAR .. " " .. spaced("ВИТРИНА"))
				tiles = showcaseTiles(strip.cols)
			end
			strip:setItems(tiles)
			strip.sel = 0
		end
		self:refreshWho()
		self:say("", "", "")
		self.hintLabel:set("выберите раздел")
	end
	function s:onShow() self:reload() end
	s.onKey = function(_, _, code) if code == 1 then return true end end
	return s
end

-- ------------------------------------------------------------------ вход

--- Вход и выход игрока. Данные прошлого забываются сразу: иначе следующий,
--- кто встанет на PIM, увидит чужой баланс, пока экран не перерисуется.
local function login(player)
	if not player then return end
	nick = player
	pcall(computer.addUser, player)
	core:forget()
	printD(("%s: вошёл %s"):format(SHOPNAME, player))
	while U:depth() > 1 do U:pop() end
	U:push(screens.main)
end

local function logout()
	if nick and not KEEP_USER[nick] then pcall(computer.removeUser, nick) end
	if nick then printD(("%s: вышел %s"):format(SHOPNAME, nick)) end
	nick = nil
	core:forget()
	if db.forget then pcall(db.forget, db) end
	U:home()
end

-- ------------------------------------------------------------------ запуск

local function build()
	screens.lock   = lockScreen()
	screens.main   = mainScreen()
	screens.buy    = buyScreen()
	screens.sell   = sellScreen()
	screens.ore    = swapScreen("ore")
	screens.swap   = swapScreen("swap")
	screens.basket = basketScreen()
	screens.rules  = rulesScreen()
end

local function run()
	build()
	U:on("player_on", function(_, _, player) login(player) end)
	U:on("player_off", function() logout() end)

	-- Уже стоит на PIM к моменту запуска: лаунчер перезапускает магазин, а
	-- игрок при этом никуда не уходил и второго player_on не будет.
	local ok, users = pcall(computer.users)
	if ok and users then login(users) end

	U:run(nick and screens.main or screens.lock)
end

local ok, err = pcall(run)

U:dropBufs()
gpu.setResolution(80, 25)
U.p:forget()
U.p:bg(0x000000)
U.p:fg(0xFFFFFF)
local rw, rh = gpu.getResolution()
gpu.fill(1, 1, rw, rh, " ")
if not ok then
	printD("shop: " .. tostring(err))
	if rawget(_G, "flushLog") then _G.flushLog() end
	-- наверх: под ShopOS присмотр в ядре поднимет магазин заново
	error(err, 0)
end
