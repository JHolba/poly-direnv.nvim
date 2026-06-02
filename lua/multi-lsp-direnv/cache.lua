--- Two-level cache for direnv resolution and environment export.
---
--- Level 1: dir_path -> { envrc_path, allowed, timestamp }
--- Level 2: envrc_path -> { env, timestamp }
---
--- Both levels use a configurable TTL. Entries are lazily evicted on access.

local M = {}

--- @class multi_lsp_direnv.CacheEntry
--- @field value any
--- @field timestamp integer ms timestamp from vim.uv.hrtime

--- @type table<string, multi_lsp_direnv.CacheEntry>
local resolve_cache = {}

--- @type table<string, multi_lsp_direnv.CacheEntry>
local env_cache = {}

--- Stable resolve map: dir -> { envrc_path, allowed }.
--- Never TTL-evicted; only cleared by explicit invalidation.
--- Used by the statusline so it doesn't flicker when the TTL cache expires.
--- @type table<string, { envrc_path: string?, allowed: integer? }>
local resolve_stable = {}

--- @type integer Cache TTL in milliseconds
local ttl = 30000

local function now_ms()
  return math.floor(vim.uv.hrtime() / 1000000)
end

--- @param entry multi_lsp_direnv.CacheEntry?
--- @return boolean
local function is_valid(entry)
  if not entry then
    return false
  end
  return (now_ms() - entry.timestamp) < ttl
end

--- Configure the cache TTL.
--- @param ttl_ms integer
function M.set_ttl(ttl_ms)
  ttl = ttl_ms
end

-- Resolve cache: directory -> { envrc_path, allowed } -----------------------

--- Get cached resolve result for a directory.
--- @param dir string
--- @return { envrc_path: string?, allowed: integer? }?
function M.get_resolve(dir)
  local entry = resolve_cache[dir]
  if is_valid(entry) then
    return entry.value
  end
  resolve_cache[dir] = nil
  return nil
end

--- Store a resolve result for a directory.
--- @param dir string
--- @param envrc_path string?
--- @param allowed integer?
function M.set_resolve(dir, envrc_path, allowed)
  local value = { envrc_path = envrc_path, allowed = allowed }
  resolve_cache[dir] = {
    value = value,
    timestamp = now_ms(),
  }
  -- Also store in the stable map (no TTL) for statusline use
  resolve_stable[dir] = value
end

--- Get the stable (non-TTL) resolve result for a directory.
--- This never expires on its own; only explicit invalidation clears it.
--- Used by the statusline to avoid flickering.
--- @param dir string
--- @return { envrc_path: string?, allowed: integer? }?
function M.get_resolve_stable(dir)
  return resolve_stable[dir]
end

-- Env cache: envrc_path -> env table ----------------------------------------

--- Get cached environment for an .envrc path.
--- @param envrc_path string
--- @return table<string, string?>?
function M.get_env(envrc_path)
  local entry = env_cache[envrc_path]
  if is_valid(entry) then
    return entry.value
  end
  env_cache[envrc_path] = nil
  return nil
end

--- Store an environment table for an .envrc path.
--- @param envrc_path string
--- @param env table<string, string?>
function M.set_env(envrc_path, env)
  env_cache[envrc_path] = {
    value = env,
    timestamp = now_ms(),
  }
end

-- Invalidation --------------------------------------------------------------

--- Invalidate all cache entries associated with an .envrc path.
--- Clears the env cache for that path and any resolve entries pointing to it.
--- @param envrc_path string
function M.invalidate(envrc_path)
  env_cache[envrc_path] = nil
  for dir, entry in pairs(resolve_cache) do
    if entry.value and entry.value.envrc_path == envrc_path then
      resolve_cache[dir] = nil
      resolve_stable[dir] = nil
    end
  end
end

--- Invalidate all cached data.
function M.invalidate_all()
  resolve_cache = {}
  env_cache = {}
  resolve_stable = {}
end

return M
