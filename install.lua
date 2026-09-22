-- Установка ShopOS из OpenOS:
--   wget -f https://raw.githubusercontent.com/Faticc/shopos/main/install.lua /tmp/i.lua && /tmp/i.lua
--
--   --repo=владелец/репо  --branch=ветка  --disk=адрес
--   --disk2=адрес  второй диск под catalog.2.bin (по умолчанию ищется сам:
--                  любой записываемый диск, кроме загрузочного и tmpfs)
--   --clean  стереть OpenOS (и прежний ShopOS из /os)   --dry  только показать
--   --cfg  перезаписать и /cfg/shop.cfg (по умолчанию он не трогается)
--   --noreboot  не перезагружать в конце (по умолчанию перезагружает сам)

local component = require("component")
local computer = require("computer")
local shell = require("shell")

local _, opts = shell.parse(...)
local REPO = opts.repo or "Faticc/shopos"
local BRANCH = opts.branch or "main"

local function die(s) io.stderr:write(s .. "\n") os.exit(1) end

if not component.isAvailable("internet") then die("нужна интернет-карта") end
local internet = require("internet")

local target = opts.disk or computer.getBootAddress()
local disk = component.proxy(component.get(target) or target)
if not disk or disk.type ~= "filesystem" or disk.isReadOnly() then
	die("диск " .. tostring(target) .. " не годится")
end

--- Скачать файл; sink(chunk) получает его по кускам. Каталог весит два
--- мегабайта - целиком в память машины он не лезет, пишется потоком.
local function fetch(path, sink)
	local url = ("https://raw.githubusercontent.com/%s/%s/%s"):format(REPO, BRANCH, path)
	local ok, h = pcall(internet.request, url, nil, { ["user-agent"] = "ShopOS" })
	if not ok then return nil, tostring(h) end
	local code
	for _ = 1, 200 do
		code = h.response()
		if code then break end
		os.sleep(0.05)
	end
	if code and code ~= 200 then
		pcall(h.close)
		return nil, "HTTP " .. code .. " (" .. path .. ")"
	end
	local size = 0
	local got, err = pcall(function()
		for chunk in h do
			size = size + #chunk
			sink(chunk)
		end
	end)
	pcall(h.close)
	if not got then return nil, tostring(err) end
	return size
end

