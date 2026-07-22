# Changelog

## [3.3.0](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.2.1...v3.3.0) (2026-07-21)


### Features

* add mod dependency declarations ([3ff7a9d](https://github.com/ametrocavich/vostok-mod-loader/commit/3ff7a9d436da57e800ea300227ce0014613890ee))
* dependency UX -- truthful launch, auto-ordering, one-click fixes ([4cf6448](https://github.com/ametrocavich/vostok-mod-loader/commit/4cf64483c0b94e53edfdd2f691396cfc0d18b051))
* godot 4.7 guardrails (v4 pck messaging, detokenizer canary, centralized format versions) ([8a7996e](https://github.com/ametrocavich/vostok-mod-loader/commit/8a7996ecd28f7318d7728ca947a029d3f9ccf1e9))
* link installed mods to their ModWorkshop page from the Mods tab ([5bef644](https://github.com/ametrocavich/vostok-mod-loader/commit/5bef6449c4a96551eddd02fc8975be32f83ecf0d))
* make the modpack create/share flow self-explanatory ([686e8f8](https://github.com/ametrocavich/vostok-mod-loader/commit/686e8f8602152eec6c3484257ddfd6e91db058d7))
* modpack apply safety net (auto restore points + crash-window hardening) ([fc7c145](https://github.com/ametrocavich/vostok-mod-loader/commit/fc7c145f78edb023a3c499d1782adb6ff80f704b))
* name a modpack independently of its source profile ([bd4a580](https://github.com/ametrocavich/vostok-mod-loader/commit/bd4a580443f162eb7fd28b0880dc3f68062e402f))
* offline cached results banner with last-refreshed and retry ([7ff4c28](https://github.com/ametrocavich/vostok-mod-loader/commit/7ff4c28b0ffcd68ac9774db46719620c25a862be))
* plain-language sweep of user-facing copy ([b6c6e0b](https://github.com/ametrocavich/vostok-mod-loader/commit/b6c6e0bbe58acbbb8180908ac6c7ac0b73f56cae))
* provides= rename aliases for mod ids ([7ce5a06](https://github.com/ametrocavich/vostok-mod-loader/commit/7ce5a0620ec284ad3a2adcc435178112590bead8))
* rate-limit aware backoff for ModWorkshop requests ([e646949](https://github.com/ametrocavich/vostok-mod-loader/commit/e646949157808f6ba55276b454ca9d0e947ae74c))
* render mod descriptions as formatted text; fix Browse search sort ([3cb2c6f](https://github.com/ametrocavich/vostok-mod-loader/commit/3cb2c6ffc43e01161956353135d5ffa2d2d89139))
* show ModWorkshop thumbnail, author, and details on Mods-tab rows ([90c5615](https://github.com/ametrocavich/vostok-mod-loader/commit/90c56154213e34dd80b82454284476557c722443))
* skip startup mod manager ([21c0049](https://github.com/ametrocavich/vostok-mod-loader/commit/21c004920c175fec3d6185f8f2b0c3994530b3db))
* **ui:** apply design system across all tabs -- token sweep, de-jank, copy pass ([1f878cd](https://github.com/ametrocavich/vostok-mod-loader/commit/1f878cd7dbddb679317d9e56e939df0cc2818968))
* **ui:** design-token layer + theme coverage (focus, scrollbars, tooltips, progress, checkbox glyphs) ([53612e4](https://github.com/ametrocavich/vostok-mod-loader/commit/53612e4b636f6748b2743b95db34aeccac808d1c))
* **ui:** sweep security-findings dialog onto the design tokens ([f6dce42](https://github.com/ametrocavich/vostok-mod-loader/commit/f6dce424b4c1b601af9aa83d01c05d93c458ce3b))


### Bug Fixes

* apply chunk-2 engine stabilization (verified safe) ([f526365](https://github.com/ametrocavich/vostok-mod-loader/commit/f526365960293df0950544f938a6faf73e3681a3))
* apply stabilization findings (10 confirmed bugs + readability) ([ee5fb8f](https://github.com/ametrocavich/vostok-mod-loader/commit/ee5fb8f7a636aa28b50b96e806a134a79d1c7d3f))
* audit-wave hardening (config persist guard, wildcard hooks, boot/vfs edges, registry read API) ([6789238](https://github.com/ametrocavich/vostok-mod-loader/commit/6789238ba3765911e0d27823b94b48d3cb7cf617))
* chunk-3 stabilization -- 40 verified findings across 21 files ([ee22cbb](https://github.com/ametrocavich/vostok-mod-loader/commit/ee22cbb2411462f899808bc65dcb99ef5c10936c))
* collapse the duplicate window title bar into the header plate ([3e03fdf](https://github.com/ametrocavich/vostok-mod-loader/commit/3e03fdfc0f77521e789b693344a80c38917e4bd6))
* compose discover landing from working list queries ([76c3f3f](https://github.com/ametrocavich/vostok-mod-loader/commit/76c3f3f796a60fefb0d5c8a47d8ea78825da5057))
* critical compile error + .pck downloads + close-mid-download crash ([c22795b](https://github.com/ametrocavich/vostok-mod-loader/commit/c22795b5372fb5aad86c01b16f3d793efb9a659e))
* darken launcher scrim 0.6 -&gt; 0.92 alpha for readability ([573f454](https://github.com/ametrocavich/vostok-mod-loader/commit/573f454d49a1fdfd6774472d3d92aef08d360683))
* dependency PR review follow-ups ([6fe09de](https://github.com/ametrocavich/vostok-mod-loader/commit/6fe09debaffc7894c708972c7f8458188dcaedf2))
* dev-folder restart loop + debounce priority saves ([3e26aaa](https://github.com/ametrocavich/vostok-mod-loader/commit/3e26aaa2563c0c5304b6e6c1002821d850746bc7))
* embed launcher sub-windows so tooltips/popups render on top ([42f85d6](https://github.com/ametrocavich/vostok-mod-loader/commit/42f85d6aac8fa3d35fef34e976dc7f0d173edb28))
* enlarge save-modpack dialog so the name field doesn't hide the description ([363a3de](https://github.com/ametrocavich/vostok-mod-loader/commit/363a3de0579389d8f9bcd677a539536ff8ddfec3))
* final audit pass -- correctness, UX, and consistency fixes ([38e0780](https://github.com/ametrocavich/vostok-mod-loader/commit/38e0780d11decbe2ce31623b877fc2b26feaf20b))
* flow-readiness follow-ups -- null-safe list parsing, unload guard, resource-pack downloads ([55d433d](https://github.com/ametrocavich/vostok-mod-loader/commit/55d433d23d219a6cc40ca38bd5847cec29b121b0))
* flow-readiness round 2 -- broken Browse download queue + filter caret + author key ([cf49992](https://github.com/ametrocavich/vostok-mod-loader/commit/cf499922f8a5c31fddc004198808930e8ee00050))
* flush pending priority edit before switching profiles ([5a8fbcb](https://github.com/ametrocavich/vostok-mod-loader/commit/5a8fbcb041cabe28c41d4e95f602958458eaa458))
* guard all in-place tab rebuilds against re-entrant tab_changed ([037e14c](https://github.com/ametrocavich/vostok-mod-loader/commit/037e14c4b99d6316eea52c8e8f30a464c8434d60))
* harden deferred engine edges + Browse cross-page sort ([aef7c00](https://github.com/ametrocavich/vostok-mod-loader/commit/aef7c0097f585a8c79df2cab7a12568d863b4809))
* harden profile share round-trip (preserve dep_ignore, reject managed-prefix names) ([072e7ac](https://github.com/ametrocavich/vostok-mod-loader/commit/072e7acd2e1b53bda0e904977557a295b9abc063))
* header close-button hint uses status line, not a stranded tooltip ([c8af42d](https://github.com/ametrocavich/vostok-mod-loader/commit/c8af42dd68cbfe4995e533d8736aef8b3efc2fe2))
* keep the mods-list scroll position across tab rebuilds ([552d79f](https://github.com/ametrocavich/vostok-mod-loader/commit/552d79ff7e6b6c1361d060c4a2c8789fb3f15515))
* modpack-state recovery + dependency ordering + download robustness ([a33f5a3](https://github.com/ametrocavich/vostok-mod-loader/commit/a33f5a31fd7442748c9b651ae36f5ef809b88fee))
* modpacks include only enabled mods, not disabled-but-installed ones ([19a38a1](https://github.com/ametrocavich/vostok-mod-loader/commit/19a38a1148ecb786862d755bfe0177d555f65274))
* order-panel hints use the status line, not stranded tooltips ([f780ced](https://github.com/ametrocavich/vostok-mod-loader/commit/f780ced055c5a373a3708405958fd3d7b7faf31c))
* panel-sized dependency messages + ellipsis trimming ([e69fe4d](https://github.com/ametrocavich/vostok-mod-loader/commit/e69fe4d0fc503627ea62d77904dd1e237a8ca54f))
* pin order-panel scrollbar + clip order labels to stop layout oscillation crash ([a7128ca](https://github.com/ametrocavich/vostok-mod-loader/commit/a7128ca75c5a794f7ad9d068cd62b65aac40bfcc))
* post-review hardening for 3.3 (config durability, content-mod save guard, update path, tooltip) ([ca40ea5](https://github.com/ametrocavich/vostok-mod-loader/commit/ca40ea5dada2113b44c1c8af11ba9feb4a69e3d3))
* readiness hardening (restore-point edges, honest apply/cancel, update feedback) ([a3dcc97](https://github.com/ametrocavich/vostok-mod-loader/commit/a3dcc97c475b3c71f8030f8e3e90162c43577c86))
* reopen-path persistence + download timeout ([b375b8d](https://github.com/ametrocavich/vostok-mod-loader/commit/b375b8d24c9354dbe49a5f52c42993155f365029))
* sort Browse search results client-side (MWS ignores sort with a query) ([be05945](https://github.com/ametrocavich/vostok-mod-loader/commit/be05945357533b5386ab7f5e569fc43ce3443fe4))
* type ordered_keys as Array[String] -- untyped loop var breaks := inference on Godot 4.6.2 ([eceb7fb](https://github.com/ametrocavich/vostok-mod-loader/commit/eceb7fb27d92cefd05bdc050e1ddd4fac68874fd))
* **ui:** audit-wave hardening (update flows, browse edges, profile state preservation, restore-point honesty) ([73beffd](https://github.com/ametrocavich/vostok-mod-loader/commit/73beffd8b935fd223a468d511d3bb75f705e85ac))
* untype the cycle-walk stack -- Array[int] assignment from plain Array is a runtime error ([59e5638](https://github.com/ametrocavich/vostok-mod-loader/commit/59e56389f11082f864b347f2fe101d35da492cc9))
* update check uses ?mod_ids[]= query params + chunk-2 discovery fixes ([52d69fb](https://github.com/ametrocavich/vostok-mod-loader/commit/52d69fb930ece7b34c76e478e843414e0ce5ba4c))

## [3.2.1](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.2.0...v3.2.1) (2026-05-05)


### Bug Fixes

* registry follow-ups from PR [#69](https://github.com/ametrocavich/vostok-mod-loader/issues/69) review ([4950cfc](https://github.com/ametrocavich/vostok-mod-loader/commit/4950cfc8999a8185edd42d6768d7d45cf67833f3))

## [3.2.0](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.1.1...v3.2.0) (2026-05-04)


### Features

* profile UX bundle (blank/all profiles, select-all, inactive filter, mass dead-mod cleanup) ([#65](https://github.com/ametrocavich/vostok-mod-loader/issues/65)) ([82a7648](https://github.com/ametrocavich/vostok-mod-loader/commit/82a76482677bb6fe748679ec5f37b44dc13471c2))
* surface modloader version in launcher + self-update check ([#70](https://github.com/ametrocavich/vostok-mod-loader/issues/70)) ([1a82a9b](https://github.com/ametrocavich/vostok-mod-loader/commit/1a82a9b86bf27ef489beaf78192ad8735273f982))


### Bug Fixes

* dedupe same-id mods + auto-enable only on Default profile ([#62](https://github.com/ametrocavich/vostok-mod-loader/issues/62)) ([4faa8e0](https://github.com/ametrocavich/vostok-mod-loader/commit/4faa8e07748cf66b3d35865a68d3932c04a4be65))
* discard stale VMZ cache when source archive is gone ([#58](https://github.com/ametrocavich/vostok-mod-loader/issues/58)) ([172992f](https://github.com/ametrocavich/vostok-mod-loader/commit/172992f91ffc52afa157d773becec78aa60a9c41))
* download update under the server-supplied filename ([#64](https://github.com/ametrocavich/vostok-mod-loader/issues/64)) ([5874698](https://github.com/ametrocavich/vostok-mod-loader/commit/5874698b0eb26681b7dba8dd4fcc41520a569e00))
* **linux-installer:** verify each mv operation lands at destination ([#56](https://github.com/ametrocavich/vostok-mod-loader/issues/56)) ([81df36d](https://github.com/ametrocavich/vostok-mod-loader/commit/81df36d6394b5e21fe0b61dbe674f2ba34cfc311))
* **windows-installer:** [#54](https://github.com/ametrocavich/vostok-mod-loader/issues/54) + two related install-script issues ([#55](https://github.com/ametrocavich/vostok-mod-loader/issues/55)) ([c0a38f1](https://github.com/ametrocavich/vostok-mod-loader/commit/c0a38f169f9d52f36f2cb0887c8ed807c48524a9))

## [3.1.1](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.1.0...v3.1.1) (2026-04-25)


### Bug Fixes

* enumerate vanilla scripts before .hook() prefix merge ([#49](https://github.com/ametrocavich/vostok-mod-loader/issues/49)) ([6623a20](https://github.com/ametrocavich/vostok-mod-loader/commit/6623a20a71bf4fc1f3c2ce789a60ceb11af10114))
* tolerantly parse [hooks] mod.txt + diagnose parse errors ([#50](https://github.com/ametrocavich/vostok-mod-loader/issues/50)) ([3fce1b3](https://github.com/ametrocavich/vostok-mod-loader/commit/3fce1b3960041bda9051b8ca0fcf208cd54dbdd8))

## [3.1.0](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.0.1...v3.1.0) (2026-04-24)


### Features

* Add Scene Nodes registry ([#44](https://github.com/ametrocavich/vostok-mod-loader/issues/44)) ([3973815](https://github.com/ametrocavich/vostok-mod-loader/commit/39738155983041d75fd8499226ce36a4ea6c67c2))
* allow .zip mods to load ([#45](https://github.com/ametrocavich/vostok-mod-loader/issues/45)) ([a64865f](https://github.com/ametrocavich/vostok-mod-loader/commit/a64865f3ff34060c83df112093b1169847ad71b0))
* dynamic launch button label ([#42](https://github.com/ametrocavich/vostok-mod-loader/issues/42)) ([290fc5f](https://github.com/ametrocavich/vostok-mod-loader/commit/290fc5f92c6dc3db1a3ccf16e0dd1aa004739d83))


### Bug Fixes

* preserve rendering-driver across modloader restart ([#41](https://github.com/ametrocavich/vostok-mod-loader/issues/41)) ([6bb3baa](https://github.com/ametrocavich/vostok-mod-loader/commit/6bb3baaf6caf365dffefdb846a884b7ec5ddac71))


### Performance Improvements

* memoize scene_nodes patch validation ([#46](https://github.com/ametrocavich/vostok-mod-loader/issues/46)) ([bcf551d](https://github.com/ametrocavich/vostok-mod-loader/commit/bcf551d69109cf00c3d2700ef4076573ff245459))

## [3.0.1](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.0.0...v3.0.1) (2026-04-23)


### Bug Fixes

* configfile drops empty sections ([91ca590](https://github.com/ametrocavich/vostok-mod-loader/commit/91ca590fea3b5d1de1e69933c9d2ae44362bc986))

## [3.0.0](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.0.1...v3.0.0) (2026-04-23)


### ⚠ BREAKING CHANGES

* mods that relied on v3.0.0's auto-wrap + Step C to have hooks fire without calling super() no longer compose. Migration: call super.method() in overrides or add a [hooks] declaration to mod.txt. See README for the new declaration syntax.

### Features

* chain-via-extends for multi-mod override conflicts ([4240d3e](https://github.com/ametrocavich/vostok-mod-loader/commit/4240d3e68f2b435255346d41335da73f7b75401f))
* **diag:** dev-mode per-method dispatch counter ([f868c9c](https://github.com/ametrocavich/vostok-mod-loader/commit/f868c9c0fd6daf398c99029bb9f5325529c93cf3))
* flag mods with code patterns matching known malware ([#18](https://github.com/ametrocavich/vostok-mod-loader/issues/18)) ([0af39fe](https://github.com/ametrocavich/vostok-mod-loader/commit/0af39fee21f44be54a81da251c23ccd03a9583ec))
* flag mods with code patterns matching known malware ([#18](https://github.com/ametrocavich/vostok-mod-loader/issues/18)) ([e33f59f](https://github.com/ametrocavich/vostok-mod-loader/commit/e33f59fb05382a3d08203461df19623552c56b7f))
* Further registry work ([#26](https://github.com/ametrocavich/vostok-mod-loader/issues/26)) ([15b5b8b](https://github.com/ametrocavich/vostok-mod-loader/commit/15b5b8b9c49be55679a121233be5bc77632294c9))
* opt-in hook declarations, cutover from inference-based wrap ([67a6abd](https://github.com/ametrocavich/vostok-mod-loader/commit/67a6abda9bb44416492fb59264613c1255252dcd))
* **ui:** add mod profiles ([#17](https://github.com/ametrocavich/vostok-mod-loader/issues/17)) ([a370673](https://github.com/ametrocavich/vostok-mod-loader/commit/a37067376a6c87edba7ef1c7993c682234ba0867))
* **ui:** add mod profiles ([#17](https://github.com/ametrocavich/vostok-mod-loader/issues/17)) ([e0801d8](https://github.com/ametrocavich/vostok-mod-loader/commit/e0801d8c444f8601d8dac365e8e51fddeea55eab))
* **ui:** key profiles by mod id + version from mod.txt ([#19](https://github.com/ametrocavich/vostok-mod-loader/issues/19)) ([4fd3053](https://github.com/ametrocavich/vostok-mod-loader/commit/4fd3053f4da9e900f0d3b24110786de7b4a2f438))
* **ui:** key profiles by mod id + version from mod.txt ([#19](https://github.com/ametrocavich/vostok-mod-loader/issues/19)) ([cff56d0](https://github.com/ametrocavich/vostok-mod-loader/commit/cff56d03062a28329ed2a4d15f7ba820c3e637ff))


### Bug Fixes

* fix _caller state getting corrupted by nested wrappers ([#24](https://github.com/ametrocavich/vostok-mod-loader/issues/24)) ([97ec490](https://github.com/ametrocavich/vostok-mod-loader/commit/97ec490c7764ac1d4d07baf5ac3f803f09615f28))
* fix casing handling and dropped const ([#27](https://github.com/ametrocavich/vostok-mod-loader/issues/27)) ([f14e902](https://github.com/ametrocavich/vostok-mod-loader/commit/f14e902a5a63ba2549a27678a4fbe8c47df34266))
* lock profile schema + explicit import manifest ([#30](https://github.com/ametrocavich/vostok-mod-loader/issues/30)) ([5132a0f](https://github.com/ametrocavich/vostok-mod-loader/commit/5132a0f8c27ee83170c6867d1dbd95bec222e282))
* opt-in hook declarations + stability fixes (3.0.1) ([#29](https://github.com/ametrocavich/vostok-mod-loader/issues/29)) ([33e599d](https://github.com/ametrocavich/vostok-mod-loader/commit/33e599dd3dd60bfca1fe2bdb68c23fab86333275))
* per-session hook pack filename to avoid stale VFS offsets ([2a06cf9](https://github.com/ametrocavich/vostok-mod-loader/commit/2a06cf97aa212d4ba14103dfb87936a765005cda))
* preserve return type in wrappers + runtime stale-swap + base() autofix ([2ff7359](https://github.com/ametrocavich/vostok-mod-loader/commit/2ff7359dd8907f9e110ab539c35bac73b2df7f6b))
* release 3.0.1 ([f851f0b](https://github.com/ametrocavich/vostok-mod-loader/commit/f851f0b8d256e5ea763e92ca95d36ce585001cee))
* release rollback ([b346178](https://github.com/ametrocavich/vostok-mod-loader/commit/b34617890f7c6aa4c58256311a02ff1b90271de0))
* stale hook pack ([#23](https://github.com/ametrocavich/vostok-mod-loader/issues/23)) ([f5e9ce8](https://github.com/ametrocavich/vostok-mod-loader/commit/f5e9ce8696c93e6eca2f7ad57184335895ed86ce))


### Performance Improvements

* strip per-call dispatch probe from wrapper template ([9c996da](https://github.com/ametrocavich/vostok-mod-loader/commit/9c996da7021dfa9c0872f021b3e4cf7df7277f80))
* wrap only vanilla scripts mods actually touch ([45aab4d](https://github.com/ametrocavich/vostok-mod-loader/commit/45aab4dd15e250c7042f622917fe25d3b19cdbe9))


### Miscellaneous Chores

* prepare 3.0.0 release ([#20](https://github.com/ametrocavich/vostok-mod-loader/issues/20)) ([2eb75c1](https://github.com/ametrocavich/vostok-mod-loader/commit/2eb75c18c83777c458bf3caea437ac44c44904bf))
* prepare 3.0.0 release ([#20](https://github.com/ametrocavich/vostok-mod-loader/issues/20)) ([208a43c](https://github.com/ametrocavich/vostok-mod-loader/commit/208a43cf830fa039b39aa377d3b1d345c491a54f))

## [3.0.0](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.0.0...v3.0.0) (2026-04-23)


### ⚠ BREAKING CHANGES

* mods that relied on v3.0.0's auto-wrap + Step C to have hooks fire without calling super() no longer compose. Migration: call super.method() in overrides or add a [hooks] declaration to mod.txt. See README for the new declaration syntax.

### Features

* chain-via-extends for multi-mod override conflicts ([4240d3e](https://github.com/ametrocavich/vostok-mod-loader/commit/4240d3e68f2b435255346d41335da73f7b75401f))
* **diag:** dev-mode per-method dispatch counter ([f868c9c](https://github.com/ametrocavich/vostok-mod-loader/commit/f868c9c0fd6daf398c99029bb9f5325529c93cf3))
* flag mods with code patterns matching known malware ([#18](https://github.com/ametrocavich/vostok-mod-loader/issues/18)) ([0af39fe](https://github.com/ametrocavich/vostok-mod-loader/commit/0af39fee21f44be54a81da251c23ccd03a9583ec))
* Further registry work ([#26](https://github.com/ametrocavich/vostok-mod-loader/issues/26)) ([15b5b8b](https://github.com/ametrocavich/vostok-mod-loader/commit/15b5b8b9c49be55679a121233be5bc77632294c9))
* opt-in hook declarations, cutover from inference-based wrap ([67a6abd](https://github.com/ametrocavich/vostok-mod-loader/commit/67a6abda9bb44416492fb59264613c1255252dcd))
* **ui:** add mod profiles ([#17](https://github.com/ametrocavich/vostok-mod-loader/issues/17)) ([a370673](https://github.com/ametrocavich/vostok-mod-loader/commit/a37067376a6c87edba7ef1c7993c682234ba0867))
* **ui:** key profiles by mod id + version from mod.txt ([#19](https://github.com/ametrocavich/vostok-mod-loader/issues/19)) ([4fd3053](https://github.com/ametrocavich/vostok-mod-loader/commit/4fd3053f4da9e900f0d3b24110786de7b4a2f438))


### Bug Fixes

* fix _caller state getting corrupted by nested wrappers ([#24](https://github.com/ametrocavich/vostok-mod-loader/issues/24)) ([97ec490](https://github.com/ametrocavich/vostok-mod-loader/commit/97ec490c7764ac1d4d07baf5ac3f803f09615f28))
* fix casing handling and dropped const ([#27](https://github.com/ametrocavich/vostok-mod-loader/issues/27)) ([f14e902](https://github.com/ametrocavich/vostok-mod-loader/commit/f14e902a5a63ba2549a27678a4fbe8c47df34266))
* lock profile schema + explicit import manifest ([#30](https://github.com/ametrocavich/vostok-mod-loader/issues/30)) ([5132a0f](https://github.com/ametrocavich/vostok-mod-loader/commit/5132a0f8c27ee83170c6867d1dbd95bec222e282))
* opt-in hook declarations + stability fixes (3.0.1) ([#29](https://github.com/ametrocavich/vostok-mod-loader/issues/29)) ([33e599d](https://github.com/ametrocavich/vostok-mod-loader/commit/33e599dd3dd60bfca1fe2bdb68c23fab86333275))
* per-session hook pack filename to avoid stale VFS offsets ([2a06cf9](https://github.com/ametrocavich/vostok-mod-loader/commit/2a06cf97aa212d4ba14103dfb87936a765005cda))
* preserve return type in wrappers + runtime stale-swap + base() autofix ([2ff7359](https://github.com/ametrocavich/vostok-mod-loader/commit/2ff7359dd8907f9e110ab539c35bac73b2df7f6b))
* stale hook pack ([#23](https://github.com/ametrocavich/vostok-mod-loader/issues/23)) ([f5e9ce8](https://github.com/ametrocavich/vostok-mod-loader/commit/f5e9ce8696c93e6eca2f7ad57184335895ed86ce))


### Performance Improvements

* strip per-call dispatch probe from wrapper template ([9c996da](https://github.com/ametrocavich/vostok-mod-loader/commit/9c996da7021dfa9c0872f021b3e4cf7df7277f80))
* wrap only vanilla scripts mods actually touch ([45aab4d](https://github.com/ametrocavich/vostok-mod-loader/commit/45aab4dd15e250c7042f622917fe25d3b19cdbe9))


### Miscellaneous Chores

* prepare 3.0.0 release ([#20](https://github.com/ametrocavich/vostok-mod-loader/issues/20)) ([2eb75c1](https://github.com/ametrocavich/vostok-mod-loader/commit/2eb75c18c83777c458bf3caea437ac44c44904bf))

## [3.0.0](https://github.com/ametrocavich/vostok-mod-loader/compare/v2.3.1...v3.0.0) (2026-04-20)


### Features

* flag mods with code patterns matching known malware ([#18](https://github.com/ametrocavich/vostok-mod-loader/issues/18)) ([e33f59f](https://github.com/ametrocavich/vostok-mod-loader/commit/e33f59fb05382a3d08203461df19623552c56b7f))
* **ui:** add mod profiles ([#17](https://github.com/ametrocavich/vostok-mod-loader/issues/17)) ([e0801d8](https://github.com/ametrocavich/vostok-mod-loader/commit/e0801d8c444f8601d8dac365e8e51fddeea55eab))
* **ui:** key profiles by mod id + version from mod.txt ([#19](https://github.com/ametrocavich/vostok-mod-loader/issues/19)) ([cff56d0](https://github.com/ametrocavich/vostok-mod-loader/commit/cff56d03062a28329ed2a4d15f7ba820c3e637ff))


### Miscellaneous Chores

* prepare 3.0.0 release ([#20](https://github.com/ametrocavich/vostok-mod-loader/issues/20)) ([208a43c](https://github.com/ametrocavich/vostok-mod-loader/commit/208a43cf830fa039b39aa377d3b1d345c491a54f))
