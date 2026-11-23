# build-release.ps1
# Builds the setup program into dist/release. The payload stores only the bytes the mod changes, so no game file ships.
# Usage: build-release.ps1 [-Root <project folder>]

[CmdletBinding()]
param(
    [string]$Root = '',                       # the project folder (default: the parent of this script's folder)
    [string]$VanillaExe = '',                 # the untouched game exe (default: <Root>\analysis\bo2\bo2.exe)
    [string]$SoundDll = '',                   # the sound engine (default: the audio project next to this one)
    [string]$SoundSha = '0871CB63F415197CCFC87925C4B2260365BE275C7EF54405E019393ED0CB76B4'   # '' = do not pin
)

$ErrorActionPreference = 'Stop'
if (-not $Root) { $Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path) }
$build = Join-Path $Root 'dist\build'
$out = Join-Path $Root 'dist\release'
$src = Join-Path $Root 'release-src'
$temp = Join-Path $out '_obj'
$csc = 'C:\Windows\Microsoft.NET\Framework\v4.0.30319\csc.exe'
New-Item -ItemType Directory -Force $out, $temp | Out-Null

function Get-Sha([byte[]]$b) { [Security.Cryptography.SHA256]::Create().ComputeHash($b) }

function Write-Entry($w, [string]$name, [byte[]]$orig, [byte[]]$patched) {
    if ($orig.Length -ne $patched.Length) { throw "$name changed size" }
    $n = [Text.Encoding]::ASCII.GetBytes($name)
    $w.Write([int]$n.Length); $w.Write($n)
    $w.Write([byte[]](Get-Sha $orig)); $w.Write([byte[]](Get-Sha $patched))
    $runs = New-Object Collections.ArrayList
    $i = 0
    while ($i -lt $orig.Length) {
        if ($orig[$i] -eq $patched[$i]) { $i++; continue }
        $start = $i
        while ($i -lt $orig.Length -and $orig[$i] -ne $patched[$i]) { $i++ }
        [void]$runs.Add(@($start, ($i - $start)))
    }
    $w.Write([int]$runs.Count)
    $total = 0
    foreach ($r in $runs) {
        $w.Write([int]$r[0]); $w.Write([int]$r[1]); $w.Write($patched, $r[0], $r[1])
        $total += $r[1]
    }
    Write-Output ("{0}: {1} runs, {2} changed bytes of {3}" -f $name, $runs.Count, $total, $orig.Length)
}

$payload = Join-Path $temp 'payload.bin'
$fs = [IO.File]::Create($payload)
$w = New-Object IO.BinaryWriter $fs
$w.Write([int]5)
if (-not $VanillaExe) { $VanillaExe = Join-Path $Root 'analysis\bo2\bo2.exe' }
$vanillaBytes = [IO.File]::ReadAllBytes($VanillaExe)
Write-Entry $w 'bo2.exe' $vanillaBytes ([IO.File]::ReadAllBytes((Join-Path $build 'bo2_fastforward_v44.exe')))
# Vanilla mode's exe: the same patch built with -NoSkip (fixes only, no hold detection, no prompt).
Write-Entry $w 'bo2_fixes.exe' $vanillaBytes ([IO.File]::ReadAllBytes((Join-Path $build 'bo2_fixes_v44.exe')))
Write-Entry $w 'precode.big' ([IO.File]::ReadAllBytes((Join-Path $build 'original-data\precode.big'))) ([IO.File]::ReadAllBytes((Join-Path $build 'patched-data\precode.big')))
Write-Entry $w 'Code.big' ([IO.File]::ReadAllBytes((Join-Path $build 'original-data\Code.big'))) ([IO.File]::ReadAllBytes((Join-Path $build 'patched-data\Code.big')))
$erg = [IO.File]::ReadAllBytes((Join-Path $build 'game.erg.vanilla'))
Write-Entry $w 'game.erg' $erg $erg
$w.Close()

# 1.0.1: the launcher, the DLLs and the patch data ship as separate files in dist\release\files (nothing embedded in setup).
$files = Join-Path $out 'files'
New-Item -ItemType Directory -Force $files | Out-Null
$manifest = Join-Path $src 'app.manifest'
$launcher = Join-Path $files 'launcher.exe'
# x86: the launcher's crash logger debugs the 32-bit game, which needs a 32-bit debugger.
& $csc /nologo /target:winexe /platform:x86 "/out:$launcher" "/win32manifest:$manifest" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll (Join-Path $src 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher failed to compile' }
# 1.0.2: the public launcher has no crash logger; the tester build (with it) goes to dist\release\tester\launcher.exe.
$testerDir = Join-Path $out 'tester'
New-Item -ItemType Directory -Force $testerDir | Out-Null
& $csc /nologo /target:winexe /platform:x86 /define:CRASHLOG "/out:$(Join-Path $testerDir 'launcher.exe')" "/win32manifest:$manifest" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll (Join-Path $src 'Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Tester launcher failed to compile' }

# Sound fix: the audio project's backend dinput.dll, pinned to the build tested in the game (13 clean sessions, 2026-11-16/17).
$soundDll = if ($SoundDll) { $SoundDll } else { Join-Path (Split-Path -Parent $Root) 'bo2-audio-replacement\build\backend\dinput.dll' }
if ($SoundSha -and (Get-FileHash -LiteralPath $soundDll -Algorithm SHA256).Hash -ne $SoundSha) { throw 'dinput.dll is not the tested sound-fix build' }

# Skip ring: ui-dll/bo2skipui.dll (built by ui-dll/build.sh), loaded by the V42+ exe.
$uiDll = Join-Path $Root 'ui-dll\build\bo2skipui.dll'
if (-not (Test-Path -LiteralPath $uiDll)) { throw 'ui-dll\build\bo2skipui.dll is missing: run sh ui-dll/build.sh' }

$setup = Join-Path $out 'Blood-Omen-2-Enhanced-Setup.exe'
& $csc /nologo /target:winexe "/out:$setup" "/win32manifest:$manifest" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll (Join-Path $src 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw 'Setup failed to compile' }
Copy-Item -LiteralPath $payload -Destination (Join-Path $files 'payload.bin') -Force
Copy-Item -LiteralPath $soundDll -Destination (Join-Path $files 'dinput.dll') -Force
Copy-Item -LiteralPath $uiDll -Destination (Join-Path $files 'bo2skipui.dll') -Force
if ($LASTEXITCODE -ne 0) { throw 'Setup failed to compile' }

foreach ($doc in 'README.txt', 'CHANGELOG.txt', 'LICENSE.txt', 'THIRD-PARTY-NOTICES.txt') {
    Copy-Item -LiteralPath (Join-Path $src $doc) -Destination (Join-Path $out $doc) -Force
}
Remove-Item -LiteralPath $temp -Recurse -Force
Get-ChildItem -LiteralPath $files | Select-Object Name, Length
Write-Output ("Setup SHA256: {0}" -f (Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash)
