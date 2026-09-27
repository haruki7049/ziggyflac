{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-compat.url = "github:edolstra/flake-compat";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      imports = [
        inputs.treefmt-nix.flakeModule
      ];

      perSystem =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          buildInputs = [ ];

          nativeBuildInputs = [
            # Compiler
            pkgs.zig_0_16
            pkgs.pkg-config

            # LSP
            pkgs.nil
            pkgs.zls

            # Music Player
            pkgs.sox # Use this command as: `play result.wav`
          ];

          ziggyflac = pkgs.stdenv.mkDerivation {
            name = "ziggyflac";
            src = lib.cleanSource ./.;
            doCheck = true;

            inherit nativeBuildInputs buildInputs;

            postConfigure = ''
              # Remove NIX_CFLAGS_COMPILE because zig cannot understand it
              unset NIX_CFLAGS_COMPILE
            '';
          };
        in
        {
          treefmt = {
            projectRootFile = ".git/config";

            # Nix
            programs.nixfmt.enable = true;

            # Zig
            programs.zig.enable = true;
            settings.formatter.zig.command = lib.getExe pkgs.zig_0_16;

            # GitHub Actions
            programs.actionlint.enable = true;

            # Markdown
            programs.mdformat.enable = true;

            # Shell Scripts
            programs.shellcheck.enable = true;
            programs.shfmt.enable = true;
          };

          packages = {
            inherit ziggyflac;
            default = ziggyflac;
          };

          checks = {
            inherit ziggyflac;
          };

          devShells.default = pkgs.mkShell {
            inherit nativeBuildInputs buildInputs;

            inputsFrom = [
              config.treefmt.build.devShell
            ];

            shellHook = ''
              # Remove NIX_CFLAGS_COMPILE because zig cannot understand it
              unset NIX_CFLAGS_COMPILE
            '';
          };
        };
    };
}
