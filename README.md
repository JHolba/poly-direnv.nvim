# poly-direnv.nvim

Neovim plugin that gives each LSP server the correct
[direnv](https://direnv.net/) environment based on which `.envrc` scope the
file belongs to.

In a monorepo where `packages/foo/.envrc` and `packages/bar/.envrc` provide
different toolchains, opening files from both directories in the same Neovim
session will spawn **separate LSP server processes** -- each with the right
`PATH`, `PYTHONPATH`, and any other variables set by the respective `.envrc`.

## Problem

Neovim starts one LSP server per `(name, root_dir)` pair. Every buffer that
shares a root shares the same server process and its environment. If two
subdirectories have different `.envrc` files (different Nix devShells, different
virtualenvs, different tool versions), the LSP servers all inherit whichever
environment happened to be active first.

## Solution

`poly-direnv.nvim` wraps `vim.lsp.start()` to:

1. Find the closest `.envrc` for the buffer's directory (`direnv status --json`).
2. Export the environment for that `.envrc` (`direnv export json`).
3. Set `cmd_env` on the LSP config so the server process spawns with the
   correct environment.
4. Override the `reuse_client` predicate so servers are keyed by
   `(name, envrc_path)` -- two servers with the same name but different
   `.envrc` scopes run as independent processes.

Results are cached. The first buffer under a new `.envrc` has a brief async
delay (~100-200ms) while the environment is resolved. Subsequent buffers under
the same `.envrc` start synchronously. Treesitter, syntax highlighting, and
other in-process features work immediately regardless.

## Requirements

- Neovim >= 0.12
- [direnv](https://direnv.net/) >= 2.33.0 (needs `direnv status --json`)

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

Add the plugin as a flake input:

```nix
# flake.nix
inputs.poly-direnv = {
  url = "github:your-user/poly-direnv.nvim";
  flake = false;
};
```

Then in your nixvim plugin file:

```nix
{ pkgs, inputs, ... }: let
  poly-direnv-nvim = pkgs.vimUtils.buildVimPlugin {
    pname = "poly-direnv-nvim";
    version = "0.1.0";
    src = inputs.poly-direnv;
  };
in {
  programs.nixvim = {
    extraPlugins = [ poly-direnv-nvim ];

    # Must be extraConfigLuaPre so the wrapper is in place
    # before vim.lsp.enable() registers FileType autocmds.
    extraConfigLuaPre = ''
      require("poly-direnv").setup()
    '';
  };
}
```

A nixvim module is also provided at `nix/nixvim.nix` for a more declarative
setup with typed options. See the file for usage instructions.

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

```lua
require("poly-direnv").setup({
  -- How long to cache direnv export results (ms).
  cache_ttl = 30000,

  -- Path to the direnv binary.
  bin = "direnv",

  -- Automatically inject env on every LSP start.
  -- Set to false to disable the wrapper and use commands manually.
  autoload = true,

  notifications = {
    -- Notify when an env is loaded for the first time.
    on_load = true,
    -- Notify when a .envrc file is saved.
    on_envrc_change = true,
  },
})
```

All options are optional. Calling `setup()` with no arguments uses the defaults
shown above.

## Statusline

The plugin provides a `statusline()` function that returns the active `.envrc`
path for the current buffer, shortened relative to the git root (or home
directory). Returns `""` when no `.envrc` applies.

### lualine

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      {
        function()
          return require("poly-direnv").statusline()
        end,
        cond = function()
          return require("poly-direnv").statusline() ~= ""
        end,
        icon = "",
      },
      "encoding",
      "fileformat",
      "filetype",
    },
  },
})
```

### Native statusline

```lua
vim.o.statusline = '%{%v:lua.require("poly-direnv").statusline()%} ...'
```

When editing a file under `packages/raw/`, the statusline shows
`packages/raw/.envrc`. Files outside any `.envrc` scope show nothing.

## Commands

| Command              | Description                                            |
|----------------------|--------------------------------------------------------|
| `:PolyDirenvStatus`   | Show running LSP servers grouped by `.envrc` scope     |
| `:PolyDirenvRestart`  | Invalidate cache and restart servers for current scope |
| `:PolyDirenvAllow`    | Run `direnv allow` for the current buffer's `.envrc`   |
| `:PolyDirenvDeny`     | Run `direnv deny` for the current buffer's `.envrc`    |
| `:PolyDirenvInvalidate` | Clear all cached environments                        |

## Example

Given a monorepo:

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

Opening `__main__.py` from both packages in the same Neovim session:

- `ruff` for `packages/raw/` starts with the `raw` devShell's `PYTHONPATH`
- `ruff` for `packages/bronze/` starts with the `bronze` devShell's `PYTHONPATH`
- Each server sees the correct dependencies for its package

Running `:PolyDirenvStatus` shows:

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

## How it works

The plugin monkey-patches `vim.lsp.start()` during `setup()`. When Neovim's
internal `FileType` autocmd triggers an LSP start for a buffer:

1. The wrapper determines the buffer's file directory.
2. It checks a two-level cache: `directory -> envrc_path -> env_table`.
3. On cache miss, it runs `direnv status --json` (to find the `.envrc`) and
   `direnv export json` (to get the environment diff) asynchronously via
   `vim.system()`.
4. It sets `config.cmd_env` to the exported environment so the LSP server
   process inherits the correct variables.
5. It tags the config with `_direnv_envrc` and overrides `reuse_client` so
   that servers are only reused when both the name **and** envrc path match.
6. It calls the original `vim.lsp.start()`.

On cache hit, steps 3-4 are skipped and the start is synchronous.

## Public API

The plugin exposes two functions for retrieving the direnv environment for any
directory. These are useful for integrating with tools that spawn external
processes outside of LSP (e.g. test runners, task runners, REPLs).

### `get_env(dir, callback)`

Asynchronously resolve the direnv environment for a directory. Runs the full
resolve + export pipeline, using the cache when possible.

```lua
require("poly-direnv").get_env("/path/to/project", function(envrc_path, env)
  -- envrc_path: string? -- the .envrc that applies, or nil
  -- env: table<string, string>? -- environment variables, or nil
end)
```

### `get_env_sync(dir)`

Synchronously return the cached direnv environment for a directory. Returns
`nil, nil` on cache miss (never spawns subprocesses). The cache is typically
warm from the LSP integration by the time you need it.

```lua
local envrc_path, env = require("poly-direnv").get_env_sync("/path/to/project")
```

### `get_env_wait(dir, timeout?)`

Synchronously resolve the direnv environment for a directory, blocking until
the result is available. Tries the cache first; on miss, runs the full async
pipeline and blocks with `vim.wait()`. The optional `timeout` defaults to
5000ms.

```lua
local envrc_path, env = require("poly-direnv").get_env_wait("/path/to/project")
```

Use this when the cache may not be warm (e.g. when a test runner triggers
before any LSP server has started for that directory).

### Neotest integration

The `poly-direnv.neotest` module provides ready-made configuration for
[neotest](https://github.com/nvim-neotest/neotest). It handles:

- Resolving executables from the direnv `PATH` (all adapters)
- Injecting direnv environment variables into test processes
- Setting `cwd` to the `.envrc` parent directory
- Python-specific: correct interpreter resolution and forced pytest runner

Three functions are provided:

| Function | Purpose |
|----------|---------|
| `wrap(adapter)` | Wraps any adapter so its command is resolved from the direnv `PATH` |
| `python(opts?)` | Returns neotest-python config with direnv-aware Python resolution |
| `run(opts?)` | Returns `run` config with env injection and cwd override |

`wrap()` is needed because `jobstart` resolves executables from the parent
process's `PATH`, not from the `env` option. Without it, bare commands like
`go`, `cargo`, or `zig` resolve to whichever version Neovim sees, ignoring the
direnv environment.

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

#### Nixvim

```nix
plugins.neotest = {
  enable = true;

  settings = let
    wrap = name: ''require("poly-direnv.neotest").wrap(${name})'';
  in {
    adapters = [
      {__raw = wrap ''require("neotest-golang")({ dap_go_enabled = true })'';}
      {__raw = wrap ''require("neotest-python")(require("poly-direnv.neotest").python())''; }
      {__raw = wrap ''require("neotest-zig")'';}
      {__raw = wrap ''require("rustaceanvim.neotest")'';}
    ];
    run.__raw = ''require("poly-direnv.neotest").run()'';
  };
};
```

## Limitations

- **Process-level environments only.** Each LSP server process gets its env at
  spawn time via `cmd_env`. The global Neovim process environment (`vim.env`)
  is not modified. Shell commands (`:!make`, toggleterm) inherit Neovim's
  process env, not the direnv-scoped env.
- **`.envrc` must be allowed.** If the `.envrc` hasn't been approved via
  `direnv allow`, the plugin warns and starts the LSP with Neovim's default
  environment. Use `:PolyDirenvAllow` to approve it.

## License

MIT
