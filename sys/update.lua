-- update - обновление ShopOS с гита прямо из панели владельца.
--
-- Установщик ставит систему из OpenOS, и ради пары изменившихся файлов
-- поднимать OpenOS заново незачем. Здесь магазин сам качает manifest.lua,
-- сверяет его с записью /var/installed.lua (что и какой версии положили в
-- прошлый раз) и берёт с гита только то, у чего разошёлся CRC32.
--
-- Качает так же, как get в DwOS (lib/fetch.lua). Интернет-карта берёт тик
-- на каждый запрос и по два тика на каждые 2 КБ ответа - около 20 КБ/с на
-- поток, и обойти это нельзя. Выжать можно остальное:
--   * четыре запроса разом (больше карта не держит): пока сервер думает
--     над одним, читаем другой;
--   * сжатие: код на Lua просим gzip-ом (raw.githubusercontent его отдаёт)
--     - приходит втрое меньше; каталоги лежат на гите .gz-двойниками
--     (tools/genmanifest.py), они в 6-7 раз легче. Распаковка тратит
--     процессор, а не тики;
--   * конец потока: размер без сжатия известен из манифеста - лишние read
--     на пустой хвост не нужны.
--
-- Чего обновление не трогает никогда: диск данных (счета, журнал,
-- rules.cfg, темы игроков) и /cfg/shop.cfg - он помечен keep в манифесте.
--
-- Порядок важен. Сперва все мелкие файлы качаются в память и лишь потом
-- подменяются разом: оборванная сеть не оставит половину системы от одной
-- версии, половину от другой. Каталог идёт последним - он в мегабайты,
-- двух копий диск не вмещает, поэтому старая стирается до загрузки. Обрыв
-- на нём оставит магазин без цен, но с рабочей панелью, из которой
-- обновление повторяется.

local root = require("root")
local disk = require("disk")

local computer, component = computer, component

local okZ, inflate = pcall(require, "inflate")
if not okZ then inflate = nil end

local update = {}

local cfg = root:table("/cfg/shop.cfg") or {}
local REPO = cfg.repo or "Faticc/shopos"
local BRANCH = cfg.branch or "main"
local BASE = ("https://raw.githubusercontent.com/%s/%s/"):format(REPO, BRANCH)

update.where = REPO .. "@" .. BRANCH

local RECORD = "/var/installed.lua"
local MARK = "/shopos.data"        -- метка диска данных: на него не пишем
local PARALLEL = 4                 -- столько запросов карта держит разом
local TIMEOUT = 30                 -- секунд ждать ответа сервера

-- ------------------------------------------------------------------ CRC32

--- Процессор бывает и на Lua 5.3 (операторы & ~ >>), и на 5.2 (bit32):
--- код под 5.3 в 5.2 даже не разберётся, поэтому собирается через load.
local crc32
do
	local f = load([[
		local T = {}
		for i = 0, 255 do
			local c = i
			for _ = 1, 8 do
				if c & 1 == 1 then c = 0xEDB88320 ~ (c >> 1) else c = c >> 1 end
			end
			T[i] = c
		end
		local byte = string.byte
		return function(crc, s)
			crc = ~crc & 0xFFFFFFFF
			for i = 1, #s do crc = T[(crc ~ byte(s, i)) & 0xFF] ~ (crc >> 8) end
			return ~crc & 0xFFFFFFFF
		end]])
	if f then
		crc32 = f()
	elseif bit32 then
		local band, bxor, rshift, bnot = bit32.band, bit32.bxor, bit32.rshift, bit32.bnot
		local T = {}
		for i = 0, 255 do
			local c = i
			for _ = 1, 8 do
				if band(c, 1) == 1 then c = bxor(0xEDB88320, rshift(c, 1)) else c = rshift(c, 1) end
			end
			T[i] = c
		end
		local byte = string.byte
		crc32 = function(crc, s)
			crc = bnot(crc)
			for i = 1, #s do crc = bxor(T[band(bxor(crc, byte(s, i)), 0xFF)], rshift(crc, 8)) end
			return bnot(crc)
		end
	end
end

local function hex(crc) return ("%08x"):format(crc) end

--- Машина, которая слишком долго не уступает управление, падает: хэш
--- считается кусками, между ними отдаём тик.
local lastYield = computer.uptime()
local function breathe()
	if computer.uptime() - lastYield > 1 then
		computer.pullSignal(0)
		lastYield = computer.uptime()
	end
end

-- ------------------------------------------------------------------ диски

