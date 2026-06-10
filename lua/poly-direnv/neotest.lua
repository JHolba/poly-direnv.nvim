--- Neotest integration helpers for poly-direnv.nvim
---
--- Provides ready-made configuration for neotest that injects direnv
--- environments into test processes. Handles:
---   - Resolving the correct Python binary from the direnv PATH
---   - Injecting direnv environment variables into test processes
---   - Setting cwd to the .envrc parent directory
---
--- Usage:
---   require("neotest").setup({
---     adapters = {
---       require("neotest-python")(require("poly-direnv.neotest").python()),
---     },
---     run = require("poly-direnv.neotest").run(),
---   })

local poly = require("poly-direnv")

local M = {}

--- Find an executable in a PATH string.
--- @param path_str string Colon-separated PATH
--- @param name string Executable name to find
--- @return string? absolute path to the executable, or nil
local function find_in_path(path_str, name)
  for dir in path_str:gmatch("[^:]+") do
    local candidate = dir .. "/" .. name
    if vim.uv.fs_stat(candidate) then
      return candidate
    end
  end
  return nil
end

--- Return neotest-python adapter config with direnv-aware Python resolution.
---
--- Merges with any additional settings you pass in. Provides:
---   - `python`: function that resolves python3 from the direnv PATH
---   - `runner`: "pytest" (bypasses module detection which fails outside direnv)
---
--- @param opts? table Additional neotest-python settings to merge
--- @return table config suitable for passing to require("neotest-python")(config)
function M.python(opts)
  return vim.tbl_deep_extend("force", {
    runner = "pytest",
    python = function(root)
      local _, env = poly.get_env_wait(root)
      if env and env.PATH then
        local py = find_in_path(env.PATH, "python3") or find_in_path(env.PATH, "python")
        if py then
          return py
        end
      end
      return "python3"
    end,
  }, opts or {})
end

--- Return neotest run config with direnv-aware augment hook.
---
--- The augment hook:
---   - Injects direnv environment variables into test processes
---   - Sets cwd to the .envrc parent directory
---
--- @param opts? table Additional run settings to merge
--- @return table config suitable for neotest's `run` setting
function M.run(opts)
  return vim.tbl_deep_extend("force", {
    augment = function(tree, args)
      local position = tree:data()
      if not position or not position.path then
        return args
      end

      local envrc, env = poly.get_env_wait(vim.fs.dirname(position.path))
      if env then
        args.env = vim.tbl_extend("force", env, args.env or {})
      end
      -- Set cwd to the .envrc's parent directory (the package root)
      -- so test runners discover tests relative to the right root.
      if envrc and not args.cwd then
        args.cwd = vim.fs.dirname(envrc)
      end
      return args
    end,
  }, opts or {})
end

return M
