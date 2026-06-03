# Nixvim module for poly-direnv.nvim
#
# Usage in a nixvim config:
#
#   # In your flake inputs:
#   poly-direnv = {
#     url = "github:<owner>/poly-direnv.nvim";
#     flake = false;
#   };
#
#   # In your nixvim plugin file:
#   { pkgs, inputs, ... }:
#   let
#     poly-direnv-nvim = pkgs.vimUtils.buildVimPlugin {
#       pname = "poly-direnv-nvim";
#       version = "0.1.0";
#       src = inputs.poly-direnv;
#     };
#   in {
#     imports = [ "${inputs.poly-direnv}/nix/nixvim.nix" ];
#     programs.nixvim.plugins.poly-direnv = {
#       enable = true;
#       package = poly-direnv-nvim;
#       settings = {
#         cache_ttl = 30000;
#         autoload = true;
#       };
#     };
#   }
{
  lib,
  config,
  ...
}: let
  cfg = config.programs.nixvim.plugins.poly-direnv;
in {
  options.programs.nixvim.plugins.poly-direnv = {
    enable = lib.mkEnableOption "poly-direnv.nvim -- per-directory direnv environments for LSP servers";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The poly-direnv.nvim plugin package.";
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        options = {
          cache_ttl = lib.mkOption {
            type = lib.types.int;
            default = 30000;
            description = "Cache TTL in milliseconds for direnv export results.";
          };

          bin = lib.mkOption {
            type = lib.types.str;
            default = "direnv";
            description = "Path to the direnv binary.";
          };

          autoload = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Automatically inject direnv env on LSP start.";
          };

          notifications = lib.mkOption {
            type = lib.types.submodule {
              options = {
                on_load = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Notify when a direnv environment is loaded.";
                };
                on_envrc_change = lib.mkOption {
                  type = lib.types.bool;
                  default = true;
                  description = "Notify when an .envrc file is saved.";
                };
              };
            };
            default = {};
            description = "Notification settings.";
          };
        };
      };
      default = {};
      description = "Plugin settings passed to require('poly-direnv').setup().";
    };
  };

  config = lib.mkIf cfg.enable {
    programs.nixvim = {
      extraPlugins = [cfg.package];

      extraConfigLuaPre = let
        luaSettings = builtins.toJSON {
          inherit (cfg.settings) cache_ttl bin autoload;
          notifications = {
            inherit (cfg.settings.notifications) on_load on_envrc_change;
          };
        };
      in ''
        require("poly-direnv").setup(vim.json.decode([[${luaSettings}]]))
      '';
    };
  };
}