local function writable(p)
	local ok, ro = pcall(p.isReadOnly)
	return ok and not ro
end

local function isData(p)
	local ok, has = pcall(p.exists, MARK)
	return ok and has
end

--- Диск под вторую часть каталога: тот, где она уже лежит, иначе самый
--- свободный записываемый - не загрузочный, не tmpfs и не диск данных.
function update.second(path)
	local boot = computer.getBootAddress()
	local tmp = computer.tmpAddress and computer.tmpAddress()
	local best, free
	for addr in component.list("filesystem") do
		if addr ~= boot and addr ~= tmp then
			local p = component.proxy(addr)
			if writable(p) and not isData(p) then
				local ok, has = pcall(p.exists, path)
				if ok and has then return disk.new(p) end
				local d = disk.new(p)
				local f = d:free()
				if not best or f > free then best, free = d, f end
			end
		end
	end
	return best
end

local function deviceFor(e) return e.disk2 and update.second(e.to) or root end

-- ------------------------------------------------------------------ сеть

--- Интернет-карта: она нужна только на время обновления, в обычной работе
--- магазина её в машине может и не быть.
function update.card()
	local c = component.internet
	if not c then return nil, "нет интернет-карты - вставьте её в машину и проверьте снова" end
	local ok, on = pcall(c.isHttpEnabled)
	if ok and on == false then return nil, "интернет-карта не разрешает HTTP" end
	return c
end

local function header(headers, name)
	if type(headers) ~= "table" then return nil end
	for k, v in pairs(headers) do
		if type(k) == "string" and k:lower() == name then
			return type(v) == "table" and v[1] or v
		end
	end
end