-- Распаковщик для .gz-двойников каталога: на гите каталог лежит ещё и
-- сжатым, в 6-7 раз легче, а интернет-карта платит тиком за каждые 2 КБ.
-- Качается первым и живёт только в памяти установщика.
local inflate
do
	local parts = {}
	if fetch("sys/inflate.lua", function(c) parts[#parts + 1] = c end) then
		local f = load(table.concat(parts), "=inflate", "t", _ENV)
		local ok, m = pcall(f or error)
		if ok and type(m) == "table" then inflate = m end
	end
end

--- Скачать прямо в файл: сначала рядом, подмена - только если всё дошло.
--- Большие части каталога стираются заранее: старая и новая рядом на диск
--- в 4 МБ не лягут. gz - сжатый двойник: качается он и распаковывается на
--- лету; нет его на гите - качается сам файл.
local function download(dev, from, to, big, gz)
	local dir = to:match("^(.*)/[^/]*$")
	if dir and dir ~= "" and not dev.exists(dir) then dev.makeDirectory(dir) end
	if big then dev.remove(to) end
	local tmp = to .. ".part"
	local function put(h)
		return function(chunk)
			local ok, werr = dev.write(h, chunk)
			if not ok then error("запись: " .. tostring(werr or "нет места на диске"), 0) end
		end
	end
	local size, err
	if gz and inflate then
		local h, why = dev.open(tmp, "w")
		if not h then return nil, why end
		local z = inflate.new(put(h), "gzip")
		size, err = fetch(gz, function(chunk) z:feed(chunk) end)
		dev.close(h)
		if size and not z.done then size, err = nil, "сжатый поток оборвался" end
		if size then size = z.size end
		if not size then dev.remove(tmp) end
		if not size and not tostring(err):find("HTTP 404", 1, true) then return nil, err end
	end
	if not size then
		local h, why = dev.open(tmp, "w")
		if not h then return nil, why end
		size, err = fetch(from, put(h))
		dev.close(h)
		if not size then dev.remove(tmp) return nil, err end
	end
	dev.remove(to)
	dev.rename(tmp, to)
	return size
end

--- Диск данных магазина (счета, журнал) помечен /shopos.data. Установщик
--- на него не пишет никогда.
local function isData(d)
	local ok, has = pcall(d.exists, "/shopos.data")
	return ok and has
end

--- Второй диск: указанный --disk2, иначе тот, где часть каталога уже
--- лежит, иначе самый свободный записываемый - не загрузочный, не tmpfs и
--- не диск данных.
local function secondDisk(path)
	if opts.disk2 then
		local d = component.proxy(component.get(opts.disk2) or opts.disk2)
		if not d or d.type ~= "filesystem" or d.isReadOnly() then die("--disk2 не годится") end
		if isData(d) then die("--disk2: это диск данных магазина - на него не пишу") end
		return d
	end
	local tmp = computer.tmpAddress and computer.tmpAddress()
	local best, free
	for addr in component.list("filesystem") do
		if addr ~= disk.address and addr ~= tmp then
			local d = component.proxy(addr)
			if not d.isReadOnly() and not isData(d) then
				if d.exists(path) then return d end
				local f = d.spaceTotal() - d.spaceUsed()
				if not best or f > free then best, free = d, f end
			end
		end
	end
	return best
end

print("ShopOS: " .. REPO .. "@" .. BRANCH .. " -> диск " .. target:sub(1, 8))
local parts = {}
local got, why = fetch("manifest.lua", function(c) parts[#parts + 1] = c end)
if not got then die("manifest.lua: " .. tostring(why)) end
local src = table.concat(parts)
local manifest = load("return " .. src, "=manifest", "t", {})()

-- второй диск проверяем до того, как что-то стирать и писать
local disk2
for _, f in ipairs(manifest.files) do
	if f.disk == 2 then
		disk2 = secondDisk(f[2])
		if not disk2 then
			die("нужен второй жёсткий диск: на нём ляжет " .. f[2]
				.. " (крупные иконки не влезают на один). Вставьте диск и повторите")
		end
	end
end
if disk2 then print("второй диск: " .. disk2.address:sub(1, 8)) end

-- диск данных: уже помеченный или тот, что магазин возьмёт при первом
-- запуске (самый свободный из оставшихся, не дискета)
do
	local tmp = computer.tmpAddress and computer.tmpAddress()
	local marked, spare, free
	for addr in component.list("filesystem") do
		local d = component.proxy(addr)
		if addr ~= disk.address and isData(d) then
			marked = d
		elseif addr ~= disk.address and addr ~= tmp and (not disk2 or addr ~= disk2.address)
			and not d.isReadOnly() and d.spaceTotal() >= 1024 * 1024 then
			local f = d.spaceTotal() - d.spaceUsed()
			if not spare or f > free then spare, free = d, f end
		end
	end
	if marked then
		print("диск данных: " .. marked.address:sub(1, 8) .. " - счета и журнал, не трогаю")
	elseif spare then
		print("диск данных: " .. spare.address:sub(1, 8) .. " - магазин возьмёт его при первом запуске")
	else
		print("третьего диска нет: счета и журнал будут на загрузочном в /var")
	end
end

if opts.dry then
	for _, f in ipairs(manifest.files) do
		local where = f.disk == 2 and "  [второй диск]" or ""
		print("  " .. f[2] .. where .. ((f.keep and disk.exists(f[2])) and "  (есть, не трогаю)" or ""))
	end
	os.exit(0)
end

-- остатки прежних версий ShopOS стираются всегда: одни они заняли бы
-- половину диска
for _, d in ipairs(manifest.obsolete or {}) do
	if disk.exists(d) then disk.remove(d) print("  убрано старое " .. d) end
end

if opts.clean then
	for _, d in ipairs(manifest.openos) do
		if disk.exists(d) then disk.remove(d) print("  стёрто " .. d) end
	end
end

for _, f in ipairs(manifest.files) do
	if f.keep and disk.exists(f[2]) and not opts.cfg then
		print("  = " .. f[2] .. "  (есть, не трогаю; --cfg перезапишет)")
	else
		local size, err = download(f.disk == 2 and disk2 or disk, f[1], f[2], f.big, f.gz)
		if not size then die("оборвалось на " .. f[1] .. ": " .. tostring(err) .. "\n/init.lua не тронут") end
		print(("  + %-20s %d КБ"):format(f[2], math.ceil(size / 1024)))
	end
end

if not disk.exists("/var") then disk.makeDirectory("/var") end

-- Запись о том, что положено. По ней обновление из панели владельца
-- (вкладка «Обновление», sys/update.lua) понимает, что менять, и качает
-- только изменившееся - переустановка из OpenOS дальше не нужна.
do
	local rows = {}
	for _, f in ipairs(manifest.files) do
		if f.crc and not f.keep then rows[#rows + 1] = { f[2], f.crc } end
	end
	table.sort(rows, function(a, b) return a[1] < b[1] end)
	local out = { "-- что и какой версии лежит на диске: пишет обновление", "{", "\tfiles = {" }
	for _, r in ipairs(rows) do out[#out + 1] = ("\t\t[%q] = %q,"):format(r[1], r[2]) end
	out[#out + 1] = "\t},"
	out[#out + 1] = "}"
	local h = disk.open("/var/installed.lua", "w")
	if h then
		disk.write(h, table.concat(out, "\n") .. "\n")
		disk.close(h)
		print("  + /var/installed.lua  (для обновления без переустановки)")
	end
end

computer.setBootAddress(target)
-- Перезагружаемся сами. После --clean набрать reboot уже нельзя: шелл
-- ищет команду через /lib/tools/programLocations.lua, а /lib стёрт.
-- computer.shutdown - вызов к самой машине, файлы OpenOS ему не нужны.
if opts.noreboot then
	print("готово, перезагрузка: выключить и включить машину")
else
	print("готово, перезагрузка через 3 с...")
	local t = computer.uptime() + 3
	while computer.uptime() < t do computer.pullSignal(t - computer.uptime()) end
	computer.shutdown(true)
end
