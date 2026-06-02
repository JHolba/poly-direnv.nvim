--- multi-lsp-direnv.nvim
---
--- Automatically provides per-directory direnv environments to LSP servers.
--- Each LSP server process is keyed by (name, envrc_path), so files under
--- different .envrc scopes get separate server instances with the correct
--- environment variables.
---
--- Works by wrapping vim.lsp.start() to inject cmd_env and override the
--- reuse_client predicate before the server process is spawned.

local cache = require("multi-lsp-direnv.cache")
local direnv = require("multi-lsp-direnv.direnv")

local M = {}

--- @class multi_lsp_direnv.Config
--- @field cache_ttl integer Cache TTL in milliseconds (default 30000)
--- @field bin string Path to direnv binary (default "direnv")
--- @field autoload boolean Automatically inject env on LSP start (default true)
--- @field notifications { on_load: boolean, on_envrc_change: boolean }

--- @type multi_lsp_direnv.Config
M.config = {
  cache_ttl = 30000,
  bin = "direnv",
  autoload = true,
  notifications = {
    on_load = true,
    on_envrc_change = true,
  },
}

--- @type fun(config: vim.lsp.ClientConfig, opts: table?): integer?
local original_lsp_start = nil

--- @type boolean
local is_setup = false

--- Sentinel value for "no envrc found" so we can cache the absence.
local NO_ENVRC = "__no_envrc__"

--- Pending LSP starts waiting for direnv resolution.
--- Key: a unique id, Value: { config, opts, bufnr, dir }
--- @type table<integer, { config: vim.lsp.ClientConfig, opts: table, bufnr: integer, dir: string }>
local pending_starts = {}
local pending_id = 0

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "multi-lsp-direnv" })
end

