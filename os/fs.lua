-- fs - файлы поверх компонента filesystem.
--
-- В OpenOS этим занимается lib/filesystem.lua с монтированием, путями,
-- символическими ссылками и правами. ShopOS живёт на одном диске, поэтому
-- ничего этого нет: есть загрузочная файловая система и путь от её корня.
--
-- Одна тонкость, из-за которой нельзя просто позвать read и успокоиться:
-- компонент отдаёт за раз не больше maxReadBuffer байт (в этой сборке 2048),
-- сколько бы ни попросили. Всё чтение тут идёт циклом до конца или до нужной
-- длины, и это же правило соблюдает io-обёртка в ядре.

local fs = {}

local concat = table.concat

local F = {}
F.__index = F

--- Обёртка вокруг proxy файловой системы. chunk - сколько просить за раз;
--- больше maxReadBuffer просить бессмысленно, меньше - лишние вызовы.
function fs.new(proxy, chunk)
	return setmetatable({ p = proxy, chunk = chunk or 2048 }, F)
end

--- Загрузочная файловая система: та, с которой BIOS прочитал init.lua.
function fs.boot(component, computer, chunk)
	local addr = computer.getBootAddress and computer.getBootAddress()
	if not addr then
		-- BIOS не сохранил адрес: берём первую, где лежит наш init
		for a in component.list("filesystem") do
			local ok, has = pcall(component.invoke, a, "exists", "/init.lua")
			if ok and has then addr = a break end
		end
	end
	if not addr then return nil, "не найдена загрузочная файловая система" end
	return fs.new(component.proxy(addr), chunk), addr
end

function F:exists(path) return self.p.exists(path) end
function F:isDirectory(path) return self.p.isDirectory(path) end
function F:size(path) return self.p.size(path) end
function F:list(path) return self.p.list(path) or {} end
function F:remove(path) return self.p.remove(path) end
function F:rename(a, b) return self.p.rename(a, b) end
function F:spaceUsed() return self.p.spaceUsed() end
function F:spaceTotal() return self.p.spaceTotal() end
function F:isReadOnly() return self.p.isReadOnly() end

--- Создать каталог вместе со всеми промежуточными.
function F:mkdir(path)
	if self.p.exists(path) then return true end
	return self.p.makeDirectory(path)
end

--- Каталог пути: /var/players/Steve.lua -> /var/players
function fs.dirname(path)
	local dir = path:match("^(.*)/[^/]*$")
	if not dir or dir == "" then return "/" end
	return dir
end

function fs.basename(path) return path:match("([^/]*)$") end

--- Прочитать файл целиком. nil и причина, если не открылся.
function F:read(path)
	local h, why = self.p.open(path, "r")
	if not h then return nil, why or ("нет файла " .. path) end
	local parts, n, chunk = {}, 0, self.chunk
	while true do
		local part = self.p.read(h, chunk)
		if not part or #part == 0 then break end
		n = n + 1
		parts[n] = part
	end
	self.p.close(h)
	return n == 1 and parts[1] or concat(parts)
end

--- Записать файл целиком, создав каталоги по пути.
function F:write(path, data)
	self:mkdir(fs.dirname(path))
	local h, why = self.p.open(path, "w")
	if not h then return nil, why or ("не открылся на запись " .. path) end
	local ok = self.p.write(h, data)
	self.p.close(h)
	return ok and true or nil, ok and nil or "не записалось"
end

--- Открыть на чтение с произвольным доступом: нужно каталогу иконок, он
--- читает ячейки по смещению, а не файл целиком.
function F:open(path, mode)
	local h, why = self.p.open(path, mode or "r")
	if not h then return nil, why end
	local p, chunk = self.p, self.chunk
	return {
		--- Ровно len байт или сколько осталось: компонент отдаёт кусками
		--- по maxReadBuffer, поэтому читаем циклом.
		read = function(len)
			local parts, got, k = {}, 0, 0
			while got < len do
				local want = len - got
				local part = p.read(h, want < chunk and want or chunk)
				if not part or #part == 0 then break end
				k = k + 1
				parts[k] = part
				got = got + #part
			end
			return k == 1 and parts[1] or concat(parts)
		end,
		seek = function(whence, offset) return p.seek(h, whence or "set", offset or 0) end,
		write = function(data) return p.write(h, data) end,
		close = function() return p.close(h) end,
	}
end

--- Загрузить и выполнить файл как кусок Lua. Возвращает то, что вернул сам
--- кусок, - так грузятся и модули, и конфиги.
function F:load(path, name, env)
	local text, why = self:read(path)
	if not text then return nil, why end
	local chunk, err = load(text, "=" .. (name or path), "bt", env)
	if not chunk then return nil, err end
	return chunk
end

--- Конфиг: файл, в котором лежит таблица Lua без слова return.
function F:config(path)
	local text, why = self:read(path)
	if not text then return nil, why end
	local chunk, err = load("return " .. text, "=" .. path, "t")
	if not chunk then return nil, err end
	local ok, value = pcall(chunk)
	if not ok or type(value) ~= "table" then return nil, tostring(value) end
	return value
end

return fs
