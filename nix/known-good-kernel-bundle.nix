{ pkgs
, lib ? pkgs.lib
, src
, publicCommunityRelease
}:

pkgs.stdenv.mkDerivation {
  pname = "was110-known-good-kernel-bundle";
  version = "public-community";

  inherit src;

  nativeBuildInputs = with pkgs; [
    bash
    coreutils
    findutils
    gnugrep
    gnutar
    jq
    squashfsTools
    ubootTools
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
        runHook preInstall

        cp -R "$src" source
        chmod -R u+w source
        patchShebangs source/audit

        mkdir -p "$out/kernel-bundle/lib" "$out/proof"
        unsquashfs -quiet -no-progress \
          -d "$TMPDIR/rootfs" \
          "${publicCommunityRelease}/rootfs.img" \
          lib/modules lib/firmware

        cp "${publicCommunityRelease}/kernel.bin" "$out/kernel-bundle/kernel.bin"
        cp -a "$TMPDIR/rootfs/lib/modules" "$out/kernel-bundle/lib/modules"
        cp -a "$TMPDIR/rootfs/lib/firmware" "$out/kernel-bundle/lib/firmware"

        source/audit/verify-kernel-bundle.sh "$out/kernel-bundle" \
          > "$out/proof/verify-kernel-bundle.txt"

        TAR=tar source/audit/pack-kernel-bundle.sh \
          "$out/kernel-bundle" \
          "$out/known-good-kernel-bundle.tar" \
          > "$out/proof/pack-kernel-bundle.txt"

        cat > "$out/README.md" <<'EOF'
    # WAS-110 known-good kernel bundle

    This bundle is derived from the pinned public community release output.
    It contains the vendor/community `kernel.bin`, matching `lib/modules`, and
    matching `lib/firmware` from the release rootfs.

    This is an evidence / integration bundle only. It does not contain
    `kernel-build.json` and must not be described as a source-built kernel.
    EOF

        (
          cd "$out"
          find . -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
        )

        runHook postInstall
  '';

  meta = {
    description = "Evidence-only WAS-110 kernel bundle derived from the pinned public community release";
    platforms = lib.platforms.linux;
  };
}
