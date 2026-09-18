-- Что из репозитория куда ложится на диск. init.lua последним: пока его
-- нет, недокачанная система не станет загрузочной.
{
	files = {
		{ "sys/disk.lua",     "/sys/disk.lua" },
		{ "sys/gfx.lua",      "/sys/gfx.lua" },
		{ "sys/catalog.lua",  "/sys/catalog.lua" },
		{ "sys/storage.lua",  "/sys/storage.lua" },
		{ "sys/wallet.lua",   "/sys/wallet.lua" },
		{ "sys/shop.lua",     "/sys/shop.lua" },
		{ "data/catalog.bin", "/data/catalog.bin" },
		{ "cfg/shop.cfg",     "/cfg/shop.cfg", keep = true },
		{ "init.lua",         "/init.lua" },
	},
	-- стирается только по --clean
	openos = { "/bin", "/lib", "/boot", "/etc", "/usr", "/home", "/mnt", "/os" },
}
