{
  description = "multi-lsp-direnv.nvim -- per-directory direnv environments for Neovim LSP servers";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAllSystems (pkgs: {
      default = pkgs.vimUtils.buildVimPlugin {
        pname = "multi-lsp-direnv-nvim";
        version = "0.1.0";
        src = self;
      };
    });

    checks = forAllSystems (pkgs: {
      lua-format = pkgs.runCommand "check-lua-format" {} ''
        ${pkgs.stylua}/bin/stylua --check ${self}/lua
        touch $out
      '';
      lua-lint = pkgs.runCommand "check-lua-lint" {} ''
        cd ${self} && ${pkgs.selene}/bin/selene --allow-warnings lua/
        touch $out
      '';
      nix-format = pkgs.runCommand "check-nix-format" {} ''
        ${pkgs.alejandra}/bin/alejandra --check ${self}
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