--- Get the directory for a buffer's file.
--- @param bufnr integer
--- @return string?
local function buf_dir(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if fname == "" then
    return nil
  end
  return vim.fs.dirname(fname)
end

--- Workspace folder check that mirrors neovim's default reuse logic.
--- Uses vim.lsp._get_workspace_folders if available, falls back to
--- a simple root_dir comparison.
--- @param client vim.lsp.Client
--- @param config vim.lsp.ClientConfig
--- @return boolean
local function workspace_match(client, config)
  local get_ws = vim.lsp._get_workspace_folders
  if not get_ws then
    -- Fallback: compare root_dir directly
    return (client.config.root_dir or "") == (config.root_dir or "")
  end

  local config_folders = get_ws(config.workspace_folders or config.root_dir)

  if not config_folders or not next(config_folders) then
    local client_config_folders = get_ws(client.config.workspace_folders or client.config.root_dir)
    return not client_config_folders or not next(client_config_folders)
  end

  for _, config_folder in ipairs(config_folders) do
    local found = false
    for _, client_folder in ipairs(client.workspace_folders or {}) do
      if config_folder.uri == client_folder.uri then
        found = true
        break
      end
    end
    if not found then
      return false
    end
  end

  return true
end

--- Reuse predicate that also checks envrc path.
--- Two servers with the same name but different .envrc scopes must NOT reuse.
--- @param client vim.lsp.Client
--- @param config vim.lsp.ClientConfig
--- @return boolean
local function reuse_client_with_envrc(client, config)
  if client.name ~= config.name or client:is_stopped() then
    return false
  end

  -- Both must agree on envrc
  local client_envrc = client.config._direnv_envrc
  local config_envrc = config._direnv_envrc
  if client_envrc ~= config_envrc then
    return false
  end

  return workspace_match(client, config)
end

--- Complete the deferred LSP start with the resolved environment.
--- @param config vim.lsp.ClientConfig
--- @param opts table
--- @param bufnr integer
--- @param envrc_path string?
--- @param env table<string, string?>?
local function complete_lsp_start(config, opts, bufnr, envrc_path, env)
  -- Tag the config so reuse_client can differentiate
  config._direnv_envrc = envrc_path or NO_ENVRC

  -- Inject env if we have one
  if env and next(env) then
    config.cmd_env = env
  end

  -- Override reuse_client
  opts.reuse_client = reuse_client_with_envrc

  -- Check buffer is still valid (user may have closed it while we were async)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  opts.bufnr = bufnr
  original_lsp_start(config, opts)
end

--- Resolve the environment for a directory and then start the LSP.
--- This is the async path taken on cache miss.
--- @param config vim.lsp.ClientConfig
--- @param opts table
--- @param bufnr integer
--- @param dir string
local function resolve_and_start(config, opts, bufnr, dir)
  direnv.resolve(dir, function(envrc_path, allowed)
    -- Cache the resolve result
    cache.set_resolve(dir, envrc_path, allowed)

    if not envrc_path then
      -- No .envrc found; start with default env
      complete_lsp_start(config, opts, bufnr, nil, nil)
      return
    end

    if allowed ~= 0 then
      -- Not allowed
      local status_text = allowed == 1 and "pending approval" or "denied"
      notify(
        envrc_path .. " is " .. status_text .. ". LSP starting with default env. Run :DirenvLspAllow to allow.",
        vim.log.levels.WARN
      )
      complete_lsp_start(config, opts, bufnr, nil, nil)
      return
    end

    -- Check env cache
    local cached_env = cache.get_env(envrc_path)
    if cached_env then
      if M.config.notifications.on_load then
        notify("Using cached env from " .. envrc_path, vim.log.levels.DEBUG)
      end
      complete_lsp_start(config, opts, bufnr, envrc_path, cached_env)
      return
    end

    -- Export the environment (async)
    direnv.export(envrc_path, function(env)
      if not env then
        notify("Failed to export env from " .. envrc_path .. ". Starting with default env.", vim.log.levels.WARN)
        complete_lsp_start(config, opts, bufnr, nil, nil)
        return
      end

      cache.set_env(envrc_path, env)

      if M.config.notifications.on_load then
        notify("Loaded env from " .. envrc_path, vim.log.levels.INFO)
      end

      complete_lsp_start(config, opts, bufnr, envrc_path, env)
    end)
  end)
end

--- The wrapper around vim.lsp.start that injects direnv environments.
--- @param config vim.lsp.ClientConfig
--- @param opts table?
--- @return integer?
local function wrapped_lsp_start(config, opts)
  opts = opts or {}

  if not M.config.autoload then
    return original_lsp_start(config, opts)
  end

  local bufnr = vim._resolve_bufnr(opts.bufnr)
  local dir = buf_dir(bufnr)

  if not dir then
    -- No file associated with buffer; pass through
    return original_lsp_start(config, opts)
  end

  -- Check resolve cache first (synchronous fast path)
  local cached_resolve = cache.get_resolve(dir)
  if cached_resolve then
    local envrc_path = cached_resolve.envrc_path

    if not envrc_path then
      -- Cached: no .envrc here. Start with default env.
      config._direnv_envrc = NO_ENVRC
      opts.reuse_client = reuse_client_with_envrc
      return original_lsp_start(config, opts)
    end

    if cached_resolve.allowed ~= 0 then
      -- Cached: not allowed. Start with default env.
      config._direnv_envrc = NO_ENVRC
      opts.reuse_client = reuse_client_with_envrc
      return original_lsp_start(config, opts)
    end

    -- Check env cache
    local cached_env = cache.get_env(envrc_path)
    if cached_env then
      -- Full cache hit: synchronous start
      config._direnv_envrc = envrc_path
      if next(cached_env) then
        config.cmd_env = cached_env
      end
      opts.reuse_client = reuse_client_with_envrc
      return original_lsp_start(config, opts)
    end

    -- Resolve is cached but env is not; need async export
    resolve_and_start(config, opts, bufnr, dir)
    return nil
  end

  -- Full cache miss; need async resolve + export
  resolve_and_start(config, opts, bufnr, dir)
  return nil
end

--- Get the .envrc path for the current buffer (cached or async).
--- @param callback fun(envrc_path: string?, allowed: integer?)
local function get_current_envrc(callback)
  local bufnr = vim.api.nvim_get_current_buf()
  local dir = buf_dir(bufnr)
  if not dir then
    callback(nil, nil)
    return
  end

  local cached = cache.get_resolve(dir)
  if cached then
    callback(cached.envrc_path, cached.allowed)
    return
  end

  direnv.resolve(dir, function(envrc_path, allowed)
    cache.set_resolve(dir, envrc_path, allowed)
    callback(envrc_path, allowed)
  end)
end

--- Create user commands.
local function create_commands()
  vim.api.nvim_create_user_command("DirenvLspRestart", function()
    get_current_envrc(function(envrc_path, _)
      if not envrc_path then
        notify("No .envrc found for current buffer", vim.log.levels.WARN)
        return
      end

      -- Invalidate cache
      cache.invalidate(envrc_path)

      -- Stop all LSP clients tied to this envrc
      local clients = vim.lsp.get_clients()
      local stopped = {}
      for _, client in ipairs(clients) do
        if client.config._direnv_envrc == envrc_path then
          table.insert(stopped, client.name)
          client:stop()
        end
      end

      if #stopped > 0 then
        notify(
          "Restarting: " .. table.concat(stopped, ", ") .. " (env: " .. envrc_path .. ")",
          vim.log.levels.INFO
        )
        -- Neovim's FileType autocmd will re-trigger vim.lsp.start for affected buffers
        vim.defer_fn(function()
          vim.cmd("doautoall FileType")
        end, 500)
      else
        notify("No active LSP servers found for " .. envrc_path, vim.log.levels.WARN)
      end
    end)
  end, { desc = "Restart LSP servers for current buffer's .envrc" })

  vim.api.nvim_create_user_command("DirenvLspStatus", function()
    local clients = vim.lsp.get_clients()
    local lines = { "multi-lsp-direnv: LSP Server Status", "" }

    local by_envrc = {}
    local no_envrc = {}

    for _, client in ipairs(clients) do
      local envrc = client.config._direnv_envrc
      if envrc and envrc ~= NO_ENVRC then
        if not by_envrc[envrc] then
          by_envrc[envrc] = {}
        end
        table.insert(by_envrc[envrc], client.name .. " (id=" .. client.id .. ")")
      else
        table.insert(no_envrc, client.name .. " (id=" .. client.id .. ")")
      end
    end

    for envrc, servers in pairs(by_envrc) do
      table.insert(lines, "  " .. envrc .. ":")
      for _, s in ipairs(servers) do
        table.insert(lines, "    " .. s)
      end
    end

    if #no_envrc > 0 then
      table.insert(lines, "  (no .envrc / default env):")
      for _, s in ipairs(no_envrc) do
        table.insert(lines, "    " .. s)
      end
    end

    if #clients == 0 then
      table.insert(lines, "  No active LSP servers")
    end

    notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "Show LSP servers grouped by .envrc" })

  vim.api.nvim_create_user_command("DirenvLspAllow", function()
    get_current_envrc(function(envrc_path, _)
      if not envrc_path then
        notify("No .envrc found for current buffer", vim.log.levels.WARN)
        return
      end

      direnv.allow(envrc_path, function(ok, err)
        if not ok then
          notify("Failed to allow " .. envrc_path .. ": " .. (err or ""), vim.log.levels.ERROR)
          return
        end

        cache.invalidate(envrc_path)
        notify("Allowed " .. envrc_path .. ". Run :DirenvLspRestart to reload.", vim.log.levels.INFO)
      end)
    end)
  end, { desc = "Allow the .envrc for current buffer" })

  vim.api.nvim_create_user_command("DirenvLspDeny", function()
    get_current_envrc(function(envrc_path, _)
      if not envrc_path then
        notify("No .envrc found for current buffer", vim.log.levels.WARN)
        return
      end

      direnv.deny(envrc_path, function(ok, err)
        if not ok then
          notify("Failed to deny " .. envrc_path .. ": " .. (err or ""), vim.log.levels.ERROR)
          return
        end

        cache.invalidate(envrc_path)
        notify("Denied " .. envrc_path, vim.log.levels.INFO)
      end)
    end)
  end, { desc = "Deny the .envrc for current buffer" })

  vim.api.nvim_create_user_command("DirenvLspInvalidate", function()
    cache.invalidate_all()
    notify("All direnv caches invalidated", vim.log.levels.INFO)
  end, { desc = "Invalidate all direnv-lsp caches" })
