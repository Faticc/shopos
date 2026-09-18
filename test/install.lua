-- Прогон install.lua без игры: поддельная OpenOS, «GitHub» - этот каталог.
--
--   lua test/install.lua <папка> [ключи установщика...]
--
-- Запускать из shopos/. В <папка>/a - загрузочный диск (на нём OpenOS и
-- остатки прежнего ShopOS), <папка>/b - второй. Каждый по 4 МБ, как диск
-- 3-го уровня: запись сверх объёма отвечает «not enough space». Ещё есть
-- tmpfs и дискета только для чтения - установщик не должен их выбрать.
-- <папка>/d - диск данных магазина с меткой /shopos.data: свободнее
-- второго, но писать на него установщик не должен никогда.
-- Ключи стенда: "nodisk2" убирает второй диск, "nodata" - диск данных.

local OUT = assert(arg[1], "папка?")
local args, nodisk2, nodata = {}, false, false
for i = 2, #arg do
	if arg[i] == "nodisk2" then nodisk2 = true
	elseif arg[i] == "nodata" then nodata = true
	else args[#args + 1] = arg[i] end
end

local function sh(c) os.execute(c .. " >nul 2>nul") end
local function win(p) return (p:gsub("/", "\\")) end
sh('rmdir /s /q "' .. win(OUT) .. '"')

-- ------------------------------------------------------------------ диски

local CAP = 4096 * 1024

local function mkdisk(addr, dir, readonly)
	sh('mkdir "' .. win(dir) .. '"')
	local d = { type = "filesystem", address = addr, used = 0 }
	local hs, nh = {}, 1
	local function real(p) return dir .. "/" .. p:gsub("^/+", "") end
	local function size(p)
		local f = io.open(real(p), "rb")
		if not f then return 0 end
		local n = f:seek("end") f:close() return n
	end
	function d.isReadOnly() return readonly end
	function d.spaceTotal() return CAP end
	function d.spaceUsed() return d.used end
	function d.exists(p)
		local f = io.open(real(p), "rb")
		if f then f:close() return true end
		return os.rename(real(p), real(p)) and true or false
	end
	function d.makeDirectory(p) sh('mkdir "' .. win(real(p)) .. '"') return true end
	function d.remove(p)
		if not d.exists(p) then return false end
		local n = size(p)
		if os.remove(real(p)) then d.used = d.used - n return true end
		-- каталог: считаем, что в нём было всё записанное туда через put
		sh('rmdir /s /q "' .. win(real(p)) .. '"')
		d.used = d.used - (d.dirs and d.dirs[p] or 0)
		return true
	end
	function d.rename(a, b) return os.rename(real(a), real(b)) and true or false end
	function d.open(p, mode)
		if readonly then return nil, "read only" end
		if mode == "w" then d.used = d.used - size(p) end
		local f = io.open(real(p), mode == "w" and "wb" or "rb")
		if not f then return nil, p end
		hs[nh] = f
		nh = nh + 1
		return nh - 1
	end
	function d.write(h, s)
		if d.used + #s > CAP then return nil, "not enough space" end
		d.used = d.used + #s
		hs[h]:write(s)
		return true
	end
	function d.close(h) hs[h]:close() hs[h] = nil end
	--- положить файл «как было до установки»
	function d.put(p, n, under)
		local dir2 = p:match("^(.*)/[^/]*$")
		if dir2 and dir2 ~= "" then d.makeDirectory(dir2) end
		local f = io.open(real(p), "wb") f:write(string.rep("x", n)) f:close()
		d.used = d.used + n
		if under then d.dirs = d.dirs or {} d.dirs[under] = (d.dirs[under] or 0) + n end
	end
	return d
end

local A = mkdisk("aaaa-boot", OUT .. "/a")
local B = mkdisk("bbbb-second", OUT .. "/b")
local T = mkdisk("tttt-tmpfs", OUT .. "/t")
local F = mkdisk("ffff-floppy", OUT .. "/f", true)
local D = mkdisk("dddd-data", OUT .. "/d")

-- OpenOS ~ 1 МБ и прежний ShopOS: /os и каталог на 2.2 МБ
A.put("/lib/core.lua", 700 * 1024, "/lib")
A.put("/bin/sh.lua", 300 * 1024, "/bin")
A.put("/os/shop.lua", 60 * 1024, "/os")
A.put("/data/shop.bin", 2200 * 1024)
A.put("/cfg/shop.cfg", 900)
-- второй диск чем-то занят, диск данных почти пуст - он «самый свободный»
B.put("/junk.bin", 64 * 1024)
D.put("/shopos.data", 40)
D.put("/wallet/Steve", 10)

local comps = { [A.address] = A, [T.address] = T, [F.address] = F, ["net-0"] = { type = "internet" } }
if not nodisk2 then comps[B.address] = B end
if not nodata then comps[D.address] = D end

-- ------------------------------------------------------------------ OpenOS

local component = {}
function component.isAvailable(t) for _, c in pairs(comps) do if c.type == t then return true end end end
function component.get(a) for k in pairs(comps) do if k:sub(1, #a) == a then return k end end end
function component.proxy(a) return comps[a] end
function component.list(t)
	local ks = {}
	for k, c in pairs(comps) do if c.type == t then ks[#ks + 1] = k end end
	table.sort(ks)
	local i = 0
	return function() i = i + 1 return ks[i] end
end

local boot
local computer = {
	getBootAddress = function() return A.address end,
	setBootAddress = function(a) boot = a end,
	tmpAddress = function() return T.address end,
	uptime = os.clock,
	pullSignal = function() end,
	shutdown = function(r) print("[машина] перезагрузка=" .. tostring(r)) end,
}

local shell = {}
function shell.parse(...)
	local a, o = {}, {}
	for _, v in ipairs({ ... }) do
		local k, val = v:match("^%-%-([^=]+)=(.*)$")
		if k then o[k] = val
		elseif v:match("^%-%-") then o[v:sub(3)] = true
		else a[#a + 1] = v end
	end
	return a, o
end

local internet = {}
function internet.request(url)
	local path = url:match("/main/(.+)$")
	local f = io.open(path, "rb")
	local data = f and f:read("a")
	if f then f:close() end
	local pos = 1
	return setmetatable({
		response = function() return data and 200 or 404 end,
		close = function() end,
	}, { __call = function()
		if not data or pos > #data then return nil end
		local c = data:sub(pos, pos + 8191)
		pos = pos + 8192
		return c
	end })
end

local mods = { component = component, computer = computer, shell = shell, internet = internet }
local env = setmetatable({
	require = function(n) return assert(mods[n], n) end,
	print = print,
	io = { stderr = { write = function(_, s) io.stdout:write("[stderr] " .. s) end } },
	os = { sleep = function() end, exit = function(c) error({ exit = c or 0 }) end },
}, { __index = _G })

local chunk = assert(loadfile("install.lua", "t", env))
local ok, e = pcall(chunk, table.unpack(args))
if not ok and not (type(e) == "table" and e.exit) then error(e) end
print(("-- код выхода %s, загрузка с %s"):format(ok and 0 or e.exit, tostring(boot)))
print(("-- диск a: занято %d КБ из 4096, диск b: %d КБ"):format(A.used // 1024, B.used // 1024))
for _, p in ipairs({ "/init.lua", "/data/catalog.bin", "/os", "/data/shop.bin", "/lib", "/cfg/shop.cfg" }) do
	print(("   a%-20s %s"):format(p, A.exists(p) and "есть" or "нет"))
end
print(("   b/data/catalog.2.bin      %s"):format(B.exists("/data/catalog.2.bin") and "есть" or "нет"))
print(("   d: %s, занято %d байт"):format(D.exists("/data") and "ТРОНУТ УСТАНОВЩИКОМ" or "не тронут", D.used))
