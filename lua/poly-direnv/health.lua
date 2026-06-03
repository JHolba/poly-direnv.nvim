--- Checkhealth for poly-direnv.nvim
---
--- Run with :checkhealth poly-direnv

local M = {}

--- @param version string e.g. "2.35.0"
--- @return integer major, integer minor, integer patch
local function parse_version(version)
  local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)")
  if not major then
    return 0, 0, 0
  end
  return tonumber(major), tonumber(minor), tonumber(patch)
end

function M.check()
  local health = vim.health

  -- 1. Neovim version -----------------------------------------------------------
  health.start("Neovim")

  local nvim_version = vim.version()
  local nvim_str = ("%d.%d.%d"):format(nvim_version.major, nvim_version.minor, nvim_version.patch)

  if nvim_version.major > 0 or (nvim_version.major == 0 and nvim_version.minor >= 10) then
    health.ok("Neovim >= 0.10 (" .. nvim_str .. ")")
  else
    health.error("Neovim >= 0.10 required, found " .. nvim_str)
  end

  -- 2. direnv binary ------------------------------------------------------------
  health.start("direnv")

  local poly = require("poly-direnv")
  local bin = poly.config.bin or "direnv"

  if vim.fn.executable(bin) ~= 1 then
    health.error("`" .. bin .. "` not found on PATH", {
      "Install direnv: https://direnv.net/docs/installation.html",
      "Or set the `bin` option to an absolute path in your setup() call",
    })
  else
    health.ok("`" .. bin .. "` found: " .. (vim.fn.exepath(bin) or bin))

    -- direnv version
    local obj = vim.system({ bin, "version" }, { text = true }):wait()
    if obj.code == 0 and obj.stdout then
      local version_str = vim.trim(obj.stdout)
      local major, minor, _ = parse_version(version_str)
      if major >= 2 and minor >= 33 then
        health.ok("direnv version: " .. version_str .. " (>= 2.33.0)")
      else
        health.warn("direnv version: " .. version_str .. " (recommended >= 2.33.0)", {
          "Older versions may work but are untested",
        })
      end
    else
      health.warn("Could not determine direnv version")
    end
  end

  -- 3. Plugin setup state -------------------------------------------------------
  health.start("Plugin status")

  -- Check if setup() has been called by looking at whether vim.lsp.start is wrapped
  local lsp_wrapped = vim.lsp.start ~= nil and type(vim.lsp.start) == "function"
  -- We can detect the wrapper by checking if the original was saved.
  -- The simplest reliable check: see if the module recorded is_setup.
  -- is_setup is local so we check indirectly: original_lsp_start is set during setup().
  -- Another approach: check if user commands exist.
  local has_commands = vim.fn.exists(":PolyDirenvStatus") == 2

  if has_commands then
    health.ok("setup() has been called")
  else
    health.warn("setup() has not been called yet", {
      'Call require("poly-direnv").setup() in your Neovim config',
    })
  end

  -- 4. Configuration ------------------------------------------------------------
  health.start("Configuration")

  health.info("bin: " .. poly.config.bin)
  health.info("autoload: " .. tostring(poly.config.autoload))
  health.info("cache_ttl: " .. tostring(poly.config.cache_ttl) .. "ms")
  health.info("notifications.on_load: " .. tostring(poly.config.notifications.on_load))
  health.info("notifications.on_envrc_change: " .. tostring(poly.config.notifications.on_envrc_change))

  if not poly.config.autoload then
    health.warn("autoload is disabled -- LSP servers will not automatically receive direnv environments")
  end

  -- 5. Active LSP clients -------------------------------------------------------
  health.start("LSP clients")

  local clients = vim.lsp.get_clients()
  if #clients == 0 then
    health.info("No active LSP clients")
  else
    local NO_ENVRC = "__no_envrc__"
    local with_envrc = 0
    local without_envrc = 0

    for _, client in ipairs(clients) do
      local envrc = client.config._direnv_envrc
      if envrc and envrc ~= NO_ENVRC then
        with_envrc = with_envrc + 1
        health.ok(client.name .. " (id=" .. client.id .. "): " .. envrc)
      elseif envrc == NO_ENVRC then
        without_envrc = without_envrc + 1
        health.info(client.name .. " (id=" .. client.id .. "): no .envrc (tagged)")
      else
        without_envrc = without_envrc + 1
        health.info(client.name .. " (id=" .. client.id .. "): not managed by poly-direnv")
      end
    end

    health.info(("%d client(s) with direnv env, %d without"):format(with_envrc, without_envrc))
  end
end

return M
