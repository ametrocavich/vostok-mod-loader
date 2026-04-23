# Changelog

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
