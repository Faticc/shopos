-- Что из репозитория куда ложится на диск. init.lua последним: пока его
-- нет, недокачанная система не станет загрузочной.
{
	files = {
		{ "sys/disk.lua",    "/sys/disk.lua",  size = 4034, crc = "f4f1ea5d" },
		{ "sys/gfx.lua",     "/sys/gfx.lua",   size = 24118, crc = "b60b5752" },
		{ "sys/catalog.lua", "/sys/catalog.lua",size = 6729, crc = "8812a011" },
		{ "sys/storage.lua", "/sys/storage.lua",size = 6278, crc = "754e836d" },
		{ "sys/vault.lua",   "/sys/vault.lua", size = 5478, crc = "b9f8d648" },
		{ "sys/wallet.lua",  "/sys/wallet.lua",size = 7503, crc = "10a6dd92" },
		{ "sys/rules.lua",   "/sys/rules.lua", size = 4264, crc = "4d95c36b" },
		{ "sys/theme.lua",   "/sys/theme.lua", size = 3159, crc = "36efb94b" },
		{ "sys/inflate.lua", "/sys/inflate.lua",size = 10384, crc = "582eaaa5" },
		{ "sys/update.lua",  "/sys/update.lua",size = 23712, crc = "ba883e1b" },
		{ "sys/admin.lua",   "/sys/admin.lua", size = 27658, crc = "53bff317" },
		{ "sys/shop.lua",    "/sys/shop.lua",  size = 63924, crc = "528d8b63" },
		-- каталог двумя частями: крупные иконки на один диск не влезают.
		-- Вторая часть ложится на второй жёсткий диск, магазин найдёт её сам
		{ "data/catalog.bin", "/data/catalog.bin",size = 2661940, crc = "690383a0", big = true, gz = "data/catalog.bin.gz", gzsize = 452565 },
		{ "data/catalog.2.bin", "/data/catalog.2.bin",size = 2970624, crc = "2812a7f8", big = true, disk = 2, gz = "data/catalog.2.bin.gz", gzsize = 402577 },
		{ "cfg/shop.cfg",    "/cfg/shop.cfg",  size = 3279, crc = "b8d18532", keep = true },
		{ "init.lua",        "/init.lua",      size = 4857, crc = "6ad6ba43" },
	},
	-- стирается только по --clean
	openos = { "/bin", "/lib", "/boot", "/etc", "/usr", "/home", "/mnt" },
	-- прежние версии ShopOS: стирается всегда
	obsolete = { "/os", "/data/shop.bin", "/data/icons.bin" },
}
