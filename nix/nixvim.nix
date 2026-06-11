# Nixvim module for poly-direnv.nvim
#
# Import inside programs.nixvim to get access to the full nixvim API:
#
#   programs.nixvim = {
#     imports = [ inputs.poly-direnv.nixvimModules.default ];
#     plugins.poly-direnv = {
#       enable = true;
#       neotest.enable = true;
#     };
#   };
#
# Neotest adapters are configured the normal nixvim way:
#
#   plugins.neotest = {
#     enable = true;
#     adapters.python.enable = true;
#     adapters.golang.enable = true;
#     settings.adapters = [
#       { __raw = ''require("rustaceanvim.neotest")''; }
#     ];
#   };
{
  lib,
  config,
  ...
}: let
  cfg = config.plugins.poly-direnv;
  neotestPythonEnabled = config.plugins.neotest.adapters.python.enable or false;
in {
  options.plugins.poly-direnv = {
    enable = lib.mkEnableOption "poly-direnv.nvim -- per-directory direnv environments for LSP servers";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The poly-direnv.nvim plugin package.";
    };

    settings = lib.nixvim.mkSettingsOption {
      description = "Options provided to the `require('poly-direnv').setup()` function.";
      options = {
        cache_ttl =
          lib.nixvim.defaultNullOpts.mkUnsignedInt null
          "Cache TTL in milliseconds for direnv export results. Plugin default: 30000.";

        bin =
          lib.nixvim.defaultNullOpts.mkStr null
          "Path to the direnv binary. Plugin default: \"direnv\".";

        autoload =
          lib.nixvim.defaultNullOpts.mkBool null
          "Automatically inject direnv env on LSP start. Plugin default: true.";

        notifications = {
          on_load =
            lib.nixvim.defaultNullOpts.mkBool null
            "Notify when a direnv environment is loaded. Plugin default: true.";

          on_envrc_change =
            lib.nixvim.defaultNullOpts.mkBool null
            "Notify when an .envrc file is saved. Plugin default: true.";
        };
      };
    };

    neotest = {
      enable = lib.mkEnableOption "Wrap neotest adapters with poly-direnv environment injection";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      extraPlugins = [cfg.package];

      # Must run before vim.lsp.enable() registers FileType autocmds.
      extraConfigLuaPre = ''
        require("poly-direnv").setup(${lib.nixvim.toLuaObject cfg.settings})
      '';
    }

    (lib.mkIf cfg.neotest.enable (lib.mkMerge [
      {
        plugins.neotest = {
          settings.run.__raw = ''require("poly-direnv.neotest").run()'';
          luaConfig.post = ''require("poly-direnv.neotest").wrap_all()'';
        };
      }

      (lib.mkIf neotestPythonEnabled {
        plugins.neotest.adapters.python.settings = {
          runner = lib.mkDefault "pytest";
          python = lib.mkDefault "python3";
        };
      })
    ]))
  ]);
}
