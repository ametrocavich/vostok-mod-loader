extends Node

# Fixture combining four OS-level misuse rules:
#   - os_kill: kills any process by PID
#   - os_crash: anti-debug / scanner-evasion crash
#   - os_create_instance: spawns another copy of the game with attacker CLI
#     args (--script, --main-pack); strictly more dangerous than create_process
#   - disable_save_safety: turns off Godot's atomic-write protection so the
#     next crash corrupts saves (ransomware setup)
# Function is never called.
func _scan_test_os_misuse_demo() -> void:
	OS.kill(1234)
	OS.crash("scantest crash message")
	OS.create_instance(["--script", "res://nonexistent.gd"])
	OS.set_use_file_access_save_and_swap(false)
