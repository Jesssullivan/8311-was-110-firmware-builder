#!/usr/bin/env bash
# Generate an in-toto/SLSA-shaped provenance statement from manifest.json.
set -euo pipefail

MANIFEST="${1:-out/manifest.json}"
OUT="${2:-$(dirname "$MANIFEST")/provenance.intoto.json}"

[ -f "$MANIFEST" ] || { echo "missing manifest: $MANIFEST" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 2; }

BUILDER_ID="${GITHUB_SERVER_URL:-local}:${GITHUB_REPOSITORY:-8311-was-110-firmware-builder}:${GITHUB_WORKFLOW:-manual}"
INVOCATION_ID="${GITHUB_RUN_ID:-local}-$(date -u +%Y%m%dT%H%M%SZ)"

jq \
  --arg builder_id "$BUILDER_ID" \
  --arg invocation_id "$INVOCATION_ID" \
  '{
    "_type": "https://in-toto.io/Statement/v1",
    "predicateType": "https://slsa.dev/provenance/v1",
    "subject": (
      .artifacts
      | to_entries
      | map({
          "name": .key,
          "digest": {"sha256": .value.sha256}
        })
    ),
    "predicate": {
      "buildDefinition": {
        "buildType": "https://github.com/8311-was-110-firmware-builder/release-build@v1",
        "externalParameters": {
          "firmware_variant": .build_inputs.firmware.variant,
          "kernel_variant": .build_inputs.kernel.variant,
          "bootcore_variant": .build_inputs.bootcore.variant,
          "allow_module_mismatch": .build_inputs.kernel.allow_module_mismatch,
          "kernel_build_provenance": (.build_inputs.kernel.build_provenance // null)
        },
        "internalParameters": {
          "source_date_epoch": .build.source_date_epoch,
          "host_uname": .build.host_uname
        },
        "resolvedDependencies": (
          [
            {
              "uri": ("git+local://8311-was-110-firmware-builder@" + .git.rev),
              "digest": {"gitCommit": .git.rev}
            }
          ]
          + (
            .materials
            | to_entries
            | map({
                "uri": ("file://" + .key),
                "digest": {"sha256": .value.sha256}
              })
          )
        )
      },
      "runDetails": {
        "builder": {"id": $builder_id},
        "metadata": {
          "invocationId": $invocation_id,
          "startedOn": .build.built_on_utc,
          "finishedOn": .build.built_on_utc
        },
        "byproducts": [
          {
            "name": "kernel-banner",
            "value": .kernel.banner
          }
        ]
      }
    }
  }' "$MANIFEST" > "$OUT"

echo "wrote $OUT"
