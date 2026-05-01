{
  description = "8311 WAS-110 firmware builder - reproducible dev shells + audit tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;
        auditPackages = with pkgs; [
          bash
          coreutils
          curl
          findutils
          gnused
          gawk
          gnugrep
          gnutar
          jq
          p7zip
          xz
          gzip
          lz4
          file
          shellcheck
          cosign
          bazelisk
          buildifier
          git
        ];
        linuxBuildPackages = with pkgs; auditPackages ++ [
          gnutar
          fakeroot
          squashfsTools
          mtdutils
          ubootTools
          (perl.withPackages (ps: [ ps.DigestCRC ]))
          python3
          pcre
          p7zip
          binwalk
        ];
        vendorInputs = import ./nix/vendor-inputs.nix {
          inherit pkgs lib;
          root = ./.;
        };
        repoSrc = lib.cleanSourceWith {
          src = ./.;
          filter = path: type:
            let
              rel = lib.removePrefix "${toString ./.}/" (toString path);
              base = baseNameOf path;
            in
              !(lib.hasPrefix "vendor-blobs/" rel
                || lib.hasPrefix ".direnv/" rel
                || base == ".git");
        };
        sourceRev = self.rev or self.dirtyRev or "unknown";
        sourceRevShort = builtins.substring 0 12 sourceRev;
        sourceDirty = !(self ? rev);
        sourceLastModified = self.lastModified or 0;
        publicCommunityRelease = import ./nix/public-community-release.nix {
          inherit pkgs lib sourceLastModified sourceDirty;
          src = repoSrc;
          sourceRev =
            if sourceRev == "unknown"
            then "path-${builtins.substring 0 12 (builtins.baseNameOf (toString repoSrc))}"
            else sourceRev;
          sourceRevShort =
            if sourceRev == "unknown"
            then "path-${builtins.substring 0 12 (builtins.baseNameOf (toString repoSrc))}"
            else sourceRevShort;
          allowDirtyPolicy = sourceDirty;
        };
        knownGoodKernelBundle = import ./nix/known-good-kernel-bundle.nix {
          inherit pkgs lib;
          src = repoSrc;
          inherit publicCommunityRelease;
        };
        publicCommunityKernelBundleHandoffProof = import ./nix/public-community-release.nix {
          inherit pkgs lib sourceLastModified sourceDirty;
          src = repoSrc;
          sourceRev =
            if sourceRev == "unknown"
            then "path-${builtins.substring 0 12 (builtins.baseNameOf (toString repoSrc))}"
            else sourceRev;
          sourceRevShort =
            if sourceRev == "unknown"
            then "path-${builtins.substring 0 12 (builtins.baseNameOf (toString repoSrc))}"
            else sourceRevShort;
          sourceDiffHash = "";
          allowDirtyPolicy = true;
          kernelBundle = knownGoodKernelBundle;
          releaseBuild = false;
          extraVersionSuffix = "-kernel-bundle-proof";
        };
      in
      {
        packages = lib.optionalAttrs pkgs.stdenv.isLinux {
          inherit
            knownGoodKernelBundle
            publicCommunityKernelBundleHandoffProof
            publicCommunityRelease
            ;
          default = publicCommunityRelease;
        };

        devShells = {
          default = pkgs.mkShell {
            name = "was110-audit";
            packages = auditPackages;
            shellHook = ''
              echo "8311 WAS-110 audit shell"
              echo "  verify pins: ./pins/verify.sh [--strict] <bfw.img> <basic-dir>"
              echo "  import blobs: ./pins/import-vendor-blobs.sh <bfw.img> <basic-dir> <private-repo>"
              echo "  verify blobs: ./pins/verify-vendor-repo.sh <private-repo>"
              echo "  public build: nix build .#publicCommunityRelease  # Linux / remote builder"
              echo "  pack kernel: ./audit/pack-kernel-bundle.sh <kernel-bundle-dir> <out.tar>"
              echo "  verify unit: ./audit/verify-device.sh <ip> root out/manifest.json"
            '';
          };
        } // lib.optionalAttrs pkgs.stdenv.isLinux {
          linux-build = pkgs.mkShell {
            name = "was110-linux-build";
            packages = linuxBuildPackages;
            shellHook = ''
              echo "8311 WAS-110 Linux build shell"
              echo "  build: ./pins/verify.sh --strict ... && ./build.sh ... && ./audit/release-pack.sh out"
            '';
          };
        };

        checks = {
          devshell-eval = self.devShells.${system}.default;
          script-syntax = pkgs.runCommand "was110-script-syntax"
            {
              nativeBuildInputs = [ pkgs.bash ];
              src = ./.;
            } ''
            cd "$src"
            bash -n build.sh create.sh wholeImage.sh bazel/*.sh mods/*.sh audit/*.sh pins/*.sh tests/*.sh
            sh -n extract.sh
            touch "$out"
          '';
          audit-tools = pkgs.runCommand "was110-audit-tools"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                findutils
                gawk
                gnugrep
                gnused
                gnutar
                jq
                p7zip
              ];
              src = ./.;
            } ''
            cp -R "$src" source
            chmod -R u+w source
            patchShebangs source/audit source/pins source/tests
            cd source
            ./tests/test-audit-tools.sh
            ./tests/test-public-input-mirror.sh
            ./tests/test-source-stack-candidates.sh
            touch "$out"
          '';
          bazel-bridge-text = pkgs.runCommand "was110-bazel-bridge-text"
            {
              nativeBuildInputs = with pkgs; [
                bash
                gnugrep
                jq
              ];
              src = ./.;
            } ''
            cp -R "$src" source
            chmod -R u+w source
            patchShebangs source/tests
            cd source
            ./tests/test-bazel-bridge.sh
            touch "$out"
          '';
          bazel-format = pkgs.runCommand "was110-bazel-format"
            {
              nativeBuildInputs = [ pkgs.buildifier ];
              src = ./.;
            } ''
            cd "$src"
            buildifier -mode=check BUILD.bazel MODULE.bazel bazel/BUILD.bazel bazel/*.bzl bazel/platforms/BUILD.bazel tests/bazel/BUILD.bazel
            touch "$out"
          '';
          vendor-input-pins = pkgs.runCommand "was110-vendor-input-pins"
            {
              nativeBuildInputs = with pkgs; [
                bash
                jq
              ];
            } ''
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList
              (name: blob: ''
                test "${blob.actual}" = "${blob.expected}"
                echo "ok ${name} ${blob.actual}"
              '')
              vendorInputs.ubootBlobs)}
            cp -R ${./.} source
            chmod -R u+w source
            patchShebangs source/pins
            cd source
            jq -e . pins/source-stack-candidates.json >/dev/null
            ./pins/verify-public-source-lock.sh
            touch "$out"
          '';
        } // lib.optionalAttrs pkgs.stdenv.isLinux {
          public-community-release-eval = publicCommunityRelease;
        };
      });
}
