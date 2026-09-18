-- ui - экраны магазина поверх paint: сетка иконок, кнопки, списки, диалоги.
--
-- Заменяет forms.lua. Разница не в наборе виджетов, а в том, где считаются
-- вызовы gpu, - в forms любое действие пересоздавало форму и перерисовывало
-- экран целиком, а экран 160x50 это 8000 ячеек.
--
-- Что тут сделано вместо этого:
--
--   * экраны живут, а не создаются заново. Кнопка меняет данные и метит
--     виджет грязным, перерисовывается только он;
--   * ряд сетки собирается в буфер видеопамяти и ложится на экран одним
--     bitblt. Страница иконок - десяток вызовов вместо пары тысяч;
--   * прокрутка не перерисовывает видимое: оно уезжает одним gpu.copy,
--     дорисовываются только открывшиеся ряды;
--   * подсветка выбранного трогает две строки подписи, а не весь ряд;
--   * цвет не переставляется, если он и так нужный, соседние ячейки одного
--     цвета склеиваются в одну запись - это уже внутри paint;
--   * диалог рисуется поверх экрана, и закрытие стоит перерисовку того, что
--     он закрывал, а сетка под ним возвращается своими bitblt.
--
-- Координаты у виджетов абсолютные и считаются один раз при сборке экрана:
-- вложенных систем координат нет, потому что на 80 колонках их некуда
-- вкладывать, а стоят они пересчёт на каждую отрисовку.

local paint = require("paint")

local ui = {}

local floor, max, min, ceil = math.floor, math.max, math.min, math.ceil
local rep, format = string.rep, string.format

-- ------------------------------------------------------------------ тема

--- Палитра. Экран OC умеет 256 цветов: куб 6x8x5 плюс 16 серых, и любой
--- другой оттенок gpu всё равно прижмёт к ближайшему. Поэтому цвета взяты
--- прямо из узлов куба - что задано, то и покажется, без сюрпризов.
---
--- Держится на трёх уровнях серого и одном акценте: фон-поле, карточка,
--- выделенная карточка. Цветом помечается только то, что несёт смысл -
--- деньги золотым, наличие зелёным, нехватка красным.
local T = {
	bg       = 0x000000,   -- поле под иконками: на чёрном они как в инвентаре
	surface  = 0x1E1E1E,   -- карточки, шапка, подвал
	surface2 = 0x2D2D2D,   -- вторичные кнопки, неактивные вкладки
	line     = 0x3C3C3C,   -- разделители
	mute     = 0x5A5A5A,   -- совсем тихий текст
	dim      = 0x787878,   -- пояснения
	text     = 0xD2D2D2,   -- основной текст
	white    = 0xF0F0F0,   -- то, на что смотрят
	ink      = 0x000000,   -- текст поверх цветной заливки
	accent   = 0x00B4BF,   -- бирюза: заголовки, выбранное, главное действие
	accent2  = 0x006C80,   -- та же бирюза в тени
	gold     = 0xFFB400,   -- деньги и цены
	green    = 0x66D800,   -- есть в наличии, выгодный курс
	red      = 0xFF2440,   -- нет в наличии, отказ
}
ui.theme = T

--- Вид кнопки задаётся одним словом, а не парой цветов на каждом вызове:
--- иначе оформление расползается по всему коду экранов.
local KIND = {
	primary = { bg = T.accent,   fg = T.ink },
	normal  = { bg = T.surface2, fg = T.text },
	ghost   = { bg = T.surface,  fg = T.dim },
	danger  = { bg = T.red,      fg = T.ink },
	gold    = { bg = T.gold,     fg = T.ink },
	tabOn   = { bg = T.accent,   fg = T.ink },
	tabOff  = { bg = T.surface2, fg = T.dim },
}
ui.kind = KIND

-- ------------------------------------------------------------- вспомогательное

--- Короткая запись больших чисел: на плитке 17 колонок, "27000000" туда не
--- лезет, а "27.0M" читается и не врёт.
function ui.short(n)
	n = floor(tonumber(n) or 0)
	if n < 100000 then return tostring(n) end
	if n < 1000000 then return format("%.0fk", n / 1000) end
	if n < 1000000000 then return format("%.1fM", n / 1000000) end
	return format("%.1fG", n / 1000000000)
end

--- Полная запись с разделителем разрядов - для строк, где место есть.
function ui.money(n)
	n = floor(tonumber(n) or 0)
	local s, sign = tostring(n), ""
	if s:sub(1, 1) == "-" then sign, s = "-", s:sub(2) end
	local out = s:sub(-3)
	local i = #s - 3
	while i > 0 do
		out = s:sub(max(1, i - 2), i) .. " " .. out
		i = i - 3
	end
	return sign .. out