--- Скачать список разом, до четырёх запросов параллельно. Задание:
---   url, plain (не просить сжатия), size (сколько ждать без сжатия),
---   gz (это .gz-двойник - распаковать), write(s), finish(err, code),
---   start(lane) - занял поток номер lane.
--- tick() зовётся между чтениями - для хода дела. wire(n) - пришло n байт
--- по сети.
local function many(jobs, tick, wire)
	local inet, why = update.card()
	if not inet then
		for _, job in ipairs(jobs) do job.finish(why) end
		return
	end
	local active, qi = {}, 1
	local lanes = {}

	local function done(a, err, code)
		for i = #active, 1, -1 do if active[i] == a then table.remove(active, i) end end
		if a.h then pcall(a.h.close) end
		a.h = nil
		lanes[a.lane] = nil
		a.job.finish(err, code)
	end

	local function start(job)
		local hd = { ["user-agent"] = "ShopOS" }
		if not job.plain and inflate then hd["accept-encoding"] = "gzip" end
		local ok, h, err = pcall(inet.request, job.url, nil, hd)
		if not ok or not h then
			err = tostring(ok and err or h)
			if err:find("too many", 1, true) then return "wait" end
			job.finish(err)
			return
		end
		local lane = 1
		while lanes[lane] do lane = lane + 1 end
		lanes[lane] = true
		active[#active + 1] = { job = job, h = h, t0 = computer.uptime(), got = 0, lane = lane }
		if job.start then job.start(lane) end
	end

	--- Ответ пришёл: код и сжатие видны бесплатно. true - можно читать.
	local function arrived(a)
		if a.code then return true end
		local ok, code, _, headers = pcall(a.h.response)
		if not ok then done(a, tostring(code)) return false end
		if not code then
			if computer.uptime() - a.t0 > TIMEOUT then done(a, "сервер не ответил за " .. TIMEOUT .. " с") end
			return false
		end
		a.code = code
		if code < 200 or code >= 300 then
			done(a, "HTTP " .. tostring(code), code)
			return false
		end
		local job = a.job
		local gz = job.gz or (header(headers, "content-encoding") or ""):lower():find("gzip", 1, true)
		if gz then
			if not inflate then done(a, "нечем распаковать: нет /sys/inflate.lua") return false end
			a.z = inflate.new(function(s)
				a.got = a.got + #s
				job.write(s)
			end, "gzip")
		end
		return true
	end

	local function step(a)
		local ok, chunk, err = pcall(a.h.read, 2048)
		if not ok or (chunk == nil and err) then return done(a, tostring(ok and err or chunk)) end
		local job = a.job
		if chunk == nil then                   -- конец потока
			if a.z and not a.z.done then return done(a, "поток оборвался") end
			if job.size and a.got ~= job.size then
				return done(a, ("пришло %d Б, а ждали %d"):format(a.got, job.size))
			end
			return done(a, nil, a.code)
		end
		if chunk == "" then return end         -- карта подкачивает следующие 2 КБ
		if wire then wire(#chunk) end
		if a.z then
			local zok, zerr = pcall(a.z.feed, a.z, chunk)
			if not zok then return done(a, tostring(zerr)) end
			if a.z.done then return done(a, nil, a.code) end
		else
			a.got = a.got + #chunk
			local wok, werr = pcall(job.write, chunk)
			if not wok then return done(a, tostring(werr)) end
			if job.size and a.got >= job.size then return done(a, nil, a.code) end
		end
	end

	while qi <= #jobs or #active > 0 do
		-- в первую очередь - новые запросы: ответ сервера идёт своим чередом,
		-- пока мы читаем другие
		local started = false
		if qi <= #jobs and #active < PARALLEL then
			local r = start(jobs[qi])
			if r ~= "wait" then qi, started = qi + 1, true end
		end
		if not started then
			local reading
			for i = 1, #active do
				local a = active[i]
				if a and arrived(a) then reading = a break end
			end
			if reading then
				step(reading)
			elseif #active > 0 then
				computer.pullSignal(0.05)          -- все ждут ответа сервера
			end
		end
		if tick then tick() end
		breathe()
	end
end

--- Скачать один файл репозитория целиком. Тело или nil и причина.
local function get(path)
	local parts, err = {}, nil
	many({ {
		url = BASE .. path,
		write = function(s) parts[#parts + 1] = s end,
		finish = function(e) err = e end,
	} })
	if err then return nil, path .. ": " .. err end
	return table.concat(parts)
end

--- Манифест с гита: что куда ложится, размеры и хэши.
function update.manifest()
	local src, why = get("manifest.lua")
	if not src then return nil, why end
	local f = load("return " .. src, "=manifest", "t", {})
	if not f then return nil, "manifest.lua не разбирается" end
	local ok, t = pcall(f)
	if not ok or type(t) ~= "table" or type(t.files) ~= "table" then
		return nil, "manifest.lua не того вида"
	end
	return t
end

-- ------------------------------------------------------------------ запись

--- Что лежит на диске по прошлому обновлению: путь -> CRC32.
function update.record()
	local t = root:table(RECORD)
	if type(t) ~= "table" or type(t.files) ~= "table" then return { files = {} } end
	return t
end

local function saveRecord(files)
	local keys = {}
	for k in pairs(files) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = { "-- что и какой версии лежит на диске: пишет обновление", "{", "\tfiles = {" }
	for _, k in ipairs(keys) do out[#out + 1] = ("\t\t[%q] = %q,"):format(k, files[k]) end
	out[#out + 1] = "\t},"
	out[#out + 1] = "}"
	return root:writeAll(RECORD, table.concat(out, "\n") .. "\n")
end

--- Хэш файла на диске. Считается только для мелких: мегабайты каталога
--- машина хэшировала бы полминуты, для него хватает размера.
local function hashOf(dev, path)
	local data = dev:readAll(path)
	if not data then return nil end
	breathe()
	return hex(crc32(0, data))
end

-- ------------------------------------------------------------------ сверка

--- Что изменилось. Возвращает список записей манифеста с пометкой need и
--- человеческим объяснением why.
function update.check()
	local man, why = update.manifest()
	if not man then return nil, why end
	local rec = update.record()
	local list = {}
	for _, f in ipairs(man.files) do
		local e = {
			from = f[1], to = f[2], size = f.size or 0, crc = f.crc,
			big = f.big, disk2 = f.disk == 2, keep = f.keep, gz = f.gz, gzsize = f.gzsize,
		}
		local dev = deviceFor(e)
		local have = rec.files[e.to]
		if e.keep then
			e.why = "своё, не трогаю"
		elseif not dev then
			e.need, e.why = true, "нет диска под него"
		elseif not dev:exists(e.to) then
			e.need, e.why = true, "нет на диске"
		elseif not e.crc then
			e.need, e.why = true, "в манифесте без хэша"
		elseif have == e.crc then
			e.why = "то же самое"
		elseif have then
			e.need, e.why = true, "другая версия"
		elseif e.big then
			-- записи ещё нет (ставили прежним установщиком), а мегабайты
			-- хэшировать долго: сверяем размер, а кому мало - «скачать всё»
			if dev:size(e.to) == e.size then e.why = "тот же размер" else e.need, e.why = true, "другой размер" end
		elseif hashOf(dev, e.to) == e.crc then
			e.why = "то же самое"
		else
			e.need, e.why = true, "другая версия"
		end
		list[#list + 1] = e
	end
	return list
end

--- Скачать заново вообще всё, кроме своего конфига: на случай, когда файл
--- сошёлся размером, а на деле не тот.
function update.forceAll(list)
	for _, e in ipairs(list) do
		if not e.keep then e.need, e.why = true, "качаю заново" end
	end
	return list
end

--- Сколько по сети: двойник - его размер, код на Lua - примерно треть.
local function wireOf(e)
	if e.gz and e.gzsize and inflate then return e.gzsize end
	if not e.big and inflate then return math.ceil(e.size / 3) end
	return e.size
end

--- Сколько файлов качать, их размер и сколько это по сети.
function update.pending(list)
	local n, bytes, wire = 0, 0, 0
	for _, e in ipairs(list or {}) do
		if e.need then n, bytes, wire = n + 1, bytes + e.size, wire + wireOf(e) end
	end
	return n, bytes, wire
end

-- ------------------------------------------------------------------ загрузка

--- Скачать и подменить всё помеченное. progress(prog) показывает ход дела
--- (не чаще двух раз в секунду):
---   prog.files  - { to, size, got, state = wait | run | ok | bad }
---   prog.lanes  - что сейчас в каждом из четырёх потоков
---   prog.got, total, wire, wireTotal, speed (байт/с по сети), phase
--- release() зовётся перед подменой каталога: магазин держит его открытым,
--- а открытый файл на Windows-сервере не стереть и не переименовать.
--- Возвращает сколько файлов положено или nil и причину.
function update.apply(list, progress, release)
	progress = progress or function() end
	if not crc32 then return nil, "нет ни битовых операций, ни bit32 - хэш считать нечем" end
	local small, big = {}, {}
	local prog = { files = {}, lanes = {}, got = 0, total = 0, wire = 0, wireTotal = 0, speed = 0,
		phase = "Качаю код" }
	for _, e in ipairs(list) do
		if e.need then
			if e.big then big[#big + 1] = e else small[#small + 1] = e end
			e.pf = { to = e.to, size = e.size, got = 0, state = "wait" }
			prog.files[#prog.files + 1] = e.pf
			prog.total = prog.total + e.size
			prog.wireTotal = prog.wireTotal + wireOf(e)
		end
	end
	if #small + #big == 0 then return 0 end

	local t0, last = computer.uptime(), 0
	local function tick(force)
		local now = computer.uptime()
		if not force and now - last < 0.5 then return end
		last = now
		local got = 0
		for _, f in ipairs(prog.files) do got = got + f.got end
		prog.got = got
		prog.speed = now > t0 and prog.wire / (now - t0) or 0
		progress(prog)
	end
	local function wire(n) prog.wire = prog.wire + n end

	--- Задание на файл: собирает в память (мелкий) или пишет в tmp (большой),
	--- считает хэш; по концу - проверка размера и хэша.
	local function job(e, dev, tmp)
		local n, crc, parts, w, werr = 0, 0, nil, nil, nil
		local j = {}
		local function reset()
			n, crc = 0, 0
			if tmp then
				if w then w.close() end
				dev:remove(tmp)
				w = dev:writer(tmp)
				if not w then werr = "не открыть " .. tmp end
			else
				parts = {}
			end
		end
		reset()
		j.size = e.size
		j.start = function(lane)
			prog.lanes[lane] = e.pf
			e.pf.state, e.lane = "run", lane
		end
		j.write = function(s)
			if werr then error(werr, 0) end
			n, crc = n + #s, crc32(crc, s)
			e.pf.got = n
			if parts then
				parts[#parts + 1] = s
			elseif not w.put(s) then
				werr = "на диске кончилось место под " .. e.to
				error(werr, 0)
			end
		end
		j.finish = function(err, code)
			if e.lane then prog.lanes[e.lane] = nil e.lane = nil end
			if w then w.close() w = nil end
			if not err and n ~= e.size then err = ("пришло %d Б вместо %d"):format(n, e.size) end
			if not err and e.crc and hex(crc) ~= e.crc then err = "хэш не сошёлся, файл побился по дороге" end
			if err then
				if tmp then dev:remove(tmp) end
				e.err, e.code, e.pf.state, e.pf.got = err, code, "bad", 0
				parts = nil
				return
			end
			e.data = parts and table.concat(parts) or nil
			e.err, e.pf.state = nil, "ok"
		end
		return j
	end

	--- Скачать группу: всё разом, что не вышло - ещё раз. Двойник .gz,
	--- которого нет на гите (404), заменяется самим файлом; 404 на самом
	--- файле повтор не лечит.
	local function fetchAll(group, place)
		for _ = 1, 3 do
			local jobs = {}
			for _, e in ipairs(group) do
				if e.pf.state ~= "ok" and not e.dead then
					local dev, tmp
					if place then dev, tmp = place(e) end
					local j = job(e, dev, tmp)
					local viaGz = e.gz and inflate and not e.noGz
					if viaGz then
						j.url, j.plain, j.gz = BASE .. e.gz, true, true
					else
						j.url, j.plain = BASE .. e.from, e.big or nil
					end
					local fin = j.finish
					j.finish = function(err, code)
						fin(err, code)
						if err and code == 404 then
							if viaGz then e.noGz = true else e.dead = true end
						end
					end
					jobs[#jobs + 1] = j
				end
			end
			if #jobs == 0 then break end
			tick(true)
			many(jobs, tick, wire)
			for _, e in ipairs(group) do
				if e.pf.state ~= "ok" then e.pf.state = "wait" end
			end
		end
		for _, e in ipairs(group) do
			if e.pf.state ~= "ok" then
				e.pf.state = "bad"
				return nil, e.to .. ": " .. tostring(e.err or "не скачался")
			end
		end
		return true
	end

	-- 1. мелкие - все в память: оборвётся на последнем, и ни один из уже
	-- скачанных не подменён
	for _, e in ipairs(small) do
		e.dev = deviceFor(e)
		if not e.dev then return nil, "некуда класть " .. e.to end
	end
	local ok, why = fetchAll(small)
	if not ok then
		tick(true)
		return nil, why
	end
	-- 2. подменить разом: сперва всё в .part, потом переименовать
	prog.phase = "Кладу файлы"
	tick(true)
	for _, e in ipairs(small) do
		local dir = e.to:match("^(.*)/[^/]*$")
		if dir and dir ~= "" and not e.dev:exists(dir) then e.dev:mkdir(dir) end
		if not e.dev:writeAll(e.to .. ".part", e.data) then
			for _, d in ipairs(small) do d.dev:remove(d.to .. ".part") end
			return nil, "не записать " .. e.to .. " - место на диске?"
		end
		e.data = nil
	end
	for _, e in ipairs(small) do
		e.dev:remove(e.to)
		if not e.dev:rename(e.to .. ".part", e.to) then return nil, "не подменить " .. e.to end
	end

	-- 3. каталог: двух копий диск не вмещает, поэтому старая уходит раньше
	if #big > 0 then
		prog.phase = "Качаю каталог"
		if release then release() end
		local need = {}
		for _, e in ipairs(big) do
			e.dev = deviceFor(e)
			if not e.dev then return nil, "некуда класть " .. e.to end
			local d = need[e.dev] or { size = 0, old = 0, list = {} }
			need[e.dev] = d
			d.size = d.size + e.size + 4096
			d.old = d.old + (e.dev:exists(e.to) and e.dev:size(e.to) or 0)
			d.list[#d.list + 1] = e
		end
		for dev, d in pairs(need) do
			if dev:free() + d.old < d.size then
				return nil, ("на диске мало места под каталог: нужно %d КБ, есть %d КБ")
					:format(math.ceil(d.size / 1024), math.floor((dev:free() + d.old) / 1024))
			end
			if dev:free() < d.size then
				for _, e in ipairs(d.list) do dev:remove(e.to) end
			end
		end
		for _, e in ipairs(big) do
			local dir = e.to:match("^(.*)/[^/]*$")
			if dir and dir ~= "" and not e.dev:exists(dir) then e.dev:mkdir(dir) end
		end
		ok, why = fetchAll(big, function(e) return e.dev, e.to .. ".part" end)
		if not ok then
			tick(true)
			return nil, why
		end
		for _, e in ipairs(big) do
			e.dev:remove(e.to)
			if not e.dev:rename(e.to .. ".part", e.to) then return nil, "не подменить " .. e.to end
		end
	end
	prog.phase = "Готово"
	tick(true)

	-- 4. запись о том, что теперь лежит. Файлы, сошедшиеся размером,
	-- записываются хэшем манифеста - с этого момента сверка по нему точная
	local rec = update.record()
	for _, e in ipairs(list) do
		if not e.keep and e.crc then rec.files[e.to] = e.crc end
	end
	if not saveRecord(rec.files) then
		return #small + #big, "файлы положены, но запись /var/installed.lua не сохранилась"
	end
	return #small + #big
end

return update
