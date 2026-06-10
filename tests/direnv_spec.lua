local helpers = require("tests.helpers")

describe("direnv", function()
  local direnv
  local mock

  before_each(function()
    helpers.reset_modules()
    direnv = require("poly-direnv.direnv")
    mock = helpers.mock_vim_system()
  end)

  after_each(function()
    mock.restore()
  end)

  describe("resolve", function()
    it("extracts foundRC.path and foundRC.allowed from valid output", function()
      mock.returns({
        code = 0,
        stdout = vim.json.encode({
          state = {
            foundRC = {
              path = "/project/.envrc",
              allowed = 0,
            },
          },
        }),
        stderr = "",
      })

      local result_path, result_allowed
      direnv.resolve("/project/src", function(path, allowed)
        result_path = path
        result_allowed = allowed
      end)
      helpers.flush_schedule()

      assert.equals("/project/.envrc", result_path)
      assert.equals(0, result_allowed)
    end)

    it("returns nil when foundRC is null (no envrc)", function()
      mock.returns({
        code = 0,
        stdout = vim.json.encode({
          state = {
            foundRC = vim.NIL,
          },
        }),
        stderr = "",
      })

      local result_path, result_allowed
      direnv.resolve("/no-envrc", function(path, allowed)
        result_path = path
        result_allowed = allowed
      end)
      helpers.flush_schedule()

      assert.is_nil(result_path)
      assert.is_nil(result_allowed)
    end)

    it("returns nil on non-zero exit code", function()
      mock.returns({ code = 1, stdout = "", stderr = "error" })

      local result_path, result_allowed
      direnv.resolve("/some/dir", function(path, allowed)
        result_path = path
        result_allowed = allowed
      end)
      helpers.flush_schedule()

      assert.is_nil(result_path)
      assert.is_nil(result_allowed)
    end)

    it("returns nil on malformed JSON", function()
      mock.returns({ code = 0, stdout = "not json{{{", stderr = "" })

      local result_path, result_allowed
      direnv.resolve("/some/dir", function(path, allowed)
        result_path = path
        result_allowed = allowed
      end)
      helpers.flush_schedule()

      assert.is_nil(result_path)
      assert.is_nil(result_allowed)
    end)

    it("passes cwd = dir to vim.system", function()
      mock.returns({
        code = 0,
        stdout = vim.json.encode({ state = { foundRC = vim.NIL } }),
        stderr = "",
      })

      direnv.resolve("/my/project", function() end)
      helpers.flush_schedule()

      assert.equals(1, #mock.calls)
      assert.equals("/my/project", mock.calls[1].opts.cwd)
      assert.same({ direnv.bin, "status", "--json" }, mock.calls[1].cmd)
    end)

    it("reports pending status (allowed=1)", function()
      mock.returns({
        code = 0,
        stdout = vim.json.encode({
          state = {
            foundRC = {
              path = "/project/.envrc",
              allowed = 1,
            },
          },
        }),
        stderr = "",
      })

      local result_path, result_allowed
      direnv.resolve("/project/src", function(path, allowed)
        result_path = path
        result_allowed = allowed
      end)
      helpers.flush_schedule()

      assert.equals("/project/.envrc", result_path)
      assert.equals(1, result_allowed)
    end)
  end)

  describe("export", function()
    it("parses env diff into normalized table", function()
      mock.returns({
        code = 0,
        stdout = vim.json.encode({
          PATH = "/nix/store/bin:/usr/bin",
          PYTHONPATH = "/project/lib",
        }),
        stderr = "",
      })

      local result_env
      direnv.export("/project/.envrc", function(env)
        result_env = env
      end)
      helpers.flush_schedule()

      assert.is_not_nil(result_env)
      assert.equals("/nix/store/bin:/usr/bin", result_env.PATH)
      assert.equals("/project/lib", result_env.PYTHONPATH)
    end)

    it("strips vim.NIL values (unset vars)", function()
      -- vim.json.encode can't encode vim.NIL, so we craft the JSON manually
      -- to include a null value
      mock.returns({
        code = 0,
        stdout = '{"KEEP": "value", "REMOVE": null}',
        stderr = "",
      })

      local result_env
      direnv.export("/project/.envrc", function(env)
        result_env = env
      end)
      helpers.flush_schedule()

      assert.is_not_nil(result_env)
      assert.equals("value", result_env.KEEP)
      assert.is_nil(result_env.REMOVE)
    end)

    it("coerces non-string values to strings", function()
      -- direnv export should always return strings, but the code handles it
      mock.returns({
        code = 0,
        stdout = '{"NUM": 42, "BOOL": true, "STR": "hello"}',
        stderr = "",
      })

      local result_env
      direnv.export("/project/.envrc", function(env)
        result_env = env
      end)
      helpers.flush_schedule()

      assert.is_not_nil(result_env)
      assert.equals("hello", result_env.STR)
      assert.equals("42", result_env.NUM)
      assert.equals("true", result_env.BOOL)
    end)

    it("returns empty table on empty stdout (already current)", function()
      mock.returns({ code = 0, stdout = "", stderr = "" })

      local result_env
      direnv.export("/project/.envrc", function(env)
        result_env = env
      end)
      helpers.flush_schedule()

      assert.is_not_nil(result_env)
      assert.same({}, result_env)
    end)

    it("returns nil on non-zero exit code", function()
      mock.returns({ code = 1, stdout = "", stderr = "not allowed" })

      local result_env
      direnv.export("/project/.envrc", function(env)
        result_env = env
      end)
      helpers.flush_schedule()

      assert.is_nil(result_env)
    end)

    it("returns nil on malformed JSON", function()
      mock.returns({ code = 0, stdout = "garbage{{{", stderr = "" })

      local result_env
      direnv.export("/project/.envrc", function(env)
        result_env = env
      end)
      helpers.flush_schedule()

      assert.is_nil(result_env)
    end)

    it("passes cwd = dirname(envrc_path) to vim.system", function()
      mock.returns({ code = 0, stdout = "{}", stderr = "" })

      direnv.export("/my/project/.envrc", function() end)
      helpers.flush_schedule()

      assert.equals(1, #mock.calls)
      assert.equals("/my/project", mock.calls[1].opts.cwd)
      assert.same({ direnv.bin, "export", "json" }, mock.calls[1].cmd)
    end)
  end)

  describe("allow", function()
    it("returns true on success", function()
      mock.returns({ code = 0, stdout = "", stderr = "" })

      local result_ok, result_err
      direnv.allow("/project/.envrc", function(ok, err)
        result_ok = ok
        result_err = err
      end)
      helpers.flush_schedule()

      assert.is_true(result_ok)
      assert.is_nil(result_err)
    end)

    it("returns false with error on failure", function()
      mock.returns({ code = 1, stdout = "", stderr = "permission denied" })

      local result_ok, result_err
      direnv.allow("/project/.envrc", function(ok, err)
        result_ok = ok
        result_err = err
      end)
      helpers.flush_schedule()

      assert.is_false(result_ok)
      assert.equals("permission denied", result_err)
    end)

    it("passes cwd = dirname(envrc_path) to vim.system", function()
      mock.returns({ code = 0, stdout = "", stderr = "" })

      direnv.allow("/my/project/.envrc", function() end)
      helpers.flush_schedule()

      assert.equals("/my/project", mock.calls[1].opts.cwd)
      assert.same({ direnv.bin, "allow" }, mock.calls[1].cmd)
    end)
  end)

  describe("deny", function()
    it("returns true on success", function()
      mock.returns({ code = 0, stdout = "", stderr = "" })

      local result_ok, result_err
      direnv.deny("/project/.envrc", function(ok, err)
        result_ok = ok
        result_err = err
      end)
      helpers.flush_schedule()

      assert.is_true(result_ok)
      assert.is_nil(result_err)
    end)

    it("returns false with error on failure", function()
      mock.returns({ code = 1, stdout = "", stderr = "something wrong" })

      local result_ok, result_err
      direnv.deny("/project/.envrc", function(ok, err)
        result_ok = ok
        result_err = err
      end)
      helpers.flush_schedule()

      assert.is_false(result_ok)
      assert.equals("something wrong", result_err)
    end)

    it("passes cwd = dirname(envrc_path) to vim.system", function()
      mock.returns({ code = 0, stdout = "", stderr = "" })

      direnv.deny("/my/project/.envrc", function() end)
      helpers.flush_schedule()

      assert.equals("/my/project", mock.calls[1].opts.cwd)
      assert.same({ direnv.bin, "deny" }, mock.calls[1].cmd)
    end)
  end)
end)
