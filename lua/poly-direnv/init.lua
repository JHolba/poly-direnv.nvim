--- poly-direnv.nvim
---
--- Automatically provides per-directory direnv environments to LSP servers.
--- Each LSP server process is keyed by (name, envrc_path), so files under
--- different .envrc scopes get separate server instances with the correct
--- environment variables.
---
--- Works by wrapping vim.lsp.start() to inject cmd_env and override the
--- reuse_client predicate before the server process is spawned.
---
--- Also exposes get_env() and get_env_sync() for non-LSP consumers (e.g.
--- neotest, overseer, toggleterm) that need direnv environments for external
--- processes.
---
--- Requires Neovim >= 0.12.

local cache = require("poly-direnv.cache")
local direnv = require("poly-direnv.direnv")

local M = {}

--- @class poly_direnv.Config
--- @field cache_ttl integer Cache TTL in milliseconds (default 30000)
--- @field bin string Path to direnv binary (default "direnv")
--- @field autoload boolean Automatically inject env on LSP start (default true)
--- @field notifications { on_load: boolean, on_envrc_change: boolean }

--- @type poly_direnv.Config
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

--- Set of (server_name, envrc_path) pairs we have already notified about.
--- Prevents repeated messages when the TTL cache expires and re-resolves.
--- @type table<string, boolean>
local notified_starts = {}

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "poly-direnv" })
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

--- Shorten a path for display by trying bases in order.
---
--- Each entry in `bases` is a literal: "cwd", "git", or "home".
--- The first base that is an ancestor of `path` wins.
--- "home"-relative paths are prefixed with "~/".
---
--- @param path string Absolute path to shorten
--- @param bases ("cwd"|"git"|"home")[] Bases to try, in order
--- @param bufnr? integer Buffer number (needed for "git")
--- @return string
local function display_path(path, bases, bufnr)
  for _, base in ipairs(bases) do
    local dir
    if base == "cwd" then
      dir = vim.uv.cwd()
    elseif base == "git" then
      dir = bufnr and vim.fs.root(bufnr, ".git")
    elseif base == "home" then
      dir = vim.env.HOME
    end

    if dir and dir ~= "" then
      local rel = vim.fs.relpath(dir, path)
      if rel then
        return base == "home" and ("~/" .. rel) or rel
      end
    end
  end

  return path
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

  -- Compare root_dir directly (mirrors Neovim 0.12 default reuse logic)
  return (client.config.root_dir or "") == (config.root_dir or "")
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

  -- Notify with server name, once per (server, envrc) pair
  if M.config.notifications.on_load and envrc_path then
    local key = (config.name or "?") .. "\0" .. envrc_path
    if not notified_starts[key] then
      notified_starts[key] = true
      notify(
        "Started " .. (config.name or "LSP") .. " for " .. display_path(envrc_path, { "cwd", "git", "home" }, bufnr),
        vim.log.levels.INFO
      )
    end
  end

  opts.bufnr = bufnr
  original_lsp_start(config, opts)
end

--- Resolve the direnv environment for a directory (async).
---
--- Runs the full resolve -> check allowed -> export pipeline, using the
--- two-level cache when possible. Calls back with (envrc_path, env) when done.
---
--- This is the generic building block for any integration that needs the
--- direnv environment for a directory. The LSP wrapper uses it internally,
--- but it can also be used by external consumers like neotest, overseer, etc.
---
--- @param dir string Absolute directory path to resolve from
--- @param callback fun(envrc_path: string?, env: table<string, string?>?) Called with results.
---   envrc_path is nil if no allowed .envrc was found.
---   env is nil when no .envrc applies (or it is not allowed / export failed).
function M.get_env(dir, callback)
  --- Export the environment for an already-resolved envrc (async).
  --- @param envrc_path string
  local function do_export(envrc_path)
    -- Check env cache first
    local cached_env = cache.get_env(envrc_path)
    if cached_env then
      callback(envrc_path, cached_env)
      return
    end

    direnv.export(envrc_path, function(env)
      if not env then
        callback(envrc_path, nil)
        return
      end

      cache.set_env(envrc_path, env)
      callback(envrc_path, env)
    end)
  end

  -- Check resolve cache first (synchronous fast path)
  local cached_resolve = cache.get_resolve(dir)
  if cached_resolve then
    local envrc_path = cached_resolve.envrc_path
    if not envrc_path or cached_resolve.allowed ~= 0 then
      callback(nil, nil)
      return
    end
    do_export(envrc_path)
    return
  end

  -- Full cache miss; need async resolve + export
  direnv.resolve(dir, function(envrc_path, allowed)
    cache.set_resolve(dir, envrc_path, allowed)

    if not envrc_path then
      callback(nil, nil)
      return
    end

    if allowed ~= 0 then
      callback(nil, nil)
      return
    end

    do_export(envrc_path)
  end)
