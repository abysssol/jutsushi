{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    utils.url = "github:numtide/flake-utils";

    rust.url = "github:oxalica/rust-overlay";
    rust.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "utils";
    };

    crane.url = "github:ipetkov/crane";
    crane.inputs.nixpkgs.follows = "nixpkgs";

    advisory-db.url = "github:rustsec/advisory-db";
    advisory-db.flake = false;
  };

  outputs = { self, nixpkgs, utils, rust, crane, advisory-db, ... }:
    utils.lib.eachSystem [
      "aarch64-darwin"
      "aarch64-linux"
      #"armv5tel-linux" # error: missing bootstrap url for platform armv5te-unknown-linux-gnueabi
      "armv6l-linux"
      "armv7a-linux"
      "armv7l-linux"
      "i686-linux"
      #"mipsel-linux" # error: attribute 'busybox' missing
      "powerpc64le-linux"
      "riscv64-linux"
      "x86_64-darwin"
      "x86_64-linux"
    ] (system:
      let
        pkgs = import nixpkgs { inherit system; };

        toolchain = rust.packages.${system}.rust;
        craneLib = (crane.mkLib pkgs).overrideToolchain toolchain;
        src = craneLib.cleanCargoSource ./.;

        nativeBuildInputs = [ pkgs.pkg-config ];
        buildInputs = with pkgs; [
          udev
          alsa-lib
          vulkan-loader

          # x11
          xorg.libX11
          xorg.libXcursor
          xorg.libXi
          xorg.libXrandr

          # wayland
          libxkbcommon
          wayland
        ];

        common = {
          inherit src nativeBuildInputs buildInputs;
        };
        commonArtifacts = common // {
          cargoArtifacts = craneLib.buildDepsOnly common;
        };

        pname = (craneLib.crateNameFromCargoToml { inherit src; }).pname;
        package = craneLib.buildPackage (commonArtifacts // {
          doCheck = false;

          # debug build with symbols
          cargoBuildCommand = "cargo build";

          postInstall = ''
            # copy assets directory
            cp -r "${./assets}" "$out"/assets
            chmod +w "$out"/assets
            ln -s ../assets "$out"/bin/assets
            # required for bevy apps to dynamically link to vulkan
            patchelf --add-needed libvulkan.so.1 "$out"/bin/${pname}
            patchelf --add-rpath ${pkgs.vulkan-loader}/lib "$out"/bin/${pname}
          '';
        });
      in {
        checks = {
          inherit package;
          cargo-clippy = craneLib.cargoClippy (commonArtifacts // {
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });
          cargo-doc = craneLib.cargoDoc commonArtifacts;
          cargo-fmt = craneLib.cargoFmt { inherit src; };
          cargo-audit = craneLib.cargoAudit { inherit src advisory-db; };
          cargo-nextest = craneLib.cargoNextest commonArtifacts;
        };

        packages.default = package;

        apps.default = utils.lib.mkApp { drv = package; };

        devShells.default = pkgs.mkShell {
          inputsFrom = builtins.attrValues self.checks.${system};
          shellInputs = buildInputs;
          nativeBuildInputs = [ toolchain ] ++ nativeBuildInputs;
          LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath buildInputs}";
        };
      });
}
