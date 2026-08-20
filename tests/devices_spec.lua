vim.opt.runtimepath:prepend(vim.fn.getcwd())

local helpers = dofile(vim.fn.getcwd() .. "/tests/helpers.lua")
local assert_equal = helpers.assert_equal

local devices = require("mpwrap.devices")

local parsed_devices = devices._parse_connect_list("/dev/cu.SLAB_USBtoUART  1234  CP210x UART Bridge\n")
assert_equal(#parsed_devices, 1, "parse device count")
assert_equal(parsed_devices[1].port, "/dev/cu.SLAB_USBtoUART", "parse device port")

local no_devices = devices._parse_connect_list("no devices found\n")
assert_equal(#no_devices, 0, "no devices line parses to zero entries")

print("devices_spec passed")
