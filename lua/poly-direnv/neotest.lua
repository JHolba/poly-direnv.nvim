--- Neotest integration helpers for poly-direnv.nvim
---
--- Provides ready-made configuration for neotest that injects direnv
--- environments into test processes. Handles:
---   - Resolving executables from the direnv PATH (generic, all adapters)
---   - Injecting direnv environment variables into test processes
---   - Setting cwd to the .envrc parent directory
---   - Python-specific: correct interpreter resolution and forced pytest runner
---
--- Usage:
---   local poly_neotest = require("poly-direnv.neotest")
---
---   require("neotest").setup({
---     adapters = {
---       poly_neotest.wrap(require("neotest-golang")({ ... })),
---       poly_neotest.wrap(require("neotest-python")(poly_neotest.python())),
---       poly_neotest.wrap(require("neotest-zig")),
---     },
---     run = poly_neotest.run(),
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

--- Resolve a command's executable from the direnv PATH.
---
--- If the command is a bare name (not an absolute path), look it up in
--- the direnv PATH for the given directory. Returns the resolved absolute
--- path, or the original command if no direnv env is available.
---
--- Uses get_env_sync (cache-only) because this runs inside build_spec,
--- which executes in a fast event context where vim.wait is forbidden.
--- The cache is expected to be warm from run.augment's get_env_wait call
--- which runs before build_spec.
---
--- @param cmd string The executable name or path
--- @param dir string Directory to resolve the direnv env from
--- @return string The resolved executable path
local function resolve_cmd(cmd, dir)
  -- Already an absolute path; don't re-resolve
  if cmd:sub(1, 1) == "/" then
    return cmd
  end

  local _, env = poly.get_env_sync(dir)
  if env and env.PATH then
    return find_in_path(env.PATH, cmd) or cmd
  end
  return cmd
end

--- Wrap a neotest adapter so its build_spec resolves the command executable
--- from the direnv PATH.
---
--- jobstart resolves executables from the parent process's PATH, not from
--- the env option. This wrapper intercepts build_spec results and replaces
--- bare command names (e.g. "go", "cargo", "zig") with absolute paths
--- found in the direnv-scoped PATH.
---
--- Works with any adapter -- not language-specific.
---
--- @param adapter table A neotest adapter (the return value of require("neotest-xxx")(...))
--- @return table The same adapter with a wrapped build_spec
function M.wrap(adapter)
  local original_build_spec = adapter.build_spec
  if not original_build_spec then
    return adapter
  end

  adapter.build_spec = function(args)
    local specs = original_build_spec(args)
    if not specs then
      return nil
    end

    -- build_spec can return a single spec or a list of specs
    local is_list = vim.islist(specs)
    local spec_list = is_list and specs or { specs }

    for _, spec in ipairs(spec_list) do
      if spec.command then
        -- Determine the directory for direnv resolution
        local position = args.tree and args.tree:data()
        local dir = (position and position.path) and vim.fs.dirname(position.path) or nil

        if dir then
          if type(spec.command) == "table" and spec.command[1] then
            spec.command[1] = resolve_cmd(spec.command[1], dir)
          elseif type(spec.command) == "string" then
            -- Some adapters use a command string; resolve the first word
            local first, rest = spec.command:match("^(%S+)(.*)")
            if first then
              spec.command = resolve_cmd(first, dir) .. rest
            end
          end
        end
      end
    end

    return is_list and spec_list or spec_list[1]
  end

  return adapter
end

--- Return neotest-python adapter config for use with wrap().
---
--- Provides:
---   - `python`: returns bare "python3" so wrap() resolves it from the
---     direnv PATH (prevents neotest-python from baking a nix store path)
---   - `runner`: "pytest" (bypasses module detection which fails outside
---     the direnv environment)
---
--- Must be used with wrap() to resolve the Python binary:
---   wrap(require("neotest-python")(poly_neotest.python()))
---
--- Note: nixvim users do not need to call this function. The nixvim module
--- auto-injects these settings when neotest.enable is set.
---
--- @param opts? table Additional neotest-python settings to merge
--- @return table config suitable for passing to require("neotest-python")(config)
function M.python(opts)
  return vim.tbl_deep_extend("force", {
    runner = "pytest",
    python = "python3",
  }, opts or {})
end

--- Wrap all neotest adapters that have been registered via neotest.setup().
---
--- Call this after neotest.setup() to retroactively wrap every adapter's
--- build_spec with direnv command resolution. This is the easiest way to
--- integrate — configure neotest adapters normally, then call wrap_all().
---
--- Note: for neotest-python, you should also configure the adapter with
--- runner = "pytest" and python = "python3" (or use python()) to bypass
--- module detection that fails outside the direnv environment.
function M.wrap_all()
  local ok, neotest_config = pcall(require, "neotest.config")
  if not ok then
    return
  end

  -- neotest.config delegates to user_config via __index metatable.
  local adapters = neotest_config.adapters
  if not adapters then
    return
  end

  for _, adapter in ipairs(adapters) do
    M.wrap(adapter)
  end
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
