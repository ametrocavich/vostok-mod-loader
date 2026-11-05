# GDSC Detokenizer

The loader needs source for every vanilla `.gd` it rewrites. An exported game ships `.gdc`, Godot's binary-tokenized form, and `load(path).source_code` is empty for those. [src/gdsc_detokenizer.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd) rebuilds readable source from it. `check_detok.sh` covers the reader on synthetic buffers ([Build](Build#the-checks)).

## Where the bytes come from

Hook-pack generation runs after mod archives are mounted, so `res://Scripts/X.gd` read through the VFS can be a mod's file. `_read_script_bytes` therefore reads the game's own `.pck` by offset first (`_vanilla_bytes_from_pck`, over `_pck_read_table` in pck_enumeration.gd), trying the `.gdc` entry before the `.gd`. Only when no `.pck` sits beside the executable (the editor, the test harnesses) does it fall back to the VFS: `FileAccess` on the `res://` path, then on the globalized path, then the `.gdc` beside it. Text read through the VFS is never cached.

Nothing here calls `load()` on a script path: a load would cache the PCK's tokenized script at that path, and later loads after the hook pack mounts would get that instead of the rewrite.

## Supported versions

`TOKENIZER_VERSION` 100 (Godot 4.3-4.4) and 101 (Godot 4.5-4.6), the `GDSC_VERSION_V100` and `GDSC_VERSION_V101` constants. `_detokenize_script` refuses anything else with a critical and returns empty, and [canary B](Stability-Canaries#canary-b-gdsc-tokenizer-version) stops hook-pack generation with one message before that can repeat for every script.

## Binary format

The file starts with a 12-byte header:

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | 4 | Magic `"GDSC"` (`_GDSC_MAGIC`) |
| 4 | 4 | Version, u32, 100 or 101 |
| 8 | 4 | Decompressed size, u32; 0 means uncompressed |

Without the magic, bytes that are plain UTF-8 GDScript (starting with `extends`, `class_name` or `@`) are returned as they are; a build can ship a few scripts untokenized. A non-zero decompressed size means the rest of the file is ZSTD.

### Metadata block

v100 uses 20 bytes (4 bytes of padding), v101 uses 16:

| Offset (v100) | Offset (v101) | Meaning |
|---|---|---|
| 0 | 0 | `ident_count` (u32) |
| 4 | 4 | `const_count` (u32) |
| 8 | 8 | `line_count` (u32) |
| 16 | 12 | `token_count` (u32) |

### Identifiers

Each identifier is a u32 length followed by that many UTF-32 code points, four bytes each. Every byte is XORed with `0xb6`; the XOR applies per byte, before the four are combined little-endian.

### Constants

Variant-encoded values, back to back. `bytes_to_var` does not report how many bytes it consumed, so the reader re-encodes each value with `var_to_bytes` to find the next offset; one failed decode shifts everything after it. Once all sections are read, the identifier, constant and token counts are checked against the header, and a mismatch logs `Section desync in <path>` and returns empty rather than reconstructing (and caching) garbage.

### Line and column maps

Two sections of `line_count * 8` bytes each, `(token_index: u32, line: u32)` pairs and then `(token_index: u32, column: u32)` pairs. They drive the reconstruction: line breaks come from the line map and indentation from the column map.

### Token stream

```
token_len  = 8 if (first_byte & 0x80) else 5
raw_type   = u32 at token start
token_type = raw_type & 0x7F
data_index = raw_type >> 8
```

`_TOKEN_TEXT` and the `_TK_*` constants hold the v101 numbering: 0-3 are EMPTY, ANNOTATION, IDENTIFIER and LITERAL (whose data index points into the identifier or constant pool), 88-90 NEWLINE, INDENT and DEDENT, 99 EOF; the rest are operators, keywords and punctuation. v100 has no `...` token, which is index 83 in v101, so every v100 index from 83 up is one lower. The reader adds one at decode time (`_GDSC_V100_SHIFT_FROM`); without it `:` reads as `...`, NEWLINE as `_`, and EOF is never seen.

## Reconstruction

`_reconstruct_source` walks the tokens and rebuilds the text line by line:

- The line map says when to start a new line, with blank lines for gaps. A jump of more than 10000 lines aborts (`Absurd line jump`): only a corrupt map produces one, and looping on a raw u32 would spin for billions of iterations.
- The first visible token on a line sets the indent from the column map through `_indent_from_column`, `col / 4`. Godot counts one column per character and the game's source is 4-space indented, so columns run 1, 5, 9, 13 and become 0, 1, 2, 3 tabs. Tab or 2-space source would collapse to depth 0; [canary C](Stability-Canaries#canary-c-detokenizer-round-trip) catches that.
- INDENT, DEDENT and EMPTY tokens are skipped; a NEWLINE token, when present, also ends the line.
- Spacing comes from `_SPACE_BEFORE` and `_SPACE_AFTER`. An identifier, literal, annotation or keyword takes a leading space unless it follows `(`, `[`, `.`, `$`, `~`, `!` or the start of a line.

`_variant_to_source` writes the literals: booleans, integers, floats (always with a `.0` or exponent, and `INF`, `-INF`, `NAN` for the non-finite ones), and strings, `StringName`s and `NodePath`s as escaped `"..."`, `&"..."` and `^"..."`. The constant pool holds only those; vectors, colors and arrays arrive as constructor tokens. Any other type logs `Constant pool holds an unexpected Variant type` and renders `null`, since its `str()` would not be valid GDScript.

## Vanilla source cache

`_read_vanilla_source` serves reconstructed text from `user://modloader_hooks/vanilla/<path>` when the file exists and is not empty, so later sessions skip the decode. `_save_vanilla_source` never writes an empty result; it writes a `.tmp` sibling and renames it into place, removing it if the write reports an error, since a truncated cache file would be trusted as vanilla forever.

Two stamp files sit at the cache root: `format` names the cache layout and `build` the mtime and size of the `.pck` the text came from (`_game_pck_stamp`). A mismatch on either wipes the cache before use, so a game update or a cache written by another loader rebuilds it. Static init in `boot.gd` also wipes it with the rest of `user://modloader_hooks` on a loader version change or a game update.

Detokenized text that already contains `_rtv_ready_done` or `Engine.get_meta("RTVModLib"` came from a previous session's mounted pack, not the game. It is refused with a critical: `[Detokenize] Detokenized source for <path> already contains rewrite markers; delete <HOOK_PACK_DIR> and restart`.

## Zero-byte entries

A game build can ship a vanilla `.gd` entry as zero bytes. PCK enumeration records them in `_pck_zero_byte_paths` (restored from the script-index cache on a cache hit), and `_detokenize_script` returns empty for them without the "Cannot read bytes" warning. They cannot be hooked ([Hook-Surface](Hook-Surface#what-cannot-be-hooked)).
