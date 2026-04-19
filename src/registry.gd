## ----- registry.gd -----
## Public registry API for mods to add/override/edit vanilla game content.
## See REGISTRY_PLAN.md for the full design. Populated incrementally:
## Section 1 (Database scenes) is the pilot, each later section adds its
## own handlers.
##
## Planned surface:
##   lib.register(registry: String, id: String, data: Variant) -> bool
##   lib.override(registry: String, id: String, data: Variant) -> bool
##   lib.patch(registry: String, id: String, fields: Dictionary) -> bool
##   lib.remove(registry: String, id: String) -> bool
##   lib.revert(registry: String, id: String, fields: Array = []) -> bool
##
## Intentionally empty for now -- implementation begins after the refactor
## split is validated.
