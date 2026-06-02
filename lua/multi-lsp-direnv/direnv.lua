--- Async wrappers around the direnv CLI.
---
--- All functions use vim.system() for non-blocking execution and call back
--- into the caller via a callback function. Results are NOT cached here;
--- the caller (init.lua) is responsible for caching via cache.lua.

local M = {}

--- @type string Path to the direnv binary
M.bin = "direnv"

--- Find the closest .envrc for a directory.
---
--- Runs `direnv status --json` with the given cwd. This is a read-only
--- operation (no .envrc evaluation).
---
--- @param dir string Directory to resolve from
--- @param callback fun(envrc_path: string?, allowed: integer?) Called with results.
---   envrc_path is nil if no .envrc was found. allowed is 0 (allowed),
---   1 (pending), or 2 (denied).
function M.resolve(dir, callback)
  vim.system(
    { M.bin, "status", "--json" },
    { text = true, cwd = dir },
    function(obj)
      if obj.code ~= 0 then
        vim.schedule(function()
          callback(nil, nil)
        end)
        return
      end

      local ok, status = pcall(vim.json.decode, obj.stdout)
      if not ok or not status or not status.state then
        vim.schedule(function()
          callback(nil, nil)
        end)
        return
      end

      if status.state.foundRC == vim.NIL or status.state.foundRC == nil then
        vim.schedule(function()
          callback(nil, nil)
        end)
        return
      end

      local envrc_path = status.state.foundRC.path
      local allowed = status.state.foundRC.allowed

      vim.schedule(function()
        callback(envrc_path, allowed)
      end)
    end
  )
end

--- Export the environment for a given .envrc.
---
--- Runs `direnv export json` with cwd set to the .envrc's parent directory.
--- This evaluates the .envrc (runs bash code). The .envrc must be `direnv allow`ed.
---
--- @param envrc_path string Absolute path to the .envrc file
--- @param callback fun(env: table<string, string?>?) Called with the env diff table.
---   nil on error. Keys with JSON null values are mapped to vim.NIL.
function M.export(envrc_path, callback)
  local envrc_dir = vim.fs.dirname(envrc_path)

  vim.system(
    { M.bin, "export", "json" },
    { text = true, cwd = envrc_dir },
    function(obj)
      if obj.code ~= 0 then
        vim.schedule(function()
          callback(nil)
        end)
        return
      end

      local stdout = obj.stdout or ""
      if stdout == "" then
        -- No env changes (direnv outputs empty string when nothing changed)
        vim.schedule(function()
          callback({})
        end)
        return
      end

      local ok, env = pcall(vim.json.decode, stdout)
      if not ok or type(env) ~= "table" then
        vim.schedule(function()
          callback(nil)
        end)
        return
      end

      -- Normalize: convert vim.NIL to nil for unset vars, ensure string values
      local normalized = {}
      for key, value in pairs(env) do
        if value == vim.NIL or value == nil then
          normalized[key] = nil
        else
          normalized[key] = type(value) == "string" and value or tostring(value)
        end
      end

      vim.schedule(function()
        callback(normalized)
      end)
    end
  )
end

--- Allow the .envrc at the given path.
--- @param envrc_path string Absolute path to the .envrc file
--- @param callback fun(ok: boolean, err: string?)
function M.allow(envrc_path, callback)
  local envrc_dir = vim.fs.dirname(envrc_path)

  vim.system(
    { M.bin, "allow" },
    { text = true, cwd = envrc_dir },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          callback(false, obj.stderr or "unknown error")
        else
          callback(true, nil)
        end
      end)
    end
  )
end

--- Deny the .envrc at the given path.
--- @param envrc_path string Absolute path to the .envrc file
--- @param callback fun(ok: boolean, err: string?)
function M.deny(envrc_path, callback)
  local envrc_dir = vim.fs.dirname(envrc_path)

  vim.system(
    { M.bin, "deny" },
    { text = true, cwd = envrc_dir },
    function(obj)
      vim.schedule(function()
        if obj.code ~= 0 then
          callback(false, obj.stderr or "unknown error")
        else
          callback(true, nil)
        end
      end)
    end
  )
end

return M
