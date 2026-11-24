Blood Omen 2 Enhanced
=====================
Version 1.0.2 by pyrociterwatz

A quality-of-life package for Blood Omen 2: Legacy of Kain (PC):

  - Hold-to-skip for in-game cutscenes, in the style of the Legacy of Kain: Soul Reaver 1 & 2 remasters.
  - Autosave at every checkpoint, listed first in the load menu.
  - A modern sound engine and fixes for several crashes of the original game.
  - Even volume sliders and a few smaller fixes (see below).

It is free. If you would like to support it: https://ko-fi.com/pyrociterwatz


Requirements
------------
- Blood Omen 2 from Steam or GOG (both have the same game files). Setup checks your files and tells you if they are not
  supported.
- Re-vamped by ClassicRebirth, installed first: https://classicrebirth.com/index.php/blood-omen-2-re-vamped/
  (Re-vamped makes the game run on modern Windows; it is not included and is not changed by this package.)


Install
-------
1. Install Re-vamped, then close the game.
2. Extract the whole zip to a folder (setup needs the "files" folder next to it), then run
   Blood-Omen-2-Enhanced-Setup.exe and click Install. It finds a Steam or GOG copy by itself (Steam first if you have
   both); "Browse..." picks a folder by hand. GOG Galaxy's "Settings" entry still opens the game's own settings window.
3. Start the game as usual. A small window lets you pick a mode each time:

  Speedrun   Cutscene skip, movies off, no cheats.
  Trainer    Cutscene skip, movies off, god mode, walk on water, debug display. Choosing Trainer opens a list where each
             of them can be turned on or off before the game starts (all are on at first; your choice is remembered).
  Vanilla    No cutscene skip and movies on, as in the original game, with all the fixes, the sound engine and autosave.

  Speedrun and Trainer skip all movies, the ending included; Vanilla plays them as the original game does.


Cutscene skip
-------------
While a cutscene plays, a hint shows the button to hold:

  Xbox controller      hold Y
  Keyboard             hold Space
  PlayStation pad      hold triangle (the pad must work through Steam Input or a tool such as DS4Windows)

Hold it for one second. The screen fades to black, the scene runs at high speed behind the black so that everything it
does in the game still happens, and the picture fades back. Sound effects and voices fade with the picture; the music keeps
playing. If a skip takes more than 3 seconds, the metal ring from the game's HUD turns in the lower right corner.

- A scene in several parts is skipped in one go. Scripted story moments (camera moves without a cutscene) skip the same way.
- After the last scene of a chapter the screen stays black into the next chapter's load screen.
- The three chapter-change scenes (Kain meets Vorador, the end of the Industrial Quarter, Kain takes Umah to the
  sanctuary) are ended with the game's own developer skip instead of being fast-forwarded.
- A few scenes cannot be skipped because fast-forwarding breaks them: the jewel scenes and most of the long lightning scene
  in the Industrial Quarter boss fight, and the Wharves scene at the big green door at the top of the stairs.
- If the game loads an area during a skip, the skip waits at normal speed (behind the black) until the load is done.


Autosave
--------
Whenever Kain reaches one of the game's checkpoints (the places you come back to after dying), the game is saved exactly as
"Save Game" in the pause menu would, into its own slot. The ring turns in the corner for a moment when it does. The
autosave is the first entry in the load menu, named "autosave"; your own saves follow in their usual order and are never
touched. The autosave uses slot 49 (folder Documents\Blood Omen 2\Save 49): if you already have a save of your own there,
it will be overwritten, so move it to another number first.


Sound and stability
-------------------
- New sound engine: the game's built-in sound library (FMOD 3, from 2002) is replaced inside the running game by a modern
  one (miniaudio, using WASAPI). The game's own sound logic stays as it was. It is the file dinput.dll in the game folder.
  "Use the new sound engine" in the launch window turns it off if you want to compare. Small differences you may hear:
  voice lines play their last fraction of a second instead of cutting off, and volume changes are smoothed, avoiding clicks.
  If the game folder already has a dinput.dll from another mod or tool, setup leaves it alone and skips the sound engine.
- Volume: the Sound and Music sliders change loudness in even steps (the original barely changes until the bottom), full
  volume leaves a little headroom against distortion, the voices in the chapter-change scenes are turned down, and the
  sliders keep working after a level raises the volume by itself.
- Crash fixes for bugs of the original game:
  - two copies of the old sound mixer could run after startup (random crashes, often around loading);
  - a voice line or music track that started while all 48 sound channels were busy corrupted memory;
  - the enemy health bar could keep pointing at an enemy unloaded by a level change;
  - stopping a voice line while its file was still being read corrupted memory.
- Movies cannot be stopped by accident in their first 2 seconds (for example by clicks left over from the last fight).
  After that, Enter, Esc or a click stops a movie as before.


Display
-------
Borderless fullscreen comes with Re-vamped: turn on its windowed mode in the game's options and set the game's resolution
to your main monitor's resolution. Re-vamped's resolution list is not fully sorted; on a 4K monitor 3840 x 2160 can be
near the top of the list.

If Windows display scaling is above 100% (common on 4K monitors), right-click bo2.exe in the game folder, Properties,
Compatibility, "Change high DPI settings", tick "Override high DPI scaling behavior" and pick "Application". The launcher
passes this setting on to the game.

"Keep the mouse inside the game window" (on by default) stops the pointer drifting onto another monitor. It lets go when
another window is in front and when the game closes.


Bug reports
-----------
The sound engine writes a short log every session (bo2audio-<date>.txt, the newest 30 are kept). "Open log folder" in the
launch window shows it (Documents\Blood Omen 2 Enhanced logs). Please attach the newest one to a report about sound or
crashes, with a description of what happened and where.

To keep anti-virus programs happy, this public version has no crash logger (it ran the game under a small debugger). Testers
get a separate build that has it.


Uninstall
---------
Run setup again and click Uninstall. Your original files are restored, and bo2skipui.dll, dinput.dll and bo2audio.ini are
removed. Re-vamped and your saves are left alone. If Steam or GOG Galaxy verifies or updates the game, run setup again
to repair the mod.


What setup changes
------------------
- Patches your own copies of bo2.exe, DATA\precode.big and DATA\Code.big (only the changed bytes come with the package; no
  game files are included), and writes settings variants of DATA\game.erg. The originals are kept in the BO2SkipMod folder
  inside the game folder, and bo2.exe becomes the mode-picking launcher.
- Adds dinput.dll (the sound engine) and bo2skipui.dll (the turning ring, the autosave, the black screen into a new chapter
  and the enemy-bar fix; it reads the ring picture from your own DATA\Code.big). The launcher writes bo2audio.ini before
  each launch. Outside the game folder only the log folder and the autosave slot are written to.


Credits and license
-------------------
Blood Omen 2 Enhanced by pyrociterwatz. Released under the MIT License (LICENSE.txt). The license covers the mod's own code
and data, not Blood Omen 2 or any of its files, which belong to their owners; the package contains only the bytes it
changes in your own copy of the game.
Testing: Prumpt and EODTex. Thank you!
Sound engine: miniaudio by David Reid (https://miniaud.io), public domain or MIT No Attribution (THIRD-PARTY-NOTICES.txt).
Requires Re-vamped by ClassicRebirth, which is distributed separately under its own license.

Blood Omen 2: Legacy of Kain is a trademark of its owners. This is an unofficial fan project, not affiliated with or
endorsed by Crystal Dynamics, Eidos, Square Enix, Embracer or ClassicRebirth.
