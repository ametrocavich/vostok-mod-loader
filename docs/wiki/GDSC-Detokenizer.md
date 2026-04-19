# GDSC Detokenizer

The loader needs source access to every vanilla `.gd` it rewrites. For exported games, Godot ships `.gdc` binary-tokenized bytecode, not source. `load(path).source_code` returns empty for tokenized scripts. The detokenizer at [src/gdsc_detokenizer.gd](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd) reconstructs readable source from the binary format.

## Supported versions

`TOKENIZER_VERSION` 100 (Godot 4.0-4.4) and 101 (Godot 4.5-4.6). Version 102+ isn't supported -- [STABILITY canary B](Stability-Canaries#canary-b-gdsc-tokenizer-version) probes and refuses to generate a hook pack rather than cascading warnings through every script.

## Binary format

The `.gdc` file starts with a 12-byte header:

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | 4 | Magic `"GDSC"` ([gdsc_detokenizer.gd:13](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L13)) |
| 4 | 4 | Version (u32, 100 or 101) |
| 8 | 4 | Decompressed size (u32, 0 = uncompressed) |

If decompressed size is non-zero, the rest of the file is ZSTD-compressed ([gdsc_detokenizer.gd:143](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L143)): `compressed.decompress(decompressed_size, FileAccess.COMPRESSION_ZSTD)`.

### Metadata block

V100 uses 20 bytes (4-byte padding), V101 uses 16 bytes:

| Offset (v100) | Offset (v101) | Meaning |
|---|---|---|
| 0 | 0 | `ident_count` (u32) |
| 4 | 4 | `const_count` (u32) |
| 8 | 8 | `line_count` (u32) |
| 16 | 12 | `token_count` (u32) |

### Identifiers

XOR-obfuscated UTF-32. Each identifier:

```
len (u32)
char_0 (u32, XOR 0xb6 per byte before assembling)
char_1 (u32, XOR 0xb6 per byte)
...
```

Per-byte XOR happens before combining to a code point ([gdsc_detokenizer.gd:173-178](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L173)):

```gdscript
var b0 = buf[offset] ^ 0xb6
var b1 = buf[offset+1] ^ 0xb6
var b2 = buf[offset+2] ^ 0xb6
var b3 = buf[offset+3] ^ 0xb6
var code_point = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
```

### Constants

Variant-encoded, sequential. `bytes_to_var` doesn't report consumed size, so the detokenizer round-trips through `var_to_bytes` to advance the offset:

```gdscript
var val = bytes_to_var(remaining)
constants.append(val)
var encoded = var_to_bytes(val)
offset += encoded.size()
```

### Line + column maps

Two parallel sections, each `line_count * 8` bytes:

```
line_map: [(token_index: u32, line: u32), ...]
col_map:  [(token_index: u32, column: u32), ...]
```

These are **load-bearing** for reconstruction -- v101 has no NEWLINE/INDENT/DEDENT/EOF tokens in the stream (unlike v100). Line breaks and indentation are derived from the maps, not from the tokens themselves. See [gdsc_detokenizer.gd:252-259](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L252).

### Token stream

Each token is 5 or 8 bytes depending on whether the high bit (`0x80`) is set on the first byte:

```
raw_type (u32 for 5-byte, or u32 for 8-byte)
token_type = raw_type & 0x7F
data_index = raw_type >> 8
```

Token type IDs ([gdsc_detokenizer.gd:18-27](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L18)):

| Range | Category |
|---|---|
| 0-3 | EMPTY, ANNOTATION, IDENTIFIER, LITERAL |
| 4-15 | Comparison + logical ops (`<`, `<=`, `==`, `!=`, `and`, `or`, `not`, `!`) |
| 16-21 | Bitwise (`&`, `|`, `~`, `^`, `<<`, `>>`) |
| 22-27 | Arithmetic (`+`, `-`, `*`, `**`, `/`, `%`) |
| 28-39 | Assignment ops |
| 40-50 | Control flow (`if`, `elif`, `else`, `for`, `while`, `break`, `continue`, `pass`, `return`, `match`, `when`) |
| 51-72 | Declaration keywords (`as`, `assert`, `await`, `breakpoint`, `class`, `class_name`, `const`, `enum`, `extends`, `func`, `in`, `is`, `namespace`, `preload`, `self`, `signal`, `static`, `super`, `trait`, `var`, `void`, `yield`) |
| 73-78 | Brackets (`[`, `]`, `{`, `}`, `(`, `)`) |
| 79-87 | Punctuation (`,`, `;`, `.`, `..`, `...`, `:`, `$`, `->`, `_`) |
| 88-90 | NEWLINE, INDENT, DEDENT (skipped in v101 reconstruction) |
| 91-94 | PI, TAU, INF, NAN |
| 99 | EOF |

