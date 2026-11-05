#!/usr/bin/env bash
# build.sh [--list] -- concatenate FILES, in this order, into modloader.gd.
# Only const initializers need the order (GDScript resolves them top to bottom).

set -euo pipefail
cd "$(dirname "$0")"

SRC=src
OUT=modloader.gd
TMP=$OUT.tmp

FILES=(
    # Fundamentals (header + module-scope state + log helpers)
    "$SRC/header.gd"
    "$SRC/constants.gd"
    "$SRC/logging.gd"
    # File + archive helpers (no game-specific logic)
    "$SRC/fs_archive.gd"
    # Boot layer: static-init mounts, then pass state, crash recovery, cache cleanup
    "$SRC/boot.gd"
    "$SRC/pass_state.gd"
    "$SRC/crash_recovery.gd"
    "$SRC/cache_cleanup.gd"
    # Mod-host seam: types, transport, dispatch, then one file per host
    "$SRC/host_types.gd"
    "$SRC/host_http.gd"
    "$SRC/host_api.gd"
    "$SRC/host_mws.gd"
    "$SRC/host_vostokmods.gd"
    # Mod discovery + loading
    "$SRC/mod_discovery.gd"
    "$SRC/mod_dependencies.gd"
    "$SRC/mod_identity.gd"
    "$SRC/mod_downloads.gd"
    "$SRC/mod_sources.gd"
    "$SRC/modpacks.gd"
    "$SRC/hosted_modpacks.gd"
    "$SRC/mod_loading.gd"
    # Developer-mode conflict and override report
    "$SRC/conflict_report.gd"
    # Profiles and their MCM snapshots
    "$SRC/profiles.gd"
    "$SRC/profile_snapshots.gd"
    # UI
    "$SRC/ui.gd"
    "$SRC/ui_images.gd"
    "$SRC/ui_format.gd"
    "$SRC/loader_update.gd"
    "$SRC/ui_theme.gd"
    "$SRC/ui_dialogs.gd"
    "$SRC/ui_mods.gd"
    "$SRC/ui_mods_rows.gd"
    "$SRC/ui_mods_metadata.gd"
    "$SRC/mod_updates.gd"
    "$SRC/ui_browse.gd"
    "$SRC/ui_modpacks.gd"
    # Public API (hooks + registry)
    "$SRC/hooks_api.gd"
    # Registry dispatcher, then one file per section ("Adding a registry section" in Development.md)
    "$SRC/registry.gd"
    "$SRC/registry/shared.gd"
    "$SRC/registry/scenes.gd"
    "$SRC/registry/items.gd"
    "$SRC/registry/loot.gd"
    "$SRC/registry/sounds.gd"
    "$SRC/registry/recipes.gd"
    "$SRC/registry/events.gd"
    "$SRC/registry/traders.gd"
    "$SRC/registry/array_entries.gd"
    "$SRC/registry/inputs.gd"
    "$SRC/registry/loader.gd"
    "$SRC/registry/ai.gd"
    "$SRC/registry/ai_loadouts.gd"
    "$SRC/registry/fish.gd"
    "$SRC/registry/resources.gd"
    "$SRC/registry/scene_nodes.gd"
    "$SRC/registry/aggregators.gd"
    # Declarative setup() entry point
    "$SRC/setup.gd"
    # Codegen pipeline
    "$SRC/gdsc_detokenizer.gd"
    "$SRC/pck_enumeration.gd"
    "$SRC/rewriter_parse.gd"            # regex compile + detokenized-source parsing
    "$SRC/rewriter_rewrite.gd"          # rename+wrap orchestrator + dispatch wrapper emitter
    "$SRC/rewriter_registry_inject.gd"  # declaration transforms, preludes, registry appendices
    "$SRC/rewriter_text.gd"             # string-aware source mask, identifier test
    "$SRC/hook_pack.gd"
    "$SRC/hook_status.gd"
    # Orchestration
    "$SRC/lifecycle.gd"
    "$SRC/main_menu_hook.gd"
    # Developer-mode probes
    "$SRC/debug.gd"
)

if [[ $# -gt 1 ]]; then
    echo "Usage: ./build.sh [--list]" >&2
    exit 2
fi
case "${1:-}" in
    --list) printf '%s\n' "${FILES[@]}"; exit 0 ;;
    "") ;;
    *) echo "Usage: ./build.sh [--list]" >&2; exit 2 ;;
esac

for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "ERROR: missing source file: $f" >&2; exit 1; }
done

trap 'rm -f "$TMP"' EXIT
: > "$TMP"
for f in "${FILES[@]}"; do
    printf '# source: %s\n' "$f" >> "$TMP"
    # A Windows checkout can hold CRLF; the release is built on Linux from LF blobs.
    LC_ALL=C tr -d '\r' < "$f" >> "$TMP"
    echo "" >> "$TMP"
done

extends_count=$(grep -c '^extends ' "$TMP" || true)
if [[ $extends_count -ne 1 ]]; then
    echo "ERROR: expected exactly 1 'extends' line, found $extends_count" >&2
    exit 1
fi
class_count=$(grep -c '^class_name ' "$TMP" || true)
if [[ $class_count -gt 1 ]]; then
    echo "ERROR: multiple class_name declarations: $class_count" >&2
    exit 1
fi

mv "$TMP" "$OUT"
echo "Built $OUT: $(wc -l < "$OUT") lines from ${#FILES[@]} source files"
