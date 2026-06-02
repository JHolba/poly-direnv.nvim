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