## Reconstruction

[gdsc_detokenizer.gd:238 `_gdsc_reconstruct`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L238) walks the token stream and rebuilds text line-by-line:

- `line_map[i]` tells the reconstructor when to advance to a new line (inserts blank lines if the next mapped line is more than one ahead).
- First visible token on each line reads `col_map[i]` and converts to tabs: `tabs = col / 4`.
- INDENT (89) / DEDENT (90) tokens are skipped -- column map handles indentation.
- Spacing is emitted via two lookup tables: `_SPACE_BEFORE` (tokens needing leading space) and `_SPACE_AFTER` (trailing space). Identifiers + literals + annotations + any keyword get a leading space unless preceded by `(`, `[`, `.`, `$`, `~`, `!`, indent, or newline.

Literal token types (strings, nodepaths, vectors, colors, etc.) go through [gdsc_detokenizer.gd:353 `_gdsc_variant_to_source`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L353):

```gdscript
TYPE_STRING      -> '"%s"' % value.c_escape()
TYPE_STRING_NAME -> '&"%s"'
TYPE_NODE_PATH   -> '^"%s"'
TYPE_VECTOR2     -> "Vector2(%s, %s)"
TYPE_COLOR       -> "Color(%s, %s, %s, %s)"
# ...
```

Floats without `.` or `e` in the string form get a `.0` appended so the round-tripped source parses as float, not int.

## Vanilla source cache

The detokenizer caches reconstructed source under `user://modloader_hooks/vanilla/<path>`. Subsequent sessions skip the decode step.

### Why never `load()` during detokenize

Critical comment at [gdsc_detokenizer.gd:395-402](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L395):

> IMPORTANT: do NOT call `load(script_path)` here, not even to "verify" the live script. Any `load()` triggers `ResourceFormatLoaderGDScript` to read the PCK's `.gdc` (via the PCK's stale `.gd.remap`) and cache the tokenized result at `script_path`. Subsequent hook-pack mounts + loads hit that cached entry instead of our rewrite. Cache must stay cold until the hook pack is mounted.

The three-method raw-bytes read ([gdsc_detokenizer.gd:92-114](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L92)) uses `FileAccess` exclusively -- never `ResourceLoader`:

1. `FileAccess.open(script_path, READ)` direct
2. `FileAccess.open(ProjectSettings.globalize_path(script_path), READ)`
3. `FileAccess.get_file_as_bytes(script_path.replace(".gd", ".gdc"))`

### Stale-overlay paranoia check

After detokenizing, [gdsc_detokenizer.gd:419-422](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L419) rejects source containing `_rtv_ready_done` or `Engine.get_meta("RTVModLib"` -- that would mean a prior-session overlay contaminated the input:

```
[Hooks] Detokenized source for <path> already contains rewrite markers
  -- possible stale overlay. Delete <HOOK_PACK_DIR> and restart.
```

## Probe

[gdsc_detokenizer.gd:437 `_probe_gdsc_version`](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L437) reads the first 4 bytes from one of four known-readable vanilla scripts (`Camera.gd`, `Controller.gd`, `Audio.gd`, `AI.gd`), confirms the `"GDSC"` magic, and returns the version byte. Used by [STABILITY canary B](Stability-Canaries#canary-b-gdsc-tokenizer-version) to bail out cleanly on unsupported tokenizer formats.

## Zero-byte entries

Some vanilla `.gd` entries are zero bytes in the base game PCK (e.g. `CasettePlayer.gd` in RTV 4.6.1). Detected during PCK enumeration ([pck_enumeration.gd:214-223](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/pck_enumeration.gd#L214)) and recorded in `_pck_zero_byte_paths`. The detokenizer returns empty silently for these paths ([gdsc_detokenizer.gd:89-90](https://github.com/ametrocavich/vostok-mod-loader/blob/development/src/gdsc_detokenizer.gd#L89)) rather than logging misleading "Cannot read bytes" warnings -- these files can't be hooked regardless.
