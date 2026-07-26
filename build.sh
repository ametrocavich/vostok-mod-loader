#!/usr/bin/env bash
# build.sh -- concatenate src/*.gd into modloader.gd
#
# Explicit ordering (not filename-based sort): the FILES list below is the
# source of truth for concat order. Dependencies flow top-down earlier
# files may not reference code defined later.

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
    # Static-init boot layer
    "$SRC/boot.gd"
    # Mod discovery + loading
    "$SRC/security_scan.gd"
    "$SRC/mws_api.gd"
    "$SRC/mod_discovery.gd"
    "$SRC/modpacks.gd"
    "$SRC/mod_loading.gd"
    "$SRC/conflict_report.gd"
    # UI -- the launcher window, split by concern. Order within this group is
    # presentation only: GDScript resolves funcs and consts regardless of
    # position, and no module-scope var in these files initializes from another
    # symbol (they are all literals), so the group can be reordered freely.
    "$SRC/ui_theme.gd"            # design tokens, dark theme, styleboxes, icons
    "$SRC/ui_config_profiles.gd"  # mod_config.cfg load/save, profile plumbing
    "$SRC/ui_dialogs.gd"          # generic dialog kit + the concrete confirms
    "$SRC/ui_shell.gd"            # the Window, tabs, bottom bar -- entry point
    "$SRC/ui_mods_tab.gd"         # Mods tab + per-mod ModWorkshop meta layer
    "$SRC/ui_browse_tab.gd"       # Browse tab: search, sort, category, paging
    "$SRC/ui_browse_detail.gd"    # Browse rows, thumbnails, the detail modal
    "$SRC/ui_modpack_io.gd"       # profile <-> modpack zip serialization
    "$SRC/ui_modpacks_tab.gd"     # Modpacks tab + the apply/retry flow
    "$SRC/ui_updates_tab.gd"      # Updates tab + the loader self-update check
    # Public API (hooks + registry)
    "$SRC/hooks_api.gd"
    # Registry dispatcher + per-section handlers. shared.gd holds helpers
    # used by more than one section; each section file owns its own verb
    # implementations. New sections: add a file here + match arm in registry.gd.
    "$SRC/registry.gd"
    "$SRC/registry/shared.gd"
    "$SRC/registry/scenes.gd"
    "$SRC/registry/items.gd"
    "$SRC/registry/loot.gd"
    "$SRC/registry/sounds.gd"
    "$SRC/registry/recipes.gd"
    "$SRC/registry/events.gd"
    "$SRC/registry/traders.gd"
    "$SRC/registry/inputs.gd"
    "$SRC/registry/loader.gd"
    "$SRC/registry/ai.gd"
    "$SRC/registry/ai_loadouts.gd"
    "$SRC/registry/fish.gd"
    "$SRC/registry/resources.gd"
    "$SRC/registry/scene_nodes.gd"
    "$SRC/registry/aggregators.gd"
    # Declarative setup() entry point (depends on registry _many verbs + hook_many)
    "$SRC/setup.gd"
    "$SRC/framework_wrappers.gd"
    # Codegen pipeline
    "$SRC/gdsc_detokenizer.gd"
    "$SRC/pck_enumeration.gd"
    "$SRC/rewriter.gd"
    "$SRC/hook_pack.gd"
    # Orchestration
    "$SRC/lifecycle.gd"
    "$SRC/main_menu_hook.gd"
    # Temporary debug scaffolding
    "$SRC/debug.gd"
)

# Validate every listed file exists before starting
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "ERROR: missing source file: $f" >&2; exit 1; }
done

# Concatenate
: > "$TMP"
for f in "${FILES[@]}"; do
    cat "$f" >> "$TMP"
    echo "" >> "$TMP"  # blank line between files
done

# Sanity checks on the output
extends_count=$(grep -c '^extends ' "$TMP" || true)
if [[ $extends_count -ne 1 ]]; then
    echo "ERROR: expected exactly 1 'extends' line, found $extends_count" >&2
    rm -f "$TMP"
    exit 1
fi
class_count=$(grep -c '^class_name ' "$TMP" || true)
if [[ $class_count -gt 1 ]]; then
    echo "ERROR: multiple class_name declarations: $class_count" >&2
    rm -f "$TMP"
    exit 1
fi

mv "$TMP" "$OUT"
lines=$(wc -l < "$OUT")
echo "Built $OUT: $lines lines from ${#FILES[@]} source files"
