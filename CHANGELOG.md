# Changelog

## [3.4.2](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.4.1...v3.4.2) (2026-10-06)


Fixes for Vostok Mods modpacks, Browse covers, settings recovery, updates, the launcher and the registry, plus a launcher skip for external mod managers.

### Bug Fixes

* **modpacks:** Vostok Mods packs apply with their mods enabled: installed mods are matched by slug, UUID or the pack's checksum, and **Get from Vostok Mods** lists packs again ([333f3cf](https://github.com/ametrocavich/vostok-mod-loader/commit/333f3cf48ac0c197c24b650fc477f7d7214f0d4e))
* **browse:** animated WebP covers show their first frame, and covers up to 8 MB load ([d02d15f](https://github.com/ametrocavich/vostok-mod-loader/commit/d02d15f3d6e2b21932cfcb5c628b0c2fc870c169))
* **config:** an empty `mod_config.cfg` is recovered from its backup instead of losing every profile ([f2bb7d1](https://github.com/ametrocavich/vostok-mod-loader/commit/f2bb7d180e157586691464327d6a5c963175db59))
* **launcher:** the title-bar drag keeps the window on screen above 1920x1080, clicks beside it no longer reach the main menu, and `--modloader-skip-ui` or a `modloader_skip_ui_once` file skips it for external mod managers ([b4f7c21](https://github.com/ametrocavich/vostok-mod-loader/commit/b4f7c21fa072a0feec6e04b2b59c303925bb50f8))
* **updates:** a locked `.zip`/`.pck` says to disable the mod and relaunch, and a download naming another mod id no longer replaces the mod ([aa6581b](https://github.com/ametrocavich/vostok-mod-loader/commit/aa6581be9a38620bc06bcf546952727ad7090bf2))
* **registry:** a `scene_paths` override of a vanilla scene loads the mod scene and keeps that scene's flags, and `sounds` clips play ([2dc5e39](https://github.com/ametrocavich/vostok-mod-loader/commit/2dc5e39ec5bd45780c2f0b6f9fb79230a47f7758))
* **hooks:** a stale hook pack is no longer mounted after the last hooking mod is disabled, and deferred scripts no longer get a false "rewrite wins" warning ([b99222a](https://github.com/ametrocavich/vostok-mod-loader/commit/b99222a2c75b81ccceffc58082c4ec892abe38dd))
* **scanner:** the malware scan reads binary `.scn`/`.res` files past their header ([47a7f73](https://github.com/ametrocavich/vostok-mod-loader/commit/47a7f734c4b0646179f3551e32cb464e5562ec8a))

## [3.4.1](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.4.0...v3.4.1) (2026-09-30)


Road to Vostok Build 2 ("Nomads") support. First stable release since 3.2.1; 3.3.0, 3.3.1 and 3.4.0 were pre-releases.

### Bug Fixes

* **registry:** follow Build 2's AI variants and AISpawner `enemy =` assignments, so `ai_loadouts` and `ai_types` work again ([b43ee6e](https://github.com/ametrocavich/vostok-mod-loader/commit/b43ee6ec3031bfab3d23fde2ee4fbb922eb9b96e))
* **registry:** know Build 2's traders (Driver, Hunter), loot tables and class names ([0de50e8](https://github.com/ametrocavich/vostok-mod-loader/commit/0de50e8501ec76a00625b78497d2969180302c2b))
* **registry:** list the current sound names when a sounds call is refused ([627a2bf](https://github.com/ametrocavich/vostok-mod-loader/commit/627a2bf576c1a71866843ff9f91fbf82f25904bd))
* **hooks:** report a declared method the game removed on a registry target ([fd0d576](https://github.com/ametrocavich/vostok-mod-loader/commit/fd0d5763a2c98bd08de24655af8995f1fee170ef))
* **vostokmods:** read the site's current API (listing `entries`, taxonomies, `ownerDisplayName`, UUID mod ids) and show mods installed from the site as installed ([48de247](https://github.com/ametrocavich/vostok-mod-loader/commit/48de247ab82147ab84226d858921b6a5a3711fd4))
* **ui:** drop the game-updated notice banner ([48953cc](https://github.com/ametrocavich/vostok-mod-loader/commit/48953ccfe8612dda7063828897e1ccd92314b44e))
* **ui:** wrap long banner messages ([6bfafb3](https://github.com/ametrocavich/vostok-mod-loader/commit/6bfafb3b2f880429f62e8ca705ff8d4e9539221d))

## [3.4.0](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.3.1...v3.4.0) (2026-09-29)


### Features

* **boot:** tell the player in the launcher when hooks stopped working ([eb4e421](https://github.com/ametrocavich/vostok-mod-loader/commit/eb4e4218a0cc4c8e8811c5c426d352147357be76))
* **browse:** hide the loader's own listing on every host ([b8a242e](https://github.com/ametrocavich/vostok-mod-loader/commit/b8a242e33cce8302d2ac271c6d855dab02d94cce))
* **hooks:** probe-compile rewrites before packing them ([065bfaf](https://github.com/ametrocavich/vostok-mod-loader/commit/065bfaf498b814c7e1790ed8d8d36202253364df))
* **host:** add the mod-host provider seam ([475d13f](https://github.com/ametrocavich/vostok-mod-loader/commit/475d13f4304cd4ed1cd83f507986328e2f10ab2f))
* **host:** drop the Nexus link-out adapter ([e90a849](https://github.com/ametrocavich/vostok-mod-loader/commit/e90a849b879cae306a37477ee34fbfc335a1124b))
* **host:** make the install path host-neutral ([73cab35](https://github.com/ametrocavich/vostok-mod-loader/commit/73cab35124d1d2545aa126f37489fb7bdf53b54b))
* **host:** provider-qualified sources and a Nexus link-out adapter ([1a78227](https://github.com/ametrocavich/vostok-mod-loader/commit/1a78227b7985d37b85f724d8f5ff5c224e3b054d))
* make VostokMods the default host and add hosted modpacks (beta) ([e5e55b6](https://github.com/ametrocavich/vostok-mod-loader/commit/e5e55b64a5801e46c80735b353eb907064d4fa12))
* make VostokMods the default host and add hosted modpacks (beta) ([faa8462](https://github.com/ametrocavich/vostok-mod-loader/commit/faa84624d51f5f6450e92bcd3f341d518a246146))
* **modpacks:** keep packs from VostokMods only ([3aa1416](https://github.com/ametrocavich/vostok-mod-loader/commit/3aa1416f8aa76cedf7ac6174e846eb342248bb24))
* **modpacks:** pull packs published on VostokMods ([f2bff9d](https://github.com/ametrocavich/vostok-mod-loader/commit/f2bff9d14474b19c6ad72af764a6bea12bea7c5f))
* **mods:** open the mod page for link-out hosts from the Mods row ([1ab7073](https://github.com/ametrocavich/vostok-mod-loader/commit/1ab70739a0d926d81fb0d0854497390c6629d3f2))
* **ui:** describe the visible tab in the bottom-bar hint ([bea989f](https://github.com/ametrocavich/vostok-mod-loader/commit/bea989fe653f72521b405ce02948b63489a1345f))
* **ui:** fold the Updates tab into the Mods tab ([ec86607](https://github.com/ametrocavich/vostok-mod-loader/commit/ec8660704acafd55f086e756a84501e97f63edec))
* **ui:** move the Browse tab and Mods-tab meta onto the host seam ([38a5b5b](https://github.com/ametrocavich/vostok-mod-loader/commit/38a5b5b3849d5b7069a06d50ef58aaf8638e318c))
* **ui:** show mod author notes only in developer mode ([4173a78](https://github.com/ametrocavich/vostok-mod-loader/commit/4173a78611be62430ff28b60a04ddb437f97525e))
* **ui:** show scanner results as a tag only ([d08678a](https://github.com/ametrocavich/vostok-mod-loader/commit/d08678aaf7c1d7d5bae2c93481ce371b7a96b05a))
* **updates:** run update checks and downloads through the host seam ([7ea4fc5](https://github.com/ametrocavich/vostok-mod-loader/commit/7ea4fc59efd41393a3cba952a664e700014fdc55))
* **vostokmods:** implement the full API ([4f778e0](https://github.com/ametrocavich/vostok-mod-loader/commit/4f778e0fcdc3af6ef1b129b3bd291af244764882))


### Bug Fixes

* **api:** keep a batch running past a value of the wrong type ([206e8e6](https://github.com/ametrocavich/vostok-mod-loader/commit/206e8e6bad6f6456de8ee4bc8f1790b70da442d6))
* **api:** read a v-prefixed version in has_mod ([36d79ae](https://github.com/ametrocavich/vostok-mod-loader/commit/36d79ae86688a7ab65e7c6781dc67cdf13f93462))
* **boot:** detect a game update through the PCK as well as the exe ([99e7da2](https://github.com/ametrocavich/vostok-mod-loader/commit/99e7da2613caac92e6cc23586c1112035b1c0c36))
* **boot:** do not follow a link when deleting a folder tree ([6a2845d](https://github.com/ametrocavich/vostok-mod-loader/commit/6a2845d76a5e98c31a0e4fe2d7db8970ef9099db))
* **boot:** fold the load order into the state hash ([fac4a31](https://github.com/ametrocavich/vostok-mod-loader/commit/fac4a31684aa1e323e877b2a97d531d5ccc2851a))
* **boot:** log which step of an override.cfg write failed ([bc00d34](https://github.com/ametrocavich/vostok-mod-loader/commit/bc00d3448a187b3ef652e7ca322eb3b64af9ada3))
* **boot:** make the crash-loop breaker work ([9314809](https://github.com/ametrocavich/vostok-mod-loader/commit/9314809beb5eb11dfc3f0ee470180de5957eb302))
* **boot:** only mount the test pack when the test flag is on ([abf0765](https://github.com/ametrocavich/vostok-mod-loader/commit/abf076554a4d208831ff38341cf78874e1e48273))
* **boot:** read an unquoted mod.txt version in the state hash ([a26efd5](https://github.com/ametrocavich/vostok-mod-loader/commit/a26efd5dd482715c45aea93cb2b2fb74fc7e00f6))
* **boot:** read pass state defensively, and stop mounting a deleted folder mod ([a491c88](https://github.com/ametrocavich/vostok-mod-loader/commit/a491c8839f5d3a1e0453b8e0895775ff2568af7b))
* **boot:** restart when nothing is enabled but the old set is mounted ([3964a49](https://github.com/ametrocavich/vostok-mod-loader/commit/3964a49b9a93eaa2db719847cdd6646256f5acf5))
* **boot:** stop unmodded restarts when cleanup fails ([742157c](https://github.com/ametrocavich/vostok-mod-loader/commit/742157c8a2704e87a51f038665f8c9ad54050e17))
* **browse:** clear the list when the host, sort or category changes ([65c1f16](https://github.com/ametrocavich/vostok-mod-loader/commit/65c1f1683811022fa958250db32a6d1041383f5c))
* **browse:** expose the profile toggle after a download ([693f51b](https://github.com/ametrocavich/vostok-mod-loader/commit/693f51b59e69d0d59aa36b3fb2d2a9c57f07fb69))
* **browse:** keep ModWorkshop behavior the seam migration had changed ([ed73e95](https://github.com/ametrocavich/vostok-mod-loader/commit/ed73e95f250547b3f82a9cc0ff19062964a3a1b1))
* **browse:** keep the loaded pages after a successful download ([7dad8af](https://github.com/ametrocavich/vostok-mod-loader/commit/7dad8af36331dd494e393d8011abae8b82de0fdf))
* **browse:** no Download button when the host has no file ([655aed9](https://github.com/ametrocavich/vostok-mod-loader/commit/655aed9ca5774de8aac0afeb42cb895483134fe8))
* **browse:** say when part of the landing page failed to load ([b7bb3f8](https://github.com/ametrocavich/vostok-mod-loader/commit/b7bb3f8a8d99532c324946dd28c69523c448fae0))
* **browse:** sync a mod's other row when its checkbox is toggled ([f7ced8f](https://github.com/ametrocavich/vostok-mod-loader/commit/f7ced8f3f86238d2a39d4597b309360f068ea1e2))
* **config:** let a missing mod_config.cfg recover from its backup ([ed9bda6](https://github.com/ametrocavich/vostok-mod-loader/commit/ed9bda6c581e04b20d36e432af4d2248cfd10d30))
* **config:** remove state left behind by removed features ([50bed3e](https://github.com/ametrocavich/vostok-mod-loader/commit/50bed3e606295c9391360e69bce0ad82169d7ffb))
* **detok:** reach the .gdc fallback when the .gd path does not open ([216f073](https://github.com/ametrocavich/vostok-mod-loader/commit/216f07365dc5266c52e33f8c0b036eb08db12a47))
* **detok:** read vanilla scripts from the game's PCK, never from a mounted mod ([bdca465](https://github.com/ametrocavich/vostok-mod-loader/commit/bdca4653d9841bd8404b96bc196fa5d9eb8dbd49))
* **discovery:** don't read a space plus a number as a version ([b92a32e](https://github.com/ametrocavich/vostok-mod-loader/commit/b92a32e9ca6a521cca592d04899df511a0f5a6d0))
* **discovery:** warn on skipped and unidentifiable mods ([56f316d](https://github.com/ametrocavich/vostok-mod-loader/commit/56f316d77004945090a628e784bb94cee6975b7a))
* **downloads:** say when a file is over the download size limit ([9b9ecbd](https://github.com/ametrocavich/vostok-mod-loader/commit/9b9ecbd85df32a0dd47e9c8359322570783d1991))
* early-autoload guard, scan budget, and the not-scanned dialog ([d6055af](https://github.com/ametrocavich/vostok-mod-loader/commit/d6055afc874f703cb8dbb658f227faf5e90ffde9))
* four small launcher and seam guards ([e8f3638](https://github.com/ametrocavich/vostok-mod-loader/commit/e8f3638cc0ea071196d6f650610dec22571d6eab))
* **fs:** refuse traversal through linked delete roots and ancestors ([8a884ea](https://github.com/ametrocavich/vostok-mod-loader/commit/8a884ea39b3029b2ce7e65f109763aa73a879c98))
* **hooks:** correct the override displacement warning ([b609ce1](https://github.com/ametrocavich/vostok-mod-loader/commit/b609ce1c36a556d4bfc2794a34c9abd9cba7c96f))
* **hooks:** count a script declared two ways once in the wrap surface ([f595b88](https://github.com/ametrocavich/vostok-mod-loader/commit/f595b88dbfb0233cbb85b428b5248b977249dba6))
* **hooks:** do not count a stale script that failed to refresh as active ([e77f86b](https://github.com/ametrocavich/vostok-mod-loader/commit/e77f86bf67ebcee6bf2362674c674e38cc6a76ef))
* **hooks:** keep deferred scripts out of the persisted wrapped-path list ([e73aa29](https://github.com/ametrocavich/vostok-mod-loader/commit/e73aa291842c8d7e4a32245694f7b47b9a42cff8))
* **hooks:** keep hooks an early autoload registered before mods load ([708fb84](https://github.com/ametrocavich/vostok-mod-loader/commit/708fb84c722fec3aa0cccb366d047903fc82796b))
* **hooks:** keep the override-displacement warning on Pass 2 ([5f7642b](https://github.com/ametrocavich/vostok-mod-loader/commit/5f7642b8269174a8cabd5d732d13a431374b7a82))
* **hooks:** let canary C pass on any well-formed probe ([f6152b4](https://github.com/ametrocavich/vostok-mod-loader/commit/f6152b4eb319d148fd5c6f24797d616f321fc93a))
* **hooks:** name the mods behind a lost registry target ([2204b68](https://github.com/ametrocavich/vostok-mod-loader/commit/2204b68dc4019d50da2aa40dbcb0bc7872664be9))
* **hooks:** record a hook pack that could not be written or mounted ([ad59c85](https://github.com/ametrocavich/vostok-mod-loader/commit/ad59c85279795a4772b73c4b79b6a3e7dc15b2b9))
* **hooks:** register the RTVModLib meta before early autoloads run ([ae74369](https://github.com/ametrocavich/vostok-mod-loader/commit/ae7436956609eb2ec6462bf941051b411dbc4674))
* **hooks:** unhook a callback whose owner was freed ([bb34739](https://github.com/ametrocavich/vostok-mod-loader/commit/bb347390e594f42d4ee7c42189dec9eab4455a45))
* **host:** arm a cooldown on any 429 and read Retry-After as seconds ([8ff5add](https://github.com/ametrocavich/vostok-mod-loader/commit/8ff5add0239ef585836914cbe1b80a0cd6e9ca8a))
* **host:** honor a row limit on the ModWorkshop listing ([32f072e](https://github.com/ametrocavich/vostok-mod-loader/commit/32f072eba1e4bdeb188f801633f0da499b3f0dec))
* **host:** read a null ModWorkshop field as empty ([79dda5c](https://github.com/ametrocavich/vostok-mod-loader/commit/79dda5cab7453a3937b7899011ecbd86044f2e9e))
* **installer:** accept a quoted path and clean a stale autoload entry ([fc592cb](https://github.com/ametrocavich/vostok-mod-loader/commit/fc592cbfd842e1ce4036aa3605bc4b51bd380d91))
* **launcher:** report export failures, warn on bad sources, allow non-ASCII names ([1e2ad33](https://github.com/ametrocavich/vostok-mod-loader/commit/1e2ad33051bc8fd0453f7998384cf7960b2770cf))
* **launcher:** show delete errors, clear active_modpack on apply abort ([1cd87df](https://github.com/ametrocavich/vostok-mod-loader/commit/1cd87df31a7b592162557cb19fe34aa7afc2c7db))
* **modpacks:** abort apply when the settings reload fails ([cf3547e](https://github.com/ametrocavich/vostok-mod-loader/commit/cf3547eef0969b3aa908a77a7e913b0ae5de8607))
* **modpacks:** call a pack with no format version damaged, not newer ([60e6a9d](https://github.com/ametrocavich/vostok-mod-loader/commit/60e6a9db1cb7a8b5bf1eca3da72689e70079fd02))
* **modpacks:** export the download source recorded at install time ([b20ef74](https://github.com/ametrocavich/vostok-mod-loader/commit/b20ef746f8651498461c5782340292f615b22a7c))
* **modpacks:** honor version pins during apply and reconciliation ([8322a1c](https://github.com/ametrocavich/vostok-mod-loader/commit/8322a1cd89b22f58244bf2a6473153647e50ceb6))
* **modpacks:** invalidate kept slots on every changed hosted import ([f496db4](https://github.com/ametrocavich/vostok-mod-loader/commit/f496db46c11248b0cbeddff53d8e3e8076022043))
* **modpacks:** keep hosted packs with non-Latin names and show refusal reasons ([53c041b](https://github.com/ametrocavich/vostok-mod-loader/commit/53c041b7f71855d3091b385587f147dac2d28070))
* **modpacks:** keep the Added confirmation after a pasted pack link ([5fe1189](https://github.com/ametrocavich/vostok-mod-loader/commit/5fe118947f7cb5fb2f22159132f912773168b810))
* **modpacks:** keep the apply preview read-only and count real downloads ([c69cf8d](https://github.com/ametrocavich/vostok-mod-loader/commit/c69cf8ddf703b9743eb64e0bc94b8619e0dcd6f6))
* **modpacks:** leave no pack MCM behind when the player had none ([3125b29](https://github.com/ametrocavich/vostok-mod-loader/commit/3125b295f820b9ccc30959f1c95bde89554a5395))
* **modpacks:** preserve unconsumed files when unloading a pack ([7a8229b](https://github.com/ametrocavich/vostok-mod-loader/commit/7a8229b065b2a6ac6c1d923cf9f726f33b829dde))
* **modpacks:** rebuild a pack's slot after Refresh rewrote its zip ([2908c89](https://github.com/ametrocavich/vostok-mod-loader/commit/2908c8950a8b6be26399b915792746f0763c1627))
* **modpacks:** reconcile pack keys on every path a mod can land ([bb17b62](https://github.com/ametrocavich/vostok-mod-loader/commit/bb17b62870116f38145b0ecd8531d12c29d78613))
* **modpacks:** reconcile pack keys with the installed mods ([e4f7b35](https://github.com/ametrocavich/vostok-mod-loader/commit/e4f7b35a2641106c39951601bd2d2c73b1842165))
* **modpacks:** report a failed apply as failed, not as partial ([f60c916](https://github.com/ametrocavich/vostok-mod-loader/commit/f60c916a22c297d27d713f9c2f871dfd2e9d4a9f))
* **modpacks:** return the apply shape from every apply failure ([23e9be2](https://github.com/ametrocavich/vostok-mod-loader/commit/23e9be2f469efcbdff38108826b37cf3e5521d71))
* **mods:** name the broken mod.txt line after a multi-line value ([efd4e6e](https://github.com/ametrocavich/vostok-mod-loader/commit/efd4e6ea64bf818ab68131953bc5c0def2446f52))
* **mods:** report a bare mod.txt section the loader does not know ([f8ae201](https://github.com/ametrocavich/vostok-mod-loader/commit/f8ae201b4d5b72e56876fc994be57b99f09c9627))
* **mount:** stop loading .remap targets when an archive mounts ([bf01b84](https://github.com/ametrocavich/vostok-mod-loader/commit/bf01b846073d7f3bca582b57fee0321eebde3522))
* null crashes in registry aggregators and setup plans, seam hardening ([0cf87ab](https://github.com/ametrocavich/vostok-mod-loader/commit/0cf87ab322692ca4edac6712d8cc7d4c52b9733f))
* **overrides:** report script overrides in developer mode only ([48f90fe](https://github.com/ametrocavich/vostok-mod-loader/commit/48f90fe76517ed7baaaa31c5796006bc309892b8))
* **profiles:** do not restart the game over a profile rename or copy ([646060c](https://github.com/ametrocavich/vostok-mod-loader/commit/646060c765e2aee84051243eed3584e23e0d9e07))
* **profiles:** drop the key a re-packaged mod leaves under its old name ([2f00e5b](https://github.com/ametrocavich/vostok-mod-loader/commit/2f00e5b745bfdd75c5f8c12cee9b8926ed22dd2c))
* **profiles:** land on the active pack's slot when the profile is gone ([c868c2f](https://github.com/ametrocavich/vostok-mod-loader/commit/c868c2ffcb1527a1bc5452ce7a6d4d259df3275e))
* **profiles:** restart for a new profile that changes the selection ([e5feb92](https://github.com/ametrocavich/vostok-mod-loader/commit/e5feb925d77c3af8fb614183eb66608273e017c4))
* **profiles:** stop a priority leaking from one profile into the next ([fd35ab3](https://github.com/ametrocavich/vostok-mod-loader/commit/fd35ab3c15f0dee811d34aaa7f026da76556adf3))
* **registry:** apply and restore the real deadzone of an input action ([92e8e04](https://github.com/ametrocavich/vostok-mod-loader/commit/92e8e0436b068d603fef6089727cea3cc67633cf))
* **registry:** keep a registration whose handle an override reused ([b664e3c](https://github.com/ametrocavich/vostok-mod-loader/commit/b664e3c067898f7508704b39a57bbecb4fb4f6b2))
* **registry:** put a patched or overridden input action back whole ([20e71fe](https://github.com/ametrocavich/vostok-mod-loader/commit/20e71fe527903b84f5f7dbcf5f8d08ac9a1ef0eb))
* **registry:** read a scene-path override and check a patched path ([906b683](https://github.com/ametrocavich/vostok-mod-loader/commit/906b68332a0ad0e6e333d355438e82f93195fe85))
* **registry:** refuse a shelter registration when the Loader rewrite is absent ([a78d27d](https://github.com/ametrocavich/vostok-mod-loader/commit/a78d27d05a538e39addf71fe9e8cda5b7dc7de16))
* **registry:** refuse array ops on maps with the message its peers get ([18c0e76](https://github.com/ametrocavich/vostok-mod-loader/commit/18c0e7630fcbb31b2222dd6655b0a3d2327bd501))
* **registry:** refuse to remove a scene that carries an override ([a12d304](https://github.com/ametrocavich/vostok-mod-loader/commit/a12d304675be94bfc5bf2bca4ee8700a27609848))
* **registry:** report false when a scene_nodes revert did nothing ([841e179](https://github.com/ametrocavich/vostok-mod-loader/commit/841e179096eb94a5ea12cb545b4aeab03a00cd56))
* **registry:** revert a patch onto the entry it changed ([f65fb37](https://github.com/ametrocavich/vostok-mod-loader/commit/f65fb370ba6e08600019914cc638409d3398a425))
* **release:** build in CI and publish releases only after assets upload ([e94670b](https://github.com/ametrocavich/vostok-mod-loader/commit/e94670b95cfbcc826121268615d92881b962fabe))
* **rewriter:** distinguish literal delimiters from code and comments ([3074abb](https://github.com/ametrocavich/vostok-mod-loader/commit/3074abb7f93b9bf452124c9b55df572e7706b6d9))
* **rewriter:** leave a valid Godot 4 script alone in the legacy autofix ([34f9d9a](https://github.com/ametrocavich/vostok-mod-loader/commit/34f9d9a523d0c2d64f808bd18c53a98d370187f3))
* **rewriter:** preserve calls to inherited base methods ([f3c8853](https://github.com/ametrocavich/vostok-mod-loader/commit/f3c88533929fd87914ebc91e7dc589f9a1d4f65c))
* **rewriter:** retain method scope across literal terminators ([83b38e3](https://github.com/ametrocavich/vostok-mod-loader/commit/83b38e39b6fb0e5437b767ef048986aa2c64118d))
* **security,host:** show unscanned mods, reject null ids, ignore poc/ ([4b9b468](https://github.com/ametrocavich/vostok-mod-loader/commit/4b9b468473464427af502b6998cd20c716f01a81))
* **security:** report compiled scripts as unscanned instead of clean ([46f523f](https://github.com/ametrocavich/vostok-mod-loader/commit/46f523fb067cb99bb56360c3b3b683ca592f7b92))
* **setup:** read a when-predicate's return by the documented rules ([be0f839](https://github.com/ametrocavich/vostok-mod-loader/commit/be0f8392f4810ef2f9f589811dab4a7324f7f596))
* **sources:** keep a download's host over a legacy modworkshop= line ([83d756a](https://github.com/ametrocavich/vostok-mod-loader/commit/83d756adf554a2771f765e4d3493cb0a4052db5a))
* **ui:** do not say a mod cannot update when a legacy line rescues it ([8545799](https://github.com/ametrocavich/vostok-mod-loader/commit/85457993ede87dbdf0462a80ea46a622f3b1e0a9))
* **ui:** give the real reason an update check found nothing ([970b0c3](https://github.com/ametrocavich/vostok-mod-loader/commit/970b0c34d8a7cbedc2a5e47da1b5357afb87071a))
* **ui:** give warnings their own color ([6e701ca](https://github.com/ametrocavich/vostok-mod-loader/commit/6e701ca4bdb57d57dcdb50c6d6b3df008396d04d))
* **ui:** keep the active profile when developer mode is toggled ([7f0f650](https://github.com/ametrocavich/vostok-mod-loader/commit/7f0f6509ffd96480ac1816eb65c44a0c8cfacafe))
* **ui:** keep the black floor under the launcher panels ([ff31989](https://github.com/ametrocavich/vostok-mod-loader/commit/ff319891ebec4ba56e10095a6a78e2743658e184))
* **ui:** make the launcher window opaque ([378784c](https://github.com/ametrocavich/vostok-mod-loader/commit/378784c372c9d840b17539f20336ca839272c38d))
* **ui:** never show a modpack slot's internal profile key ([fab68ab](https://github.com/ametrocavich/vostok-mod-loader/commit/fab68abe1cf2ee49d0efc8b153adbc2344c73803))
* **ui:** restart when a download changes the mod set after boot ([4306077](https://github.com/ametrocavich/vostok-mod-loader/commit/43060774ce9c27389b840b7c8a088ab854295dea))
* **ui:** stop a Mods row saying "loading..." during a host cooldown ([28d3c8f](https://github.com/ametrocavich/vostok-mod-loader/commit/28d3c8faefb23313e59f773bd616cb42f02b7e37))
* **ui:** tell a loading thumbnail apart from a missing one ([f57c4a2](https://github.com/ametrocavich/vostok-mod-loader/commit/f57c4a2c43a7f1fa2531f478b6b9838e8e44f898))
* **ui:** warn on a developer folder whose mod.txt does not parse ([52e747b](https://github.com/ametrocavich/vostok-mod-loader/commit/52e747b905f848b5b81c274282899bc4d7731833))
* **updates:** allow an update whose file name changes only in case ([6cc244b](https://github.com/ametrocavich/vostok-mod-loader/commit/6cc244bf2397776dbb34cf7be7c0ac3a33633dbf))
* **updates:** keep a leftover .bak until the new download has landed ([b6dec1e](https://github.com/ametrocavich/vostok-mod-loader/commit/b6dec1edbe371eb3117e2a7fb140f9bfcff8fc63))
* **updates:** rank a prerelease below its own release ([aa454d2](https://github.com/ametrocavich/vostok-mod-loader/commit/aa454d21ea597e129bbb0a2dfa9c38756a545b91))
* **vostokmods:** follow the API's newestFile sort and latestVersion field ([87ff886](https://github.com/ametrocavich/vostok-mod-loader/commit/87ff8866e866d2ddcf31ce3cdde3c124b98d9d8d))

## [3.3.1](https://github.com/ametrocavich/vostok-mod-loader/compare/v3.3.0...v3.3.1) (2026-07-26)


### Bug Fixes

* 3.3.1 -- rendering, flow, and error-message fixes ([64f3bcd](https://github.com/ametrocavich/vostok-mod-loader/commit/64f3bcd98f6e22f450216dad90d5d1e10dda9bb6))
* 3.3.1 -- repair the 3.3.0 hook regression, and make it untestable-no-more ([91c14c8](https://github.com/ametrocavich/vostok-mod-loader/commit/91c14c850b8e05eeb739e73c997dc6fe5e236d07))
* 3.3.1 issue sweep -- rebuild perf, thumbnails, Browse, Updates, modpacks ([f738e2e](https://github.com/ametrocavich/vostok-mod-loader/commit/f738e2e8e0eb55f74524116c112f4e5f1f7d6335))
* a second instance of the 3.3.0 coroutine bug, plus startup cost ([af3ee52](https://github.com/ametrocavich/vostok-mod-loader/commit/af3ee526fe0ef4d7bf6aa3a8eed71445196543dc))
* dev-mode folder mods mount at res:// root, like the shipped zip ([3fde97a](https://github.com/ametrocavich/vostok-mod-loader/commit/3fde97afa173b8c71233bc791345794468030c9c))
* don't make every wrapped vanilla method a coroutine ([0476e6c](https://github.com/ametrocavich/vostok-mod-loader/commit/0476e6c692b14e67ae3534e3ba430b21d2796a4b))
* final pre-release pass -- repair two bugs this cycle introduced ([226bb63](https://github.com/ametrocavich/vostok-mod-loader/commit/226bb63073cca857507f57a6f8a110fdcbfe04fb))
* hardening sweep -- data loss, path traversal, and poisoned caches ([7947bcf](https://github.com/ametrocavich/vostok-mod-loader/commit/7947bcf0f7d0b69ec374a236b674d643d2cb7982))
* honest transport errors, API hardening, and UI clipping polish ([2170bb9](https://github.com/ametrocavich/vostok-mod-loader/commit/2170bb99cd36d7acd0d54fb621fc6e17b1c89720))
* make wrong autoload paths visible, and correct the packaging docs ([c4c2332](https://github.com/ametrocavich/vostok-mod-loader/commit/c4c23322d9599ff3a2d4a9da6bf013e060c7731c))
* prove declared hooks actually got wrapped, and cut per-launch work ([82b816f](https://github.com/ametrocavich/vostok-mod-loader/commit/82b816f8f38ed3d5ab32597e8350bee7a221ca5f))
* stop auto-scaling the launcher from DPI; caption every thumbnail cell ([2c49a72](https://github.com/ametrocavich/vostok-mod-loader/commit/2c49a72679521e8011c67b0d2a5c0f9fc79ffafc))
* stop showing users developer diagnostics ([652bbc2](https://github.com/ametrocavich/vostok-mod-loader/commit/652bbc2bec80c1850d7024c1ec9340a7d7e4fe13))
* title every Browse view, not just the curated landing ([5b67a5a](https://github.com/ametrocavich/vostok-mod-loader/commit/5b67a5ae4b2b1c9d4cc3eba3ab8908c2a0f42f3f))
* UI polish pass -- DPI scaling, thumbnails, browse UX, dev-mode perf ([2cf5e79](https://github.com/ametrocavich/vostok-mod-loader/commit/2cf5e793e73e22ff8cbcfd9cb0ee619c19bfa1da))

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
