local helpers = require("tests.helpers")

-- Helpers for building mock direnv responses
local function resolve_response(envrc_path, allowed)
  return {
    code = 0,
    stdout = vim.json.encode({
      state = {
        foundRC = envrc_path and { path = envrc_path, allowed = allowed } or vim.NIL,
      },
    }),
    stderr = "",
  }
end

local function export_response(env)
  return {
    code = 0,
    stdout = vim.json.encode(env),
    stderr = "",
  }
end

local function export_failure()
  return { code = 1, stdout = "", stderr = "export failed" }
end

describe("init", function()
  local poly, cache, mock

  before_each(function()
    helpers.reset_modules()
    cache = require("poly-direnv.cache")
    -- Require init after cache so we have a fresh instance
    poly = require("poly-direnv")
  end)

  describe("get_env_sync", function()
    it("returns nil when cache is empty", function()
      local envrc, env = poly.get_env_sync("/unknown/dir")
      assert.is_nil(envrc)
      assert.is_nil(env)
    end)

    it("returns envrc_path and env when both caches are warm", function()
      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { FOO = "bar" })

      local envrc, env = poly.get_env_sync("/project/src")
      assert.equals("/project/.envrc", envrc)
      assert.is_not_nil(env)
      assert.equals("bar", env.FOO)
    end)

    it("returns nil when resolve is cached but env is not", function()
      cache.set_resolve("/project/src", "/project/.envrc", 0)
      -- env cache is empty

      local envrc, env = poly.get_env_sync("/project/src")
      assert.is_nil(envrc)
      assert.is_nil(env)
    end)

    it("returns nil when envrc is not allowed (pending)", function()
      cache.set_resolve("/project/src", "/project/.envrc", 1)
      cache.set_env("/project/.envrc", { FOO = "bar" })

      local envrc, env = poly.get_env_sync("/project/src")
      assert.is_nil(envrc)
      assert.is_nil(env)
    end)

    it("returns nil when envrc is denied", function()
      cache.set_resolve("/project/src", "/project/.envrc", 2)
      cache.set_env("/project/.envrc", { FOO = "bar" })

      local envrc, env = poly.get_env_sync("/project/src")
      assert.is_nil(envrc)
      assert.is_nil(env)
    end)

    it("returns nil when no envrc was found", function()
      cache.set_resolve("/project/src", nil, nil)

      local envrc, env = poly.get_env_sync("/project/src")
      assert.is_nil(envrc)
      assert.is_nil(env)
    end)
  end)

  describe("get_env_wait", function()
    before_each(function()
      mock = helpers.mock_vim_system()
    end)

    after_each(function()
      mock.restore()
    end)

    it("returns cached values immediately without calling vim.system", function()
      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { FOO = "bar" })

      local envrc, env = poly.get_env_wait("/project/src")
      assert.equals("/project/.envrc", envrc)
      assert.equals("bar", env.FOO)
      assert.equals(0, #mock.calls)
    end)

    it("blocks and resolves on cache miss", function()
      mock.returns(resolve_response("/project/.envrc", 0))
      mock.returns(export_response({ PATH = "/nix/bin" }))

      local envrc, env = poly.get_env_wait("/project/src")
      assert.equals("/project/.envrc", envrc)
      assert.is_not_nil(env)
      assert.equals("/nix/bin", env.PATH)
    end)

    it("returns nil when no envrc is found", function()
      mock.returns(resolve_response(nil, nil))

      local envrc, env = poly.get_env_wait("/no-envrc/src")
      assert.is_nil(envrc)
      assert.is_nil(env)
    end)

    it("returns nil when envrc is not allowed", function()
      mock.returns(resolve_response("/project/.envrc", 1))

      local envrc, env = poly.get_env_wait("/project/src")
      assert.is_nil(envrc)
      assert.is_nil(env)
    end)

    it("populates cache for subsequent get_env_sync calls", function()
      mock.returns(resolve_response("/project/.envrc", 0))
      mock.returns(export_response({ FOO = "cached" }))

      poly.get_env_wait("/project/src")

      local envrc, env = poly.get_env_sync("/project/src")
      assert.equals("/project/.envrc", envrc)
      assert.equals("cached", env.FOO)
    end)
  end)

  describe("get_env", function()
    before_each(function()
      mock = helpers.mock_vim_system()
    end)

    after_each(function()
      mock.restore()
    end)

    it("returns cached values on full cache hit without calling vim.system", function()
      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { PATH = "/bin" })

      local result_envrc, result_env
      poly.get_env("/project/src", function(envrc, env)
        result_envrc = envrc
        result_env = env
      end)

      assert.equals("/project/.envrc", result_envrc)
      assert.equals("/bin", result_env.PATH)
      assert.equals(0, #mock.calls)
    end)

    it("calls export when resolve is cached but env is cold", function()
      cache.set_resolve("/project/src", "/project/.envrc", 0)
      -- env cache is empty
      mock.returns(export_response({ PATH = "/nix/bin" }))

      local result_envrc, result_env
      poly.get_env("/project/src", function(envrc, env)
        result_envrc = envrc
        result_env = env
      end)
      helpers.flush_schedule()

      assert.equals("/project/.envrc", result_envrc)
      assert.equals("/nix/bin", result_env.PATH)
      -- Should have called vim.system once for export
      assert.equals(1, #mock.calls)
      assert.same({ "direnv", "export", "json" }, mock.calls[1].cmd)
    end)

    it("runs full resolve + export on cache miss", function()
      mock.returns(resolve_response("/project/.envrc", 0))
      mock.returns(export_response({ PYTHONPATH = "/lib" }))

      local result_envrc, result_env
      poly.get_env("/project/src", function(envrc, env)
        result_envrc = envrc
        result_env = env
      end)
      helpers.flush_schedule()

      assert.equals("/project/.envrc", result_envrc)
      assert.equals("/lib", result_env.PYTHONPATH)
      -- Should have called vim.system twice: resolve + export
      assert.equals(2, #mock.calls)
    end)

    it("returns nil when no envrc is found", function()
      mock.returns(resolve_response(nil, nil))

      local result_envrc, result_env
      poly.get_env("/no-envrc/src", function(envrc, env)
        result_envrc = envrc
        result_env = env
      end)
      helpers.flush_schedule()

      assert.is_nil(result_envrc)
      assert.is_nil(result_env)
    end)

    it("returns nil when envrc is not allowed (pending)", function()
      mock.returns(resolve_response("/project/.envrc", 1))

      local result_envrc, result_env
      poly.get_env("/project/src", function(envrc, env)
        result_envrc = envrc
        result_env = env
      end)
      helpers.flush_schedule()

      assert.is_nil(result_envrc)
      assert.is_nil(result_env)
      -- Should not attempt export
      assert.equals(1, #mock.calls)
    end)

    it("returns nil when envrc is denied", function()
      mock.returns(resolve_response("/project/.envrc", 2))

      local result_envrc, result_env
      poly.get_env("/project/src", function(envrc, env)
        result_envrc = envrc
        result_env = env
      end)
      helpers.flush_schedule()

      assert.is_nil(result_envrc)
      assert.is_nil(result_env)
    end)

    it("returns envrc_path with nil env on export failure", function()
      mock.returns(resolve_response("/project/.envrc", 0))
      mock.returns(export_failure())

      local result_envrc, result_env
      poly.get_env("/project/src", function(envrc, env)
        result_envrc = envrc
        result_env = env
      end)
      helpers.flush_schedule()

      assert.equals("/project/.envrc", result_envrc)
      assert.is_nil(result_env)
    end)

    it("populates cache after async resolution", function()
      mock.returns(resolve_response("/project/.envrc", 0))
      mock.returns(export_response({ FOO = "cached" }))

      poly.get_env("/project/src", function() end)
      helpers.flush_schedule()

      -- Now get_env_sync should return the cached values
      local envrc, env = poly.get_env_sync("/project/src")
      assert.equals("/project/.envrc", envrc)
      assert.equals("cached", env.FOO)
    end)

    it("returns nil from cache when envrc not allowed", function()
      cache.set_resolve("/project/src", "/project/.envrc", 2)

      local result_envrc, result_env
      poly.get_env("/project/src", function(envrc, env)
        result_envrc = envrc
        result_env = env
      end)

      assert.is_nil(result_envrc)
      assert.is_nil(result_env)
      -- Should not call vim.system at all
      assert.equals(0, #mock.calls)
    end)
  end)

  describe("setup", function()
    local original_lsp_start

    before_each(function()
      original_lsp_start = vim.lsp.start
    end)

    after_each(function()
      -- Restore vim.lsp.start in case setup wrapped it
      vim.lsp.start = original_lsp_start
      -- Clean up commands that setup creates
      pcall(vim.api.nvim_del_user_command, "PolyDirenvRestart")
      pcall(vim.api.nvim_del_user_command, "PolyDirenvStatus")
      pcall(vim.api.nvim_del_user_command, "PolyDirenvAllow")
      pcall(vim.api.nvim_del_user_command, "PolyDirenvDeny")
      pcall(vim.api.nvim_del_user_command, "PolyDirenvInvalidate")
    end)

    it("wraps vim.lsp.start", function()
      poly.setup()
      assert.is_not.equals(original_lsp_start, vim.lsp.start)
    end)

    it("is idempotent", function()
      poly.setup()
      local wrapped = vim.lsp.start
      poly.setup()
      assert.equals(wrapped, vim.lsp.start)
    end)

    it("creates user commands", function()
      poly.setup()
      assert.equals(2, vim.fn.exists(":PolyDirenvStatus"))
      assert.equals(2, vim.fn.exists(":PolyDirenvRestart"))
      assert.equals(2, vim.fn.exists(":PolyDirenvAllow"))
      assert.equals(2, vim.fn.exists(":PolyDirenvDeny"))
      assert.equals(2, vim.fn.exists(":PolyDirenvInvalidate"))
    end)

    it("respects user config", function()
      poly.setup({ cache_ttl = 5000, bin = "/custom/direnv" })
      assert.equals(5000, poly.config.cache_ttl)
      assert.equals("/custom/direnv", poly.config.bin)
    end)
  end)

  describe("wrapped_lsp_start", function()
    local original_lsp_start
    local captured_config, captured_opts
    local test_bufs

    before_each(function()
      mock = helpers.mock_vim_system()
      test_bufs = {}

      -- Save real vim.lsp.start, setup will wrap it
      original_lsp_start = vim.lsp.start

      -- Replace vim.lsp.start with a spy before setup() wraps it
      captured_config = nil
      captured_opts = nil
      vim.lsp.start = function(config, opts)
        captured_config = config
        captured_opts = opts
        return 1 -- fake client id
      end

      poly.setup()
    end)

    after_each(function()
      mock.restore()
      vim.lsp.start = original_lsp_start
      for _, buf in ipairs(test_bufs) do
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
      pcall(vim.api.nvim_del_user_command, "PolyDirenvRestart")
      pcall(vim.api.nvim_del_user_command, "PolyDirenvStatus")
      pcall(vim.api.nvim_del_user_command, "PolyDirenvAllow")
      pcall(vim.api.nvim_del_user_command, "PolyDirenvDeny")
      pcall(vim.api.nvim_del_user_command, "PolyDirenvInvalidate")
    end)

    --- Create a named buffer for testing and track it for cleanup.
    local function make_buf(name)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(buf, name)
      vim.api.nvim_set_current_buf(buf)
      table.insert(test_bufs, buf)
      return buf
    end

    it("passes through when autoload is false", function()
      poly.config.autoload = false

      local config = { name = "test_lsp" }
      vim.lsp.start(config, {})

      assert.equals("test_lsp", captured_config.name)
      -- Should not have _direnv_envrc tag
      assert.is_nil(captured_config._direnv_envrc)
    end)

    it("passes through when config already has _direnv_envrc", function()
      local config = { name = "test_lsp", _direnv_envrc = "/project/.envrc" }
      vim.lsp.start(config, {})

      assert.equals("test_lsp", captured_config.name)
      assert.equals("/project/.envrc", captured_config._direnv_envrc)
    end)

    it("passes through when buffer has no file", function()
      -- Create a scratch buffer with no name
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_set_current_buf(buf)
      table.insert(test_bufs, buf)

      local config = { name = "test_lsp" }
      vim.lsp.start(config, {})

      assert.equals("test_lsp", captured_config.name)
      assert.is_nil(captured_config._direnv_envrc)
    end)

    it("does synchronous start on full cache hit", function()
      make_buf("/test/sync_hit/main.py")

      -- Warm the cache
      cache.set_resolve("/test/sync_hit", "/test/.envrc", 0)
      cache.set_env("/test/.envrc", { PATH = "/nix/bin" })

      local config = { name = "test_lsp" }
      local result = vim.lsp.start(config, {})

      -- Should return a client id (synchronous path)
      assert.equals(1, result)
      -- Should have injected cmd_env
      assert.is_not_nil(captured_config.cmd_env)
      assert.equals("/nix/bin", captured_config.cmd_env.PATH)
      -- Should have tagged with _direnv_envrc
      assert.equals("/test/.envrc", captured_config._direnv_envrc)
      -- Should have set reuse_client
      assert.is_function(captured_opts.reuse_client)
      -- Should not have called vim.system
      assert.equals(0, #mock.calls)
    end)

    it("returns nil on cache miss (async path)", function()
      make_buf("/test/async_miss/main.py")

      -- No cache populated
      mock.returns(resolve_response("/test/.envrc", 0))
      mock.returns(export_response({ PATH = "/nix/bin" }))

      local config = { name = "test_lsp" }
      local result = vim.lsp.start(config, {})

      -- Async path returns nil initially
      assert.is_nil(result)

      -- Flush vim.schedule to let the async callback complete
      helpers.flush_schedule()

      -- Now the original lsp start should have been called
      assert.is_not_nil(captured_config)
      assert.equals("/test/.envrc", captured_config._direnv_envrc)
    end)

    it("sets reuse_client that checks envrc path", function()
      make_buf("/test/reuse_client/main.py")

      cache.set_resolve("/test/reuse_client", "/test/.envrc", 0)
      cache.set_env("/test/.envrc", { PATH = "/bin" })

      vim.lsp.start({ name = "test_lsp" }, {})

      local reuse_fn = captured_opts.reuse_client
      assert.is_function(reuse_fn)

      -- Mock client objects for testing reuse predicate
      local matching_client = {
        name = "test_lsp",
        config = {
          _direnv_envrc = "/test/.envrc",
          root_dir = "/test",
        },
        is_stopped = function()
          return false
        end,
      }

      local matching_config = {
        name = "test_lsp",
        _direnv_envrc = "/test/.envrc",
        root_dir = "/test",
      }

      -- Should reuse when name, envrc, and root_dir match
      assert.is_true(reuse_fn(matching_client, matching_config))

      -- Should not reuse when envrc differs
      local diff_envrc_config = vim.tbl_extend("force", matching_config, {
        _direnv_envrc = "/other/.envrc",
      })
      assert.is_false(reuse_fn(matching_client, diff_envrc_config))

      -- Should not reuse when name differs
      local diff_name_config = vim.tbl_extend("force", matching_config, {
        name = "other_lsp",
      })
      assert.is_false(reuse_fn(matching_client, diff_name_config))

      -- Should not reuse when root_dir differs
      local diff_root_config = vim.tbl_extend("force", matching_config, {
        root_dir = "/other/test",
      })
      assert.is_false(reuse_fn(matching_client, diff_root_config))

      -- Should not reuse when client is stopped
      local stopped_client = vim.tbl_extend("force", matching_client, {
        is_stopped = function()
          return true
        end,
      })
      assert.is_false(reuse_fn(stopped_client, matching_config))
    end)
  end)
end)
