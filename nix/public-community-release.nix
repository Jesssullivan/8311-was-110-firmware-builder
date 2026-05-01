{ pkgs
, lib ? pkgs.lib
, src
, sourceRev ? "unknown"
, sourceRevShort ? lib.substring 0 12 sourceRev
, sourceLastModified ? 0
, sourceDirty ? false
, sourceDiffHash ? ""
, allowDirtyPolicy ? false
, kernelBundle ? null
, releaseBuild ? true
, extraVersionSuffix ? ""
}:

let
  lock = builtins.fromJSON (builtins.readFile ../pins/public-source-lock.json);
  bfw = lock.sources.bfw_image;
  basic = lock.sources.basic_image_dir;
  bypassLock = lock.source_dependencies."8311-xgspon-bypass";

  bfwArchive = pkgs.fetchurl {
    url = bfw.asset_url;
    sha256 = bfw.asset_sha256;
  };

  basicArchive = pkgs.fetchurl {
    url = basic.asset_url;
    sha256 = basic.asset_sha256;
  };

  bypass = pkgs.fetchgit {
    url = bypassLock.url;
    rev = bypassLock.rev;
    hash = bypassLock.fetchgit_hash;
  };

  buildInputs = with pkgs; [
    bash
    coreutils
    findutils
    gnused
    gawk
    gnugrep
    gnutar
    gzip
    xz
    p7zip
    fakeroot
    squashfsTools
    mtdutils
    ubootTools
    (perl.withPackages (ps: [ ps.DigestCRC ]))
    pcre
    jq
    file
    python3
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "was110-public-community-release";
  version = "${lock.version_label}${extraVersionSuffix}";

  inherit src;
  nativeBuildInputs = buildInputs;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    cp -R "$src" source
    chmod -R u+w source
    rm -rf source/8311-xgspon-bypass
    cp -R "${bypass}" source/8311-xgspon-bypass
    chmod -R u+w source/8311-xgspon-bypass
    patchShebangs \
      source/build.sh \
      source/copy_packages.sh \
      source/create.sh \
      source/extract.sh \
      source/wholeImage.sh \
      source/audit \
      source/bazel \
      source/pins \
      source/tests \
      source/tools

    mkdir -p public-inputs/archives public-inputs/bfw public-inputs/basic
    cp "${bfwArchive}" public-inputs/archives/${bfw.asset_name}
    cp "${basicArchive}" public-inputs/archives/${basic.asset_name}

    7z e -y -opublic-inputs/bfw \
      public-inputs/archives/${bfw.asset_name} \
      "${bfw.extract.archive_path}" >/dev/null
    7z e -y -opublic-inputs/basic \
      public-inputs/archives/${basic.asset_name} \
      bootcore.bin kernel.bin rootfs.img >/dev/null

    cd source
    ./pins/verify.sh --strict \
      "$PWD/../public-inputs/bfw/local-upgrade.img" \
      "$PWD/../public-inputs/basic"

    export SUDO=
    export SOURCE_BUILD_SYSTEM=nix
    export SOURCE_GIT_REV="${sourceRev}"
    export SOURCE_GIT_REV_SHORT="${sourceRevShort}"
    export SOURCE_GIT_EPOCH="${toString sourceLastModified}"
    export SOURCE_GIT_DIRTY="${lib.boolToString sourceDirty}"
    export SOURCE_GIT_DIFF_HASH="${sourceDiffHash}"

    build_args=(
      --image "$PWD/../public-inputs/bfw/local-upgrade.img"
      --image-dir "$PWD/../public-inputs/basic"
      --out-dir "$out"
      --work-dir "$TMPDIR/was110-work"
    )
    ${lib.optionalString releaseBuild ''
      build_args=(--release "''${build_args[@]}")
    ''}
    ${lib.optionalString (kernelBundle != null) ''
      build_args+=("--kernel-bundle" "${kernelBundle}/kernel-bundle")
    ''}

    fakeroot -- ./build.sh "''${build_args[@]}"

    cp pins/public-source-lock.json "$out/public-source-lock.json"
    ./audit/release-pack.sh "$out"
    if [ "${lib.boolToString releaseBuild}" = true ]; then
      ./audit/verify-release-pack.sh "$out"
      policy_args=()
      if [ "${lib.boolToString allowDirtyPolicy}" = true ]; then
        policy_args+=(--allow-dirty)
      fi
      ./audit/verify-release-policy.sh "''${policy_args[@]}" "$out/manifest.json"
    else
      jq -e '
        .build_inputs.kernel.source == "external:kernel-bundle"
        and .build_inputs.kernel.build_provenance == null
        and .kernel.rebuilt_from_source == false
        and (.build_inputs.kernel.modules_tree_sha256 == .build_inputs.kernel.installed_modules_tree_sha256)
        and (.build_inputs.kernel.firmware_tree_sha256 == .build_inputs.kernel.installed_firmware_tree_sha256)
      ' "$out/manifest.json" >/dev/null
    fi

    runHook postInstall
  '';

  meta = {
    description = "WAS-110 public community baseline release pack built from pinned source lock inputs";
    platforms = lib.platforms.linux;
  };
}
