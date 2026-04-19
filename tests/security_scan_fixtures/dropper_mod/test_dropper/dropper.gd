extends Node

# Fixture for the modloader security scanner. Mimics a real malicious mod
# pattern: large integer literal, byte-array decode loop, FileAccess.WRITE,
# and OS.execute on the dropped file. Function is never called from anywhere
# in this mod (no autoload, no _ready hook), so enabling this mod is safe.
# The encoded bytes decode to "echo demo test" -- harmless even if invoked.

func _scan_test_dropper_demo() -> void:
	var output = []
	var update = "scantest_demo.txt"
	# Decodes to "echo modloader scanner test pattern" -- 27 bytes, well above
	# the 16-int threshold of the large_int_array rule. Harmless even if run.
	var encoded = [101, 99, 104, 111, 32, 109, 111, 100, 108, 111, 97, 100, 101, 114, 32, 115, 99, 97, 110, 110, 101, 114, 32, 116, 101, 115, 116, 32, 112, 97, 116, 116, 101, 114, 110]
	var content = ""
	for c in encoded:
		content += char(c)
	var file = FileAccess.open(update, FileAccess.WRITE)
	file.store_string(content)
	file.close()
	OS.execute("nonexistent-scantest-binary", [update], output, false)
