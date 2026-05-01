"""Private local repository rule for WAS-110 vendor blobs."""

def _sha256_size(repository_ctx, path):
    python = repository_ctx.which("python3")
    if python:
        result = repository_ctx.execute([
            str(python),
            "-c",
            "import hashlib, os, sys\np = sys.argv[1]\nh = hashlib.sha256()\nwith open(p, 'rb') as f:\n    for b in iter(lambda: f.read(1024 * 1024), b''):\n        h.update(b)\nprint('%s %d' % (h.hexdigest(), os.path.getsize(p)))\n",
            str(path),
        ])
    else:
        result = repository_ctx.execute([
            "sh",
            "-c",
            "set -e; f=$1; h=$(openssl dgst -sha256 -r \"$f\" 2>/dev/null | awk '{print $1}'); if [ -z \"$h\" ]; then h=$(shasum -a 256 \"$f\" | awk '{print $1}'); fi; s=$(wc -c < \"$f\" | tr -d ' '); printf '%s %s\\n' \"$h\" \"$s\"",
            "sha256-size",
            str(path),
        ])
    if result.return_code != 0:
        fail("failed to hash %s: %s" % (path, result.stderr))
    parts = result.stdout.strip().split(" ")
    if len(parts) != 2:
        fail("unexpected hash output for %s: %s" % (path, result.stdout))
    return struct(sha256 = parts[0], size_bytes = int(parts[1]))

def _expect_pin(label, pin):
    expected = pin.get("sha256", "TBD")
    if expected == "TBD" or expected == None:
        fail("%s pin is missing/TBD in pins manifest" % label)
    return struct(
        sha256 = expected,
        size_bytes = pin.get("size_bytes"),
    )

def _verify_pin(repository_ctx, label, path, pin):
    expected = _expect_pin(label, pin)
    actual = _sha256_size(repository_ctx, path)
    if actual.sha256 != expected.sha256:
        fail("%s sha256 mismatch: expected %s, got %s" % (label, expected.sha256, actual.sha256))
    if expected.size_bytes != None and actual.size_bytes != expected.size_bytes:
        fail("%s size mismatch: expected %s, got %s" % (label, expected.size_bytes, actual.size_bytes))

def _verify_pins(repository_ctx, paths, pins_path):
    pins = json.decode(repository_ctx.read(pins_path))
    inputs = pins["inputs"]
    basic_files = inputs["basic_image_dir"]["files"]
    _verify_pin(repository_ctx, "bfw_image", paths["bfw.img"], inputs["bfw_image"])
    _verify_pin(repository_ctx, "basic/bootcore.bin", paths["basic/bootcore.bin"], basic_files["bootcore.bin"])
    _verify_pin(repository_ctx, "basic/kernel.bin", paths["basic/kernel.bin"], basic_files["kernel.bin"])
    _verify_pin(repository_ctx, "basic/rootfs.img", paths["basic/rootfs.img"], basic_files["rootfs.img"])

def _was110_vendor_blobs_repository_impl(repository_ctx):
    srcs = {
        "bfw.img": repository_ctx.attr.bfw_image,
        "basic/bootcore.bin": repository_ctx.attr.basic_bootcore,
        "basic/kernel.bin": repository_ctx.attr.basic_kernel,
        "basic/rootfs.img": repository_ctx.attr.basic_rootfs,
    }
    paths = {}

    for dest, src in srcs.items():
        if not src:
            fail("%s path is required" % dest)
        src_path = repository_ctx.path(src)
        if not src_path.exists:
            fail("%s does not exist: %s" % (dest, src))
        paths[dest] = src_path

    pins_path = None
    if repository_ctx.attr.pins_manifest:
        pins_path = repository_ctx.path(repository_ctx.attr.pins_manifest)
        if not pins_path.exists:
            fail("pins manifest does not exist: %s" % repository_ctx.attr.pins_manifest)
        if repository_ctx.attr.verify_pins:
            _verify_pins(repository_ctx, paths, pins_path)

    for dest, src_path in paths.items():
        repository_ctx.symlink(src_path, dest)

    exports = ["bfw.img"]
    visibility = repr(repository_ctx.attr.target_visibility)
    kernel_bundle_target = ""
    pins_target = ""
    if pins_path:
        repository_ctx.symlink(pins_path, "pins.inputs.json")
        exports.append("pins.inputs.json")
        pins_target = 'filegroup(name = "pins_inputs", srcs = ["pins.inputs.json"], visibility = %s)\n' % visibility

    if repository_ctx.attr.kernel_bundle_tar:
        src_path = repository_ctx.path(repository_ctx.attr.kernel_bundle_tar)
        if not src_path.exists:
            fail("kernel-bundle.tar does not exist: %s" % repository_ctx.attr.kernel_bundle_tar)
        repository_ctx.symlink(src_path, "kernel-bundle.tar")
        exports.append("kernel-bundle.tar")
        kernel_bundle_target = 'filegroup(name = "kernel_bundle_tar", srcs = ["kernel-bundle.tar"], visibility = %s)\n' % visibility

    repository_ctx.file(
        "BUILD.bazel",
        """\
package(default_visibility = ["//visibility:private"])

exports_files(%s, visibility = %s)

filegroup(name = "basic_bootcore", srcs = ["basic/bootcore.bin"], visibility = %s)
filegroup(name = "basic_kernel", srcs = ["basic/kernel.bin"], visibility = %s)
filegroup(name = "basic_rootfs", srcs = ["basic/rootfs.img"], visibility = %s)
%s%s""" % (repr(exports), visibility, visibility, visibility, visibility, pins_target, kernel_bundle_target),
    )

was110_vendor_blobs_repository = repository_rule(
    implementation = _was110_vendor_blobs_repository_impl,
    attrs = {
        "bfw_image": attr.string(mandatory = True),
        "basic_bootcore": attr.string(mandatory = True),
        "basic_kernel": attr.string(mandatory = True),
        "basic_rootfs": attr.string(mandatory = True),
        "kernel_bundle_tar": attr.string(),
        "pins_manifest": attr.string(),
        "target_visibility": attr.string_list(default = ["@//:__pkg__"]),
        "verify_pins": attr.bool(default = True),
    },
    local = True,
    doc = "Creates a private local repository exposing reviewed WAS-110 vendor blobs and an optional pins snapshot as Bazel labels.",
)
