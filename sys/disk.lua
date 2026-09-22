-- disk - файлы поверх компонента filesystem.
--
-- Грузится ядром до require, поэтому ничего не требует сам. Чтение режется
-- на куски: мод отдаёт за один read не больше maxReadBuffer (2048 байт в
-- конфиге сборки), и тот, кто просит 8 КБ одним вызовом, получит 2.

local disk = {}

local D = {}
D.__index = D

function disk.new(proxy) return setmetatable({ p = proxy }, D) end

function D:exists(path) return self.p.exists(path) end
function D:size(path) return self.p.size(path) or 0 end
function D:mkdir(path) return self.p.makeDirectory(path) end
function D:remove(path) return self.p.remove(path) end
function D:rename(a, b) return self.p.rename(a, b) end
function D:list(path) return self.p.list(path) or {} end

--- Свободно байт на диске.
function D:free()
	local ok1, total = pcall(self.p.spaceTotal)
	local ok2, used = pcall(self.p.spaceUsed)
	if not (ok1 and ok2) then return 0 end
	return (total or 0) - (used or 0)
end

--- Когда файл менялся, секунды настоящего времени; nil - мод не говорит.
function D:modified(path)
	local ok, ms = pcall(self.p.lastModified, path)
	if ok and type(ms) == "number" and ms > 0 then return ms / 1000 end
	return nil
end

--- Прочитать ровно len байт с позиции pos (или меньше, если файл кончился).
local function readAt(p, h, pos, len)
	if pos then p.seek(h, "set", pos) end
	local parts, got = {}, 0
	while got < len do
		local s = p.read(h, math.min(2048, len - got))
		if not s or #s == 0 then break end
		parts[#parts + 1] = s
		got = got + #s
	end
	return table.concat(parts)
end

function D:readAll(path)
	local h = self.p.open(path, "r")
	if not h then return nil end
	local parts = {}
	while true do
		local s = self.p.read(h, 2048)
		if not s or #s == 0 then break end
		parts[#parts + 1] = s
	end
	self.p.close(h)
	return table.concat(parts)
end

--- Записать файл целиком так, чтобы обрыв питания не оставил его пустым:
--- сначала рядом во временный, потом подменой.
function D:writeAll(path, data)
	local tmp = path .. ".new"
	local h = self.p.open(tmp, "w")
	if not h then return false end
	local ok = self.p.write(h, data)
	self.p.close(h)
	if not ok then return false end
	self.p.remove(path)
	return self.p.rename(tmp, path)
end

function D:append(path, data)
	local h = self.p.open(path, "a")
	if not h then return false end
	self.p.write(h, data)
	self.p.close(h)
	return true
end

--- Загрузить Lua-файл как функцию.
function D:load(path, env)
	local src = self:readAll(path)
	if not src then return nil, "нет файла " .. path end
	return load(src, "=" .. path, "t", env)
end

--- Файл-таблица: конфиг вида "{ ... }" без return.
function D:table(path)
	local src = self:readAll(path)
	if not src then return nil end
	local f = load("return " .. src, "=" .. path, "t", {})
	if not f then return nil end
	local ok, t = pcall(f)
	return ok and type(t) == "table" and t or nil
end

--- Файл, открытый на запись кусками - для обновления: каталог весит
--- мегабайты и в память машины целиком не лезет.
function D:writer(path)
	local p = self.p
	local h = p.open(path, "w")
	if not h then return nil end
	return {
		put = function(chunk) return p.write(h, chunk) end,
		close = function() pcall(p.close, h) end,
	}
end

--- Файл, открытый на чтение по смещениям - для каталога.
function D:reader(path)
	local p = self.p
	local h = p.open(path, "r")
	if not h then return nil end
	return {
		at = function(pos, len) return readAt(p, h, pos, len) end,
		close = function() pcall(p.close, h) end,
	}
end

return disk
