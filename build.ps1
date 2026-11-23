# build.ps1 - builds Blood-Omen-2-Enhanced-Setup.exe from source.
#
# The game's own files are never part of this repository: they are read from your installed copy of Blood Omen 2
# (the untouched Steam version; if the mod is already installed, its saved originals in BO2SkipMod are used).
#
# Usage (Windows PowerShell 5.1):
#   .\build.ps1 -GameDir "C:\...\steamapps\common\Blood Omen 2 Legacy of Kain" [-CC <i686 clang>] [-Sh <sh.exe>]
# Output: dist\release\Blood-Omen-2-Enhanced-Setup.exe (and the documents next to it)

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GameDir,
    [string]$CC = 'i686-w64-mingw32-clang',              # llvm-mingw's 32-bit clang (on PATH, or a full path)
    [string]$Sh = 'C:\Program Files\Git\bin\sh.exe'       # Git for Windows' sh
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $root 'dist\build'
New-Item -ItemType Directory -Force $build, (Join-Path $build 'original-data'), (Join-Path $build 'patched-data'), (Join-Path $build 'vanilla') | Out-Null

function Original([string]$saved, [string]$live) {
    $s = Join-Path $GameDir "BO2SkipMod\$saved"
    if (Test-Path -LiteralPath $s) { return $s }
    return (Join-Path $GameDir $live)
}
Copy-Item -LiteralPath (Original 'bo2_vanilla.exe' 'bo2.exe') -Destination (Join-Path $build 'vanilla\bo2.exe') -Force
Copy-Item -LiteralPath (Original 'precode.big.orig' 'DATA\precode.big') -Destination (Join-Path $build 'original-data\precode.big') -Force
Copy-Item -LiteralPath (Original 'Code.big.orig' 'DATA\Code.big') -Destination (Join-Path $build 'original-data\Code.big') -Force
Copy-Item -LiteralPath (Original 'game.erg.vanilla' 'DATA\game.erg') -Destination (Join-Path $build 'game.erg.vanilla') -Force

# 1. The game exe patch (skip build and Vanilla mode's fixes-only build). Checks that the input is the supported exe.
$patch = Join-Path $root 'patches\apply-cutscene-fastforward-v44.ps1'
$vanilla = Join-Path $build 'vanilla\bo2.exe'
& $patch -InPath $vanilla -OutPath (Join-Path $build 'bo2_fastforward_v44.exe') | Select-Object -Last 1
& $patch -InPath $vanilla -OutPath (Join-Path $build 'bo2_fixes_v44.exe') -NoSkip | Select-Object -Last 1

# 2. The button icons in the game font.
& (Join-Path $root 'scripts\build-font-icons.ps1') -SourceDir (Join-Path $build 'original-data') -OutDir (Join-Path $build 'patched-data')

# 3. The two DLLs.
$env:CC = $CC
& $Sh (Join-Path $root 'sound/build.sh'); if ($LASTEXITCODE) { throw 'sound engine build failed' }
& $Sh (Join-Path $root 'ui-dll/build.sh'); if ($LASTEXITCODE) { throw 'bo2skipui.dll build failed' }

# 4. The setup program (payload = only the changed bytes).
& (Join-Path $root 'scripts\build-release.ps1') -Root $root -VanillaExe $vanilla `
    -SoundDll (Join-Path $root 'sound\build\backend\dinput.dll') -SoundSha ''
