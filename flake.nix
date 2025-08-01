{
  inputs = {
    nixpkgs = {
      url = "github:nixos/nixpkgs/nixos-25.05";
    };
    nixpkgs-unstable = {
      url = "github:nixos/nixpkgs/nixos-unstable";
    };
    flake-utils.url = "github:numtide/flake-utils";
    fenix = {
      url = "github:nix-community/fenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flakebox = {
      url = "github:dpc/flakebox?rev=f96cbeafded56bc6f5c27fbd96e4fcc78b8a8861";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.fenix.follows = "fenix";
    };
    cargo-deluxe = {
      url = "github:rustshop/cargo-deluxe?rev=4acc6488d02f032434a5a1341f21f20d328bba40";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    bundlers = {
      url = "github:NixOS/bundlers?rev=ea1e72ad1dbb0864fd55b3ba52ed166cd190afa2";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      flake-utils,
      flakebox,
      cargo-deluxe,
      advisory-db,
      bundlers,
      ...
    }:
    let
      # overlay combining all overlays we use
      overlayAll = nixpkgs.lib.composeManyExtensions [
        (import ./nix/overlays/wasm-bindgen.nix)
        (import ./nix/overlays/cargo-nextest.nix)
        (import ./nix/overlays/esplora-electrs.nix)
        (import ./nix/overlays/darwin-compile-fixes.nix)
        (import ./nix/overlays/cargo-honggfuzz.nix)
        (import ./nix/overlays/trustedcoin.nix)
      ];
    in
    {
      overlays = {
        all = overlayAll;
        wasm-bindgen = import ./nix/overlays/wasm-bindgen.nix;
        darwin-compile-fixes = import ./nix/overlays/darwin-compile-fixes.nix;
        cargo-honggfuzz = import ./nix/overlays/cargo-honggfuzz.nix;
      };

      bundlers = bundlers.bundlers;

      nixosModules = {
        # Note: since it conflicts with the module in nixpkgs, you're going
        # to need to disable the upstream one with:
        #
        # disabledModules = [ "services/networking/fedimintd.nix" ];
        fedimintd = import ./nix/modules/fedimintd.nix;
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs-unstable = nixpkgs-unstable.legacyPackages.${system};
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            overlayAll

            (final: prev: {
              cargo-deluxe = cargo-deluxe.packages.${system}.default;
              cargo-udeps = nixpkgs-unstable.legacyPackages.${system}.cargo-udeps;
            })
          ];
        };

        lib = pkgs.lib;

        stdenv = pkgs.stdenv;

        flakeboxLib = flakebox.lib.${system} {
          # customizations will go here in the future
          config = {
            direnv.enable = false;
            github.ci = {
              workflows.flakebox-flakehub-publish.enable = false;
            };

            toolchain.components = [
              "rustc"
              "cargo"
              "clippy"
              "rust-analyzer"
              "rust-src"
              "llvm-tools"
            ];

            just.rules.clippy = {
              content = lib.mkForce ''
                # run `cargo clippy` on everything
                clippy *ARGS="--locked --offline --workspace --all-targets -- -D warnings":
                  cargo clippy {{ARGS}}

                # run `cargo clippy --fix` on everything
                clippy-fix *ARGS="--locked --offline --workspace --all-targets":
                  cargo clippy {{ARGS}} --fix
              '';
            };

            motd = {
              enable = true;
              command = ''
                >&2 echo "🚧 In an enfort to improve documentation, we now require all structs and"
                >&2 echo "🚧 and public methods to be documented with a docstring."
                >&2 echo "🚧 See https://github.com/fedimint/fedimint/issues/3807"
              '';
            };
            # we have our own weird CI workflows
            github.ci.enable = false;
            just.importPaths = [ "justfile.fedimint.just" ];
            # we have a custom final check
            just.rules.final-check.enable = false;
            git.pre-commit.trailing_newline = false;
            git.pre-commit.hooks = {
              check_forbidden_dependencies = builtins.readFile ./nix/check-forbidden-deps.sh;
            };
            git.pre-commit.hooks = {
              cargo-sort = builtins.readFile ./nix/check-cargo-sort.sh;
            };
          };
        };

        toolchainArgs = lib.optionalAttrs stdenv.isLinux {
          # TODO: we seem to be hitting some miscompilation(?) with
          # the new (as of nixos-24.11 default: clang 18), which causes
          # fedimint-cli segfault randomly, but only in Nix sandbox.
          # Supper weird.
          stdenv = pkgs.clang14Stdenv;
          clang = pkgs.llvmPackages_14.clang;
          libclang = pkgs.llvmPackages_14.libclang.lib;
          clang-unwrapped = pkgs.llvmPackages_14.clang-unwrapped;
        };

        stdTargets = flakeboxLib.mkStdTargets { };
        stdToolchains = flakeboxLib.mkStdToolchains toolchainArgs;

        # toolchains for the native build (default shell)
        toolchainNative = flakeboxLib.mkFenixToolchain (
          toolchainArgs
          // {
            targets = (
              pkgs.lib.getAttrs [
                "default"
                "wasm32-unknown"
              ] stdTargets
            );
          }
        );

        # toolchains for the native + wasm build
        toolchainWasm = flakeboxLib.mkFenixToolchain (
          toolchainArgs
          // {
            defaultTarget = "wasm32-unknown-unknown";
            targets = (
              pkgs.lib.getAttrs [
                "default"
                "wasm32-unknown"
              ] stdTargets
            );

            args = {
              nativeBuildInputs = [
                pkgs.wasm-bindgen-cli
                pkgs.geckodriver
                pkgs.wasm-pack
              ]
              ++ lib.optionals (stdenv.isLinux) [ pkgs.firefox ];
            };
          }
        );

        # toolchains for the native + wasm build
        toolchainAll = flakeboxLib.mkFenixToolchain (
          toolchainArgs
          // {
            targets = (
              pkgs.lib.getAttrs (
                [
                  "default"
                  "aarch64-android"
                  "x86_64-android"
                  "arm-android"
                  "armv7-android"
                  "wasm32-unknown"
                ]
                ++ lib.optionals pkgs.stdenv.isDarwin [
                  "aarch64-ios"
                  "aarch64-ios-sim"
                  "x86_64-ios"
                ]
              ) stdTargets
            );
          }
        );
        # Replace placeholder git hash in a binary
        #
        # To avoid impurity, we use a git hash placeholder when building binaries
        # and then replace them with the real git hash in the binaries themselves.
        replaceGitHash =
          let
            # the hash we will set if the tree is dirty;
            dirtyHashPrefix = builtins.substring 0 16 self.dirtyRev;
            dirtyHashSuffix = builtins.substring (40 - 16) 16 self.dirtyRev;
            # the string needs to be 40 characters, like the original,
            # so to denote `-dirty` we replace the middle with zeros
            dirtyHash = "${dirtyHashPrefix}00000000${dirtyHashSuffix}";
          in
          {
            package,
            name,
            placeholder,
            gitHash ? if (self ? rev) then self.rev else dirtyHash,
          }:
          stdenv.mkDerivation {
            inherit system;
            inherit name;

            # some bundlers want `pname` here, instead of `name`
            pname = name;

            dontUnpack = true;
            dontStrip = !pkgs.stdenv.isDarwin;

            installPhase = ''
              cp -a ${package} $out
              for path in `find $out -type f -executable`; do
                # need to use a temporary file not to overwrite source as we are reading it
                bbe -e 's/${placeholder}/${gitHash}/' $path -o ./tmp || exit 1
                chmod +w $path
                # use cat to keep all the original permissions etc as they were
                cat ./tmp > "$path"
                chmod -w $path
              done
            '';

            buildInputs = [ pkgs.bbe ];
          };

        craneMultiBuild = import nix/flakebox.nix {
          inherit
            pkgs
            flakeboxLib
            advisory-db
            replaceGitHash
            ;

          # Yes, you're seeing right. We're passing result of this call as an argument
          # to it.
          inherit craneMultiBuild;

          toolchains = stdToolchains // {
            "wasm32-unknown" = toolchainWasm;
          };
          profiles = [
            "dev"
            "ci"
            "test"
            "release"
          ];
        };

        devShells =

          let
            commonShellArgs =
              craneMultiBuild.commonEnvsShell
              // craneMultiBuild.commonArgs
              // {
                toolchain = toolchainNative;
                buildInputs = craneMultiBuild.commonArgs.buildInputs;
                nativeBuildInputs =
                  craneMultiBuild.commonArgs.nativeBuildInputs
                  ++ [
                    pkgs.cargo-udeps
                    pkgs.cargo-audit
                    pkgs.cargo-deny
                    pkgs.cargo-sort
                    pkgs.parallel
                    pkgs.nixfmt-rfc-style
                    pkgs.just
                    pkgs.time
                    pkgs.gawk
                    pkgs.taplo

                    (pkgs.writeShellScriptBin "git-recommit" "exec git commit --edit -F <(cat \"$(git rev-parse --git-path COMMIT_EDITMSG)\" | grep -v -E '^#.*') \"$@\"")

                    # This is required to prevent a mangled bash shell in nix develop
                    # see: https://discourse.nixos.org/t/interactive-bash-with-nix-develop-flake/15486
                    (pkgs.hiPrio pkgs.bashInteractive)
                    pkgs.mprocs
                    pkgs.docker-compose
                    pkgs.tokio-console
                    pkgs.git

                    # Nix
                    pkgs.nixfmt-rfc-style
                    pkgs.shellcheck
                    pkgs.nil
                    pkgs.convco
                    pkgs.nodePackages.bash-language-server
                  ]
                  ++ lib.optionals (!stdenv.isAarch64 && !stdenv.isDarwin) [ pkgs.semgrep ]
                  ++ lib.optionals (!stdenv.isDarwin) [
                    # broken on MacOS?
                    pkgs.cargo-workspaces

                    # marked as broken on MacOS
                    pkgs.cargo-llvm-cov
                  ];

                shellHook = ''
                  export REPO_ROOT="$(git rev-parse --show-toplevel)"
                  export PATH="$REPO_ROOT/bin:$PATH"

                  # workaround https://github.com/rust-lang/cargo/issues/11020
                  cargo_cmd_bins=( $(ls $HOME/.cargo/bin/cargo-{clippy,udeps,llvm-cov} 2>/dev/null) )
                  if (( ''${#cargo_cmd_bins[@]} != 0 )); then
                    >&2 echo "⚠️  Detected binaries that might conflict with reproducible environment: ''${cargo_cmd_bins[@]}" 1>&2
                    >&2 echo "   Considering deleting them. See https://github.com/rust-lang/cargo/issues/11020 for details" 1>&2
                  fi

                  export CARGO_BUILD_TARGET_DIR="''${CARGO_BUILD_TARGET_DIR:-''${REPO_ROOT}/target-nix}"
                  export FM_DISCOVER_API_VERSION_TIMEOUT=10

                  export FLAKEBOX_GIT_LS_IGNORE=fedimint-server-ui/assets/
                  export FLAKEBOX_GIT_LS_TEXT_IGNORE=fedimint-server-ui/assets/
                  [ -f "$REPO_ROOT/.shrc.local" ] && source "$REPO_ROOT/.shrc.local"

                  if [ ''${#TMPDIR} -ge 40 ]; then
                      >&2 echo "⚠️  TMPDIR too long. This might lead to problems running tests and regtest fed. Will try to use /tmp/ instead"
                      # Note: this seems to work fine in `nix develop`, but doesn't work on some `direnv` implementations (doesn't work for dpc at least)
                      export TMPDIR="/tmp"
                  fi

                  if [ "$(ulimit -Sn)" -lt "1024" ]; then
                      >&2 echo "⚠️  ulimit too small. Run 'ulimit -Sn 1024' to avoid problems running tests"
                  fi

                  if [ -z "$(git config --global merge.ours.driver)" ]; then
                      >&2 echo "⚠️  Recommended to run 'git config --global merge.ours.driver true' to enable better lock file handling. See https://blog.aspect.dev/easier-merges-on-lockfiles for more info"
                  fi
                '';
              };
          in
          {
            # The default shell - meant to developers working on the project,
            # so notably not building any project binaries, but including all
            # the settings and tools necessary to build and work with the codebase.
            default = flakeboxLib.mkDevShell (commonShellArgs // { });

            fuzz = flakeboxLib.mkDevShell (
              commonShellArgs
              // {
                nativeBuildInputs =
                  with pkgs;
                  commonShellArgs.nativeBuildInputs
                  ++ [
                    cargo-hongfuzz
                    libbfd_2_38
                    libunwind.dev
                    libopcodes_2_38
                    pkgsStatic.libblocksruntime
                    lldb
                    clang
                  ];

              }
            );

            lint = flakeboxLib.mkLintShell {
              nativeBuildInputs = [
                pkgs.cargo-sort
                pkgs.taplo
              ];
              env = {
                FLAKEBOX_GIT_LS_IGNORE = "fedimint-server-ui/assets/";
                FLAKEBOX_GIT_LS_TEXT_IGNORE = "fedimint-server-ui/assets/";
              };
            };

            linkcheck = flakeboxLib.mkDevShell {
              nativeBuildInputs = [ nixpkgs-unstable.legacyPackages.${system}.lychee ];
            };

            # Like `cross` but only with wasm
            crossWasm = flakeboxLib.mkDevShell (
              commonShellArgs
              // {
                toolchain = toolchainWasm;

                nativeBuildInputs =
                  commonShellArgs.nativeBuildInputs or [ ]
                  ++ [
                    pkgs.wasm-pack
                    pkgs.wasm-bindgen-cli
                    pkgs.geckodriver
                  ]
                  ++ lib.optionals (stdenv.isLinux) [ pkgs.firefox ];
              }
            );

            replit = pkgs.mkShell {
              nativeBuildInputs = with pkgs; [
                pkg-config
                openssl
              ];
            };

            bootstrap = pkgs.mkShell { nativeBuildInputs = with pkgs; [ cachix ]; };
          }
          //
            lib.attrsets.optionalAttrs
              (lib.lists.elem system [
                "x86_64-linux"
                "x86_64-darwin"
                "aarch64-darwin"
              ])
              {
                # Shell with extra stuff to support cross-compilation with `cargo build --target <target>`
                #
                # This will pull extra stuff so to save time and download time to most common developers,
                # was moved into another shell.
                cross = flakeboxLib.mkDevShell (
                  commonShellArgs
                  // craneMultiBuild.commonEnvsCrossShell
                  // {
                    toolchain = toolchainAll;
                    shellHook = ''
                      export REPO_ROOT="$(git rev-parse --show-toplevel)"
                      export PATH="$REPO_ROOT/bin:$PATH"
                    '';
                  }
                );
              };
      in
      {
        inherit devShells;

        # Technically nested sets are not allowed in `packages`, so we can
        # dump the nested things here. They'll work the same way for most
        # purposes (like `nix build`).
        legacyPackages = craneMultiBuild;

        packages = {
          inherit (craneMultiBuild)
            gatewayd
            fedimint-dbtool
            gateway-cli
            fedimint-cli
            fedimintd
            fedimint-load-test-tool
            fedimint-recurringd
            ;
          inherit (craneMultiBuild)
            client-pkgs
            gateway-pkgs
            fedimint-pkgs
            devimint
            ;

          wasmBundle = craneMultiBuild.wasm32-unknown.release.wasmBundle;
        };

        lib = {
          inherit replaceGitHash devShells;
        };
      }
    );

  nixConfig = {
    extra-substituters = [ "https://fedimint.cachix.org" ];
    extra-trusted-public-keys = [
      "fedimint.cachix.org-1:FpJJjy1iPVlvyv4OMiN5y9+/arFLPcnZhZVVCHCDYTs="
    ];
  };
}