end

-- ------------------------------------------------------------------ ядро

local U = {}
U.__index = U

function ui.new(gpu, unicode, event, computer)
	local self = setmetatable({
		gpu = gpu, unicode = unicode, event = event, computer = computer,
		p = paint.new(gpu, unicode),
		stack = {}, timers = {}, hooks = {},
		bufs = {}, haveBufs = false,
	}, U)
	local w, h = gpu.maxResolution()
	gpu.setResolution(w, h)
	self.W, self.H = w, h
	-- буферы видеопамяти есть не у всякой карты и не во всякой версии OC
	if gpu.allocateBuffer then
		local ok, id = pcall(gpu.allocateBuffer, w, 4)
		if ok and id then self.haveBufs = true gpu.freeBuffer(id) end
	end
	return self
end

function U:clear(color)
	self.p:fill(1, 1, self.W, self.H, color or T.bg)
end

--- Освободить всю видеопамять. Зовётся при смене экрана: ряды старого
--- экрана в буферах больше не нужны, а память нужна новому.
function U:dropBufs()
	for k, id in pairs(self.bufs) do
		pcall(self.gpu.freeBuffer, id)
		self.bufs[k] = nil
	end
end

-- --------------------------------------------------------------- виджеты

local W = {}
W.__index = W
ui.widget = W

function W:mark() self.dirty = true end
function W:hit(x, y)
	return x >= self.x and x < self.x + self.w and y >= self.y and y < self.y + self.h
end
function W:draw() end

-- ------------------------------------------------------------------ экран

local S = {}
S.__index = S

--- Экран: плоский список виджетов в абсолютных координатах плюс обработчики.
--- Никакой иерархии - на этих размерах она только считает координаты заново.
function U:screen(name)
	return setmetatable({ ui = self, name = name, items = {}, bg = T.bg }, S)
end

