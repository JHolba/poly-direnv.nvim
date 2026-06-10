{
  description = "poly-direnv.nvim -- per-directory direnv environments for Neovim LSP servers";

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
        pname = "poly-direnv-nvim";
        version = "0.1.0";
        src = self;
      };
    });

    checks = forAllSystems (pkgs: {
      formatting = treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.check self;
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
      tests = let
        busted = pkgs.luajitPackages.busted;
        luaEnv = pkgs.luajit.withPackages (_: [busted]);
      in
        pkgs.runCommand "check-tests" {
          nativeBuildInputs = [pkgs.neovim-unwrapped pkgs.direnv];
          LUA_PATH = "${luaEnv}/share/lua/5.1/?.lua;${luaEnv}/share/lua/5.1/?/init.lua;;";
          LUA_CPATH = "${luaEnv}/lib/lua/5.1/?.so;;";
        } ''
          # vim.lsp.log needs a writable HOME for its log directory
          export HOME=$(mktemp -d)
          cd ${self}
          nvim --headless --clean -l tests/run.lua tests/ --output utfTerminal
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
          luajitPackages.busted
        ];
      };
    });

    formatter = forAllSystems (pkgs: treefmtEval.${pkgs.stdenv.hostPlatform.system}.config.build.wrapper);

    overlays.default = final: _: {
      vimPlugins =
        (final.vimPlugins or {})
        // {
          poly-direnv-nvim = final.vimUtils.buildVimPlugin {
            pname = "poly-direnv-nvim";
            version = "0.1.0";
            src = self;
          };
        };
    };

    nixosModules.nixvim = import ./nix/nixvim.nix;
  };
}
