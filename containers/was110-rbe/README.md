# WAS-110 RBE execution image

Minimal Debian-based execution image for the Bazel `was110_firmware`
action.

Build and publish inside the lab registry:

```sh
docker build -t registry.internal/was110-rbe:<tag> containers/was110-rbe
docker push registry.internal/was110-rbe:<tag>
```

Then override the platform image in your consuming Bazel workspace or copy
`//bazel/platforms:was110_rbe_linux` and set its `container-image` property
to the internal image reference.

The image intentionally sets `SUDO=`. Remote workers should run the
firmware build as an unprivileged user; the Bazel action wraps `build.sh`
with `fakeroot` so device nodes survive rootfs extraction/repack, and
`build.sh` uses `mksquashfs -all-root` for output ownership.
