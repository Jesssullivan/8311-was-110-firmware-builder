"""Bazel bridge for the WAS-110 firmware builder."""

def _manifest_line(f):
    return "%s\t%s" % (f.path, f.short_path)

def _was110_firmware_impl(ctx):
    out_dir = ctx.actions.declare_directory(ctx.attr.name + ".out")
    src_manifest = ctx.actions.declare_file(ctx.attr.name + ".srcs.tsv")

    builder_srcs = ctx.files.builder_srcs
    ctx.actions.write(
        output = src_manifest,
        content = "\n".join([_manifest_line(f) for f in builder_srcs]) + "\n",
    )

    inputs = (
        builder_srcs +
        [
            src_manifest,
            ctx.file._runner,
            ctx.info_file,
            ctx.version_file,
            ctx.file.bfw_image,
            ctx.file.basic_bootcore,
            ctx.file.basic_kernel,
            ctx.file.basic_rootfs,
        ]
    )

    kernel_bundle_tar = ""
    if ctx.file.kernel_bundle_tar:
        inputs.append(ctx.file.kernel_bundle_tar)
        kernel_bundle_tar = ctx.file.kernel_bundle_tar.path

    pins_manifest = ""
    if ctx.file.pins_manifest:
        inputs.append(ctx.file.pins_manifest)
        pins_manifest = ctx.file.pins_manifest.path

    args = ctx.actions.args()
    args.add(src_manifest.path)
    args.add(ctx.file.bfw_image.path)
    args.add(ctx.file.basic_bootcore.path)
    args.add(ctx.file.basic_kernel.path)
    args.add(ctx.file.basic_rootfs.path)
    args.add(kernel_bundle_tar)
    args.add(out_dir.path)
    args.add("1" if ctx.attr.release else "0")
    args.add(ctx.info_file.path)
    args.add(ctx.version_file.path)
    args.add(pins_manifest)

    ctx.actions.run_shell(
        inputs = depset(inputs),
        outputs = [out_dir],
        command = "bash %s \"$@\"" % ctx.file._runner.path,
        arguments = [args],
        mnemonic = "Was110Firmware",
        progress_message = "Building WAS-110 firmware %{label}",
        execution_requirements = ctx.attr.execution_requirements,
    )

    return [DefaultInfo(files = depset([out_dir]))]

was110_firmware = rule(
    implementation = _was110_firmware_impl,
    attrs = {
        "bfw_image": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Pinned stock BFW local-upgrade image.",
        ),
        "basic_bootcore": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Pinned basic firmware bootcore.bin.",
        ),
        "basic_kernel": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Pinned basic firmware kernel.bin.",
        ),
        "basic_rootfs": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "Pinned basic firmware rootfs.img.",
        ),
        "kernel_bundle_tar": attr.label(
            allow_single_file = True,
            doc = "Optional tar containing kernel.bin, lib/modules, optional lib/firmware, and release-required kernel-build.json.",
        ),
        "pins_manifest": attr.label(
            allow_single_file = True,
            doc = "Optional pins/inputs.json override. Use this for private Bazel blob repositories that carry a reviewed pins snapshot outside the public source tree.",
        ),
        "builder_srcs": attr.label(
            default = Label("//:was110_builder_srcs"),
            allow_files = True,
            doc = "Builder source files copied into the action sandbox.",
        ),
        "release": attr.bool(
            default = True,
            doc = "Whether to pass -R and build release archives.",
        ),
        "execution_requirements": attr.string_dict(
            default = {},
            doc = "Bazel execution requirements, e.g. {'no-remote': '1', 'no-remote-cache': '1', 'no-remote-exec': '1'} for local-only blob handling.",
        ),
        "_runner": attr.label(
            default = Label("//bazel:build_action.sh"),
            allow_single_file = True,
        ),
    },
    doc = "Builds a WAS-110 firmware release directory as a Bazel TreeArtifact.",
)
