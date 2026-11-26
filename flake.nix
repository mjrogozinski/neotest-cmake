{
  description = "neotest-cmake development tools and integration-test dependencies";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
    in {
      devShells = nixpkgs.lib.genAttrs systems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          dependencies = pkgs.linkFarm "neotest-cmake-dependencies" [
            { name = "neotest"; path = pkgs.vimPlugins.neotest; }
            { name = "nvim-nio"; path = pkgs.vimPlugins.nvim-nio; }
            { name = "plenary.nvim"; path = pkgs.vimPlugins.plenary-nvim; }
            { name = "overseer.nvim"; path = pkgs.vimPlugins.overseer-nvim; }
          ];
          parser = pkgs.symlinkJoin {
            name = "neotest-cmake-cpp-parser";
            paths = (pkgs.vimPlugins.nvim-treesitter.withPlugins (grammars: [ grammars.cpp ])).dependencies;
          };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              neovim stylua lua-language-server lua51Packages.luacheck
              pandoc git gnumake cmake ninja pkg-config
            ];
            buildInputs = [ pkgs.gtest ];
            NEOTEST_DEPS = "${dependencies}";
            CPP_PARSER_DIR = "${parser}";
            NEOTEST_REQUIRE_OVERSEER = "1";
          };
        });
    };
}
