# Tofu WoW patches

Client updates for the Tofu Worldview private server (World of Warcraft 3.3.5a). Players get them automatically from the launcher in their WoW folder; this repo holds the launchers and the patcher, and each GitHub Release holds the patch files.

## Players

Start the game with the launcher in your WoW folder, every time:

- **Windows:** double-click `Tofu WoW (Windows).bat`. The first time, Windows may say it protected your PC: click "More info", then "Run anyway".
- **Mac** (the Windows client under CrossOver, Whisky, or Wine): use `Tofu WoW (Mac).command`. The first time only, open Terminal, type `bash ` (with a space), drag the file into the window, and press Return. After that you can double-click it.

It downloads any new Tofu patches and addons, then starts WoW. If the update server cannot be reached, it starts WoW without updating. Keep the `Tofu` folder next to `Wow.exe`.

## How it works

- `manifest.txt` in the newest release (`https://github.com/cdenq/wow-tofuworld-patches/releases/latest/download/manifest.txt`) lists, tab-separated: the version, the realmlist, the HD patches to keep, the HD patches every player needs, and every Tofu file (`script`, `data`, `addons`) with its SHA-1, size, and download URL. A file that did not change keeps the URL of the release it was first uploaded to. A file of 2 GB or more (GitHub's limit) has the URL `bundled`: it ships only in the client zip and is checked, never downloaded.
- `client/Tofu/tofu-patcher.ps1` (Windows) and `client/Tofu/tofu-patcher.sh` (Mac, bash 3.2) do the same steps: update themselves, move every `Data\patch-*.mpq` that is not Blizzard's, a kept HD patch, or a Tofu patch into `Data\Removed Patches`, copy missing standard HD patches from `Data\OPTIONAL PATCHES`, download changed Tofu patches (checked by SHA-1 before they replace anything), replace the Tofu addon folders (only those; other addons are untouched), set `realmlist.wtf`, and clear `Cache` at every launch (so server-side database changes always show).
- Local state lives in the client's `Tofu` folder: `hashes.txt` (SHA-1 cache by size and modified time), `addon-folders.txt`, `addon-pack.txt`, `version.txt`, and `downloads`.

## Publishing (Chris, on the server host)

Built and published from `wow-tofuworld-internal\client-patches`: double-click `Publish Tofu Patches.bat`, or run `./publish.sh` (`./publish.sh --retail` for the retail stage) in Git Bash. It picks the next version (`vYYYY.MM.DD.N`), builds, writes `manifest.txt`, installs the result on the host's client with the same patcher players use, then commits, tags, pushes, and creates the release. Patch files are release assets and are never committed (`*.mpq` is ignored).

The patch files contain data derived from Blizzard's game files; they are not covered by the LICENSE in this repo.
