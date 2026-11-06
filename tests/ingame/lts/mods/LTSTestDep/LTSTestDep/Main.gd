## LTS Test: Dependency, the mod LTSTestCore requires; it records when its _ready ran
## so the core mod can prove the load order (D1). Never ships to players.
extends Node

const TAG := "[LTSTEST]"
# The game log is buffered and lost on a crash at exit; this copy is flushed.
const PROGRESS := "user://ltstest_dep_progress.txt"
const READY_META := "lts_dep_ready_ticks"

func _ready() -> void:
	var f := FileAccess.open(PROGRESS, FileAccess.WRITE)
	if f != null:
		f.store_line("run start")
	var ticks := Time.get_ticks_msec()
	Engine.set_meta(READY_META, ticks)
	var lib = Engine.get_meta("RTVModLib", null)
	var version := str(lib.get("MODLOADER_VERSION")) if lib != null else "no RTVModLib"
	var text := "PASS D0 dep ready: ticks %d, loader %s" % [ticks, version]
	print("%s %s" % [TAG, text])
	if f != null:
		f.store_line("%s %s" % [Time.get_time_string_from_system(), text])
		f.close()