end

--- Synchronously get the cached direnv environment for a directory.
---
--- Returns immediately from the cache without spawning any subprocesses.
--- Returns nil on cache miss. This is useful in synchronous hooks (e.g.
--- neotest's run.augment) where the cache is expected to already be warm
--- from the LSP integration or a prior get_env() call.
---
--- @param dir string Absolute directory path
--- @return string? envrc_path The .envrc path, or nil on cache miss / no envrc
--- @return table<string, string?>? env The environment table, or nil on cache miss / no envrc
function M.get_env_sync(dir)
  local cached_resolve = cache.get_resolve(dir)
  if not cached_resolve then
    return nil, nil
  end

  local envrc_path = cached_resolve.envrc_path
  if not envrc_path or cached_resolve.allowed ~= 0 then
    return nil, nil
  end

  local cached_env = cache.get_env(envrc_path)
  if not cached_env then
    return nil, nil
  end

  return envrc_path, cached_env
end

--- Synchronously resolve the direnv environment for a directory, blocking
--- until the result is available.
---
--- Tries the cache first (fast path). On cache miss, runs the full async
--- resolve + export pipeline and blocks with vim.wait() until it completes.
--- This is useful in contexts where you need the environment immediately
--- and can tolerate a brief blocking delay (~100-200ms on first call).
---
--- @param dir string Absolute directory path
--- @param timeout? integer Timeout in milliseconds (default 5000)
--- @return string? envrc_path The .envrc path, or nil on timeout / no envrc
--- @return table<string, string?>? env The environment table, or nil on timeout / no envrc
function M.get_env_wait(dir, timeout)
  -- Fast path: cache hit
  local envrc_path, env = M.get_env_sync(dir)
  if envrc_path then
    return envrc_path, env
  end

  -- Slow path: async resolve + export, then block
  local done = false
  local result_envrc, result_env

  M.get_env(dir, function(envrc, e)
    result_envrc = envrc
    result_env = e
    done = true
  end)

  vim.wait(timeout or 5000, function()
    return done
  end)

  return result_envrc, result_env
end

--- Resolve the environment for a directory and then start the LSP.
--- This is the async path taken on cache miss.
--- @param config vim.lsp.ClientConfig
--- @param opts table
--- @param bufnr integer
--- @param dir string
local function resolve_and_start(config, opts, bufnr, dir)
  M.get_env(dir, function(envrc_path, env)
    if not envrc_path and not env then
      -- Check if we should warn about unapproved envrc
      local cached_resolve = cache.get_resolve(dir)
      if cached_resolve and cached_resolve.envrc_path and cached_resolve.allowed ~= 0 then
        local status_text = cached_resolve.allowed == 1 and "pending approval" or "denied"
        notify(
          cached_resolve.envrc_path
            .. " is "
            .. status_text
            .. ". LSP starting with default env. Run :PolyDirenvAllow to allow.",
          vim.log.levels.WARN
        )
      end
    end

    if envrc_path and not env then
      notify("Failed to export env from " .. envrc_path .. ". Starting with default env.", vim.log.levels.WARN)
      envrc_path = nil
    end

    complete_lsp_start(config, opts, bufnr, envrc_path, env)
  end)
end

--- Synchronous LSP start with direnv tagging applied.
--- @param config vim.lsp.ClientConfig
--- @param opts table
--- @param envrc string? The envrc path (nil means no envrc / default env)
--- @param env table<string, string?>? Environment variables to inject
--- @return integer?
local function sync_start(config, opts, envrc, env)
  config._direnv_envrc = envrc or NO_ENVRC
  if env and next(env) then
    config.cmd_env = env
  end
  opts.reuse_client = reuse_client_with_envrc
  return original_lsp_start(config, opts)
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

  -- Fast path for :lsp restart -- the config already carries _direnv_envrc
  -- and cmd_env from the previous client. Pass through synchronously so the
  -- restart code gets a client_id back instead of nil.
  if config._direnv_envrc then
    opts.reuse_client = reuse_client_with_envrc
    return original_lsp_start(config, opts)
  end

  local bufnr = (opts.bufnr == nil or opts.bufnr == 0) and vim.api.nvim_get_current_buf() or opts.bufnr
  local dir = buf_dir(bufnr)

  if not dir then
    -- No file associated with buffer; pass through
    return original_lsp_start(config, opts)
  end

  -- Check resolve cache first (synchronous fast path)
  local cached_resolve = cache.get_resolve(dir)
  if cached_resolve then
    local envrc_path = cached_resolve.envrc_path

    if not envrc_path or cached_resolve.allowed ~= 0 then
      -- Cached: no .envrc or not allowed. Start with default env.
      return sync_start(config, opts, nil, nil)
    end

    -- Check env cache
    local cached_env = cache.get_env(envrc_path)
    if cached_env then
      return sync_start(config, opts, envrc_path, cached_env)
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
  vim.api.nvim_create_user_command("PolyDirenvRestart", function()
    get_current_envrc(function(envrc_path, _)
      if not envrc_path then
        notify("No .envrc found for current buffer", vim.log.levels.WARN)
        return
      end

      -- Invalidate cache and allow re-notification
      cache.invalidate(envrc_path)
      for key in pairs(notified_starts) do
        if key:find(envrc_path, 1, true) then
          notified_starts[key] = nil
        end
      end

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
        notify("Restarting: " .. table.concat(stopped, ", ") .. " (env: " .. envrc_path .. ")", vim.log.levels.INFO)
        -- Neovim's FileType autocmd will re-trigger vim.lsp.start for affected buffers
        vim.defer_fn(function()
          vim.cmd("doautoall FileType")
        end, 500)
      else
        notify("No active LSP servers found for " .. envrc_path, vim.log.levels.WARN)
      end
    end)
  end, { desc = "Restart LSP servers for current buffer's .envrc" })

  vim.api.nvim_create_user_command("PolyDirenvStatus", function()
    local clients = vim.lsp.get_clients()
    local lines = { "poly-direnv: LSP Server Status", "" }

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

  vim.api.nvim_create_user_command("PolyDirenvAllow", function()
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
        notify("Allowed " .. envrc_path .. ". Run :PolyDirenvRestart to reload.", vim.log.levels.INFO)
      end)
    end)
  end, { desc = "Allow the .envrc for current buffer" })

  vim.api.nvim_create_user_command("PolyDirenvDeny", function()
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

  vim.api.nvim_create_user_command("PolyDirenvInvalidate", function()
    cache.invalidate_all()
    notified_starts = {}
    notify("All direnv caches invalidated", vim.log.levels.INFO)
  end, { desc = "Invalidate all poly-direnv caches" })
end

--- Create autocmds for .envrc change detection.
local function create_autocmds()
  local group = vim.api.nvim_create_augroup("PolyDirenv", { clear = true })

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
        notify(envrc_path .. " changed. Run :PolyDirenvAllow then :PolyDirenvRestart to reload.", vim.log.levels.INFO)
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
---   lualine_x = { function() return require("poly-direnv").statusline() end }
---
--- @return string
function M.statusline()
  local bufnr = vim.api.nvim_get_current_buf()
  local dir = buf_dir(bufnr)
  if not dir then
    return ""
  end

  -- Use the stable (non-TTL) cache so the statusline doesn't flicker
  -- when the TTL cache expires between direnv re-checks.
  local cached = cache.get_resolve_stable(dir)
  if not cached or not cached.envrc_path then
    return ""
  end

  -- Use git root (not cwd) so the statusline stays stable when cwd changes.
  return display_path(cached.envrc_path, { "git", "home" }, bufnr)
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

  -- Wrap vim.lsp.start to inject direnv environments and override reuse_client.
  -- This intercept point works regardless of whether users configure LSP via
  -- vim.lsp.config()/vim.lsp.enable() or call vim.lsp.start() directly.
  original_lsp_start = vim.lsp.start
  vim.lsp.start = wrapped_lsp_start

  create_commands()
  create_autocmds()

  is_setup = true
end

return M
