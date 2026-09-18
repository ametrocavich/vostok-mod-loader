# GDSC Detokenizer

The loader needs source for every vanilla `.gd` it rewrites. An exported game ships `.gdc`, Godot's binary-tokenized form, and `load(path).source_code` is empty for those. The detokenizer in [src/gdsc_detokenizer.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd) reconstructs readable source from the binary format.

`check_detok.sh` covers the reader against synthetic buffers (see [Build](Build#checksh)). Function names below are the anchors; line numbers drift.


## Where the bytes come from

Hook-pack generation runs after mod archives are mounted, so reading `res://Scripts/X.gd` through the VFS can return a mod's file instead of the game's. The detokenizer therefore reads a script's bytes straight out of the game's `.pck` by offset (`_vanilla_bytes_from_pck`, using the same file-table parser the security scanner uses), trying the compiled `.gdc` entry first and the plain `.gd` second. The VFS is only a fallback when no `.pck` sits beside the executable (the editor, the test harnesses), and text obtained that way is never written to the vanilla cache. The cache directory carries a `format` stamp; a cache without the current stamp is wiped before use, which is how installs poisoned by an older loader recover on upgrade. A second stamp, `build`, holds the mtime and size of the PCK the text was read from (`_game_pck_stamp`), so a game update that replaces the PCK drops the cache as well.

## Supported versions

`TOKENIZER_VERSION` 100 (Godot 4.3-4.4) and 101 (Godot 4.5-4.6), the `GDSC_VERSION_V100` / `V101` constants. Anything else is refused: `_detokenize_script` logs a critical and returns empty, and [canary B](Stability-Canaries#canary-b-gdsc-tokenizer-version) stops hook pack generation with one message before that can cascade through every script.

## Binary format

The file starts with a 12-byte header:

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | 4 | Magic `"GDSC"` (`_GDSC_MAGIC`) |
| 4 | 4 | Version, u32, 100 or 101 |
| 8 | 4 | Decompressed size, u32; 0 means uncompressed |

If the magic is missing but the bytes are plain UTF-8 GDScript (starting with `extends`, `class_name` or `@`), the text is returned as is. Some games ship a few scripts untokenized.

A non-zero decompressed size means the rest of the file is ZSTD: `compressed.decompress(decompressed_size, FileAccess.COMPRESSION_ZSTD)`.

### Metadata block

v100 uses 20 bytes (4 bytes of padding), v101 uses 16:

| Offset (v100) | Offset (v101) | Meaning |
|---|---|---|
| 0 | 0 | `ident_count` (u32) |
| 4 | 4 | `const_count` (u32) |
| 8 | 8 | `line_count` (u32) |
| 16 | 12 | `token_count` (u32) |

### Identifiers

XOR-obfuscated UTF-32. Each identifier is a `len` (u32) followed by `len` code points, each stored as four bytes XORed with `0xb6`:

```gdscript
var b0 = buf[offset] ^ 0xb6
var b1 = buf[offset + 1] ^ 0xb6
var b2 = buf[offset + 2] ^ 0xb6
var b3 = buf[offset + 3] ^ 0xb6
var code_point = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
```

The XOR happens per byte, before the bytes are combined.

### Constants

Variant-encoded, one after another. `bytes_to_var` does not report how many bytes it consumed, so the reader round-trips each value through `var_to_bytes` to advance:

```gdscript
var val = bytes_to_var(remaining)
constants.append(val)
var encoded = var_to_bytes(val)
offset += encoded.size()
```

A failed `bytes_to_var` desyncs everything after it. After all three sections are read, the collected identifier, constant and token counts are checked against the header counts; a mismatch logs `Section truncation/desync ... refusing partial reconstruction` and returns empty instead of reconstructing (and caching) garbage.

### Line and column maps

Two sections of `line_count * 8` bytes each:

```
line_map: [(token_index: u32, line: u32), ...]
col_map:  [(token_index: u32, column: u32), ...]
```

These drive the reconstruction. Line advancement comes from `line_map` (blank lines are inserted when the next mapped line is more than one ahead) and indentation from `col_map`. INDENT and DEDENT tokens are skipped, not trusted. A NEWLINE token, when present, also ends the current line.

### Token stream

Each token is 5 or 8 bytes, depending on the high bit (`0x80`) of its first byte:

```
token_len  = 8 if (first_byte & 0x80) else 5
raw_type   = u32 at token start
token_type = raw_type & 0x7F
data_index = raw_type >> 8
```

Token type ids, v101 numbering (`_TOKEN_TEXT` and the `TK_*` constants):

| Range | Category |
|---|---|
| 0-3 | EMPTY, ANNOTATION, IDENTIFIER, LITERAL |
| 4-15 | Comparison and logical ops (`<` `<=` `>` `>=` `==` `!=`, `and` `or` `not` `&&` `||` `!`) |
| 16-21 | Bitwise (`&` `|` `~` `^` `<<` `>>`) |
| 22-27 | Arithmetic (`+` `-` `*` `**` `/` `%`) |
| 28-39 | Assignment ops |
| 40-50 | Control flow (`if` `elif` `else` `for` `while` `break` `continue` `pass` `return` `match` `when`) |
| 51-72 | Declaration keywords (`as` `assert` `await` `breakpoint` `class` `class_name` `const` `enum` `extends` `func` `in` `is` `namespace` `preload` `self` `signal` `static` `super` `trait` `var` `void` `yield`) |
| 73-78 | Brackets (`[` `]` `{` `}` `(` `)`) |
| 79-87 | Punctuation (`,` `;` `.` `..` `...` `:` `$` `->` `_`) |
| 88-90 | NEWLINE, INDENT, DEDENT |
| 91-94 | PI, TAU, INF, NAN |
| 96-97 | backtick, `?` |
| 99 | EOF |

v100 has no `...` token (index 83 in v101), so every v100 index from 83 up sits one below the v101 table. The reader adds one at decode time (`_GDSC_V100_SHIFT_FROM`). Without that, `:` reads as `...`, NEWLINE as `_`, and EOF is never seen, so the stream never terminates. This went unnoticed until `check_detok.sh` existed, because the version gate accepted v100 while the table was v101-only, and a v100 script decoded to garbage that was then cached as pristine vanilla.

## Reconstruction

`_gdsc_reconstruct` walks the token stream and rebuilds the text line by line:

- `line_map[i]` says when to move to a new line, inserting blank lines for gaps. A jump of more than 10000 lines aborts; only a corrupt line map produces one, and looping on raw u32 garbage would spin for billions of iterations.
- The first visible token on a line reads `col_map[i]` and converts it to tabs through `_indent_from_column`: `col / 4`. Godot counts one column per character, and RTV's vanilla source is 4-space indented, so columns run 1, 5, 9, 13. Tab or 2-space source would collapse to depth 0; [canary C](Stability-Canaries#canary-c-detokenizer-round-trip) catches that.
- INDENT and DEDENT tokens are skipped. EMPTY tokens are skipped too; otherwise they would render as a `<tk0>` placeholder.
- Spacing comes from two lookup tables, `_SPACE_BEFORE` and `_SPACE_AFTER`. An identifier, literal, annotation or keyword gets a leading space unless it follows `(`, `[`, `.`, `$`, `~`, `!`, an indent or a newline.

Literals go through `_gdsc_variant_to_source`:

```gdscript
TYPE_BOOL        -> "true" / "false"
TYPE_INT         -> str(value)
TYPE_FLOAT       -> str(value), with ".0" appended when it has no "." or "e";
                    INF / -INF / NAN for the non-finite values
TYPE_STRING      -> '"%s"' % value.c_escape()
TYPE_STRING_NAME -> '&"%s"'
TYPE_NODE_PATH   -> '^"%s"'
```

The constant pool only holds those literal types; vectors, colors and arrays arrive as constructor tokens. Any other Variant type logs a critical (`Constant pool holds an unexpected Variant type`) and renders `null`, because `str()` on it would not be valid GDScript and the rewritten script would not compile.

## Vanilla source cache

`_read_vanilla_source` serves reconstructed source from `user://modloader_hooks/vanilla/<path>` when the file exists and is non-empty, so later sessions skip the decode. `_save_vanilla_source` never writes an empty result, writes to a `.tmp` sibling first, removes it if `store_string` reports an error, and renames it into place. A truncated cache file would otherwise be trusted as pristine vanilla forever.

The cache is wiped with the rest of `user://modloader_hooks` on a loader version change or a game update (static init in `boot.gd`).

### Why nothing here calls `load()`

From the comment in `_read_vanilla_source`: never call `load(script_path)` here, not even to verify the live script. Any `load()` makes `ResourceFormatLoaderGDScript` read the PCK's `.gdc` (through the PCK's stale `.gd.remap`) and cache the tokenized result at `script_path`. Later hook-pack mounts and loads then hit that cached entry instead of the rewrite. The cache must stay cold until the hook pack is mounted.

`_detokenize_script` reads raw bytes with `FileAccess` only, trying three ways in order:

1. `FileAccess.open(script_path, READ)`
2. `FileAccess.open(ProjectSettings.globalize_path(script_path), READ)`
3. `FileAccess.get_file_as_bytes(script_path.replace(".gd", ".gdc"))`

### Stale-overlay check

After detokenizing, `_read_vanilla_source` rejects source that contains `_rtv_ready_done` or `Engine.get_meta("RTVModLib"`. That means a previous session's overlay contaminated the input:

```
[Hooks] Detokenized source for <path> already contains rewrite markers
  -- possible stale overlay. Delete <HOOK_PACK_DIR> and restart.
```

## Probe

`_probe_gdsc_version` reads each of four known vanilla scripts (`Camera.gd`, `Controller.gd`, `Audio.gd`, `AI.gd`, falling back to the `.gdc` extension), needs at least a 12-byte header and the `GDSC` magic, and returns the u32 version field of the first that qualifies. Returns -1 when none is readable. Canary B uses it to stop cleanly on an unsupported tokenizer.

Caveat, stated in the code as well: `_generate_hook_pack` treats -1 as "no probe" and proceeds without canary B. If a game update renamed all four paths, the canary would stop guarding without saying so.

## Zero-byte entries

Some vanilla `.gd` entries are zero bytes in the base PCK (`CasettePlayer.gd` in RTV 4.6.1). PCK enumeration records them in `_pck_zero_byte_paths` (and restores that set from the script-index cache on a cache hit), and `_detokenize_script` returns empty for them without the "Cannot read bytes" warning. They cannot be hooked either way.
