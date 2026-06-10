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

describe("neotest", function()
  local neotest_helper, cache, mock

  before_each(function()
    helpers.reset_modules()
    cache = require("poly-direnv.cache")
    -- Warm the poly-direnv module (needed before neotest helper)
    require("poly-direnv")
    neotest_helper = require("poly-direnv.neotest")
  end)

  describe("python", function()
    before_each(function()
      mock = helpers.mock_vim_system()
    end)

    after_each(function()
      mock.restore()
    end)

    it("returns a table with runner and python fields", function()
      local config = neotest_helper.python()
      assert.equals("pytest", config.runner)
      assert.is_function(config.python)
    end)

    it("merges user opts", function()
      local config = neotest_helper.python({ dap = { justMyCode = false } })
      assert.equals("pytest", config.runner)
      assert.is_function(config.python)
      assert.is_not_nil(config.dap)
      assert.is_false(config.dap.justMyCode)
    end)

    it("user opts can override runner", function()
      local config = neotest_helper.python({ runner = "unittest" })
      assert.equals("unittest", config.runner)
    end)

    it("python function resolves from cached direnv PATH", function()
      -- Create a temp directory with a fake python3
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir .. "/bin", "p")
      local py_path = tmpdir .. "/bin/python3"
      local f = io.open(py_path, "w")
      f:write("#!/bin/sh\n")
      f:close()

      cache.set_resolve("/project", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { PATH = tmpdir .. "/bin:/usr/bin" })

      local config = neotest_helper.python()
      local result = config.python("/project")

      assert.equals(py_path, result)

      -- Cleanup
      os.remove(py_path)
      os.remove(tmpdir .. "/bin")
      os.remove(tmpdir)
    end)

    it("python function falls back to 'python3' when no direnv env", function()
      mock.returns(resolve_response(nil, nil))

      local config = neotest_helper.python()
      local result = config.python("/no-envrc")

      assert.equals("python3", result)
    end)

    it("python function falls back to 'python3' when PATH has no python", function()
      cache.set_resolve("/project", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { PATH = "/nonexistent/bin" })

      local config = neotest_helper.python()
      local result = config.python("/project")

      assert.equals("python3", result)
    end)
  end)

  describe("run", function()
    before_each(function()
      mock = helpers.mock_vim_system()
    end)

    after_each(function()
      mock.restore()
    end)

    it("returns a table with augment function", function()
      local config = neotest_helper.run()
      assert.is_function(config.augment)
    end)

    it("merges user opts", function()
      local config = neotest_helper.run({ enabled = false })
      assert.is_function(config.augment)
      assert.is_false(config.enabled)
    end)

    it("augment injects env and cwd from direnv", function()
      cache.set_resolve("/project/tests", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { PATH = "/nix/bin", FOO = "bar" })

      local config = neotest_helper.run()
      local tree = {
        data = function()
          return { path = "/project/tests/test_foo.py" }
        end,
      }
      local args = {}
      local result = config.augment(tree, args)

      assert.equals("bar", result.env.FOO)
      assert.equals("/nix/bin", result.env.PATH)
      assert.equals("/project", result.cwd)
    end)

    it("augment preserves user-provided cwd", function()
      cache.set_resolve("/project/tests", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { FOO = "bar" })

      local config = neotest_helper.run()
      local tree = {
        data = function()
          return { path = "/project/tests/test_foo.py" }
        end,
      }
      local args = { cwd = "/custom/dir" }
      local result = config.augment(tree, args)

      assert.equals("/custom/dir", result.cwd)
    end)

    it("augment preserves user-provided env vars over direnv", function()
      cache.set_resolve("/project/tests", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { FOO = "from_direnv", BAR = "from_direnv" })

      local config = neotest_helper.run()
      local tree = {
        data = function()
          return { path = "/project/tests/test_foo.py" }
        end,
      }
      local args = { env = { FOO = "from_user" } }
      local result = config.augment(tree, args)

      assert.equals("from_user", result.env.FOO)
      assert.equals("from_direnv", result.env.BAR)
    end)

    it("augment passes through when no position", function()
      local config = neotest_helper.run()
      local tree = {
        data = function()
          return nil
        end,
      }
      local args = { extra = "preserved" }
      local result = config.augment(tree, args)

      assert.equals("preserved", result.extra)
      assert.is_nil(result.env)
      assert.is_nil(result.cwd)
    end)

    it("augment passes through when no direnv env found", function()
      mock.returns(resolve_response(nil, nil))

      local config = neotest_helper.run()
      local tree = {
        data = function()
          return { path = "/no-envrc/tests/test_foo.py" }
        end,
      }
      local args = {}
      local result = config.augment(tree, args)

      assert.is_nil(result.env)
      assert.is_nil(result.cwd)
    end)
  end)
end)
