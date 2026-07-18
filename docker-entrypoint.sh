#!/usr/bin/env bash
# Prepare goose's config (config.yaml + adversary.md), then exec the given
# command. The command is whatever CMD/args the image passes ("$@") — e.g.
# `goosed agent` for the HTTP-server image, or `openab run -c ...` for the
# Slack/OpenAB image, which in turn spawns `goose acp` as a child. Either way
# goose reads the same ~/.config/goose we lay down here, so the adversary
# reviewer is active regardless of which frontend drives the agent.
#
# Precedence (highest wins): user override > baked default.
# Merge is a per-key deep merge; arrays are replaced (not appended).
# Set GOOSE_CONFIG_MERGE=off to skip merging and use the override verbatim.
set -euo pipefail

DEFAULT=/etc/goose/config.default.yaml
OVERRIDE=${GOOSE_CONFIG_OVERRIDE:-/etc/goose/config.override.yaml}
TARGET="${HOME}/.config/goose/config.yaml"

# HOME (/data) is the single state mountpoint. Recreate the state dirs here so a
# fresh/empty mount (bind mount, or a first-run named volume that shadows the
# image's dirs) still has the layout goose + OpenAB expect. The baked defaults
# we install below live in /etc, not HOME, so they survive an empty mount.
mkdir -p "$(dirname "$TARGET")" "${HOME}/.openab" "${HOME}/workspace"

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

# ---------------------------------------------------------------------------
# OpenAB config
# ---------------------------------------------------------------------------
# Same precedence/merge semantics as the goose config above, but for the
# OpenAB TOML: user override > baked default, per-key deep merge, arrays
# replaced. `${VAR}` placeholders survive the merge as plain strings — OpenAB
# expands them from the environment at load time, so an override can add new
# runtime-tunable settings (e.g. extra [agent.env] vars) without restating the
# whole file. Mounting over $AB_DEFAULT still works as a wholesale replacement.
# The merged file lands under HOME because /etc is read-only to the goose user;
# the image CMD points OpenAB at it.
#
#   OPENAB_CONFIG_OVERRIDE  path to an override TOML
#                           (default /etc/openab/config.override.toml)
#   OPENAB_CONFIG_MERGE=off use the override verbatim, ignore the baked default
AB_DEFAULT=/etc/openab/config.toml
AB_OVERRIDE=${OPENAB_CONFIG_OVERRIDE:-/etc/openab/config.override.toml}
AB_TARGET="${HOME}/.openab/config.toml"

# Skip entirely on variants without a baked OpenAB config (e.g. the goosed
# HTTP-server image) unless an override is provided.
if [[ -f "$AB_OVERRIDE" && ( "${OPENAB_CONFIG_MERGE:-on}" == "off" || ! -f "$AB_DEFAULT" ) ]]; then
  cp "$AB_OVERRIDE" "$AB_TARGET"
elif [[ -f "$AB_OVERRIDE" ]]; then
  yq eval-all -p toml -o toml '. as $item ireduce ({}; . * $item)' \
    "$AB_DEFAULT" "$AB_OVERRIDE" > "$AB_TARGET"
elif [[ -f "$AB_DEFAULT" ]]; then
  cp "$AB_DEFAULT" "$AB_TARGET"
fi

# Hand off to the image's command (goosed, openab, or anything else). Keeping
# this generic lets a single entrypoint serve every image variant; the goose
# config/adversary setup above is the shared invariant.
exec "$@"
