local M = {}

local config = require("mpwrap.config")
local jobs = require("mpwrap.jobs")

local function parse_connect_list(output)
  local devices = {}

  for line in (output or ""):gmatch("[^\r\n]+") do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:lower():match("^no devices") then
      local port, serial, description = trimmed:match("^(%S+)%s+(%S+)%s+(.+)$")
      if not port then
        port, description = trimmed:match("^(%S+)%s+(.+)$")
      end
      if not port then
        port = trimmed:match("^(%S+)$")
      end

      if port and port:match("^/") or port and port:match("^COM%d+") then
        table.insert(devices, {
          port = port,
          serial = serial,
          description = description,
          is_usb = serial and serial ~= "None" and not trimmed:match("0000:0000"),
        })
      end
    end
  end

  table.sort(devices, function(a, b)
    if a.is_usb ~= b.is_usb then
      return a.is_usb
    end
    return a.port < b.port
  end)

  return devices
end

function M.list(callback)
  jobs.execute_raw({ "connect", "list" }, function(success, output, errors)
    if not success then
      callback(false, {}, errors or "Failed to list devices")
      return
    end

    callback(true, parse_connect_list(output), nil)
  end)
end

function M.pick(callback)
  M.list(function(success, devices, error)
    if not success then
      vim.notify("Failed to list devices: " .. (error or "unknown error"), vim.log.levels.ERROR)
      if callback then
        callback(false, nil)
      end
      return
    end

    if #devices == 0 then
      vim.notify("No MicroPython devices found by `mpremote connect list`", vim.log.levels.WARN)
      if callback then
        callback(false, nil)
      end
      return
    end

    vim.ui.select(devices, {
      prompt = "Select MicroPython device:",
      format_item = function(device)
        local label = device.port
        if device.is_usb then
          label = "USB  " .. label
        else
          label = "Other  " .. label
        end
        if device.description and device.description ~= "" then
          label = label .. "  " .. device.description
        elseif device.serial and device.serial ~= "" then
          label = label .. "  " .. device.serial
        end
        return label
      end,
    }, function(choice)
      if not choice then
        if callback then
          callback(false, nil)
        end
        return
      end

      config.select_device_port(choice.port)
      vim.notify("Selected MicroPython device: " .. choice.port, vim.log.levels.INFO)
      if callback then
        callback(true, choice)
      end
    end)
  end)
end

function M.ensure_selected(callback, opts)
  opts = opts or {}
  local policy = config.get_device_policy()

  if opts.force_pick or policy == "pick" then
    M.pick(callback)
    return
  end

  if policy == "auto" then
    if config.get_selected_device() then
      if callback then
        callback(true, { port = config.get_selected_device() })
      end
      return
    end
    M.pick(callback)
    return
  end

  if callback then
    callback(true, { port = policy })
  end
end

M._parse_connect_list = parse_connect_list

return M