function S:add(w)
	w.ui = self.ui
	w.screen = self
	w.dirty = true
	if w.visible == nil then w.visible = true end
	self.items[#self.items + 1] = w
	return w
end

--- Пометка снимается ДО отрисовки, а не после. Виджет во время draw может
--- позвать обработчик, тот - flush, и если пометка ещё висит, виджет уйдёт
--- рисоваться заново: сетка так уходила в бесконечную рекурсию через
--- onSelect.
local function paintItems(items)
	for i = 1, #items do
		local w = items[i]
		if w.visible then w.dirty = false w:draw() end
	end
end

function S:draw()
	local u = self.ui
	u.p:fill(1, 1, u.W, u.H, self.bg)
	if self.onDraw then self:onDraw() end
	paintItems(self.items)
end

--- Перерисовать только помеченное. Весь смысл экранов, которые не
--- пересоздаются: нажатие кнопки стоит одну строку, а не восемь тысяч ячеек.
---
--- Вложенный вызов отбрасывается, а внешний идёт кругами, пока помеченного
--- не останется: обработчик внутри draw может пометить соседний виджет,
--- который в этом проходе уже прошли.
function S:flush()
	if self.flushing then return end
	self.flushing = true
	local rounds = 0
	repeat
		local any = false
		for i = 1, #self.items do
			local w = self.items[i]
			if w.dirty and w.visible then
				w.dirty = false
				w:draw()
				any = true
			end
		end
		rounds = rounds + 1
	until not any or rounds >= 4
	self.flushing = false
end

function S:markAll()
	for i = 1, #self.items do self.items[i].dirty = true end
end

--- Виджет под курсором, сверху вниз по порядку добавления.
function S:at(x, y)
	for i = #self.items, 1, -1 do
		local w = self.items[i]
		if w.visible and w.onTouch and w:hit(x, y) then return w end
	end
end

-- ------------------------------------------------------------------ метка

local Label = setmetatable({}, { __index = W })
Label.__index = Label

function Label:draw()
	local p = self.ui.p
	p:text(self.x, self.y, p:pad(tostring(self.text or ""), self.w, self.align),
	       self.fg or T.text, self.bg or T.bg)
end

function Label:set(text)
	if self.text ~= text then self.text = text self.dirty = true end
end

function S:label(x, y, w, text, opt)
	opt = opt or {}
	opt.x, opt.y, opt.w, opt.h, opt.text = x, y, w, 1, text
	return self:add(setmetatable(opt, Label))
end

-- ------------------------------------------------------------------ кнопка

local Button = setmetatable({}, { __index = W })
Button.__index = Button

function Button:draw()
	local p, u = self.ui.p, self.ui.unicode
	local on = self.enabled ~= false
	local k = KIND[self.kind or "normal"] or KIND.normal
	local bg = on and (self.bg or k.bg) or T.surface2
	local fg = on and (self.fg or k.fg) or T.mute
	p:fill(self.x, self.y, self.w, self.h, bg)
	local mid = self.y + floor((self.h - 1) / 2)
	local s = p:clip(self.text or "", self.w - 2)
	p:text(self.x + floor((self.w - u.len(s)) / 2), mid, s, fg, bg)
	-- вторая строка под названием: на крупных плитках главного экрана она
	-- объясняет, что кнопка делает, и её нечем заменить - места под
	-- отдельную подпись там нет
	if self.sub and self.h >= 3 then
		local t = p:clip(self.sub, self.w - 2)
		p:text(self.x + floor((self.w - u.len(t)) / 2), mid + 1, t,
		       on and (self.subFg or T.mute) or T.mute, bg)
	end
end

function Button:setKind(kind)
	if self.kind ~= kind then self.kind = kind self.dirty = true end
end

function Button:onTouch()
	if self.enabled ~= false and self.onClick then self.onClick(self) end
end

function Button:enable(on)
	on = on and true or false
	if (self.enabled ~= false) ~= on then self.enabled = on self.dirty = true end
end

function Button:set(text)
	if self.text ~= text then self.text = text self.dirty = true end
end

function S:button(x, y, w, h, text, onClick, opt)
	opt = opt or {}
	opt.x, opt.y, opt.w, opt.h, opt.text, opt.onClick = x, y, w, h, text, onClick
	return self:add(setmetatable(opt, Button))
end

-- ------------------------------------------------------------------ панель

local Panel = setmetatable({}, { __index = W })
Panel.__index = Panel

function Panel:draw()
	local p = self.ui.p
	local bg = self.bg or T.surface
	p:fill(self.x, self.y, self.w, self.h, bg)
	if self.border then p:box(self.x, self.y, self.w, self.h, self.border, bg) end
	if self.title then
		p:text(self.x + 2, self.y, " " .. self.title .. " ", self.fg or T.accent, bg)
	end
end

function S:panel(x, y, w, h, opt)
	opt = opt or {}
	opt.x, opt.y, opt.w, opt.h = x, y, w, h
	return self:add(setmetatable(opt, Panel))
end

-- ------------------------------------------------------------- сетка иконок

local Grid = setmetatable({}, { __index = W })
Grid.__index = Grid

--- Плитка: иконка, число поверх её нижней строки, две строки подписи.
--- Рисуется и на экран, и в буфер - paint одинаково работает и там, и там.
function Grid:tile(it, x, y)
	local p, u = self.ui.p, self.ui.unicode
	local ic, iw, ih = self.icons, self.iw, self.ih
	local bg = self.bg or T.bg
	if it.key and ic then
		local cells, mode = ic:cells(it.key)
		if cells then p:icon(cells, mode, iw, ih, x, y, bg)
		else p:text(x + floor(iw / 2) - 1, y + floor(ih / 2), "нет", T.dim, bg) end
	end
	if it.badge and it.badge ~= "" then
		local s = p:clip(it.badge, iw)
		p:text(x + iw - u.len(s), y + ih - 1, s, it.badgeFg or T.white, bg)
	end
	p:text(x, y + ih, p:clip(it.title or "", self.tw), it.titleFg or T.text, bg)
	if it.sub then
		p:text(x, y + ih + 1, p:clip(it.sub, self.tw), it.subFg or T.dim, bg)
	end
end

function Grid:rowOf(i) return ceil(i / self.cols) end
function Grid:lastRow() return max(1, ceil(#self.data / self.cols)) end
function Grid:rowY(r) return self.y + (r - self.top) * self.th end

--- Один ряд целиком, в текущую цель рисования.
function Grid:paintRow(r, x, y)
	local p = self.ui.p
	p:fill(x, y, self.w, self.th, self.bg or T.bg)
	local base = (r - 1) * self.cols
	for c = 0, self.cols - 1 do
		local it = self.data[base + c + 1]
		if not it then break end
		self:tile(it, x + c * self.tw, y)
	end
end

--- Ряд в буфере видеопамяти. Не влезло - вытесняем самый дальний от экрана:
--- к нему прокрутка вернётся позже всего.
function Grid:buf(r)
	local u, gpu = self.ui, self.ui.gpu
	local id = u.bufs[r]
	if id then return id end
	local ok
	ok, id = pcall(gpu.allocateBuffer, self.w, self.th)
	if not ok or not id then
		local far, fd = nil, -1
		for k in pairs(u.bufs) do
			local d = k - self.top
			if d < 0 then d = -d end
			if d > fd then far, fd = k, d end
		end
		if not far then return nil end
		gpu.freeBuffer(u.bufs[far])
		u.bufs[far] = nil
		ok, id = pcall(gpu.allocateBuffer, self.w, self.th)
		if not ok or not id then return nil end
	end
	u.bufs[r] = id
	gpu.setActiveBuffer(id)
	u.p:forget()
	self:paintRow(r, 1, 1)          -- в буфере ряд лежит от единицы
	gpu.setActiveBuffer(0)
	u.p:forget()
	return id
end

function Grid:drawRow(r)
	local u = self.ui
	local y = self:rowY(r)
	if r > self:lastRow() or #self.data == 0 then
		u.p:fill(self.x, y, self.w, self.th, self.bg or T.bg)
		return
	end
	if u.haveBufs then
		local id = self:buf(r)
		if id then
			u.gpu.bitblt(0, self.x, y, self.w, self.th, id, 1, 1)
			u.p.calls = u.p.calls + 1
			return
		end
	end
	self:paintRow(r, self.x, y)
end

--- Подсветка: перекрашиваются строки подписи, иконка не трогается.
--- Снять подсветку - положить ряд из буфера обратно, это один bitblt.
function Grid:drawSel(on)
	local it = self.data[self.sel]
	if not it then return end
	local r = self:rowOf(self.sel)
	if r < self.top or r >= self.top + self.rows then return end
	local p = self.ui.p
	local x = self.x + ((self.sel - 1) % self.cols) * self.tw
	local y = self:rowY(r) + self.ih
	if on then
		p:fill(x, y, self.tw, 2, T.accent)
		p:text(x, y, p:clip(it.title or "", self.tw), T.ink, T.accent)
		if it.sub then p:text(x, y + 1, p:clip(it.sub, self.tw), T.ink, T.accent) end
	else
		self:drawRow(r)
	end
end

function Grid:announce()
	if self.onSelect then self.onSelect(self.data[self.sel], self.sel) end
end

function Grid:draw()
	local last = self:lastRow()
	for k = 0, self.rows - 1 do
		local r = self.top + k
		if r <= last and #self.data > 0 then self:drawRow(r)
		else self.ui.p:fill(self.x, self.y + k * self.th, self.w, self.th, self.bg or T.bg) end
	end
	self:drawSel(true)
	self:announce()
end

--- Сменить содержимое. Буферы старого содержимого больше не годятся.
function Grid:setItems(list)
	self.data = list or {}
	self.ui:dropBufs()
	self.top = 1
	self.sel = #self.data > 0 and 1 or 0
	self.dirty = true
end

function Grid:selected() return self.data[self.sel] end

function Grid:moveTo(i)
	if #self.data == 0 then return end
	if i < 1 then i = 1 elseif i > #self.data then i = #self.data end
	if i == self.sel then return end
	self:drawSel(false)
	self.sel = i
	local r = self:rowOf(i)
	if r < self.top then self.top = r self:draw()
	elseif r >= self.top + self.rows then self.top = r - self.rows + 1 self:draw()
	else self:drawSel(true) self:announce() end
end

--- Прокрутка на drows рядов. Видимое уезжает одним gpu.copy, дорисовываются
--- только открывшиеся ряды: шаг стоит copy плюс один bitblt.
function Grid:scrollBy(drows)
	local last = self:lastRow()
	local maxTop = max(1, last - self.rows + 1)
	local nt = self.top + drows
	if nt < 1 then nt = 1 elseif nt > maxTop then nt = maxTop end
	if nt == self.top then return end
	local d = nt - self.top
	local oldRow = self:rowOf(self.sel)
	self.top = nt

	local r = self:rowOf(self.sel)
	if r < self.top then
		self.sel = (self.top - 1) * self.cols + ((self.sel - 1) % self.cols) + 1
	elseif r >= self.top + self.rows then
		self.sel = (self.top + self.rows - 2) * self.cols + ((self.sel - 1) % self.cols) + 1
	end
	if self.sel > #self.data then self.sel = #self.data end

	local ad = d < 0 and -d or d
	if ad < self.rows then
		local u = self.ui
		local keep = (self.rows - ad) * self.th
		local from = d > 0 and self.y + d * self.th or self.y
		u.gpu.copy(self.x, from, self.w, keep, 0, -d * self.th)
		u.p.calls = u.p.calls + 1
		if d > 0 then for k = self.rows - d, self.rows - 1 do self:drawRow(self.top + k) end
		else for k = 0, -d - 1 do self:drawRow(self.top + k) end end
		-- подсветка уехала вместе с картинкой: кладём старый ряд обратно
		if oldRow >= self.top and oldRow < self.top + self.rows then self:drawRow(oldRow) end
		self:drawSel(true)
		self:announce()
	else
		self:draw()
	end
end

function Grid:onTouch(x, y)
	local c = floor((x - self.x) / self.tw)
	local r = floor((y - self.y) / self.th)
	if c < 0 or c >= self.cols then return end
	local i = (self.top + r - 1) * self.cols + c + 1
	if not self.data[i] then return end
	if i == self.sel and self.onActivate then self.onActivate(self.data[i], i) return end
	self:moveTo(i)
end

function Grid:onScroll(dir) self:scrollBy(-(dir or 0)) end

function Grid:onKey(code)
	if code == 200 then self:moveTo(self.sel - self.cols)
	elseif code == 208 then self:moveTo(self.sel + self.cols)
	elseif code == 203 then self:moveTo(self.sel - 1)
	elseif code == 205 then self:moveTo(self.sel + 1)
	elseif code == 201 then self:moveTo(self.sel - self.cols * self.rows)
	elseif code == 209 then self:moveTo(self.sel + self.cols * self.rows)
	elseif code == 199 then self:moveTo(1)
	elseif code == 207 then self:moveTo(#self.data)
	elseif code == 28 then
		if self.onActivate and self.data[self.sel] then self.onActivate(self.data[self.sel], self.sel) end
	else return false end
	return true
end

--- Сетка по размеру области. Плитка это иконка плюс колонка зазора по ширине
--- и две строки подписи по высоте.
function S:grid(x, y, w, h, icons, opt)
	opt = opt or {}
	local iw = (icons and icons.ok) and icons.w or 8
	local ih = (icons and icons.ok) and icons.h or 3
	local tw, th = iw + 1, ih + 2
	local cols = max(1, floor(w / tw))
	local rows = max(1, floor(h / th))
	opt.w, opt.h = cols * tw, rows * th
	-- сетка уже колонки: остаток делим пополам, иначе поле иконок липнет к
	-- левому краю, а справа висит пустая полоса в половину плитки
	opt.x = opt.center and (x + floor((w - opt.w) / 2)) or x
	opt.y = y
	opt.icons, opt.iw, opt.ih, opt.tw, opt.th = icons, iw, ih, tw, th
	opt.cols, opt.rows = cols, rows
	opt.data = opt.data or {}
	opt.top = 1
	opt.sel = #opt.data > 0 and 1 or 0
	return self:add(setmetatable(opt, Grid))
end

-- --------------------------------------------------------------- текст-список

local List = setmetatable({}, { __index = W })
List.__index = List

function List:draw()
	local p = self.ui.p
	for i = 0, self.h - 1 do
		local idx = self.top + i
		local row = self.data[idx]
		if row then
			-- plain - список только для чтения: подсветка строки там лишняя,
			-- выбирать в справочном тексте нечего
			local sel = not self.plain and (idx == self.sel)
			p:text(self.x, self.y + i, p:pad(row.text or tostring(row), self.w),
			       sel and T.ink or (row.fg or self.fg or T.text),
			       sel and T.accent or (self.bg or T.bg))
		else
			p:fill(self.x, self.y + i, self.w, 1, self.bg or T.bg)
		end
	end
	if self.onSelect then self.onSelect(self.data[self.sel], self.sel) end
end

function List:setRows(rows)
	self.data = rows or {}
	self.top = 1
	self.sel = #self.data > 0 and 1 or 0
	self.dirty = true
end

function List:selected() return self.data[self.sel] end

function List:moveTo(i)
	if #self.data == 0 then return end
	if i < 1 then i = 1 elseif i > #self.data then i = #self.data end
	self.sel = i
	if i < self.top then self.top = i end
	if i >= self.top + self.h then self.top = i - self.h + 1 end
	self.dirty = true
end

function List:onTouch(x, y)
	if self.plain then return end
	self:moveTo(self.top + (y - self.y))
end

function List:onScroll(dir)
	local maxTop = max(1, #self.data - self.h + 1)
	local nt = self.top - (dir or 0) * 2
	if nt < 1 then nt = 1 elseif nt > maxTop then nt = maxTop end
	if nt ~= self.top then self.top = nt self.dirty = true end
end

--- Прокрутить окно, не трогая выбор: для списка только для чтения стрелки
--- листают текст, а не переставляют подсветку.
function List:scrollTo(t)
	local maxTop = max(1, #self.data - self.h + 1)
	if t < 1 then t = 1 elseif t > maxTop then t = maxTop end
	if t ~= self.top then self.top = t self.dirty = true end
end

function List:onKey(code)
	if self.plain then
		if code == 200 then self:scrollTo(self.top - 1)
		elseif code == 208 then self:scrollTo(self.top + 1)
		elseif code == 201 then self:scrollTo(self.top - self.h)
		elseif code == 209 then self:scrollTo(self.top + self.h)
		elseif code == 199 then self:scrollTo(1)
		elseif code == 207 then self:scrollTo(#self.data)
		else return false end
		return true
	end
	if code == 200 then self:moveTo(self.sel - 1)
	elseif code == 208 then self:moveTo(self.sel + 1)
	elseif code == 201 then self:moveTo(self.sel - self.h)
	elseif code == 209 then self:moveTo(self.sel + self.h)
	elseif code == 199 then self:moveTo(1)
	elseif code == 207 then self:moveTo(#self.data)
	elseif code == 28 then
		if self.onActivate and self.data[self.sel] then self.onActivate(self.data[self.sel], self.sel) end
	else return false end
	return true
end

function S:list(x, y, w, h, opt)
	opt = opt or {}
	opt.x, opt.y, opt.w, opt.h = x, y, w, h
	opt.data = opt.data or {}
	opt.top = 1
	opt.sel = #opt.data > 0 and 1 or 0
	return self:add(setmetatable(opt, List))
end

-- ------------------------------------------------------------------ стек

--- Показать экран. Прежний остаётся в стеке и ждёт возврата.
function U:push(screen)
	self.stack[#self.stack + 1] = screen
	self:dropBufs()
	if screen.onShow then screen:onShow() end
	screen:draw()
	return screen
end

function U:pop()
	local n = #self.stack
	if n <= 1 then return self.stack[1] end
	local top = self.stack[n]
	if top.onHide then top:onHide() end
	self.stack[n] = nil
	local back = self.stack[n - 1]
	self:dropBufs()
	if back.onShow then back:onShow() end
	back:draw()
	return back
end

--- Заменить верхний экран, не наращивая стек.
function U:swap(screen)
	local n = #self.stack
	if n > 0 then
		local top = self.stack[n]
		if top.onHide then top:onHide() end
		self.stack[n] = nil
	end
	return self:push(screen)
end

--- Сбросить стек до самого нижнего экрана.
function U:home()
	while #self.stack > 1 do
		local top = self.stack[#self.stack]
		if top.onHide then top:onHide() end
		self.stack[#self.stack] = nil
	end
	local s = self.stack[1]
	if s then
		self:dropBufs()
		if s.onShow then s:onShow() end
		s:draw()
	end
	return s
end

function U:top() return self.stack[#self.stack] end

function U:depth() return #self.stack end

-- ------------------------------------------------------------------ диалоги

--- Диалог рисуется поверх экрана. Своих буферов не заводит: под ним лежит
--- готовая картинка, и при закрытии хватит перерисовать экран под ним.
--- Диалог - плоская карточка: цветная полоса заголовка сверху, тело, полоса
--- кнопок снизу. Рамок из псевдографики нет специально: три уровня заливки
--- очерчивают карточку сами и стоят три fill вместо рамки в h+2 вызова.
---
--- Своих буферов диалог не заводит: под ним лежит готовая картинка, и при
--- закрытии хватит перерисовать экран под ним.
function U:dialog(w, h, title, tone)
	local s = self:screen("dialog")
	s.modal = true
	s.w, s.h = w, h
	s.x = floor((self.W - w) / 2) + 1
	s.y = floor((self.H - h) / 2) + 1
	s.tone = tone or T.accent
	s.barY = s.y + h - 2
	s.onDraw = function(self2)
		local p, u = self2.ui.p, self2.ui.unicode
		p:fill(s.x, s.y + 1, w, h - 3, T.surface)
		p:fill(s.x, s.y, w, 1, s.tone)
		p:fill(s.x, s.barY, w, 2, T.surface2)
		if title and title ~= "" then
			p:text(s.x + 2, s.y, u.sub(title, 1, w - 4), T.ink, s.tone)
		end
	end
	return s
end

--- Показать диалог. В отличие от push, фон не стирается и буферы сетки под
--- ним остаются живы.
function U:openDialog(s)
	self.stack[#self.stack + 1] = s
	if s.onShow then s:onShow() end
	s:onDraw()
	paintItems(s.items)
	return s
end

--- Закрыть диалог: перерисовать то, что он закрывал.
function U:closeDialog()
	local n = #self.stack
	local d = self.stack[n]
	if not d or not d.modal then return self:pop() end
	if d.onHide then d:onHide() end
	self.stack[n] = nil
	local back = self.stack[n - 1]
	if not back then return end
	if back.modal then
		back:onDraw()
		paintItems(back.items)
	else
		-- сетка вернётся своими bitblt: буферы рядов живы
		back:draw()
	end
	return back
end

--- Уведомление. Полоса заголовка красится по исходу: получилось - бирюза,
--- отказ - красный. Раньше удача и отказ выглядели одинаково, и игрок
--- отличал их только по тексту.
function U:note(text, second, onClose, seconds, bad)
	local u = self.unicode
	local wide = max(u.len(text or ""), second and u.len(second) or 0)
	local w, h = min(self.W - 4, max(40, wide + 10)), 9
	local s = self:dialog(w, h, bad and "  НЕ ВЫШЛО" or "  ГОТОВО",
	                      bad and T.red or T.accent)
	s:label(s.x + 2, s.y + 3, w - 4, text or "",
	        { align = "center", fg = T.white, bg = T.surface })
	if second then
		s:label(s.x + 2, s.y + 5, w - 4, second,
		        { align = "center", fg = T.dim, bg = T.surface })
	end
	local done = false
	local function close()
		if done then return end
		done = true
		self:closeDialog()
		if onClose then onClose() end
	end
	s:button(s.x + floor((w - 16) / 2), s.barY, 16, 1, "Понятно", close,
	         { kind = bad and "danger" or "primary" })
	s.onKey = function(_, ch, code)
		if code == 28 or code == 1 then close() return true end
	end
	if seconds and seconds > 0 then
		s.deadline = self.computer.uptime() + seconds
		s.onTimeout = close
	end
	return self:openDialog(s)
end

--- Ввод числа. Проверка тут же: количество это целое от единицы, всё прочее
--- просто не набирается, так что до логики магазина мусор не доходит.
function U:askNumber(title, prompt, onOk, opt)
	opt = opt or {}
	local w, h = 48, 12
	local s = self:dialog(w, h, "  " .. title)
	local text = opt.value and tostring(opt.value) or ""
	local maxN = opt.max and floor(opt.max) or nil
	if maxN and maxN < 1 then maxN = nil end

	s:label(s.x + 3, s.y + 2, w - 6, prompt, { align = "center", fg = T.text, bg = T.surface })
	-- поле ввода тёмное на светлой карточке: видно, куда попадёт набранное.
	-- Ширина оставляет место кнопке «макс» справа, иначе они лезут друг на друга
	s:panel(s.x + 5, s.y + 4, w - 22, 1, { bg = T.bg })
	local field = s:label(s.x + 6, s.y + 4, w - 24, "", { fg = T.gold, bg = T.bg })
	local hint = s:label(s.x + 3, s.y + 6, w - 6, "", { align = "center", fg = T.dim, bg = T.surface })

	local function refresh()
		field:set(text .. "█")                  -- каретка блоком
		hint:set(maxN and ("можно до " .. ui.money(maxN)) or (opt.hint or ""))
		s:flush()
	end
	local function value()
		local n = tonumber(text)
		if not n then return nil end
		n = floor(n)
		if n < 1 then return nil end
		if maxN and n > maxN then n = maxN end
		return n
	end
	local function ok()
		local n = value()
		if not n then return end
		self:closeDialog()
		onOk(n)
	end

	s:button(s.x + 2, s.barY, 14, 1, "Назад", function() self:closeDialog() end, { kind = "ghost" })
	s:button(s.x + w - 18, s.barY, 16, 1, opt.okText or "Готово", ok, { kind = "primary" })
	if maxN then
		s:button(s.x + w - 15, s.y + 4, 10, 1, "макс", function() text = tostring(maxN) refresh() end,
		         { kind = "normal" })
	end

	s.onKey = function(_, ch, code)
		if code == 28 then ok()
		elseif code == 1 then self:closeDialog()
		elseif code == 14 then text = text:sub(1, -2) refresh()
		elseif ch and ch >= 48 and ch <= 57 and #text < 12 then
			text = text .. string.char(ch)
			refresh()
		else return false end
		return true
	end
	self:openDialog(s)
	refresh()
	return s
end

--- Ввод строки - поиск по витрине.
function U:askText(title, onOk, value)
	local u = self.unicode
	local w, h = 52, 9
	local s = self:dialog(w, h, "  " .. title)
	local text = value or ""
	s:panel(s.x + 4, s.y + 3, w - 8, 1, { bg = T.bg })
	local field = s:label(s.x + 5, s.y + 3, w - 10, "", { fg = T.white, bg = T.bg })
	local function refresh() field:set(text .. "█") s:flush() end
	local function ok() self:closeDialog() onOk(text) end
	s:button(s.x + 2, s.barY, 14, 1, "Отмена", function() self:closeDialog() end, { kind = "ghost" })
	s:button(s.x + w - 18, s.barY, 16, 1, "Найти", ok, { kind = "primary" })
	s.onKey = function(_, ch, code)
		if code == 28 then ok()
		elseif code == 1 then self:closeDialog()
		elseif code == 14 then text = u.sub(text, 1, -2) refresh()
		elseif ch and ch >= 32 and u.len(text) < 30 then
			text = text .. u.char(ch)
			refresh()
		else return false end
		return true
	end
	self:openDialog(s)
	refresh()
	return s
end

-- ------------------------------------------------------------------ цикл

--- Свой обработчик события OpenComputers - player_on, player_off и прочее,
--- что приходит мимо экранов.
function U:on(name, fn)
	local list = self.hooks[name]
	if not list then list = {} self.hooks[name] = list end
	list[#list + 1] = fn
end

function U:every(seconds, fn)
	self.timers[#self.timers + 1] =
		{ period = seconds, next = self.computer.uptime() + seconds, fn = fn }
end

function U:stop() self.running = false end

--- Сколько ждать до ближайшего дела: таймера или самозакрытия диалога.
function U:nextDeadline()
	local t
	for i = 1, #self.timers do
		local d = self.timers[i].next
		if not t or d < t then t = d end
	end
	local top = self:top()
	if top and top.deadline and (not t or top.deadline < t) then t = top.deadline end
	return t
end

function U:fireTimers()
	local now = self.computer.uptime()
	for i = 1, #self.timers do
		local tm = self.timers[i]
		if now >= tm.next then
			tm.next = now + tm.period
			tm.fn()
		end
	end
	local top = self:top()
	if top and top.deadline and now >= top.deadline then
		top.deadline = nil
		if top.onTimeout then top.onTimeout() end
	end
end

function U:dispatch(ev, adr, a, b, c, d)
	local list = self.hooks[ev]
	if list then
		for i = 1, #list do list[i](ev, adr, a, b, c, d) end
	end
	local top = self:top()
	if not top then return end
	if ev == "key_down" then
		if top.onKey and top.onKey(top, a, b) then top:flush() return end
		local f = top.focus
		if f and f.onKey and f:onKey(b) then top:flush() return end
	elseif ev == "touch" then
		local w = top:at(a, b)
		if w then w:onTouch(a, b, c) top:flush() end
	elseif ev == "scroll" then
		-- scroll(адрес, x, y, направление, ник). Направление в четвёртом
		-- аргументе, в пятом - имя игрока. Пока тут стояло d or c, на живой
		-- машине в арифметику уезжала строка с ником, и магазин падал на
		-- первом же движении колеса.
		local w = top:at(a, b)
		if w and w.onScroll then w:onScroll(c) top:flush()
		elseif top.focus and top.focus.onScroll then top.focus:onScroll(c) top:flush() end
	elseif ev == "drag" then
		local w = top:at(a, b)
		if w and w.onDrag then w:onDrag(a, b) top:flush() end
	end
	if top.onEvent then top:onEvent(ev, adr, a, b, c, d) top:flush() end
end

function U:run(screen)
	self.running = true
	self:clear()
	self:push(screen)
	while self.running do
		local deadline = self:nextDeadline()
		local timeout = deadline and max(0, deadline - self.computer.uptime()) or nil
		local ev, adr, a, b, c, d = self.event.pull(timeout)
		if ev == nil then
			self:fireTimers()
		elseif ev == "interrupted" then
			break
		else
			self:dispatch(ev, adr, a, b, c, d)
			self:fireTimers()
		end
	end
end

return ui
