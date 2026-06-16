# poly-direnv.nvim

**Per-directory [direnv](https://direnv.net/) environments for Neovim LSP and
[neotest](https://github.com/nvim-neotest/neotest).**

If you work in a monorepo (or any project) where different subdirectories have
their own `.envrc` -- different Nix devShells, different virtualenvs, different
tool versions -- this plugin makes sure each LSP server and test runner starts
with the right environment, automatically.

Without it, every LSP server inherits whichever environment was active when
Neovim launched. That means your linter in `packages/foo/` might see
`packages/bar/`'s Python, or vice versa -- and `neotest` runs tests with the
wrong toolchain for the same reason.

With `poly-direnv.nvim`, opening files from both directories in the same Neovim
session spawns **separate LSP server processes**, each with the correct `PATH`,
`PYTHONPATH`, and any other variables set by the respective `.envrc`. Neotest
adapters are wrapped so test commands resolve from the direnv-scoped `PATH`
too. No manual switching, no restarts.

## Requirements

- Neovim >= 0.12
- [direnv](https://direnv.net/) >= 2.33.0

## Installation

### lazy.nvim

```lua
{
  "your-user/poly-direnv.nvim",
  config = function()
    require("poly-direnv").setup()
  end,
}
```

### Nix (nixvim)

```nix
# flake.nix
inputs.poly-direnv.url = "github:your-user/poly-direnv.nvim";
```

```nix
{ pkgs, inputs, ... }: {
  programs.nixvim = {
    imports = [ inputs.poly-direnv.nixvimModules.default ];

    plugins.poly-direnv = {
      enable = true;
      package = inputs.poly-direnv.packages.${pkgs.system}.default;
    };
  };
}
```

### Nix (flake overlay)

```nix
# flake.nix
inputs.poly-direnv.url = "github:your-user/poly-direnv.nvim";

# In your nixos/home-manager config:
nixpkgs.overlays = [ inputs.poly-direnv.overlays.default ];

# Then use:
pkgs.vimPlugins.poly-direnv-nvim
```

## Configuration

All options are optional. `setup()` with no arguments uses the defaults shown
below.

```lua
require("poly-direnv").setup({
  cache_ttl = 30000,       -- cache lifetime (ms)
  bin = "direnv",          -- path to direnv binary
  autoload = true,         -- inject env on every LSP start (false = manual only)
  notifications = {
    on_load = true,        -- notify when an env is loaded for the first time
    on_envrc_change = true, -- notify when a .envrc file is saved
  },
})
```

## Commands

| Command                 | Description                                        |
|-------------------------|----------------------------------------------------|
| `:PolyDirenvStatus`     | Show LSP servers grouped by `.envrc` scope         |
| `:PolyDirenvRestart`    | Invalidate cache and restart servers for this scope|
| `:PolyDirenvAllow`      | `direnv allow` for the current buffer's `.envrc`   |
| `:PolyDirenvDeny`       | `direnv deny` for the current buffer's `.envrc`    |
| `:PolyDirenvInvalidate` | Clear all cached environments                      |

## Statusline

`statusline()` returns the active `.envrc` path for the current buffer
(relative to the git root), or `""` when none applies.

### lualine

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        function() return require("poly-direnv").statusline() end,
        cond = function() return require("poly-direnv").statusline() ~= "" end,
        icon = "",
      },
      "encoding", "fileformat", "filetype",
    },
  },
})
```

### Native statusline

```lua
vim.o.statusline = '%{%v:lua.require("poly-direnv").statusline()%} ...'
```

## Neotest integration

`poly-direnv.neotest` wraps adapters so test commands resolve from the
direnv-scoped `PATH` and run with the correct environment variables.

| Function         | Purpose                                                  |
|------------------|----------------------------------------------------------|
| `wrap(adapter)`  | Resolve the adapter's command from the direnv `PATH`     |
| `python(opts?)`  | neotest-python config with direnv-aware Python resolution|
| `run(opts?)`     | `run` config with env injection and cwd override         |

```lua
local poly_neotest = require("poly-direnv.neotest")

require("neotest").setup({
  adapters = {
    poly_neotest.wrap(require("neotest-golang")({ dap_go_enabled = true })),
    poly_neotest.wrap(require("neotest-python")(poly_neotest.python({
      dap = { justMyCode = false },
    }))),
    poly_neotest.wrap(require("neotest-zig")),
    poly_neotest.wrap(require("rustaceanvim.neotest")),
  },
  run = poly_neotest.run(),
})
```

### Nixvim

```nix
plugins.poly-direnv.neotest.enable = true;

plugins.neotest = {
  enable = true;
  adapters = {
    python.enable = true;
    golang = { enable = true; settings.dap_go_enabled = true; };
    zig.enable = true;
  };
  settings.adapters = [
    { __raw = ''require("rustaceanvim.neotest")''; }
  ];
};
```

All adapters are wrapped automatically. Python-specific settings are injected
via `mkDefault` when the python adapter is enabled.

## Example

```
aurora/
  flake.nix               # defines devShells: raw, bronze
  packages/
    raw/
      .envrc               # use flake .#raw
      src/aurora_raw/
        __main__.py
    bronze/
      .envrc               # use flake .#bronze
      src/aurora_bronze/
        __main__.py
```

Opening `__main__.py` from both packages in the same session:

- `ruff` for `packages/raw/` starts with the `raw` devShell's `PYTHONPATH`
- `ruff` for `packages/bronze/` starts with the `bronze` devShell's `PYTHONPATH`

`:PolyDirenvStatus` shows:

```
poly-direnv: LSP Server Status

  /home/user/aurora/packages/raw/.envrc:
    ruff (id=1)
    ty (id=3)
  /home/user/aurora/packages/bronze/.envrc:
    ruff (id=2)
    ty (id=4)
  (no .envrc / default env):
    nixd (id=5)
```

## Limitations

- **Process-level environments only.** LSP servers get their env at spawn time
  via `cmd_env`. The global Neovim process environment is not modified, so
  `:!make` and toggleterm still use Neovim's own env.
- **`.envrc` must be allowed.** Unapproved `.envrc` files cause a warning; the
  LSP starts with Neovim's default environment. Use `:PolyDirenvAllow`.

## How it works

The plugin monkey-patches `vim.lsp.start()` during `setup()`. When an LSP
start is triggered:

1. Determines the buffer's directory.
2. Checks a two-level cache: `directory -> envrc_path -> env_table`.
3. On miss, runs `direnv status --json` and `direnv export json` asynchronously.
4. Sets `cmd_env` on the config so the server inherits the correct variables.
5. Overrides `reuse_client` so servers are keyed by `(name, envrc_path)`.
6. Calls the original `vim.lsp.start()`.

On cache hit, steps 3-4 are skipped and the start is synchronous (~0ms).

## Public API

Three functions expose the direnv environment for use outside LSP (test
runners, task runners, REPLs, etc.).

### `get_env(dir, callback)`

Async. Resolves the environment, using the cache when possible.

```lua
require("poly-direnv").get_env("/path/to/project", function(envrc_path, env)
  -- envrc_path: string?
  -- env: table<string, string>?
end)
```

### `get_env_sync(dir)`

Returns the cached environment. Returns `nil, nil` on cache miss (never
blocks).

```lua
local envrc_path, env = require("poly-direnv").get_env_sync("/path/to/project")
```

### `get_env_wait(dir, timeout?)`

Blocks until the environment is available (default timeout 5000ms). Tries the
cache first.

```lua
local envrc_path, env = require("poly-direnv").get_env_wait("/path/to/project")
```

## License

MIT
