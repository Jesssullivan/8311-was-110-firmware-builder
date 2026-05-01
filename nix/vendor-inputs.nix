{ pkgs
, lib ? pkgs.lib
, pinsPath ? ../pins/inputs.json
, root ? ./..
}:

let
  pins = builtins.fromJSON (builtins.readFile pinsPath);

  ubootBlob = name: _pin:
    let
      expected = pins.inputs.uboot_blobs.files.${name}.sha256;
      path = root + "/whole_image/${name}";
      actual = builtins.hashFile "sha256" path;
    in
    assert expected == "TBD" || actual == expected;
    {
      inherit name path expected actual;
      pinned = expected != "TBD";
    };

  privateInput = name: pin: {
    inherit name pin;
    pinned = (pin.sha256 or "TBD") != "TBD";
    fetchable = (pin.source_url or "TBD") != "TBD";
  };
in
{
  inherit pins;

  bfwImage = privateInput "bfw_image" pins.inputs.bfw_image;
  basicImageDir = pins.inputs.basic_image_dir;
  ubootBlobs = lib.mapAttrs ubootBlob pins.inputs.uboot_blobs.files;
}
