#!/usr/bin/env bash
# Layer the user's config override on top of the image default, then start goosed.
#
# Precedence (highest wins): user override > baked default.
# Merge is a per-key deep merge; arrays are replaced (not appended).
# Set GOOSE_CONFIG_MERGE=off to skip merging and use the override verbatim.
set -euo pipefail

DEFAULT=/etc/goose/config.default.yaml
OVERRIDE=${GOOSE_CONFIG_OVERRIDE:-/etc/goose/config.override.yaml}
TARGET="${HOME}/.config/goose/config.yaml"

mkdir -p "$(dirname "$TARGET")"

if [[ -f "$OVERRIDE" && "${GOOSE_CONFIG_MERGE:-on}" == "off" ]]; then
  # Power-user escape hatch: use the override as-is, ignore baked defaults.
  cp "$OVERRIDE" "$TARGET"
elif [[ -f "$OVERRIDE" ]]; then
  # Deep merge: later files win per-key; arrays are replaced.
  yq eval-all '. as $item ireduce ({}; . * $item)' "$DEFAULT" "$OVERRIDE" > "$TARGET"
else
  cp "$DEFAULT" "$TARGET"
fi

# ---------------------------------------------------------------------------
# Adversary mode (claw policy)
# ---------------------------------------------------------------------------
# Goose activates the adversary reviewer by the mere presence of
# ~/.config/goose/adversary.md. We install the baked claw policy there by
# default so every image ships with the second-pair-of-eyes reviewer on.
# Unlike config.yaml this is plain-language rules, not YAML — there is nothing
# to deep-merge, so an override REPLACES the default wholesale.
#
#   GOOSE_ADVERSARY_OVERRIDE  path to a replacement adversary.md
#                             (default /etc/goose/adversary.override.md)
#   GOOSE_ADVERSARY_DISABLE   set truthy to ship WITHOUT adversary mode
#                             (no adversary.md is installed -> feature off)
ADV_DEFAULT=/etc/goose/adversary.default.md
ADV_OVERRIDE=${GOOSE_ADVERSARY_OVERRIDE:-/etc/goose/adversary.override.md}
ADV_TARGET="${HOME}/.config/goose/adversary.md"

if [[ "${GOOSE_ADVERSARY_DISABLE:-false}" =~ ^(1|true|yes|on)$ ]]; then
  # Explicit opt-out: remove any baked adversary file so the reviewer is off.
  rm -f "$ADV_TARGET"
elif [[ -f "$ADV_OVERRIDE" ]]; then
  cp "$ADV_OVERRIDE" "$ADV_TARGET"
elif [[ -f "$ADV_DEFAULT" ]]; then
  cp "$ADV_DEFAULT" "$ADV_TARGET"
fi

exec /usr/local/bin/goosed "$@"
