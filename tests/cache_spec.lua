local helpers = require("tests.helpers")

describe("cache", function()
  local cache

  before_each(function()
    helpers.reset_modules()
    cache = require("poly-direnv.cache")
  end)

  describe("resolve cache", function()
    it("returns nil for unknown key", function()
      assert.is_nil(cache.get_resolve("/unknown/dir"))
    end)

    it("round-trips set/get", function()
      cache.set_resolve("/some/dir", "/some/dir/.envrc", 0)
      local result = cache.get_resolve("/some/dir")
      assert.is_not_nil(result)
      assert.equals("/some/dir/.envrc", result.envrc_path)
      assert.equals(0, result.allowed)
    end)

    it("stores nil envrc_path (no envrc found)", function()
      cache.set_resolve("/some/dir", nil, nil)
      local result = cache.get_resolve("/some/dir")
      assert.is_not_nil(result)
      assert.is_nil(result.envrc_path)
      assert.is_nil(result.allowed)
    end)

    it("returns nil after TTL expires", function()
      cache.set_ttl(1) -- 1ms TTL
      cache.set_resolve("/some/dir", "/some/dir/.envrc", 0)
      helpers.sleep_ms(5)
      assert.is_nil(cache.get_resolve("/some/dir"))
    end)
  end)

  describe("env cache", function()
    it("returns nil for unknown key", function()
      assert.is_nil(cache.get_env("/unknown/.envrc"))
    end)

    it("round-trips set/get", function()
      local env = { PATH = "/usr/bin", HOME = "/home/user" }
      cache.set_env("/some/.envrc", env)
      local result = cache.get_env("/some/.envrc")
      assert.is_not_nil(result)
      assert.equals("/usr/bin", result.PATH)
      assert.equals("/home/user", result.HOME)
    end)

    it("returns nil after TTL expires", function()
      cache.set_ttl(1) -- 1ms TTL
      cache.set_env("/some/.envrc", { FOO = "bar" })
      helpers.sleep_ms(5)
      assert.is_nil(cache.get_env("/some/.envrc"))
    end)
  end)

  describe("stable cache", function()
    it("returns nil for unknown key", function()
      assert.is_nil(cache.get_resolve_stable("/unknown/dir"))
    end)

    it("is populated by set_resolve", function()
      cache.set_resolve("/some/dir", "/some/dir/.envrc", 0)
      local result = cache.get_resolve_stable("/some/dir")
      assert.is_not_nil(result)
      assert.equals("/some/dir/.envrc", result.envrc_path)
      assert.equals(0, result.allowed)
    end)

    it("persists after TTL expires", function()
      cache.set_ttl(1) -- 1ms TTL
      cache.set_resolve("/some/dir", "/some/dir/.envrc", 0)
      helpers.sleep_ms(5)
      -- Regular cache should be expired
      assert.is_nil(cache.get_resolve("/some/dir"))
      -- Stable cache should still have the value
      local result = cache.get_resolve_stable("/some/dir")
      assert.is_not_nil(result)
      assert.equals("/some/dir/.envrc", result.envrc_path)
    end)
  end)

  describe("invalidate", function()
    it("clears env entry for the given envrc", function()
      cache.set_env("/project/.envrc", { FOO = "bar" })
      cache.invalidate("/project/.envrc")
      assert.is_nil(cache.get_env("/project/.envrc"))
    end)

    it("clears resolve entries pointing to the envrc", function()
      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.set_resolve("/project/lib", "/project/.envrc", 0)
      cache.invalidate("/project/.envrc")
      assert.is_nil(cache.get_resolve("/project/src"))
      assert.is_nil(cache.get_resolve("/project/lib"))
    end)

    it("clears stable entries pointing to the envrc", function()
      cache.set_resolve("/project/src", "/project/.envrc", 0)
      cache.invalidate("/project/.envrc")
      assert.is_nil(cache.get_resolve_stable("/project/src"))
    end)

    it("does not clear unrelated entries", function()
      cache.set_resolve("/project-a/src", "/project-a/.envrc", 0)
      cache.set_env("/project-a/.envrc", { A = "1" })
      cache.set_resolve("/project-b/src", "/project-b/.envrc", 0)
      cache.set_env("/project-b/.envrc", { B = "2" })

      cache.invalidate("/project-a/.envrc")

      -- project-a should be gone
      assert.is_nil(cache.get_resolve("/project-a/src"))
      assert.is_nil(cache.get_env("/project-a/.envrc"))
      -- project-b should be untouched
      assert.is_not_nil(cache.get_resolve("/project-b/src"))
      assert.is_not_nil(cache.get_env("/project-b/.envrc"))
    end)
  end)

  describe("invalidate_all", function()
    it("clears everything", function()
      cache.set_resolve("/dir-a", "/a/.envrc", 0)
      cache.set_resolve("/dir-b", "/b/.envrc", 0)
      cache.set_env("/a/.envrc", { A = "1" })
      cache.set_env("/b/.envrc", { B = "2" })

      cache.invalidate_all()

      assert.is_nil(cache.get_resolve("/dir-a"))
      assert.is_nil(cache.get_resolve("/dir-b"))
      assert.is_nil(cache.get_env("/a/.envrc"))
      assert.is_nil(cache.get_env("/b/.envrc"))
      assert.is_nil(cache.get_resolve_stable("/dir-a"))
      assert.is_nil(cache.get_resolve_stable("/dir-b"))
    end)
  end)

  describe("set_ttl", function()
    it("changes the TTL used for expiry checks", function()
      -- Set a very short TTL
      cache.set_ttl(1)
      cache.set_resolve("/short", "/short/.envrc", 0)
      helpers.sleep_ms(5)
      -- Should be expired
      assert.is_nil(cache.get_resolve("/short"))

      -- Now set a long TTL and verify entries survive
      cache.set_ttl(60000)
      cache.set_resolve("/long", "/long/.envrc", 0)
      helpers.sleep_ms(5)
      -- Should still be valid
      assert.is_not_nil(cache.get_resolve("/long"))
    end)
  end)
end)
