--- Busted test runner for poly-direnv.nvim
---
--- Usage: nvim --headless --clean -l tests/run.lua [busted args...]
---
--- Requires LUA_PATH/LUA_CPATH to include the busted package and its
--- dependencies. The flake.nix devShell and checks handle this automatically.
---
--- Uses --clean to avoid loading user config. Configures package.preload
--- so that poly-direnv modules are loaded from the local source tree
--- instead of any installed version on the runtimepath.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

-- Force poly-direnv modules to load from the local source tree by
-- registering them in package.preload. This takes priority over both
-- Neovim's rtp-based loader and package.path, ensuring tests always
-- exercise the working copy.
local modules = {
  "poly-direnv",
  "poly-direnv.cache",
  "poly-direnv.direnv",
  "poly-direnv.health",
  "poly-direnv.neotest",
  "poly-direnv.types",
}
for _, mod in ipairs(modules) do
  local path = plugin_root .. "/lua/" .. mod:gsub("%.", "/")
  -- Try init.lua for packages, then direct .lua
  local file = path .. "/init.lua"
  if vim.uv.fs_stat(file) then
    package.preload[mod] = function()
      return dofile(file)
    end
  else
    file = path .. ".lua"
    if vim.uv.fs_stat(file) then
      package.preload[mod] = function()
        return dofile(file)
      end
    end
  end
end

-- Add the tests/ directory to package.path so require("tests.helpers") works.
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/?/init.lua;" .. package.path

require("busted.runner")({ standalone = false })