end

--- Create autocmds for .envrc change detection.
local function create_autocmds()
  local group = vim.api.nvim_create_augroup("MultiLspDirenv", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = ".envrc",
    callback = function(ev)
      local envrc_path = vim.api.nvim_buf_get_name(ev.buf)
      if envrc_path == "" then
        return
      end

      cache.invalidate(envrc_path)

      if M.config.notifications.on_envrc_change then
        notify(envrc_path .. " changed. Run :DirenvLspAllow then :DirenvLspRestart to reload.", vim.log.levels.INFO)
      end
    end,
  })
end

--- Statusline component showing the active .envrc for the current buffer.
---
--- Returns a short string like "raw/.envrc" (the .envrc path relative to the
--- nearest git root or home directory). Returns "" if no .envrc applies.
---
--- Usage with lualine:
---   lualine_x = { function() return require("multi-lsp-direnv").statusline() end }
---
--- @return string
function M.statusline()
  local bufnr = vim.api.nvim_get_current_buf()
  local dir = buf_dir(bufnr)
  if not dir then
    return ""
  end

  local cached = cache.get_resolve(dir)
  if not cached or not cached.envrc_path then
    return ""
  end

  local envrc = cached.envrc_path
  local display = envrc

  -- Try to shorten relative to git root
  local git_root = vim.fs.root(bufnr, ".git")
  if git_root then
    local prefix = git_root .. "/"
    if display:sub(1, #prefix) == prefix then
      display = display:sub(#prefix + 1)
    end
  else
    -- Fall back to home-relative
    local home = vim.env.HOME or ""
    if home ~= "" then
      local prefix = home .. "/"
      if display:sub(1, #prefix) == prefix then
        display = "~/" .. display:sub(#prefix + 1)
      end
    end
  end

  return display
end

--- Initialize the plugin.
--- @param user_config? table
function M.setup(user_config)
  if is_setup then
    return
  end

  M.config = vim.tbl_deep_extend("force", M.config, user_config or {})

  -- Configure dependencies
  cache.set_ttl(M.config.cache_ttl)
  direnv.bin = M.config.bin

  -- Check direnv is available
  if vim.fn.executable(M.config.bin) ~= 1 then
    notify("direnv binary not found: " .. M.config.bin .. ". Plugin disabled.", vim.log.levels.ERROR)
    return
  end

  -- Monkey-patch vim.lsp.start
  original_lsp_start = vim.lsp.start
  vim.lsp.start = wrapped_lsp_start

  create_commands()
  create_autocmds()

  is_setup = true
end

return M
