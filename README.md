# Blood Omen 2 Enhanced

by pyrociterwatz

A quality-of-life package for *Blood Omen 2: Legacy of Kain* (PC): hold-to-skip cutscenes in the style of the Soul Reaver
remasters, autosave at every checkpoint, a modern sound engine, crash fixes, even volume sliders and more.
The player-facing description is in [release-src/README.txt](release-src/README.txt); changes are in [CHANGELOG.txt](CHANGELOG.txt).

**Download:** [Nexus Mods](https://www.nexusmods.com/legacyofkainbloodomen2/mods/6) — **Support:** [ko-fi.com/pyrociterwatz](https://ko-fi.com/pyrociterwatz)

Requires [Re-vamped](https://classicrebirth.com/index.php/blood-omen-2-re-vamped/) by ClassicRebirth (not included).

## What is in this repository

| Folder | What it is |
|---|---|
| `patches/` | The game exe patch: a PowerShell assembler script that writes the mod's code into unused space in your own copy of `bo2.exe` (`-NoSkip` builds Vanilla mode's fixes-only exe). Its header documents every change and the game addresses involved. |
| `scripts/` | `build-font-icons.ps1` draws the Y and Space button icons into the game font; `build-release.ps1` builds the setup program; `extract-font.ps1` documents the font file layout. |
| `release-src/` | The launcher (mode picker) and the setup program (C#, built with the .NET Framework compiler that ships with Windows), plus the player documents. The crash logger in `Launcher.cs` is compiled only into tester builds (`/define:CRASHLOG`); the public launcher leaves it out. |
| `ui-dll/` | `bo2skipui.dll` (C): the turning ring on long skips, the autosave, the black screen into a new chapter, the save-list label and the enemy-bar crash fix. |
| `sound/` | `dinput.dll` (C): replaces the game's FMOD 3 sound code with [miniaudio](https://miniaud.io) inside the running game. |

No file of the game is in this repository. The setup program contains only the bytes the mod changes and checks the
player's files by SHA-256 before applying them.

## Building

Needs Windows, Windows PowerShell 5.1, [Git for Windows](https://gitforwindows.org) (for `sh`),
[llvm-mingw](https://github.com/mstorsjo/llvm-mingw) (its 32-bit `i686-w64-mingw32-clang`) and an installed, untouched
Steam or GOG copy of Blood Omen 2 (or one with this mod installed: its saved originals are used).

```powershell
.\build.ps1 -GameDir "C:\Program Files (x86)\Steam\steamapps\common\Blood Omen 2 Legacy of Kain" `
            -CC "C:\llvm-mingw\bin\i686-w64-mingw32-clang.exe"
```

The setup program and its documents end up in `dist\release`. Build output and game files are ignored by git.

## Credits

Testing: Prumpt, ACrispyTaco and EODTex.

## License

MIT, see [LICENSE.txt](LICENSE.txt). It covers the mod's own code and data, not the game or its files. miniaudio is public domain / MIT No Attribution ([THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt)).
Blood Omen 2 belongs to its owners; this is an unofficial fan project, not affiliated with or endorsed by them.
