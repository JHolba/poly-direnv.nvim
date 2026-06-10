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
    it("returns a table with runner and python fields", function()
      local config = neotest_helper.python()
      assert.equals("pytest", config.runner)
      assert.equals("python3", config.python)
    end)

    it("merges user opts", function()
      local config = neotest_helper.python({ dap = { justMyCode = false } })
      assert.equals("pytest", config.runner)
      assert.equals("python3", config.python)
      assert.is_not_nil(config.dap)
      assert.is_false(config.dap.justMyCode)
    end)

    it("user opts can override runner", function()
      local config = neotest_helper.python({ runner = "unittest" })
      assert.equals("unittest", config.runner)
    end)

    it("user opts can override python", function()
      local config = neotest_helper.python({ python = "/custom/python3" })
      assert.equals("/custom/python3", config.python)
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

  describe("wrap", function()
    before_each(function()
      mock = helpers.mock_vim_system()
    end)

    after_each(function()
      mock.restore()
    end)

    it("resolves bare command from direnv PATH (table command)", function()
      -- Create a temp directory with a fake executable
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir .. "/bin", "p")
      local go_path = tmpdir .. "/bin/go"
      local f = io.open(go_path, "w")
      f:write("#!/bin/sh\n")
      f:close()

      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { PATH = tmpdir .. "/bin:/usr/bin" })

      local adapter = {
        build_spec = function()
          return {
            command = { "go", "test", "-json", "./..." },
          }
        end,
      }

      local wrapped = neotest_helper.wrap(adapter)
      local spec = wrapped.build_spec({
        tree = {
          data = function()
            return { path = "/project/src/main_test.go" }
          end,
        },
      })

      assert.equals(go_path, spec.command[1])
      assert.equals("test", spec.command[2])

      os.remove(go_path)
      os.remove(tmpdir .. "/bin")
      os.remove(tmpdir)
    end)

    it("resolves bare command from direnv PATH (string command)", function()
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir .. "/bin", "p")
      local ctest_path = tmpdir .. "/bin/ctest"
      local f = io.open(ctest_path, "w")
      f:write("#!/bin/sh\n")
      f:close()

      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { PATH = tmpdir .. "/bin:/usr/bin" })

      local adapter = {
        build_spec = function()
          return {
            command = "ctest --test-dir build --quiet",
          }
        end,
      }

      local wrapped = neotest_helper.wrap(adapter)
      local spec = wrapped.build_spec({
        tree = {
          data = function()
            return { path = "/project/src/test_main.cpp" }
          end,
        },
      })

      assert.equals(ctest_path .. " --test-dir build --quiet", spec.command)

      os.remove(ctest_path)
      os.remove(tmpdir .. "/bin")
      os.remove(tmpdir)
    end)

    it("leaves absolute paths unchanged", function()
      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { PATH = "/some/bin" })

      local adapter = {
        build_spec = function()
          return {
            command = { "/usr/bin/go", "test" },
          }
        end,
      }

      local wrapped = neotest_helper.wrap(adapter)
      local spec = wrapped.build_spec({
        tree = {
          data = function()
            return { path = "/project/src/main_test.go" }
          end,
        },
      })

      assert.equals("/usr/bin/go", spec.command[1])
    end)

    it("falls back to original command when not found in direnv PATH", function()
      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { PATH = "/nonexistent/bin" })

      local adapter = {
        build_spec = function()
          return {
            command = { "cargo", "test" },
          }
        end,
      }

      local wrapped = neotest_helper.wrap(adapter)
      local spec = wrapped.build_spec({
        tree = {
          data = function()
            return { path = "/project/src/lib.rs" }
          end,
        },
      })

      assert.equals("cargo", spec.command[1])
    end)

    it("passes through when build_spec returns nil", function()
      local adapter = {
        build_spec = function()
          return nil
        end,
      }

      local wrapped = neotest_helper.wrap(adapter)
      local spec = wrapped.build_spec({
        tree = {
          data = function()
            return { path = "/project/src/test.go" }
          end,
        },
      })

      assert.is_nil(spec)
    end)

    it("handles multiple specs", function()
      local tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir .. "/bin", "p")
      local go_path = tmpdir .. "/bin/go"
      local f = io.open(go_path, "w")
      f:write("#!/bin/sh\n")
      f:close()

      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.set_env("/project/.envrc", { PATH = tmpdir .. "/bin:/usr/bin" })

      local adapter = {
        build_spec = function()
          return {
            { command = { "go", "test", "./pkg1" } },
            { command = { "go", "test", "./pkg2" } },
          }
        end,
      }

      local wrapped = neotest_helper.wrap(adapter)
      local specs = wrapped.build_spec({
        tree = {
          data = function()
            return { path = "/project/src/main_test.go" }
          end,
        },
      })

      assert.equals(2, #specs)
      assert.equals(go_path, specs[1].command[1])
      assert.equals(go_path, specs[2].command[1])

      os.remove(go_path)
      os.remove(tmpdir .. "/bin")
      os.remove(tmpdir)
    end)

    it("preserves all other adapter fields", function()
      local adapter = {
        name = "test-adapter",
        root = function()
          return "/project"
        end,
        build_spec = function()
          return { command = { "go", "test" } }
        end,
      }

      local wrapped = neotest_helper.wrap(adapter)
      assert.equals("test-adapter", wrapped.name)
      assert.is_function(wrapped.root)
    end)

    it("returns adapter unchanged when no build_spec", function()
      local adapter = { name = "no-build-spec" }
      local wrapped = neotest_helper.wrap(adapter)
      assert.equals("no-build-spec", wrapped.name)
      assert.is_nil(wrapped.build_spec)
    end)
  end)
end)
