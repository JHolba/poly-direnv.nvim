{
  description = "multi-lsp-direnv.nvim -- per-directory direnv environments for Neovim LSP servers";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    treefmt-nix,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    treefmtEval = forAllSystems (pkgs:
      treefmt-nix.lib.evalModule pkgs {
        projectRootFile = "flake.nix";
        programs.alejandra.enable = true;
        programs.stylua.enable = true;
      });
  in {
    packages = forAllSystems (pkgs: {
      default = pkgs.vimUtils.buildVimPlugin {
        pname = "multi-lsp-direnv-nvim";
        version = "0.1.0";
        src = self;
      };
    });

    checks = forAllSystems (pkgs: {
      formatting = treefmtEval.${pkgs.system}.config.build.check self;
      lua-lint = pkgs.runCommand "check-lua-lint" {} ''
        cd ${self} && ${pkgs.selene}/bin/selene --allow-warnings lua/
        touch $out
      '';
      nix-lint = pkgs.runCommand "check-nix-lint" {} ''
        ${pkgs.statix}/bin/statix check ${self}
        touch $out
      '';
      nix-deadcode = pkgs.runCommand "check-nix-deadcode" {} ''
        ${pkgs.deadnix}/bin/deadnix --fail ${self}
        touch $out
      '';
    });

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = with pkgs; [
          stylua
          selene
          alejandra
          statix
          deadnix
        ];
      };
    });

    formatter = forAllSystems (pkgs: treefmtEval.${pkgs.system}.config.build.wrapper);

    overlays.default = final: _: {
      vimPlugins =
        (final.vimPlugins or {})
        // {
          multi-lsp-direnv-nvim = final.vimUtils.buildVimPlugin {
            pname = "multi-lsp-direnv-nvim";
            version = "0.1.0";
            src = self;
          };
        };
    };

    nixvimModule = import ./nix/nixvim.nix;
  };
}
