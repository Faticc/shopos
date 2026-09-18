-- paint - рисование иконок и текста на экране OC.
--
-- Два правила, от которых тут всё пляшет:
--   1. setForeground/setBackground стоят ровно столько же, сколько сам set,
--      поэтому цвет не переставляется, если он и так нужный, а соседние
--      ячейки одного цвета склеиваются в одну запись;
--   2. рисовать лучше не на экран, а в буфер видеопамяти и класть готовое
--      одним bitblt - экранные вызовы и есть весь бюджет.
-- Цвет у gpu общий на экран и на буферы, так что один и тот же painter
-- годится и туда, и туда.

local paint = {}

local byte, concat, rep = string.byte, table.concat, string.rep

-- Палитра OC: куб 6x8x5 и 16 серых, ровно в том порядке, в каком индексы
-- писал упаковщик (tools/png2img.py). В ячейке лежит индекс, gpu хочет rgb.
local PAL = {}
do
	local i = 0
	for r = 0, 5 do
		for g = 0, 7 do
			for b = 0, 4 do
				PAL[i] = r * 0x33 * 65536 + g * 0x24 * 256 + math.floor(b / 4 * 0xFF + 0.5)
				i = i + 1
			end
		end
	end
	for gr = 1, 16 do
		local v = gr * 0x0F
		PAL[i] = v * 65536 + v * 256 + v
		i = i + 1
	end
end
paint.PAL = PAL

local P = {}
P.__index = P

function paint.new(gpu, unicode)
	local half = unicode.char(0x2584)
	return setmetatable({
		gpu = gpu,
		unicode = unicode,
		half = half,
		glyph = setmetatable({}, { __index = function(t, k)
			local c = unicode.char(0x2800 + k) t[k] = c return c end }),
		curFg = nil, curBg = nil,
		calls = 0,
	}, P)
end

function P:fg(c)
	if c ~= self.curFg then self.gpu.setForeground(c) self.curFg = c self.calls = self.calls + 1 end
end

function P:bg(c)
	if c ~= self.curBg then self.gpu.setBackground(c) self.curBg = c self.calls = self.calls + 1 end
end

--- Цвета сбрасываются при смене буфера не всегда, но полагаться на это
--- нельзя: после setActiveBuffer состояние считаем неизвестным.
function P:forget() self.curFg, self.curBg = nil, nil end

function P:fill(x, y, w, h, color)
	self:bg(color)
	self.gpu.fill(x, y, w, h, " ")
	self.calls = self.calls + 1
end

function P:text(x, y, s, fg, bg)
	if bg then self:bg(bg) end
	if fg then self:fg(fg) end
	self.gpu.set(x, y, s)
	self.calls = self.calls + 1
end

function P:clip(s, n)
	local u = self.unicode
	if u.len(s) <= n then return s end
	return u.sub(s, 1, n - 1) .. "…"
end

--- Иконка из сырых ячеек каталога. w, h - размер в ячейках, transparent -
--- цвет, который считать прозрачным (обычно фон списка): такие ячейки просто
--- пропускаются, под ними и так нужный цвет.
function P:icon(cells, mode, w, h, x, y, transparent)
	local step = mode == 0 and 2 or 3
	local gpu, glyph, half = self.gpu, self.glyph, self.half
	for row = 0, h - 1 do
		local buf, bx, bbg, bfg
		local base = row * w * step
		for col = 0, w - 1 do
			local p = base + col * step + 1
			local bi, fi = byte(cells, p), byte(cells, p + 1)
			local ch
			if step == 2 then
				if bi == fi then ch = " " else ch = half end
			else
				local gl = byte(cells, p + 2)
				if gl == 0 then ch, fi = " ", bi else ch = glyph[gl] end
			end
			local bgc = PAL[bi]
			local fgc = PAL[fi]
			if ch == " " and bgc == transparent then
				if buf then
					self:bg(bbg) self:fg(bfg)
					gpu.set(bx, y + row, concat(buf))
					self.calls = self.calls + 1
					buf = nil
				end
			elseif buf and bgc == bbg and fgc == bfg then
				buf[#buf + 1] = ch
			else
				if buf then
					self:bg(bbg) self:fg(bfg)
					gpu.set(bx, y + row, concat(buf))
					self.calls = self.calls + 1
				end
				buf, bx, bbg, bfg = { ch }, x + col, bgc, fgc
			end
		end
		if buf then
			self:bg(bbg) self:fg(bfg)
			gpu.set(bx, y + row, concat(buf))
			self.calls = self.calls + 1
		end
	end
end

--- Подогнать строку ровно под n ячеек: обрезать длинную, добить короткую.
--- Пробелы дописываются здесь, а не в вызывающем коде, чтобы строка уходила
--- в gpu.set одним куском - иначе на каждую подпись шло бы два вызова.
function P:pad(s, n, align)
	local u = self.unicode
	s = tostring(s)
	local l = u.len(s)
	if l > n then return self:clip(s, n) end
	local gap = n - l
	if align == "right" then return rep(" ", gap) .. s end
	if align == "center" then
		local left = (gap - gap % 2) / 2
		return rep(" ", left) .. s .. rep(" ", gap - left)
	end
	return s .. rep(" ", gap)
end

--- Рамка вокруг прямоугольника. Четыре вызова вместо h+2: боковые стойки
--- рисуются столбцами через fill, а не строкой на каждый ряд.
function P:box(x, y, w, h, fg, bg)
	self:bg(bg) self:fg(fg)
	local g = self.gpu
	g.set(x, y, "┌" .. rep("─", w - 2) .. "┐")
	g.set(x, y + h - 1, "└" .. rep("─", w - 2) .. "┘")
	g.fill(x, y + 1, 1, h - 2, "│")
	g.fill(x + w - 1, y + 1, 1, h - 2, "│")
	self.calls = self.calls + 4
end

return paint
