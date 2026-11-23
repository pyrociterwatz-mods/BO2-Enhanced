# apply-cutscene-fastforward-v44.ps1
# Remaster-style cutscene skip. Apply to the vanilla exe.
#
# V44 (release 0.9.8): the autosave (Save 49) is the first entry of the load and save lists (user, 2026-11-18: "This should
#   be the first save slot when loading for quicker access").
# - The list built by 0x51B920 is sorted (0x51D1B0, from 0x51BF80) with the comparator 0x51C0A0: entry+0x10 (slot number)
#   a < b, unsigned. It has no other user; the new-save numbering in 0x51C370 lists and sorts on its own (0x51D950).
#   Every menu that uses this list (0x549F19, 0x54BA26, 0x55ADF7, 0x55B22C, 0x55B59F, 0x55BB2C) indexes the same sorted list.
# - The comparator is rewritten in place (its 19 bytes plus 13 bytes of padding): it compares (number - 49) unsigned, so
#   49 sorts first and 0-48 keep their order after it.
#
# V43 (release 0.9.7): autosave at checkpoints (user, 2026-11-18). FrameExtra3 now also looks up bo2skipui.dll's export
#   BO2UiTick (GetProcAddress, IAT 0x83F100) when it loads the DLL, keeps it in [UiTick] 0xAAFED4, and calls it every
#   frame before FrameExtra2 (main thread, inside the world update). The DLL watches Kain's checkpoint and saves to Save 49.
#
# V42 (release 0.9.6): loads bo2skipui.dll, which draws a turning ring on the black screen of a long skip (user, 2026-11-18:
#   "rather than try to speed up the ff, lets add some spinning icon to the faded out screens that are longer than a few
#   seconds"; chose the HUD's metal ring and a DLL).
# - Frame's first call (FrameExtra2) now goes to FrameExtra3 (spare H), which the first time calls LoadLibraryA
#   (IAT 0x83F110) on "bo2skipui.dll" ([UiLoaded] 0xAAFED8 = 1 whatever the result), then jumps to FrameExtra2 with the
#   stack unchanged. A missing DLL just means no ring. The DLL (ui-dll/bo2skipui.c) does the rest by itself.
#
# V41 (release 0.9.5): a movie cannot be stopped in its first 2 seconds.
# - User (2026-11-18), clicking to attack at the Sarafan Lord's last blow: the ending movie and the credits both stopped at
#   once and the game went to the main menu (log: at most about 1.3 s of movie). The movie loops (0x5BCC30, 0x5BD190,
#   0x5BDAC0) call 0x5BC2C0 each frame, which sets the stop flag ([ecx]) on Esc (key 0x401), Enter (0x41C) or the click latch
#   [0xA69824] that the window procedure 0x5783F0 sets on WM_LBUTTONDOWN. The latch is cleared when each movie starts
#   (0x5BC290), but clicks still queued from the fight arrive during the movie, since the loop pumps window messages.
# - MovieStart (spare H): the movie open's call to 0x5BC290 (0x5BC58A) first stores GetTickCount in [MovieT0].
# - MovieCheck (spare H): the three calls to 0x5BC2C0 run it as before (input kept up to date, latch cleared when it fires),
#   then clear the stop flag again while less than MovieGraceMs (2000) have passed since the movie opened.
# - Applies to every movie (logos, intro, credits from the menu, the ending), in every mode. Spare H = 0x4CCB80-0x4CCC0F, an
#   unreferenced script accessor next to spare G (from the unreferenced-function scan).
#
# V40 (release 0.9.4): the ending movies play in every mode (user, 2026-11-18: "I think it should play the ending movie").
# - The outro state (state 12, entered when the last script calls endgame) runs at 0x4AEC42: it reads PlayMovie (0x5768C0
#   "PlayMovie") and, only if it is set, plays OutroMovie1..9 from game.erg (outro, then credits), then sets state 3. Speedrun
#   and Trainer have PlayMovie=0, so the game went straight from the last fight to the main menu.
# - The je at 0x4AEC6F (74 72, to the SetState(3) at 0x4AECE3) is now two nops, so the outro movies always play. PlayMovie is
#   read only by the state handlers (all 9 references to the string are in 0x4AE5C9-0x4AEC64), not by the movie player, and
#   every other movie state keeps its check. Vanilla mode has PlayMovie=1 already: no change there.
#
# V39 (release 0.9.3): game bug fix, voice streams started with no free sound channel.
# - User log bo2-log-20261117-093843 (0.9.2, sound fix on): crash 0.25 s into the fast-forward of m_cinematic_east in the
#   Smuggler's Den boss arena (jvarena01). Main thread in the sound update (0x72ECB4 -> 0x6CEA40 -> 0x6E0C30), which walks the
#   stream type's list of registered stream sounds ([0xA7C1A0]+0x10) and calls each one's update (+0x3C). The object it reached
#   had been freed: its first dword was the allocator's free-list head 0xA734E8 (the bin at 0xA734E8 held exactly that block).
#   Same family as the v0.5 crash "via 0x6E0C30 calling a garbage address" (before the sound fix existed).
# - Stream sounds (vtable 0x876B8C) are registered (+0x44 = 0x6D51D0 -> 0x6D5140, +0x74 = 1) by the stream's start callback
#   0x6EB5E0 and unregistered (+0x48 -> 0x6D5190) only by its end callback 0x6EB620, which 0x6DDAA0 calls when the stream is
#   closed, and only if the stream has a channel. The destructor 0x6D4FC0 stops the sound but never unregisters it.
# - The stream's channel comes from the game's channel allocator 0x6D3300 (48 slots of 0x40 bytes at 0xAACFE0: in use +8,
#   priority +0x10, owner callback +0x14), called at 0x6DE0F6. It returns -1 when every slot is busy and none can be stolen (a
#   stream may only steal another stream's slot). The sound-effect caller checks for -1 (0x6EDF9B); the stream caller does not.
#   With -1 the game then writes the voice table at index -1 (0x6D3C90, 0x6D3900, 0x6D3B40 write 0xAACFA4, 0xAACFBC, 0xAACFC4,
#   0xAACFD0-D8: inside FMOD's own globals, 0xAACFBC being the mixer's block shift used for the mix-buffer address, which fits
#   the earlier after_iq mixer crashes), writes [channel table - 4] (0x6EB60C), registers the sound, and later never closes the
#   FMOD stream or unregisters the sound (0x6DDAA0 skips channel -1). When the sound is freed it stays on the update list.
#   A fast-forward makes this likely: sound effects start 16 times as often and can fill all 48 channels.
# - StreamAlloc (spare G) now wraps the stream's allocator call: if no slot is free, it releases the lowest-priority slot that
#   does not belong to a stream through 0x6D3DB0 (the same release the allocator uses when one sound steals another's channel,
#   which calls that sound's own steal callback), counts it in [VoiceEvicts], and then calls the allocator as before. Done under
#   the game's sound lock (0x6E2310/0x6E2340, a critical section; the allocator takes it too, in the same order after the stream lock).
# - StreamDtor (spare G): the stream sound's destructor now also unregisters the sound (a no-op when it is not on the list), so
#   a freed sound can never stay on the update list, whatever left it there. Not at shutdown, once the stream type is gone.
# - Everything else is V38. Without the two call-site changes the code is the same; addresses of existing code are unchanged.
#
# V38 (release 0.9.1): -NoSkip builds the "fixes only" exe for the launcher's Vanilla mode (user, 2026-11-17: Vanilla should
# keep the fixes and the sound fix, just no cutscene skip). Without -NoSkip the output is byte-identical to V37.
# - Both changes replace an instruction of the same length, so every address stays as in V37 (the main code area is full).
# - A skip only ever starts from $Button, which only IsHeld's callers set (CaveB for cinematics, ScriptScene for scripted
#   scenes) or ChainCheck, and ChainCheck only after an earlier skip. With -NoSkip, IsHeld still does its one-time set-up
#   (XInput and GetAsyncKeyState lookups) but then returns 0, so $Phase never leaves 0.
# - The hint is created in one place, HintUpdate with $Hint == 0. With -NoSkip it returns there, so $Hint stays 0 and no
#   prompt is ever shown. PromptTick still counts, so TrackDevice and TrimVoice (chapter-scene voice lowered) still run.
# - Unchanged: slider curve and slider/gain factors, mixer start fix, stream stop wait, OnLoaded, SoundDt (idle at 1x).
#
# V37 (release 0.8.18): DoorGate now matches the door scene it was meant for.
# - User log bo2-log-20261117-054200 (V36): the door scene still showed the prompt, was skipped and the level reloaded. V36
#   compared [cin+0x2C] with the wh05 bo2cinematic001 position, but at the stairs wh05 and wh08 are both loaded, both place a
#   bo2cinematic001 and both share one name record; the earlier live read had found the wh05 one through that record.
# - A read-only watcher on the user's unskipped run (log bo2-log-20261117-071511, scene 18.65-34.43 s, no reload) read the
#   played cinematic's [cin+0x2C]: position 1162.65, 3852.58, 0.31 (0x449154DE, 0x4570C938) at +0x44, +0xB4 and +0xCC,
#   name record at +0xB0. That x/y pair is wh08's bo2cinematic001 (wh08.big 0xB2678) and occurs nowhere else in DATA\*.big.
# - Only DoorGate's two constants change. Everything else is V36.
#
# V36 (release 0.8.17): the Wharves wh05 door scene is no longer skippable.
# - User logs bo2-log-20261117-050130 (V35, skipped) and bo2-log-20261117-052916 (not skipped): played normally the scene runs
#   about 16 s and sends two enemies walking into the arena; nothing reloads. Each fast-forward of it was followed, 9-11 s of
#   game time in (during the enemies' walk), by the wharves load screen and a reload of wh05 at the foot of the stairs. No region
#   file was queued before that, so V35's load-timing idea was not the cause; the walk does not survive the 16x time step.
# - The scene's object is bo2cinematic001, a name wh02, wh08 and wh09 use too. Its instance ([cin+0x2C]) holds the placed
#   position at +0xB4/+0xB8/+0xBC (read live in the game: the same floats as the entity record in wh05.big, offset 0x1E078C):
#   x = -1235.98 (0xC49A7F72), y = 5080.48 (0x459EC3D3). wh05's bo2cinematic002 is at x = -1174.09, wh08's bo2cinematic001 at
#   x = 1162.65.
# - DoorGate (spare G, the unused script accessor 0x4CCC10-0x4CCCAF; no call, jump or pointer into it): NoSkipName's "anything
#   else" exit now goes there. Name characters 12-15 "001 " and that x and y -> NSYes (no prompt, as for the jewel scenes);
#   otherwise SeerTick as before. It uses eax only and restores it (SeerTick reads the name from eax).
#
# V35 (release 0.8.14): game time runs at normal speed while the stream loader has files queued, and a level reload during a
# skip stops the skip from continuing into the next cinematic.
# - Tester log bo2-log-20261116-111026 and video: the Wharves wh05 door scene (bo2cinematic001). Each skip of it was followed,
#   0.67-0.85 s real (about 11-14 s of game time) into the fast-forward, by hud/load_screens/wharves_load.big and wh05.big: the
#   game reloaded wh05 and put Kain back at the foot of the stairs. The scene started again about a second later, inside the
#   2 s chain window, so the mod skipped it again at once: 14 rounds until the tester quit. Region scripts there include
#   waitforregionload_face and resetingforplayandretrigger: the scene seems to wait for a region load and to reset if it takes
#   too long. File loads take real time, the fast-forward runs game time 16 times faster.
# - MulGate (spare B): ScaleDt's and SoundDt's fmul [multiplier] became a call to it. It multiplies only when the stream
#   loader's queue is empty: loader = [[0x00A79CD4]], queue sentinel = [loader+0xC], empty when [sentinel] == sentinel (the
#   test 0x6C5950 makes before it updates the first request; the game calls it through 0x6AA440 with ecx = [0x00A79CD4]). The
#   queue holds the .big files only (the ones the launcher logs as "Loading ..."), so other skips are not slowed down except
#   while a region streams in. The screen stays black and voices stopped meanwhile; MaxSkipSeconds still applies.
# - OnLoaded (spare C): when the finished file is a load screen ([[req]]+6+34 = "load", in
#   "/gogames/bo2/resources/levels/hud/load_screens/..."), it closes the chain window and stores Latch in LoadReset.
#   SkipEndExtra opens the chain window only when LoadReset differs from Latch, and clears LoadReset. So after a level load
#   during a skip, the next cinematic shows its prompt as usual instead of being skipped by itself.
# - IsChapter moved from spare B to spare D to make room.
#
# V34 (release 0.8.13): after a skip of the Seer scene (cy07 bo2cinematic_meeting_seer) the HUD is put back into kain mode.
# - Two user runs (logs bo2-log-20261115-045857 and -080247): the fast-forward plays the whole 252 s scene, telekinesis is given,
#   but the HUD stays in cinematic mode (invisible) until the next level load. When the scene is watched, the HUD goes back to
#   kain mode as the scene ends. No other skip in the logs leaves the HUD in cinematic mode during play.
# - SeerTick (main cave): NoSkipName's "anything else" exit now passes through it. If the ticking cinematic is the latched one and
#   its name has "_meeting" at characters 12-19 (only bo2cinematic_meeting_seer among the game's 122 cinematic names), SeerSkip = 1.
# - HudFix (spare C, called from FrameExtra after ScriptScene, so HudMode/HudPtr are this frame's): once SeerSkip is set, the
#   skip is over (Phase 0) and the 2 s chain window has closed, it clears SeerSkip. Then, if no cinematic is ticking and the HUD is
#   still in mode 2, it calls HUD::SetMode(1) (0x531030, thiscall, ret 4) on the HUD, the way the game's own callers do
#   (for example 0x4AD514: push 1 / mov ecx,hud / call 0x531030).
# - HudRead also stores the validated HUD pointer in HudPtr.
#
# V33 (release 0.8.12): the speed-vampire fight's lightning scenes can be skipped again, but only their first LightCap seconds.
# - m_cinematic_lightning comes in two forms: about 9.6 s (the boss gets zapped) and about 25 s (the zap, then the charmed control-
#   booth worker flipping switches before the third phase). In the v0.8.8 log every fast-forward of the long form (1.83-1.87 s real)
#   was followed by m_cinematic_jg_jewel and the phase started over; the short ones (0.58-0.63 s real) were not.
# - LightGate (spare C): for a lightning cinematic latched in phase 2, once SkipT (real seconds of fast-forward) reaches LightCap
#   (0.70 s, about 11 s of game time) it records the cinematic as CapCine and returns through NSYes. Counter is no longer
#   refreshed, so the skip ends 3 frames later and the rest plays at normal speed. CapCine also keeps the prompt off for the rest of that
#   cinematic; ScriptScene clears it once no cinematic has ticked for 3 frames (the same object runs every lightning scene).
# - m_cinematic_jewel and m_cinematic_jg_jewel stay unskippable. NoSkipName now tests only the 4 characters at name+12 (still only
#   those three of the game's 122 cinematic names).
# - OnLoaded is reduced to a jump to the original handler: the chapter-region mark has not chosen anything since V30, and its
#   space in spare C now holds LightGate. ChapterCine and KeyBuf stay 0.
#
# V32 (release 0.8.11): the camera-mode-5 rule is gone; only the three named boss-fight cinematics are left unskippable.
# - User log bo2-log-20261114-072642: svarena's m_cinematic_end (an ordinary cutscene after the boss) also puts the camera in mode 5.
#   Each time it did, NoSkipGate stopped refreshing Counter mid-skip, the skip ended and the rest played with no prompt, so the
#   scene was skipped in three pieces (562-565, 578-580, 587-593 s). Mode 5 is not specific to the charm, so NoSkipGate now
#   checks only the name (m_cinematic_lightning / _jewel / _jg_jewel).
#
# V31 (release 0.8.10): no skip during the speed-vampire fight's in-fight cinematics, or while the camera follows a target.
# - svarena's m_cinematic_lightning runs while the player uses the charmed control-booth worker; its camera goes to mode 5 (GameCamera
#   +0x98 = 5, set by 0x40BB90 when the camera is given a target, as in charm). Skipping it fast-forwarded the turn away and the boss
#   could not be finished (user log bo2-log-20261114-050357: 15 lightning skips, each ending after 0.6 or 1.9 s real time).
# - CaveB0's call to ChainCheck now goes to NoSkipGate (spare B). If CamMode is 5, or the cinematic's object name is
#   m_cinematic_lightning / m_cinematic_jewel / m_cinematic_jg_jewel (NoSkipName, spare E: "m_ci" at +0 and "ligh"/"jewe"/"jg_j" at
#   +12 of the name; only these three of the game's 122 cinematic names match), it returns to fn2 as CaveB does (eax = 0) without
#   setting Button, Counter or PromptTick: no prompt, no hold, no chain. LastCine and CineSeen are still set. Otherwise ChainCheck
#   and the rest of CaveB0 run as before.
#
# V30 (release 0.8.9): the elevator ride after the speed-vampire boss is fast-forwarded again instead of being aborted.
# - The cinematic that runs while after_iq.big streams in is svarena's bo2cinematic001: Kain rides the dais (a_dais, an elevator)
#   to the sanctuary. V24's region mark tagged it as the chapter scene, so it got the dev abort: the ride ended at the arena,
#   the dais never arrived and nothing moved on to after_iq's own scene or its m_levelloaddispatcher (canyons\cy01). The user had
#   to reload five times (log bo2-log-20261114-050357).
# - IsChapter now uses only NameCheck (bo2cinematic_after_iq / _kainmeet... / _kaintake...). The region mark is still recorded
#   (OnLoaded, ChapterCine, KeyBuf) for the launcher's log, but no longer selects the abort. The other two chapter scenes were
#   already found by name in the 0.8.x logs; after_iq's own scene, if it runs as bo2cinematic_after_iq, is also found by name.
#
# V29 (release 0.8.7): sound effects fade out and back in with the picture, and the Sound and Music sliders always apply.
# - A sound group's final volume is computed in its update (0x6D2E30, vtable 0x876B3C +0xC): parent's final volume
#   ([params+0x14]) times its own ([+0x1C]), stored at +0x40 and passed on to its child groups and sounds. Both places that do
#   this (0x6D2E61 full update, 0x6D2F30 volume update) now call GainEdi/GainEax. For the root groups sfx, vo and music (matched
#   by the group vtable and the name symbol at +0x54 against the sound manager's +0x12/+0x14/+0x18) they also multiply by the
#   slider level, and for sfx and vo by the skip fade, (1 - FxAtt)^2. The game's own value at +0x1C is never written.
# - The options code (startup 0x55A200, options screen 0x4AB640) set the slider level straight into the sfx, vo and music groups'
#   own volume, and level scripts write that same value: at the start of Smuggler's Den something raised sfx from the slider's
#   0.28 to 1.0 (0.80 seen during the rise, 1.00 later in Lower City), so effects got much louder after the chapter change and
#   stayed so. Those six calls now go to SliderSfx/SliderVo/SliderMusic, which keep the slider level in the mod state and
#   re-apply the group's own volume; a script's volume then counts relative to the slider.
# - FxTick (each frame, real time) moves FxAtt toward 1 in skip phases 1 and 2 and toward 0 otherwise, at 1/FadeSeconds per
#   second, so effects and voices fade out with the fade to black and back in with the fade back; music is not faded. While it
#   moves, the sfx and vo groups' own volume is set again (same value) so the new final volume reaches the playing sounds.
# - V28's MuteFx/UnmuteFx (save, set 0, restore) are gone: restoring a saved value wrote over whatever the game set meanwhile.
#
# V28 (release 0.8.6): sound effects are muted while a scene is fast-forwarded; music keeps playing. The sound manager's root groups
# are main, sfx, vo, menu and music (symbols at +0x10..+0x18, made in 0x6CCAB0); the Sound slider sets sfx, vo and menu and the
# Music slider sets music (0x4AB640). On the first fast-forward frame MuteFx looks up sfx and vo (FindGroup 0x6CDB90 on the
# symbols at +0x12/+0x14), saves their volume ([group+0x1C]) and sets 0 (SetGroupVolume 0x6D2860, which updates playing sounds);
# SkipEndExtra restores the saved volumes when the skip ends, before the fade back. Groups are looked up again each time.
#
# V27 (release 0.8.5): a scripted scene is skipped in one go. The Upper City stairs part is several camera paths in a row; between
# them the camera spends a few frames in mode 1 (no creature followed) or mode 3 with no path, and V26 ended the skip there, so
# each later shot needed its own prompt. While a scripted skip runs (Latch is the marker) it now carries on as long as the camera
# mode is 3 or 1; it ends when the camera follows a creature again (mode 4). And right after any skip ends (the chain window), a
# playing path continues it at once, with no ScriptDelay wait, so a cinematic followed by a scripted part stays black throughout.
#
# V26 (release 0.8.3):
# - Scripted scenes are now recognised by the game camera, not the HUD. The HUD signal never fired for the Upper City stairs
#   part (the HUD stays in kain mode there) and fired once by mistake: after kainmeetsvorador the HUD stayed in cinematic mode for
#   0.5 s while the level change started. The game camera is [[world+0x44]+0x124] (world: [[0xA83C84]+8] when [0xA83C84] is 1,
#   as 0x4A9B30/0x4A9B90 read it), a GameCamera at offset 0 (vtable 0x83F77C, written by its constructor at 0x409C7E). Its mode
#   is +0x98 and +0x90 the exported camera path it plays: GameCamera.PlayExportedCamera sets mode 3 (0x40DBD0) and 0x40DF20
#   reports the path done when +0x90 is null. A path that plays for ScriptDelay seconds while no cinematic ticks, and that was
#   not already playing during a cinematic, counts as a scripted scene. The HUD mode is still read, for the launcher's log only.
# - Chapter scenes are also recognised by the cinematic's own name (bo2cinematic_after_iq, _kainmeetsvorador,
#   _kaintakesumahtosanctuary), so a chapter region preloaded with a checkpoint (kainmeetsvorador: loaded 190 s before its
#   scene) still uses the game's abort. The region mark from V24 still applies (after_iq runs as svarena's bo2cinematic001).
# - CamMode, CamPath and CineCam are kept in the mod state for the launcher's log.
#
# V25 (release 0.8.2): scripted scenes. Some story moments are not cinematics but level scripts that take the camera and put the
# HUD in its cinematic mode (the second part of the Upper City stairs scene: nothing ticks in cinematicstate there). The HUD's mode
# is [HUD+0x104] (set by 0x531030, read by 0x54F6F0; 0 none, 1 kain, 2 cinematic, 3 kain and enemy, 4 charm); the HUD is
# [[0x91EF00]+0x58], checked by its vtable 0x869000 (written at 0x52EACC). When the mode has been 2 for ScriptDelay seconds and
# no cinematic has ticked for 3 frames, ScriptScene treats it like a ticking cinematic with the marker 1 in place of a cinematic
# pointer: prompt, hold, fade, fast-forward, and the fade back once the mode leaves 2. It also continues a skip that just ended
# (the chain window), so the stairs scene goes on in one skip. A scripted fast-forward stops after ScriptMaxSeconds of real time.
#
# V24 (release 0.8.1):
# - Chapter scenes are recognised by the region the game streams in for them, not by name. The cinematic objects have generic
#   names (the after_iq scene is svarena's "bo2cinematic001"); while it starts, the loader finishes the region
#   "resources/levels/industrial quarter/cinematics/after_iq.big". The loader's completion call (0x6C8C9C -> 0x6C8800, argument:
#   request whose [[req]]+6 is the file name) now goes through OnLoaded: a file whose path contains "/cinematics/" records the
#   cinematic ticking at that moment as ChapterCine (only after_iq, kainmeetsvorador and kaintakesumahtosanctuary live in such
#   folders); any other file clears it, so a stale pointer cannot match after a level change. The file name is copied to KeyBuf
#   for the launcher's log. A region that loads while no cinematic is ticking (a checkpoint preload) marks nothing.
# - A skip carries on into a cinematic that starts ticking within ChainSeconds after the skipped one stopped (scenes made of
#   several cinematics, such as the stairs at the start of Upper City). During the fade back it goes straight back to black and
#   fast-forward (or the abort, for a chapter scene); after the fade back it starts a normal skip at once, fade included.
#
# V23: chapter scenes use the game's own developer skip. Once the fade is black, the next tick of the chapter cinematic takes the
# path the debug flag "always allow abort from cinematics" plus jump would take in fn2 (0x4E01A9): end routine 0x4E0070 with
# endedwithabortstate. The game then runs endofcinematicstate as it does after a normal ending; cinematics cannot load levels
# themselves (0x4DF140), so the chapter change is left to the region's own m_levelloaddispatcher. Voice tracks are still stopped
# while the screen is black and fading back. Other scenes are unchanged.
# The extra code lives in game functions that nothing references (0x4E0130, 0x4E0230-0x4E02CF: unused copies of fn2's
# abort test; 0x4E8EE0-0x4E901F: an unused function; no call, jump or pointer into them exists in the exe), because the cave at
# the end of .text is full.
#
# A prompt shows during cinematics. Hold Y (XInput pad 0) or Space: after HoldSeconds the screen fades to
# black, the scene runs at Multiplier speed with voice lines ended early, and the screen fades back when
# the scene stops updating. Every script command still runs. See notes/remaster-skip-technique.md.
#
# The fade uses StartScreenCutMsg, which drives the HUD's ui_hud_screen_cut element and leaves the letterbox
# alone. Layout: +4/+8/+C time list (count, capacity, data), +10/+14/+18 RGBA list (same shape), +1C "only if
# enabled" flag. Each time is that key's duration. A last key with alpha above zero is held until replaced;
# one with alpha zero ends the fade. Capacity 0 marks the lists as not owned, so they can live on the stack.
#
# The prompt is a real HUDHint pushed onto the HUD's HUDHintPopup, so it uses the game's font. Icons: \g triangle (the game's own),
# \u Y and \4 Space (added by scripts/build-font-icons.ps1, which must be applied too). The icon follows the last input device:
# pad input (XInput packet number) or a new keyboard key press (GetAsyncKeyState), ignoring keys that arrive with pad input,
# and a PlayStation pad is recognised by vendor id 0x054C in the Windows joystick list.
#
# Long recorded voice tracks (sound groups vo/cinestream and vo/scripted) run in real time, so each frame of a skip stops whatever
# is playing in those groups. If a skip is still running after MaxSkipSeconds of real time, the screen fades back rather than stay black.
#
# Audio: the game turns its 0-9 Sound and Music sliders into volume as step/9, a straight line that barely changes loudness until
# the bottom. All four places that do this (startup and options) now read a table instead: step 9 is TopDb, each step below is
# StepDb quieter, step 0 is silent. The vo/cinestream group (chapter-scene voice tracks) is also set to CineDb once.
# The hint's reference is deliberately never released: the HUD can be torn down between scenes and the leak is a few bytes.
#
# Game bug fix (sound mixer): at startup the game initialises FMOD, closes it and initialises it again. The close waits for the mixer
# thread's "exited" flag (0x0090C840), which starts as 1 and is only cleared once the thread runs, so if the first thread has not
# started yet the close returns at once and that thread later runs alongside the second one. Two mixer threads share the block
# counter without a lock and occasionally read past the mix buffer (seen as a crash in the mixer thread). The flag is now cleared
# just before each mixer thread is created, so the close waits for the thread to really exit.
#
# Game bug avoided (stream close during a read): a recorded stream refills itself with asynchronous file reads, marking the stream
# busy (+0x5C) until the read completes. Closing it while busy (0x6DD9A0) defers the close but deletes the file reader and its
# queued requests at once, so the read's completion touches freed memory and corrupts the heap (seen as later crashes, in the
# mixer at the end of after_iq). The game itself only closes streams that have finished reading; a skip stops them mid-play, so
# the skip now takes the stream lock (0x6DD390/0x6DD3C0) and stops a stream only when it has no read in flight, else it retries
# on the next frame. [StopWaits] counts the retries.
#
# Sound clock: the sound update (0x6CEA40) reads its own frame time (0x6A0F00) and also runs script threads timed against
# sounds (0x7A2AA0 -> 0x580CB0). During the fast-forward the world ran at Multiplier speed but those scripts at normal speed,
# so they reached steps whose objects the scene had already removed (crashes 2.8 s into the after_iq skip, "GetCreatureWithName
# failed" messages). The sound update's frame time is now multiplied too while fast-forwarding.
#
# Hooks:
#   0x004E0183  fn2's debug-flag call -> CaveB0 (runs each cinematic tick; takes the abort path when a chapter skip asks for it,
#               otherwise CaveB, which reports the flag as off)
#   0x0072EDE9  per-frame update, just after frame time is computed -> Frame
#   0x004B7316  speech handler's "still playing?" call -> CaveC
#   0x006CEAB5  sound update's frame-time call -> SoundDt (scaled during the fast-forward)
#   0x006D495A  FMOD init's "start mixer thread" call -> MixerStart (clears the exited flag first)
#   0x006C8C9C  stream loader's "file finished" call -> OnLoaded (notes chapter-scene regions)
#   0x006D2E61, 0x006D2F30  sound group's final volume -> GainEdi / GainEax (slider level, skip fade)
#   0x004AB735, 0x0055A29D / 0x004AB74C, 0x0055A2B4 / 0x004AB77E, 0x0055A2E6  options' sfx / vo / music volume -> SliderSfx /
#               SliderVo / SliderMusic
# New code lives in unused zeros at the end of .text; state lives in the unused end of the last .data page.

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InPath,
    [Parameter(Mandatory)][string]$OutPath,
    [switch]$NoSkip,                     # V38: fixes-only exe (no hold detection, no prompt)
    [single]$LightCap = 0.70,           # real seconds of fast-forward allowed in a lightning scene (V33)
    [single]$Multiplier = 16.0,
    [single]$HoldSeconds = 1.0,
    [single]$FadeSeconds = 0.4,
    [single]$MaxSkipSeconds = 45.0,
    [single]$TopDb = -3.0,
    [single]$StepDb = 4.0,
    [single]$CineDb = -6.0,
    [single]$ChainSeconds = 2.0,
    [single]$ScriptDelay = 0.5,
    [single]$ScriptMaxSeconds = 10.0
)

$VanillaSha = '4ABEE85A1DA1B2C2AE9764A53CC34A8F6EC3F496E5CE6FD8A918AF79BF0F9ADE'
$ImageBase = 0x400000
$CodeBase = 0x0083E780
$CodeLimit = 0x0083F000
# Constants and strings go in the unused, file-backed end of .rdata (it is zeros and nothing points into it).
$DataBase = 0x008E5A80
$DataLimit = 0x008E6000

# State in spare .data
$Latch = 0x00AAFF00; $Counter = 0x00AAFF04; $HoldT = 0x00AAFF08; $Button = 0x00AAFF0C
$Phase = 0x00AAFF10; $WaitT = 0x00AAFF14; $PXInput = 0x00AAFF18; $PKey = 0x00AAFF1C; $Init = 0x00AAFF20; $PadOk = 0x00AAFF24
$PromptTick = 0x00AAFF28; $Hint = 0x00AAFF2C; $HintPopup = 0x00AAFF30
$LastPacket = 0x00AAFF34; $LastKb = 0x00AAFF38; $Dev = 0x00AAFF3C; $DevShown = 0x00AAFF40; $DevInit = 0x00AAFF44
$PLastInput = 0x00AAFF48; $PJoy = 0x00AAFF4C; $JoyInit = 0x00AAFF50
$VoGroup1 = 0x00AAFF54; $VoGroup2 = 0x00AAFF58; $SkipT = 0x00AAFF5C; $PadRecent = 0x00AAFF60; $VoTrimmed = 0x00AAFF64
$StopWaits = 0x00AAFF68                 # times a voice stop waited for a stream read (read by the launcher's log)
$AbortReq = 0x00AAFF6C                  # 1: the next tick of the latched cinematic takes the game's abort path
$DevSkip = 0x00AAFF70                   # 1: the running skip is a chapter-scene abort, not a fast-forward
$DevSkips = 0x00AAFF74                  # number of chapter-scene aborts started (read by the launcher's log)
$AbortPath = 0x004E01A9                 # fn2: mov eax,[esi+0x68] / push eax / mov ecx,esi / call 0x4E0070 / pop esi / ret 4
$SpareA = 0x004E0130; $SpareALimit = 0x004E0170
$SpareB = 0x004E0230; $SpareBLimit = 0x004E02D0
$SpareC = 0x004E8EE0; $SpareCLimit = 0x004E9020
$HudPtr = 0x00AAFEFC                    # HUD object HudRead validated this frame (V34)
$SeerSkip = 0x00AAFFF4                  # 1 after the Seer scene was skipped, until HudFix has looked at the HUD (V34)
$HudSetMode = 0x00531030               # HUD::SetMode(mode), thiscall, ret 4
$LoadReset = 0x00AAFFF8                 # the Latch of a skip during which a load screen loaded (V35)
$LoadQueue = 0x00A79CD4                 # [[this]] = stream loader, [loader+0xC] = request queue sentinel (V35)
$CapCine = 0x00AAFEF8                   # lightning cinematic whose fast-forward was stopped at LightCap (V33)
$ChapterCine = 0x00AAFF78               # cinematic that was ticking when a /cinematics/ region finished loading
$LastCine = 0x00AAFF7C                  # last cinematic seen ticking in cinematicstate
$ChainOn = 0x00AAFF80                   # 1: a new cinematic may continue the skip that just ended
$ChainT = 0x00AAFF84                    # seconds since that skip ended
$PrevLatch = 0x00AAFF88                 # the cinematic that skip was on
$Chains = 0x00AAFF8C                    # number of skips continued into a following cinematic (read by the launcher's log)
$KeyBuf = 0x00AAFFA0; $KeyBufSize = 64  # last /cinematics/ file name loaded (read by the launcher's log)
$LoadDoneCall = 0x006C8C9C; $LoadStats = 0x006C8800
$SpareD = 0x004CA8D0; $SpareDLimit = 0x004CAA00
$CineSeen = 0x00AAFF90                  # 3 when a cinematic ticked this frame, counting down
$HudMode = 0x00AAFF94                   # HUD mode read this frame (-1: no HUD)
$ScriptT = 0x00AAFF98                   # seconds the HUD has been in cinematic mode with no cinematic ticking
$ScriptOn = 0x00AAFF9C                  # 1 while that counts as a scripted scene
$HudVtable = 0x00869000; $ScriptMarker = 1
$SpareE = 0x004CC810; $SpareELimit = 0x004CC940
$CamMode = 0x00AAFFE0                   # game camera mode this frame (-1: no camera; 3: playing an exported camera path)
$CamPath = 0x00AAFFE4                   # the path it plays (+0x90), 0 if none
$CineCam = 0x00AAFFE8                   # the path last seen playing while a cinematic ticked (not a scripted scene)
$WorldState = 0x00A83C84; $CameraVtable = 0x0083F77C
$SpareF = 0x0049AB70; $SpareFLimit = 0x0049AD00
$SpareG = 0x004CCC10; $SpareGLimit = 0x004CCCB0   # unused script accessor (V36)
$SpareH = 0x004CCB80; $SpareHLimit = 0x004CCC10   # unused script accessor (V41)
$MovieOpenCall = 0x005BC58A             # movie open: call 0x5BC290 (movie input object) (V41)
$MovieInput = 0x005BC290; $MovieStopCheck = 0x005BC2C0
$MovieCheckSites = 0x005BCE22, 0x005BD51D, 0x005BDD60   # each movie loop's call to 0x5BC2C0
$IatGetTickCount = 0x0083F128
$MovieT0 = 0x00AAFEDC                   # GetTickCount when the current movie opened (V41)
$MovieGraceMs = 2000
$IatGetProc2 = 0x0083F100              # GetProcAddress (V43)
$UiTick = 0x00AAFED4                    # bo2skipui.dll's BO2UiTick, 0 if none (V43)
$UiLoaded = 0x00AAFED8                  # 1 once FrameExtra3 has tried to load bo2skipui.dll (V42)
$SaveListCompare = 0x0051C0A0          # load list sort comparator, rewritten in place (V44)
$OutroMovieCheck = 0x004AEC6F           # outro state: je past the outro movies when PlayMovie is 0 (V40)
$StreamAllocCall = 0x006DE0F6           # stream play: call 0x6D3300 (channel allocator) for a voice/music stream (V39)
$ChanAlloc = 0x006D3300; $ChanRelease = 0x006D3DB0; $SndLock = 0x006E2310; $SndUnlock = 0x006E2340
$ChanTable = 0x00AACFE0; $ChanCount = 48; $StreamChanCb = 0x006DE1C0
$StreamDtorCall = 0x006D4FEB; $StreamUnreg = 0x006D5190   # stream sound destructor's stop call; unregister (V39)
$StreamTypeObj = 0x00A7C1A0             # the stream sound type (vtable 0x876D10), its list of registered sounds at +0xC/+0x10
$VoiceEvicts = 0x00AAFFFC               # times a stream needed a channel and a sound effect's was released for it (V39)
$FxAtt = 0x00AAFFEC                     # skip fade of sfx and vo: 0 full volume, 1 silent (float)
$SliderSet = 0x00AAFFF0                 # bits 1/2/4: SlSfx/SlVo/SlMus have been set by the options code
$SlSfx = 0x00AAFEE0; $SlVo = 0x00AAFEE4; $SlMus = 0x00AAFEE8   # slider levels (after VolCurve)
$SfxGrp = 0x00AAFEEC; $VoGrp = 0x00AAFEF0; $MusGrp = 0x00AAFEF4   # the root groups last seen (read by the launcher's log)
$GroupVtable = 0x00876B3C
$GainSiteFull = 0x006D2E61; $GainSiteVol = 0x006D2F30
$SliderSfxSites = 0x004AB735, 0x0055A29D; $SliderVoSites = 0x004AB74C, 0x0055A2B4; $SliderMusSites = 0x004AB77E, 0x0055A2E6
$StreamStop = 0x006D5070; $StreamLock = 0x006DD390; $StreamUnlock = 0x006DD3C0
$SetGroupVolume = 0x006D2860
$VolumeSites = 0x004AB70D, 0x004AB724, 0x0055A275, 0x0055A28C   # each: fmul dword [0x0086029C] (slider step * 1/9)
$LastKeys = $LastKb                    # number of keys down last frame

# Game addresses
$IatGetProc = 0x0083F100; $IatLoadLib = 0x0083F110; $IatGetModule = 0x0083F124
$BroadcastMsg = 0x0071D200; $CutVtable = 0x00843604
$CameraGlobal = 0x00A83664; $FrameReturn = 0x0072EDEF; $PhraseCheck = 0x004B7530; $TextObject = 0x00A6A694
$FlagCall = 0x004E0183; $FrameHook = 0x0072EDE9; $PhraseCall = 0x004B7316
$SoundDtCall = 0x006CEAB5; $FrameTimeFn = 0x006A0F00
$MixerStartCall = 0x006D495A; $MixerStartFn = 0x006E8D40; $MixerExited = 0x0090C840
$SoundManager = 0x00A7A1E4; $MakeSymbol = 0x00695930; $FindGroup = 0x006CDB90
$HudOwner = 0x0091EF00; $Allocator = 0x00A74590; $MakeString = 0x0068E940; $HintCtor = 0x0053B1D0; $HintAdd = 0x0053C0C0; $HintRemove = 0x0053C270

function Le32([long]$v) { , [byte[]]@(($v -band 0xFF), (($v -shr 8) -band 0xFF), (($v -shr 16) -band 0xFF), (($v -shr 24) -band 0xFF)) }
function FloatBytes([single]$f) { , [BitConverter]::GetBytes($f) }

# Minimal assembler: raw bytes, labels, and absolute or relative references to labels or addresses.
$script:Items = New-Object System.Collections.ArrayList
function B([byte[]]$b) { [void]$script:Items.Add(@{ k = 'b'; v = $b }) }
function L([string]$n) { [void]$script:Items.Add(@{ k = 'l'; v = $n }) }
function Abs($t) { [void]$script:Items.Add(@{ k = 'a'; v = $t }) }
function Rel($t) { [void]$script:Items.Add(@{ k = 'r'; v = $t }) }
function Org([long]$a, [long]$limit) { [void]$script:Items.Add(@{ k = 'o'; v = $a; lim = $limit }) }
function Rel8($t) { [void]$script:Items.Add(@{ k = 'r8'; v = $t }) }
function Jz8($t) { B 0x74; Rel8 $t }
function Jbe8($t) { B 0x76; Rel8 $t }
function Jnz8($t) { B 0x75; Rel8 $t }
function Jmp8($t) { B 0xEB; Rel8 $t }
function AndZero($a) { B 0x83, 0x25; Abs $a; B 0x00 }   # and dword [a],0

function Jmp($t) { B 0xE9; Rel $t }
function Je($t) { B 0x0F, 0x84; Rel $t }
function Jne($t) { B 0x0F, 0x85; Rel $t }
function Jle($t) { B 0x0F, 0x8E; Rel $t }
function Jl($t) { B 0x0F, 0x8C; Rel $t }
function Call($t) { B 0xE8; Rel $t }
function CallIat($a) { B 0xFF, 0x15; Abs $a }
function CmpImm8($a, [byte]$v) { B 0x83, 0x3D; Abs $a; B $v }
function MovImm($a, [long]$v) { B 0xC7, 0x05; Abs $a; B (Le32 $v) }
function Dec32($a) { B 0xFF, 0x0D; Abs $a }
function Inc32($a) { B 0xFF, 0x05; Abs $a }
function PushMem($a) { B 0xFF, 0x35; Abs $a }
function PushImm([byte[]]$v) { B 0x68; B $v }
function PushAbs($t) { B 0x68; Abs $t }
function FldMem($a) { B 0xD9, 0x05; Abs $a }
function FstpMem($a) { B 0xD9, 0x1D; Abs $a }
function FaddDt { B 0xD8, 0x44, 0x24, 0x18 }

function SendCut([single]$Time, [switch]$Black) {
    # Key colour, pushed alpha first, then the key's duration.
    if ($Black) { PushImm (FloatBytes 1.0); B 0x6A, 0x00, 0x6A, 0x00, 0x6A, 0x00 }
    else { B 0x6A, 0x00, 0x6A, 0x00, 0x6A, 0x00, 0x6A, 0x00 }
    PushImm (FloatBytes $Time)
    B 0x6A, 0x00                      # +1C flag 0: apply unconditionally
    B 0x8D, 0x44, 0x24, 0x08          # lea eax,[esp+8] (colour)
    B 0x50                            # +18 colour list data
    B 0x6A, 0x00, 0x6A, 0x01          # +14 capacity 0 / +10 count 1
    B 0x8D, 0x44, 0x24, 0x10          # lea eax,[esp+0x10] (duration)
    B 0x50                            # +C time list data
    B 0x6A, 0x00, 0x6A, 0x01          # +8 capacity 0 / +4 count 1
    PushImm (Le32 $CutVtable)
    B 0x8B, 0xC4                      # mov eax,esp
    B 0x6A, 0x00, 0x50                # push 0 / push eax
    Call $BroadcastMsg
    B 0x83, 0xC4, 0x3C                # add esp,0x3C
}

# --- CaveB: called in place of the debug flag getter; esi = cinematic ---
L 'CaveB'
Call 'IsHeld'
B 0x85, 0xC0                          # test eax,eax
Je 'B1'
B 0x89, 0x35; Abs $Button             # mov [button],esi
L 'B1'
B 0x39, 0x35; Abs $Latch              # cmp [latch],esi
Jne 'B2'
MovImm $Counter 3
L 'B2'
MovImm $PromptTick 3
B 0x33, 0xC0, 0xC3                    # xor eax,eax / ret

# --- IsHeld: eax = 1 if Y on pad 0 or Space is down ---
L 'IsHeld'
CmpImm8 $Init 0
Jne 'Ready'
MovImm $Init 1
PushAbs 'StrXInput'; CallIat $IatLoadLib
B 0x85, 0xC0; Je 'NoXInput'
PushAbs 'StrGetState'; B 0x50; CallIat $IatGetProc
B 0xA3; Abs $PXInput
L 'NoXInput'
PushAbs 'StrUser32'; CallIat $IatGetModule
B 0x85, 0xC0; Je 'Ready'
PushAbs 'StrKeyState'; B 0x50; CallIat $IatGetProc
B 0xA3; Abs $PKey
L 'Ready'
if ($NoSkip) { B 0x33, 0xC0, 0xC3, 0x90, 0x90 }   # V38 -NoSkip: never held (xor eax,eax / ret), same 5 bytes as the mov
else { B 0xA1; Abs $PXInput }         # mov eax,[pXInput]
B 0x85, 0xC0; Je 'Keyboard'
B 0x83, 0xEC, 0x10                    # sub esp,16 (XINPUT_STATE)
B 0x54, 0x6A, 0x00, 0xFF, 0xD0        # push esp / push 0 / call eax
B 0x85, 0xC0; Jne 'PadGone'
MovImm $PadOk 1
B 0x66, 0xF7, 0x44, 0x24, 0x04, 0x00, 0x80  # test word [esp+4],0x8000 (Y)
Je 'PadNo'
B 0x83, 0xC4, 0x10                    # add esp,16
B 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3  # mov eax,1 / ret
L 'PadGone'
MovImm $PadOk 0
L 'PadNo'
B 0x83, 0xC4, 0x10
L 'Keyboard'
B 0xA1; Abs $PKey
B 0x85, 0xC0; Je 'NotHeld'
B 0x6A, 0x20, 0xFF, 0xD0              # push VK_SPACE / call eax
B 0xA9, 0x00, 0x80, 0x00, 0x00        # test eax,0x8000
Je 'NotHeld'
B 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3
L 'NotHeld'
B 0x33, 0xC0, 0xC3

# --- CaveC: speech "still playing?" check ---
L 'CaveC'
CmpImm8 $Phase 2
Je 'CDone'
Jmp $PhraseCheck
L 'CDone'
B 0x33, 0xC0, 0xC2, 0x04, 0x00        # xor eax,eax / ret 4

# --- GetPopup: eax = the HUD's HUDHintPopup, or 0. Same object path the game uses to reach HUD message handlers. ---
L 'GetPopup'
B 0xA1; Abs $HudOwner
B 0x85, 0xC0; Je 'GRet'
B 0x8B, 0x40, 0x58                    # mov eax,[eax+0x58]
B 0x85, 0xC0; Je 'GRet'
B 0x8B, 0x48, 0x0C                    # mov ecx,[eax+0xC]
B 0x8B, 0x49, 0x04                    # mov ecx,[ecx+4]
B 0x8D, 0x44, 0x08, 0x0C              # lea eax,[eax+ecx+0xC]
B 0x2B, 0x40, 0xFC                    # sub eax,[eax-4]
B 0x8B, 0x40, 0x88                    # mov eax,[eax-0x78]
L 'GRet'
B 0xC3

# --- StopVoice: stops any recorded voice still playing, so nothing waits on it or carries on past the scene ---
function LookupGroup([string]$Name, $Var, [string]$Skip) {
    CmpImm8 $Var 0
    Jne $Skip
    B 0x83, 0xEC, 0x04                    # sub esp,4 (symbol)
    PushAbs $Name
    B 0x8D, 0x4C, 0x24, 0x04              # lea ecx,[esp+4]
    Call $MakeSymbol
    B 0x54                                # push esp
    B 0x8B, 0x0D; Abs $SoundManager       # mov ecx,[sound manager]
    Call $FindGroup
    B 0xA3; Abs $Var
    B 0x83, 0xC4, 0x04                    # add esp,4
    L $Skip
}

L 'StopVoice'
LookupGroup 'StrVoCine' $VoGroup1 'VG1'
LookupGroup 'StrVoScripted' $VoGroup2 'VG2'
B 0xA1; Abs $VoGroup1
Call 'StopGroup'
B 0xA1; Abs $VoGroup2
Call 'StopGroup'
B 0xC3

L 'StopGroup'                         # eax = sound group
B 0x85, 0xC0; Je 'SGRet'
B 0x56, 0x57                          # push esi / push edi
B 0x8B, 0x78, 0x50                    # mov edi,[eax+0x50] (list of playing sounds)
B 0x85, 0xFF; Je 'SGDone'
B 0x8B, 0x37                          # mov esi,[edi]
L 'SGLoop'
B 0x3B, 0xF7; Je 'SGDone'             # cmp esi,edi
B 0x8B, 0x4E, 0x08                    # mov ecx,[esi+8]
B 0x8B, 0x36                          # mov esi,[esi] (advance first: stopping may unlink this node)
B 0x85, 0xC9; Je 'SGLoop'
B 0x51                                # push ecx
B 0x8B, 0x01, 0xFF, 0x50, 0x28        # is it playing? mov eax,[ecx] / call [eax+0x28]
B 0x59                                # pop ecx
B 0x84, 0xC0; Je 'SGLoop'
# A recorded stream must not be stopped while FMOD has a file read in flight for it: the game's close then deletes the
# reader at once and the read's completion writes into freed memory. Take the stream lock, and only stop when idle;
# otherwise leave it for the next frame.
B 0x8B, 0x01                          # mov eax,[ecx] (vtable)
B 0x81, 0x78, 0x24; B (Le32 $StreamStop)   # cmp dword [eax+0x24],stream stop
Jne 'SGStop'
B 0x83, 0x79, 0x48, 0x00              # cmp dword [ecx+0x48],0 (no stream open: nothing to race)
Je 'SGStop'
B 0x51; Call $StreamLock; B 0x59      # push ecx / enter stream lock / pop ecx
B 0x8B, 0x51, 0x48                    # mov edx,[ecx+0x48]
B 0x85, 0xD2; Je 'SGLocked'           # closed meanwhile: stop is safe
B 0x83, 0x7A, 0x5C, 0x00              # cmp dword [edx+0x5c],0 (read in flight?)
Je 'SGLocked'
Inc32 $StopWaits
Jmp 'SGUnlock'
L 'SGLocked'
B 0x8B, 0x01, 0xFF, 0x50, 0x24        # stop: mov eax,[ecx] / call [eax+0x24]
L 'SGUnlock'
Call $StreamUnlock
Jmp 'SGLoop'
L 'SGStop'
B 0x8B, 0x01, 0xFF, 0x50, 0x24        # stop: mov eax,[ecx] / call [eax+0x24]
Jmp 'SGLoop'
L 'SGDone'
B 0x5F, 0x5E                          # pop edi / pop esi
L 'SGRet'
B 0xC3

# --- TrackDevice: [Dev] = 1 after pad input, 0 after a new keyboard key press ---
# Windows' last-input timer also counts pad input, so keys are polled directly, and a key that goes down while the pad is
# active counts as pad (some controller tools send keys).
L 'TrackDevice'
B 0xA1; Abs $PXInput
B 0x85, 0xC0; Je 'TKb'
B 0x83, 0xEC, 0x10                    # sub esp,16 (XINPUT_STATE)
B 0x54, 0x6A, 0x00, 0xFF, 0xD0        # push esp / push 0 / call eax
B 0x85, 0xC0; Jne 'TGone'
CmpImm8 $DevInit 0
Jne 'TSeen'
MovImm $DevInit 1
MovImm $Dev 1                         # a connected pad is the starting assumption
L 'TSeen'
B 0x8B, 0x04, 0x24                    # mov eax,[esp] (packet number)
B 0x3B, 0x05; Abs $LastPacket
Je 'TSame'
B 0xA3; Abs $LastPacket
MovImm $Dev 1
MovImm $PadRecent 20
Jmp 'TPadDone'
L 'TSame'
CmpImm8 $PadRecent 0
Jle 'TPadDone'
Dec32 $PadRecent
Jmp 'TPadDone'
L 'TGone'
MovImm $Dev 0
L 'TPadDone'
B 0x83, 0xC4, 0x10                    # add esp,16
L 'TKb'
B 0xA1; Abs $PKey
B 0x85, 0xC0; Je 'TRet'
B 0x53, 0x56, 0x57                    # push ebx / push esi / push edi
B 0x8B, 0xF8                          # mov edi,eax (GetAsyncKeyState)
B 0x33, 0xDB                          # xor ebx,ebx (keys down)
B 0xBE, 0x08, 0x00, 0x00, 0x00        # mov esi,8 (skip mouse buttons)
L 'TKLoop'
B 0x56, 0xFF, 0xD7                    # push esi / call edi
B 0x66, 0xA9, 0x00, 0x80              # test ax,0x8000
Je 'TKUp'
B 0x43                                # inc ebx
L 'TKUp'
B 0x46                                # inc esi
B 0x81, 0xFE, 0xFF, 0x00, 0x00, 0x00  # cmp esi,0xFF
Jl 'TKLoop'
B 0x3B, 0x1D; Abs $LastKeys           # cmp ebx,[keys down last frame]
Jle 'TKNoNew'
CmpImm8 $PadRecent 0
Jne 'TKNoNew'
MovImm $Dev 0
L 'TKNoNew'
B 0x89, 0x1D; Abs $LastKeys           # mov [keys down last frame],ebx
B 0x5F, 0x5E, 0x5B                    # pop edi / pop esi / pop ebx
L 'TRet'
B 0xC3

# --- VolCurve: replaces "fmul [1/9]"; st0 holds the slider step, and is replaced by that step's volume from the table ---
L 'VolCurve'
B 0x50                                # push eax
B 0x83, 0xEC, 0x04                    # sub esp,4
B 0xDB, 0x1C, 0x24                    # fistp dword [esp]
B 0x8B, 0x04, 0x24                    # mov eax,[esp]
B 0x83, 0xC4, 0x04                    # add esp,4
B 0x83, 0xF8, 0x00, 0x7D, 0x02        # cmp eax,0 / jge +2
B 0x33, 0xC0                          # xor eax,eax
B 0x83, 0xF8, 0x09, 0x7E, 0x05        # cmp eax,9 / jle +5
B 0xB8, 0x09, 0x00, 0x00, 0x00        # mov eax,9
B 0xD9, 0x04, 0x85; Abs 'VolTable'    # fld dword [table+eax*4]
B 0x58, 0xC3                          # pop eax / ret

# --- TrimVoice: lowers the chapter-scene voice group once ---
L 'TrimVoice'
CmpImm8 $VoTrimmed 0
Jne 'TVRet'
LookupGroup 'StrVoCine' $VoGroup1 'TV1'
B 0xA1; Abs $VoGroup1
B 0x85, 0xC0; Je 'TVRet'
MovImm $VoTrimmed 1
PushImm (FloatBytes ([Math]::Pow(10, $CineDb / 20)))
B 0x8B, 0xC8                          # mov ecx,eax
Call $SetGroupVolume
L 'TVRet'
B 0xC3

# --- PickText: eax = prompt for the current device; records which device it is for ---
L 'PickText'
B 0xA1; Abs $Dev
B 0xA3; Abs $DevShown
CmpImm8 $Dev 0
Jne 'PPad'
B 0xB8; Abs 'StrPromptKeys'
B 0xC3
L 'PPad'
Call 'IsSony'
B 0x85, 0xC0; Jne 'PTri'
B 0xB8; Abs 'StrPromptY'
B 0xC3
L 'PTri'
B 0xB8; Abs 'StrPromptTri'
B 0xC3

# --- IsSony: eax = 1 if any Windows joystick has Sony's vendor id ---
L 'IsSony'
CmpImm8 $JoyInit 0
Jne 'SReady'
MovImm $JoyInit 1
PushAbs 'StrWinmm'; CallIat $IatLoadLib
B 0x85, 0xC0; Je 'SReady'
PushAbs 'StrJoyCaps'; B 0x50; CallIat $IatGetProc
B 0xA3; Abs $PJoy
L 'SReady'
CmpImm8 $PJoy 0
Je 'SNone'
B 0x56                                # push esi
B 0x33, 0xF6                          # xor esi,esi
B 0x81, 0xEC, 0x94, 0x01, 0x00, 0x00  # sub esp,0x194 (JOYCAPSA)
L 'SLoop'
B 0x68, 0x94, 0x01, 0x00, 0x00        # push 0x194
B 0x8D, 0x44, 0x24, 0x04              # lea eax,[esp+4]
B 0x50, 0x56                          # push eax / push esi
B 0xA1; Abs $PJoy
B 0xFF, 0xD0                          # call eax
B 0x85, 0xC0; Jne 'SNext'
B 0x66, 0x81, 0x3C, 0x24, 0x4C, 0x05  # cmp word [esp],0x054C
Je 'SFound'
L 'SNext'
B 0x46                                # inc esi
B 0x83, 0xFE, 0x10                    # cmp esi,16
Jl 'SLoop'
B 0x33, 0xC0                          # xor eax,eax
Jmp 'SDone'
L 'SFound'
B 0xB8, 0x01, 0x00, 0x00, 0x00        # mov eax,1
L 'SDone'
B 0x81, 0xC4, 0x94, 0x01, 0x00, 0x00  # add esp,0x194
B 0x5E, 0xC3                          # pop esi / ret
L 'SNone'
B 0x33, 0xC0, 0xC3

# --- HintUpdate: shows the hint while a cinematic is ticking and no skip is running; hides it otherwise ---
L 'HintUpdate'
CmpImm8 $PromptTick 0
Jle 'HNoScene'
Dec32 $PromptTick
Call 'TrackDevice'
Call 'TrimVoice'
Jmp 'H1'
L 'HNoScene'
MovImm $LastKeys 0x7FFFFFFF             # keys held when a scene starts are not a new press
L 'H1'
CmpImm8 $Hint 0
Jne 'HActive'
if ($NoSkip) { B 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 }   # V38 -NoSkip: never create the hint (ret), same 7 bytes as the cmp
else { CmpImm8 $PromptTick 0 }
Jle 'HRet'
CmpImm8 $Phase 0
Jne 'HRet'
Call 'GetPopup'
B 0x85, 0xC0; Je 'HRet'
B 0xA3; Abs $HintPopup
B 0x83, 0xEC, 0x08                    # sub esp,8 ([esp] allocator flag, [esp+4] string handle)
B 0xC7, 0x04, 0x24, 0x00, 0x00, 0x00, 0x00  # mov dword [esp],0
Call 'PickText'
B 0x50                                # push eax
B 0x8D, 0x4C, 0x24, 0x08              # lea ecx,[esp+8] (string handle)
Call $MakeString
B 0x8B, 0x0D; Abs $Allocator          # mov ecx,[allocator]
B 0x8B, 0x11                          # mov edx,[ecx]
B 0x8D, 0x04, 0x24                    # lea eax,[esp]
B 0x50, 0x6A, 0x0C                    # push eax / push 0xC
B 0xFF, 0x52, 0x2C                    # call [edx+0x2C]
B 0x85, 0xC0; Je 'HFail'
B 0x8D, 0x4C, 0x24, 0x04              # lea ecx,[esp+4]
B 0x51                                # push ecx
B 0x8B, 0xC8                          # mov ecx,eax
Call $HintCtor
B 0xA3; Abs $Hint
B 0xFF, 0x40, 0x04                    # inc dword [eax+4] (our reference)
B 0xFF, 0x40, 0x04                    # inc dword [eax+4] (consumed by HintAdd)
B 0x50                                # push eax
B 0x8B, 0x0D; Abs $HintPopup          # mov ecx,[popup]
Call $HintAdd
L 'HFail'
B 0x83, 0xC4, 0x08                    # add esp,8
L 'HRet'
B 0xC3

L 'HActive'
CmpImm8 $PromptTick 0
Jle 'HHide'
CmpImm8 $Phase 0
Jne 'HHide'
B 0xA1; Abs $Dev
B 0x3B, 0x05; Abs $DevShown            # cmp eax,[device shown]
Je 'HRet'
L 'HHide'
Call 'GetPopup'
B 0x3B, 0x05; Abs $HintPopup          # cmp eax,[popup]
Jne 'HClear'                          # the HUD was rebuilt, so the hint went with it
B 0x8B, 0xC8                          # mov ecx,eax
B 0xA1; Abs $Hint
B 0xFF, 0x40, 0x04                    # inc dword [eax+4] (consumed by HintRemove)
B 0x50                                # push eax
Call $HintRemove
L 'HClear'
MovImm $Hint 0
MovImm $HintPopup 0
B 0xC3

# --- Frame: frame time is at [esp+0x18] ---
L 'Frame'
Call 'FrameExtra3'                    # (V42: load bo2skipui.dll once) sound fade, chain timer, then HintUpdate
CmpImm8 $Phase 2
Jne 'NotForward'
CmpImm8 $Counter 0
Jle 'SkipEnd'
Dec32 $Counter
FldMem $SkipT; FaddDt; FstpMem $SkipT
FldMem $SkipT
B 0xD8, 0x1D; Abs 'ValMaxSkip'         # fcomp [max skip seconds]
B 0xDF, 0xE0, 0xF6, 0xC4, 0x01        # fnstsw ax / test ah,1
Je 'SkipEnd'
Call 'ScaleDt'                        # frame time *= multiplier, unless this is a chapter-scene abort
SendCut 0.0 -Black                    # re-assert black each frame in case something else restarts the element
Call 'StopVoice'
Jmp 'Done'

L 'SkipEnd'
Call 'SkipEndExtra'                   # clears a pending abort, opens the window for a following cinematic
MovImm $Latch 0
MovImm $Phase 3
MovImm $HoldT 0
MovImm $Counter 0
MovImm $WaitT 0
SendCut $FadeSeconds
Jmp 'Done'

L 'NotForward'
CmpImm8 $Phase 1
Jne 'CheckReset'
CmpImm8 $Counter 0
Jle 'SkipEnd'
Dec32 $Counter
FldMem $WaitT; FaddDt; FstpMem $WaitT
FldMem $WaitT
B 0xD8, 0x1D; Abs 'ValFade'           # fcomp [fade seconds]
B 0xDF, 0xE0, 0xF6, 0xC4, 0x01        # fnstsw ax / test ah,1
Jne 'Done'
MovImm $Phase 2
AndZero $SkipT
Call 'StartForward'                   # chapter scene? then ask for the game's abort instead of fast-forwarding
Jmp 'Done'

L 'CheckReset'
CmpImm8 $Phase 3
Jne 'Idle'
CmpImm8 $DevSkip 0                    # after a chapter-scene abort, keep its voice track stopped while fading back
Jz8 'CR1'
Call 'StopVoice'
L 'CR1'
FldMem $WaitT; FaddDt; FstpMem $WaitT
FldMem $WaitT
B 0xD8, 0x1D; Abs 'ValFade'           # fcomp [fade seconds]
B 0xDF, 0xE0, 0xF6, 0xC4, 0x01        # fnstsw ax / test ah,1
Jne 'Done'
MovImm $Phase 0
AndZero $DevSkip
Jmp 'Done'

L 'Idle'
B 0x8B, 0x0D; Abs $Button             # mov ecx,[button]
B 0x85, 0xC9; Je 'Released'
MovImm $Button 0
FldMem $HoldT; FaddDt; FstpMem $HoldT
FldMem $HoldT
B 0xD8, 0x1D; Abs 'ValHold'           # fcomp [hold seconds]
B 0xDF, 0xE0, 0xF6, 0xC4, 0x01
Jne 'Done'
B 0x89, 0x0D; Abs $Latch              # mov [latch],ecx
MovImm $Counter 3
MovImm $Phase 1
MovImm $WaitT 0
MovImm $HoldT 0
SendCut $FadeSeconds -Black
Jmp 'Done'

L 'Released'
MovImm $HoldT 0

L 'Done'
B 0x8B, 0x0D; B (Le32 $CameraGlobal)  # mov ecx,[camera global], the instruction the hook replaced
Jmp $FrameReturn

# --- MixerStart: clears the mixer thread's "exited" flag, then starts the thread as before ---
L 'MixerStart'
B 0xC6, 0x05; Abs $MixerExited; B 0x00   # mov byte [exited],0
Jmp $MixerStartFn

# --- ScaleDt: called from Frame; the frame time is at [esp+0x1C] here. Fast-forwards unless this skip is a chapter-scene abort. ---
L 'ScaleDt'
CmpImm8 $DevSkip 0
Jnz8 'SCRet'
B 0xD9, 0x44, 0x24, 0x1C              # fld dword [esp+1C]
Call 'MulGate'; B 0x90                # fmul [multiplier], unless the stream loader is busy (V35)
B 0xD9, 0x5C, 0x24, 0x1C              # fstp dword [esp+1C]
L 'SCRet'
B 0xC3

# SeerTick: eax = name of the ticking cinematic esi (not a no-skip one). Marks a skip of bo2cinematic_meeting_seer, then NSNo.
L 'SeerTick'
B 0x81, 0x78, 0x12; B ([Text.Encoding]::ASCII.GetBytes('_mee'))
Jnz8 'STNo'
B 0x81, 0x78, 0x16; B ([Text.Encoding]::ASCII.GetBytes('ting'))
Jnz8 'STNo'
B 0x3B, 0x35; Abs $Latch              # cmp esi,[latch]: being skipped
Jnz8 'STNo'
MovImm $SeerSkip 1
L 'STNo'
Jmp 'NSNo'
L 'CodeEnd'

# --- Spare A (unused game function at 0x4E0130) ---
Org $SpareA $SpareALimit
# CaveB0: fn2 calls this in place of the debug-flag getter, only while the cinematic is in cinematicstate; esi = cinematic,
# stack = [return 0x4E0188][7][5][fn2's saved ebx]. For a requested chapter-scene abort, unwind to the state fn2 has after its own
# "flag set and jump pressed" test and continue at its abort call. Otherwise this is CaveB as before.
L 'CaveB0'
B 0x89, 0x35; Abs $LastCine           # mov [last cinematic],esi
MovImm $CineSeen 3
Call 'NoSkipGate'                     # boss-fight scenes the player takes part in: return to fn2 with no prompt
CmpImm8 $AbortReq 0
Je 'CaveB'
B 0x39, 0x35; Abs $Latch              # cmp [latch],esi
Jne 'CaveB'
AndZero $AbortReq
B 0x83, 0xC4, 0x0C                    # add esp,0xC (return address and the getter's two arguments)
B 0x5B                                # pop ebx
Jmp $AbortPath                        # 0x4E0070(this, endedwithabortstate), as the developer skip does
L 'SpareAEnd'

# --- Spare B (unused game functions at 0x4E0230-0x4E02CF) ---
Org $SpareB $SpareBLimit
# StartForward: the fade is black. For a chapter scene, mark the skip as an abort and ask the cinematic's next tick to take it.
L 'StartForward'
Call 'IsChapter'
B 0xA3; Abs $DevSkip                  # mov [DevSkip],eax
B 0xA3; Abs $AbortReq                 # mov [AbortReq],eax
B 0x01, 0x05; Abs $DevSkips           # add [DevSkips],eax
B 0xC3

# SoundDt: the sound update's frame time, multiplied while fast-forwarding (st0 = seconds)
L 'SoundDt'
Call $FrameTimeFn
CmpImm8 $Phase 2
Jnz8 'SDRet'
CmpImm8 $DevSkip 0
Jnz8 'SDRet'
Call 'MulGate'; B 0x90                # fmul [multiplier], unless the stream loader is busy (V35)
L 'SDRet'
B 0xC3

# SkipEndExtra: a skip just ended (Latch still set). Drop a pending abort; let a cinematic that starts within ChainSeconds carry on.
L 'SkipEndExtra'
AndZero $AbortReq
B 0xA1; Abs $Latch
B 0xA3; Abs $PrevLatch
B 0x2B, 0x05; Abs $LoadReset          # sub eax,[LoadReset]: 0 when a load screen loaded during this skip (V35)
B 0xA3; Abs $ChainOn                  # chain window open when nonzero
AndZero $LoadReset
AndZero $ChainT
B 0xC3

# MulGate: st0 *= multiplier, unless the stream loader has files queued (see the V35 header). Uses eax only.
L 'MulGate'
B 0xA1; Abs $LoadQueue                # mov eax,[0x00A79CD4]
B 0x85, 0xC0; Jz8 'MGMul'
B 0x8B, 0x00                          # mov eax,[eax] (loader)
B 0x85, 0xC0; Jz8 'MGMul'
B 0x8B, 0x40, 0x0C                    # mov eax,[eax+0xC] (queue sentinel)
B 0x39, 0x00                          # cmp [eax],eax
Jnz8 'MGRet'                          # a file is queued: leave the time as it is
L 'MGMul'
B 0xD8, 0x0D; Abs 'ValMult'           # fmul [multiplier]
L 'MGRet'
B 0xC3

# NoSkipGate: called from CaveB0 (esi = cinematic). For a cinematic that must play out (see the V31 header), drop CaveB0's frame and
# return to fn2 with eax = 0, as CaveB does; otherwise run ChainCheck and go back to CaveB0.
L 'NoSkipGate'
B 0x8B, 0x46, 0x2C                    # mov eax,[esi+0x2C]
B 0x85, 0xC0; Jz8 'NSNo'
B 0x8B, 0x80; B (Le32 0xB0)           # mov eax,[eax+0xB0] (name string)
B 0x85, 0xC0; Jz8 'NSNo'
Jmp 'NoSkipName'                      # comes back to NSNo or NSYes
L 'NSNo'
Jmp 'ChainCheck'
L 'NSYes'
B 0x83, 0xC4, 0x04                    # add esp,4 (CaveB0's return address)
B 0x33, 0xC0, 0xC3                    # xor eax,eax / ret (to fn2)
L 'SpareBEnd'

# --- Spare C (unused game function at 0x4E8EE0) ---
Org $SpareC $SpareCLimit
# FrameExtra: called first in Frame (frame time at [esp+0x1C]); ages the chain window, then runs HintUpdate.
L 'FrameExtra'
CmpImm8 $ChainOn 0
Jz8 'FXHint'
FldMem $ChainT
B 0xD8, 0x44, 0x24, 0x1C              # fadd dword [esp+1C]
FstpMem $ChainT
FldMem $ChainT
B 0xD8, 0x1D; Abs 'ValChain'          # fcomp [chain seconds]
B 0xDF, 0xE0, 0xF6, 0xC4, 0x01        # fnstsw ax / test ah,1
Jnz8 'FXHint'
AndZero $ChainOn
L 'FXHint'
Call 'ScriptScene'
Call 'HudFix'
Jmp 'HintUpdate'

# ChainCheck: a cinematic (esi) ticks. If a skip ended less than ChainSeconds ago and this is another cinematic, continue it.
L 'ChainCheck'
CmpImm8 $ChainOn 0
Jz8 'CCRet'
B 0x3B, 0x35; Abs $PrevLatch          # cmp esi,[previous latch]
Jz8 'CCRet'
AndZero $ChainOn
Inc32 $Chains
CmpImm8 $Phase 3
Jnz8 'CCIdle'
B 0x89, 0x35; Abs $Latch              # still fading back: latch it and go straight back to black
MovImm $Counter 3
MovImm $Phase 2
Jmp 'StartForward'                    # chapter scene? (returns to our caller)
L 'CCIdle'
CmpImm8 $Phase 0
Jnz8 'CCRet'
B 0x89, 0x35; Abs $Button             # already faded back: start a skip now, as if the button had been held long enough
FldMem 'ValHold'
FstpMem $HoldT
L 'CCRet'
B 0xC3

# OnLoaded: the stream loader finished a file (esi = request, [[req]]+6 = file name). A load screen closes the chain window and
# marks the skip running now (if any) so that it does not open one when it ends (V35).
L 'OnLoaded'
B 0x8B, 0x06                          # mov eax,[esi] (name string)
B 0x85, 0xC0; Jz8 'OLDone'
B 0x81, 0x78, 0x28; B ([Text.Encoding]::ASCII.GetBytes('load'))   # "/gogames/bo2/resources/levels/hud/load_screens/"
Jnz8 'OLDone'
AndZero $ChainOn
B 0xA1; Abs $Latch
B 0xA3; Abs $LoadReset
L 'OLDone'
Jmp $LoadStats

# HudFix: after a skip of the Seer scene, put the HUD back into kain mode if the game left it in cinematic mode (see the V34 header).
L 'HudFix'
CmpImm8 $SeerSkip 0
Jz8 'HFRet'
CmpImm8 $Phase 0
Jnz8 'HFRet'
CmpImm8 $ChainOn 0                    # the skip ended less than ChainSeconds ago
Jnz8 'HFRet'
AndZero $SeerSkip                     # one look only
CmpImm8 $CineSeen 0                   # another cinematic is running: leave its HUD alone
Jnz8 'HFRet'
CmpImm8 $HudMode 2                    # HUD already out of cinematic mode
Jnz8 'HFRet'
B 0x6A, 0x01                          # push 1 (kain_hud)
B 0x8B, 0x0D; Abs $HudPtr             # mov ecx,[HudPtr]
Call $HudSetMode
L 'HFRet'
B 0xC3

# LightGate: esi = a lightning cinematic (from NoSkipName). Skippable, but the fast-forward stops after LightCap real seconds.
L 'LightGate'
B 0x3B, 0x35; Abs $CapCine            # cmp esi,[CapCine]: already stopped once, play the rest normally
Jz8 'LGYes'
CmpImm8 $Phase 2
Jnz8 'LGNo'
FldMem $SkipT
B 0xD8, 0x1D; Abs 'ValLightCap'       # fcomp [light cap]
B 0xDF, 0xE0, 0xF6, 0xC4, 0x01        # fnstsw ax / test ah,1 (below the cap)
Jnz8 'LGNo'
B 0x89, 0x35; Abs $CapCine            # mov [CapCine],esi
L 'LGYes'
Jmp 'NSYes'
L 'LGNo'
Jmp 'NSNo'
L 'SpareCEnd'

# --- Spare D (unused game function at 0x4CA8D0) ---
Org $SpareD $SpareDLimit
# ScriptScene: called from FrameExtra each frame (frame time at [esp+0x20]). A scripted scene (the game camera playing an exported
# path for ScriptDelay seconds while no cinematic ticks) acts like a ticking cinematic whose pointer is ScriptMarker, the way CaveB
# acts for real cinematics.
L 'ScriptScene'
CmpImm8 $CineSeen 0
Jle 'SS1'
Dec32 $CineSeen
L 'SS1'
Call 'HudRead'                        # for the launcher's log
Call 'CamRead'                        # eax = exported camera path playing, or 0
CmpImm8 $CineSeen 0
Jz8 'SS4'
B 0x85, 0xC0; Je 'SSOff'              # a cinematic is ticking (it drives the skip itself)
B 0xA3; Abs $CineCam                  # and this path is its own
Jmp 'SSOff'
L 'SS4'
AndZero $CapCine                      # no cinematic ticking: the next lightning scene is skippable again
CmpImm8 $Latch 1                      # a scripted skip is running: carry on while the camera stays scripted
Jnz8 'SS5'
CmpImm8 $CamMode 3
Je 'SSGo'
CmpImm8 $CamMode 1                    # between two paths: no creature followed
Je 'SSGo'
Jmp 'SSOff'
L 'SS5'
B 0x85, 0xC0; Je 'SSOff'              # no path playing
CmpImm8 $ChainOn 0                    # a skip just ended: continue into this path at once
Jne 'SSGo'
B 0x3B, 0x05; Abs $CineCam            # cmp eax,[CineCam]: still the path a cinematic was playing
Je 'SSOff'
FldMem $ScriptT
B 0xD8, 0x44, 0x24, 0x20              # fadd dword [esp+20] (real frame time; scaling happens after FrameExtra)
FstpMem $ScriptT
FldMem $ScriptT
B 0xD8, 0x1D; Abs 'ValScriptDelay'
B 0xDF, 0xE0, 0xF6, 0xC4, 0x01        # fnstsw ax / test ah,1
Jne 'SSRet'                          # not long enough yet
L 'SSGo'
MovImm $ScriptOn 1
B 0x56                                # push esi
B 0xBE; B (Le32 $ScriptMarker)        # mov esi,marker
Call 'ChainCheck'
Call 'IsHeld'
B 0x85, 0xC0; Jz8 'SS2'
B 0x89, 0x35; Abs $Button
L 'SS2'
B 0x39, 0x35; Abs $Latch              # cmp [latch],esi
Jnz8 'SS3'
CmpImm8 $Phase 2
Jnz8 'SSKeep'
FldMem $SkipT
B 0xD8, 0x1D; Abs 'ValScriptMax'
B 0xDF, 0xE0, 0xF6, 0xC4, 0x01        # fnstsw ax / test ah,1
Jz8 'SS3'                             # ran long enough: let the skip end
L 'SSKeep'
MovImm $Counter 3
L 'SS3'
MovImm $PromptTick 3
B 0x5E                                # pop esi
B 0xC3
L 'SSOff'
AndZero $ScriptT
AndZero $ScriptOn
L 'SSRet'
B 0xC3
# IsChapter: eax = 1 if the latched cinematic has a chapter name (V30: the region mark no longer counts; see the header).
L 'IsChapter'
B 0xA1; Abs $Latch                    # mov eax,[latch]
B 0x85, 0xC0; Jz8 'INo'
Jmp 'NameCheck'                       # eax = cinematic; returns eax
L 'INo'
B 0x33, 0xC0, 0xC3

L 'SpareDEnd'

# --- Spare E (unused game functions at 0x4CC810-0x4CC93F) ---
Org $SpareE $SpareELimit
# HudRead: HudMode = the HUD's mode ([HUD+0x104]), -1 if there is no HUD. Only the launcher's log uses it.
L 'HudRead'
B 0x83, 0x0D; Abs $HudMode; B 0xFF    # or dword [HudMode],-1
B 0xA1; Abs $HudOwner
B 0x85, 0xC0; Jz8 'HRDone'
B 0x8B, 0x40, 0x58                    # mov eax,[eax+0x58] (HUD)
B 0x85, 0xC0; Jz8 'HRDone'
B 0x81, 0x38; B (Le32 $HudVtable)     # cmp dword [eax],HUD vtable
Jnz8 'HRDone'
B 0xA3; Abs $HudPtr                   # mov [HudPtr],eax
B 0x8B, 0x80; B (Le32 0x104)          # mov eax,[eax+0x104] (mode)
B 0xA3; Abs $HudMode
L 'HRDone'
B 0xC3

# CamRead: CamMode/CamPath from the game camera; eax = the exported path it plays (mode 3), else 0. Only eax is changed.
L 'CamRead'
B 0x83, 0x0D; Abs $CamMode; B 0xFF    # or dword [CamMode],-1
AndZero $CamPath
B 0xA1; Abs $WorldState               # mov eax,[world state]
B 0x85, 0xC0; Jz8 'CRNo'
B 0x83, 0x38, 0x01; Jnz8 'CRNo'       # cmp dword [eax],1 (a world is running)
B 0x8B, 0x40, 0x08                    # mov eax,[eax+8]
B 0x85, 0xC0; Jz8 'CRNo'
B 0x8B, 0x00                          # mov eax,[eax] (world)
B 0x85, 0xC0; Jz8 'CRNo'
B 0x8B, 0x40, 0x44                    # mov eax,[eax+0x44]
B 0x85, 0xC0; Jz8 'CRNo'
B 0x8B, 0x80; B (Le32 0x124)          # mov eax,[eax+0x124] (camera behaviour)
B 0x85, 0xC0; Jz8 'CRNo'
B 0x81, 0x38; B (Le32 $CameraVtable)  # cmp dword [eax],GameCamera vtable
Jnz8 'CRNo'
B 0xFF, 0xB0; B (Le32 0x98)           # push dword [eax+0x98] (mode)
B 0x8F, 0x05; Abs $CamMode            # pop dword [CamMode]
B 0x8B, 0x80; B (Le32 0x90)           # mov eax,[eax+0x90] (exported camera path)
B 0xA3; Abs $CamPath
CmpImm8 $CamMode 3
Jnz8 'CRNo'
B 0xC3
L 'CRNo'
B 0x33, 0xC0, 0xC3

# NameCheck: eax = cinematic; eax = 1 if its object name is bo2cinematic_after_iq / _kainmeet... / _kaintake..., else 0.
L 'NameCheck'
B 0x83, 0xF8, 0x01; Jbe8 'NCNo'       # cmp eax,1 / jbe (no cinematic, or the scripted-scene marker)
B 0x8B, 0x40, 0x2C                    # mov eax,[eax+0x2C]
B 0x85, 0xC0; Jz8 'NCNo'
B 0x8B, 0x80; B (Le32 0xB0)           # mov eax,[eax+0xB0] (name string)
B 0x85, 0xC0; Jz8 'NCNo'
B 0x81, 0x78, 0x06; B ([Text.Encoding]::ASCII.GetBytes('bo2c'))
Jnz8 'NCNo'
B 0x81, 0x78, 0x0A; B ([Text.Encoding]::ASCII.GetBytes('inem'))
Jnz8 'NCNo'
B 0x81, 0x78, 0x0E; B ([Text.Encoding]::ASCII.GetBytes('atic'))
Jnz8 'NCNo'
B 0x80, 0x78, 0x12, 0x5F              # cmp byte [eax+0x12],'_'
Jnz8 'NCNo'
B 0x81, 0x78, 0x13; B ([Text.Encoding]::ASCII.GetBytes('afte'))
Jnz8 'NC2'
B 0x81, 0x78, 0x17; B ([Text.Encoding]::ASCII.GetBytes('r_iq'))
Jz8 'NCYes'
L 'NC2'
B 0x81, 0x78, 0x13; B ([Text.Encoding]::ASCII.GetBytes('kain'))
Jnz8 'NCNo'
B 0x81, 0x78, 0x17; B ([Text.Encoding]::ASCII.GetBytes('meet'))
Jz8 'NCYes'
B 0x81, 0x78, 0x17; B ([Text.Encoding]::ASCII.GetBytes('take'))
Jz8 'NCYes'
L 'NCNo'
B 0x33, 0xC0, 0xC3
L 'NCYes'
B 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3

# NoSkipName: eax = cinematic object name. m_cinematic_jewel / _jg_jewel -> NSYes; m_cinematic_lightning -> LightGate; else NSNo.
L 'NoSkipName'
B 0x81, 0x78, 0x12; B ([Text.Encoding]::ASCII.GetBytes('jewe'))
Jz8 'NNYes'
B 0x81, 0x78, 0x12; B ([Text.Encoding]::ASCII.GetBytes('jg_j'))
Jz8 'NNYes'
B 0x81, 0x78, 0x12; B ([Text.Encoding]::ASCII.GetBytes('ligh'))
Jnz8 'NNNo'
Jmp 'LightGate'
L 'NNNo'
Jmp 'DoorGate'                        # the Wharves door scene -> NSYes; else SeerTick, then NSNo (V36)
L 'NNYes'
Jmp 'NSYes'
L 'SpareEEnd'

# --- Spare F (unused game function at 0x49AB70) ---
Org $SpareF $SpareFLimit
# FrameExtra2: called first in Frame (frame time at [esp+0x1C]); runs the sound fade, then FrameExtra.
L 'FrameExtra2'
Call 'FxTick'
Jmp 'FrameExtra'

# FxTick: frame time at [esp+0x20]. FxAtt goes toward 1 while the screen fades out and the scene is skipped (phases 1 and 2),
# toward 0 otherwise, by frame time / FadeSeconds; while it moves, the sfx and vo groups pass their new final volume on.
L 'FxTick'
CmpImm8 $Phase 1
Jz8 'FTOut'
CmpImm8 $Phase 2
Jz8 'FTOut'
CmpImm8 $FxAtt 0                      # already at full volume
Je 'FTRet'
FldMem $FxAtt
B 0xD9, 0x44, 0x24, 0x20              # fld dword [esp+0x20] (frame time)
B 0xD8, 0x35; Abs 'ValFade'           # fdiv [fade seconds]
B 0xDE, 0xE9                          # fsubp st1,st0
FstpMem $FxAtt
B 0xF6, 0x05; Abs ($FxAtt + 3); B 0x80   # test byte [FxAtt+3],0x80: below zero?
Jz8 'FTApply'
AndZero $FxAtt
Jmp8 'FTApply'
L 'FTOut'
B 0x81, 0x3D; Abs $FxAtt; B (Le32 0x3F800000)   # cmp dword [FxAtt],1.0
B 0x73; Rel8 'FTRet'                  # jae: already silent
FldMem $FxAtt
B 0xD9, 0x44, 0x24, 0x20              # fld dword [esp+0x20]
B 0xD8, 0x35; Abs 'ValFade'           # fdiv [fade seconds]
B 0xDE, 0xC1                          # faddp st1,st0
FstpMem $FxAtt
B 0x81, 0x3D; Abs $FxAtt; B (Le32 0x3F800000)
B 0x72; Rel8 'FTApply'                # jb
MovImm $FxAtt 0x3F800000
L 'FTApply'
B 0xA1; Abs $SoundManager             # mov eax,[sound manager]
B 0x85, 0xC0; Jz8 'FTRet'
B 0x83, 0xC0, 0x12                    # add eax,0x12 (symbol "sfx")
Call 'Refresh'
B 0xA1; Abs $SoundManager
B 0x83, 0xC0, 0x14                    # add eax,0x14 (symbol "vo")
Call 'Refresh'
L 'FTRet'
B 0xC3

# Refresh: eax = a root group's name symbol. Sets the group's own volume again (same value), so its final volume is computed
# afresh and reaches its child groups and sounds.
L 'Refresh'
B 0x50                                # push eax
B 0x8B, 0x0D; Abs $SoundManager       # mov ecx,[sound manager]
Call $FindGroup
B 0x85, 0xC0; Jz8 'RAret'
B 0x8B, 0xC8                          # mov ecx,eax
# Reapply: ecx = group.
L 'Reapply'
B 0xFF, 0x71, 0x1C                    # push dword [ecx+0x1C] (the group's own volume)
Call $SetGroupVolume
L 'RAret'
B 0xC3

# SliderSfx/SliderVo/SliderMusic: the options code's volume calls for those groups (thiscall, ecx = group, volume on the stack).
# Keep the slider level for GainEax and leave the group's own volume as it is.
L 'SliderSfx'
B 0x8B, 0x44, 0x24, 0x04              # mov eax,[esp+4]
B 0xA3; Abs $SlSfx
B 0x80, 0x0D; Abs $SliderSet; B 0x01  # or byte [SliderSet],1
Jmp8 'SlApply'
L 'SliderVo'
B 0x8B, 0x44, 0x24, 0x04
B 0xA3; Abs $SlVo
B 0x80, 0x0D; Abs $SliderSet; B 0x02
Jmp8 'SlApply'
L 'SliderMusic'
B 0x8B, 0x44, 0x24, 0x04
B 0xA3; Abs $SlMus
B 0x80, 0x0D; Abs $SliderSet; B 0x04
L 'SlApply'
B 0x85, 0xC9; Jz8 'SlRet'
Call 'Reapply'
L 'SlRet'
B 0xC2, 0x04, 0x00                    # ret 4

# GainEdi/GainEax: in place of "fld [params+0x14] / fmul [esi+0x1C] / fstp [esi+0x40]" in the group update (esi = group,
# edi or eax = the parent's params). Root sfx, vo and music groups also take their slider level; sfx and vo the skip fade.
L 'GainEdi'
B 0x8B, 0xC7                          # mov eax,edi
L 'GainEax'
B 0xD9, 0x40, 0x14                    # fld dword [eax+0x14] (parent's final volume)
B 0xD8, 0x4E, 0x1C                    # fmul dword [esi+0x1C] (own volume)
B 0x81, 0x3E; B (Le32 $GroupVtable)   # cmp dword [esi],sound group vtable
Jnz8 'GStore'
B 0x8B, 0x0D; Abs $SoundManager       # mov ecx,[sound manager]
B 0x85, 0xC9; Jz8 'GStore'
B 0x66, 0x8B, 0x46, 0x54              # mov ax,[esi+0x54] (group name symbol)
B 0x66, 0x85, 0xC0; Jz8 'GStore'
B 0x66, 0x3B, 0x41, 0x12; Jnz8 'G2'   # cmp ax,[ecx+0x12]: sfx?
B 0x89, 0x35; Abs $SfxGrp             # mov [SfxGrp],esi
B 0xF6, 0x05; Abs $SliderSet; B 0x01  # test byte [SliderSet],1
Jz8 'GFx'
B 0xD8, 0x0D; Abs $SlSfx              # fmul [slider level]
Jmp8 'GFx'
L 'G2'
B 0x66, 0x3B, 0x41, 0x14; Jnz8 'G3'   # vo?
B 0x89, 0x35; Abs $VoGrp
B 0xF6, 0x05; Abs $SliderSet; B 0x02
Jz8 'GFx'
B 0xD8, 0x0D; Abs $SlVo
L 'GFx'
B 0xD9, 0xE8                          # fld1
B 0xD8, 0x25; Abs $FxAtt              # fsub [FxAtt]
B 0xD8, 0xC8                          # fmul st0,st0 (fade on a squared curve)
B 0xDE, 0xC9                          # fmulp st1,st0
Jmp8 'GStore'
L 'G3'
B 0x66, 0x3B, 0x41, 0x18; Jnz8 'GStore'   # music?
B 0x89, 0x35; Abs $MusGrp
B 0xF6, 0x05; Abs $SliderSet; B 0x04
Jz8 'GStore'
B 0xD8, 0x0D; Abs $SlMus
L 'GStore'
B 0xD9, 0x5E, 0x40                    # fstp dword [esi+0x40] (final volume)
B 0xC3
L 'SpareFEnd'

# --- Spare G (unused game function at 0x4CCC10, V36) ---
Org $SpareG $SpareGLimit
# DoorGate: eax = name record of cinematic esi (not one of the named no-skip scenes). The Wharves door scene
# (wh08's bo2cinematic001 placed at x 1162.65, y 3852.58; V36 had wh05's by mistake) goes to NSYes: fast-forwarding it makes the level reset. Else SeerTick.
L 'DoorGate'
B 0x81, 0x78, 0x12; B ([byte[]](0x30, 0x30, 0x31, 0x00))   # cmp dword [eax+0x12],"001 " (name characters 12-15)
Jnz8 'DGOut'
B 0x50                                # push eax
B 0x8B, 0x46, 0x2C                    # mov eax,[esi+0x2C] (instance; NoSkipGate checked it is not null)
B 0x81, 0xB8; B (Le32 0xB4); B (Le32 0x449154DE)   # cmp dword [eax+0xB4],x (1162.65, V37)
Jnz8 'DGPop'
B 0x81, 0xB8; B (Le32 0xB8); B (Le32 0x4570C938)   # cmp dword [eax+0xB8],y (3852.58, V37)
Jnz8 'DGPop'
B 0x58                                # pop eax
Jmp 'NSYes'
L 'DGPop'
B 0x58                                # pop eax
L 'DGOut'
Jmp 'SeerTick'

# StreamAlloc (V39): replaces the stream play's call to the channel allocator (same cdecl arguments: channel -1, priority,
# owner callback). When all 48 channels are in use, release the lowest-priority one that is not a stream's, then allocate.
L 'StreamAlloc'
B 0x56, 0x57                          # push esi / push edi
Call $SndLock
B 0xB9; B (Le32 $ChanTable)           # mov ecx,slot 0
B 0x33, 0xF6                          # xor esi,esi (index)
B 0x83, 0xCF, 0xFF                    # or edi,-1 (victim)
B 0xBA; B (Le32 0x7FFFFFFF)           # mov edx,lowest priority so far (the lock call is done with edx)
L 'SALoop'
B 0x83, 0x79, 0x08, 0x00              # cmp dword [ecx+8],0 (slot in use?)
Jz8 'SAFree'                          # a free slot: the allocator will take it
B 0x81, 0x79, 0x14; B (Le32 $StreamChanCb)   # cmp dword [ecx+0x14],stream callback
Jz8 'SANext'                          # never release a stream's channel here
B 0x8B, 0x41, 0x10                    # mov eax,[ecx+0x10] (priority)
B 0x3B, 0xC2                          # cmp eax,edx
B 0x7D; Rel8 'SANext'                 # jge
B 0x8B, 0xD0                          # mov edx,eax
B 0x8B, 0xFE                          # mov edi,esi
L 'SANext'
B 0x83, 0xC1, 0x40                    # add ecx,0x40
B 0x46                                # inc esi
B 0x83, 0xFE; B ([byte]$ChanCount)    # cmp esi,48
B 0x7C; Rel8 'SALoop'                 # jl
B 0x85, 0xFF                          # test edi,edi
B 0x78; Rel8 'SAFree'                 # js (nothing to release)
B 0x57                                # push edi
Call $ChanRelease                     # release it (stops it and calls its owner's steal callback)
B 0x83, 0xC4, 0x04                    # add esp,4
Inc32 $VoiceEvicts
L 'SAFree'
Call $SndUnlock
B 0x5F, 0x5E                          # pop edi / pop esi
Jmp $ChanAlloc                        # the allocator, with the caller's arguments and return address

# StreamDtor (V39): the stream sound destructor's call to its stop (ecx = esi = the sound). Afterwards unregister it from the
# stream type (0x6D5190 removes its node if there is one and clears +0x74; with no node it changes nothing), so the sound
# update never reaches it once it is freed. Skipped when the stream type itself is gone ([0xA7C1A0] = 0, set by its
# destructor 0x6E06B0 at shutdown, which frees the whole list).
L 'StreamDtor'
Call $StreamStop
B 0xA1; B (Le32 $StreamTypeObj)       # mov eax,[stream type]
B 0x85, 0xC0                          # test eax,eax
Jz8 'SDtorRet'
B 0x8B, 0xCE                          # mov ecx,esi
Call $StreamUnreg
L 'SDtorRet'
B 0xC3
L 'SpareGEnd'

# --- Spare H (unused game function at 0x4CCB80, V41) ---
Org $SpareH $SpareHLimit
# MovieStart: replaces the movie open's call to 0x5BC290 (ecx = the new input object). Note the time, then construct it.
L 'MovieStart'
B 0x51                                # push ecx
CallIat $IatGetTickCount
B 0xA3; Abs $MovieT0                  # mov [MovieT0],eax
B 0x59                                # pop ecx
Jmp $MovieInput
# MovieCheck: replaces each movie loop's call to 0x5BC2C0 (ecx = input object, [ecx] = stop flag). Callers reload ecx after.
L 'MovieCheck'
B 0x51                                # push ecx
Call $MovieStopCheck                  # Esc / Enter / left click -> [ecx] = 1, click latch cleared
CallIat $IatGetTickCount
B 0x2B, 0x05; Abs $MovieT0            # sub eax,[MovieT0]
B 0x59                                # pop ecx
B 0x3D; B (Le32 $MovieGraceMs)        # cmp eax,grace
B 0x73; Rel8 'MCRet'                  # jae: past the grace, keep the game's decision
B 0x83, 0x21, 0x00                    # and dword [ecx],0 (too early: ignore it)
L 'MCRet'
B 0xC3
# FrameExtra3 (V42): called first in Frame in place of FrameExtra2. The first time, load bo2skipui.dll (the skip's
# ring on long black screens); then FrameExtra2 with the same stack.
L 'FrameExtra3'
CmpImm8 $UiLoaded 0
Jnz8 'FE3Tick'
MovImm $UiLoaded 1
PushAbs 'StrUiDll'
CallIat $IatLoadLib
B 0x85, 0xC0                          # test eax,eax
Jz8 'FE3Go'
PushAbs 'StrUiTick'
B 0x50                                # push eax (module)
CallIat $IatGetProc2
B 0xA3; Abs $UiTick                   # mov [UiTick],eax
L 'FE3Tick'
B 0xA1; Abs $UiTick                   # mov eax,[UiTick]
B 0x85, 0xC0                          # test eax,eax
Jz8 'FE3Go'
B 0xFF, 0xD0                          # call eax (BO2UiTick: cdecl, no arguments)
L 'FE3Go'
Jmp 'FrameExtra2'
L 'SpareHEnd'

Org $DataBase $DataLimit
L 'ValScriptDelay'; B (FloatBytes $ScriptDelay)
L 'ValScriptMax'; B (FloatBytes $ScriptMaxSeconds)
L 'ValChain'; B (FloatBytes $ChainSeconds)
L 'ValMult'; B (FloatBytes $Multiplier)
L 'ValHold'; B (FloatBytes $HoldSeconds)
L 'ValFade'; B (FloatBytes $FadeSeconds)
L 'ValMaxSkip'; B (FloatBytes $MaxSkipSeconds)
L 'ValLightCap'; B (FloatBytes $LightCap)
L 'VolTable'
B (FloatBytes 0.0)
foreach ($step in 1..9) { B (FloatBytes ([Math]::Pow(10, ($TopDb - (9 - $step) * $StepDb) / 20))) }
L 'StrVoCine'; B ([Text.Encoding]::ASCII.GetBytes("vo/cinestream`0"))
L 'StrVoScripted'; B ([Text.Encoding]::ASCII.GetBytes("vo/scripted`0"))
L 'StrXInput'; B ([Text.Encoding]::ASCII.GetBytes("xinput1_4.dll`0"))
L 'StrGetState'; B ([Text.Encoding]::ASCII.GetBytes("XInputGetState`0"))
L 'StrUser32'; B ([Text.Encoding]::ASCII.GetBytes("user32.dll`0"))
L 'StrKeyState'; B ([Text.Encoding]::ASCII.GetBytes("GetAsyncKeyState`0"))
L 'StrPromptTri'; B ([Text.Encoding]::ASCII.GetBytes("hold \g to skip`0"))
L 'StrPromptY'; B ([Text.Encoding]::ASCII.GetBytes("hold \u to skip`0"))
L 'StrWinmm'; B ([Text.Encoding]::ASCII.GetBytes("winmm.dll`0"))
L 'StrJoyCaps'; B ([Text.Encoding]::ASCII.GetBytes("joyGetDevCapsA`0"))
L 'StrPromptKeys'; B ([Text.Encoding]::ASCII.GetBytes("hold \4 to skip`0"))
L 'StrUiDll'; B ([Text.Encoding]::ASCII.GetBytes("bo2skipui.dll`0"))
L 'StrUiTick'; B ([Text.Encoding]::ASCII.GetBytes("BO2UiTick`0"))

# Pass 1: label addresses. Pass 2: emit. Org switches from the code area to the data area.
$labels = @{}
$pc = $CodeBase
$limit = $CodeLimit
foreach ($it in $script:Items) {
    switch ($it.k) {
        'b' { $pc += $it.v.Length }
        'l' { if ($labels.ContainsKey($it.v)) { throw "Duplicate label $($it.v)" }; $labels[$it.v] = $pc }
        'o' { if ($pc -gt $limit) { throw ("Area ending 0x{0:X} overflows by {1} bytes" -f $limit, ($pc - $limit)) }; $pc = $it.v; $limit = $it.lim }
        'r8' { $pc += 1 }
        default { $pc += 4 }
    }
}
if ($pc -gt $limit) { throw ("Area ending 0x{0:X} overflows by {1} bytes" -f $limit, ($pc - $limit)) }

function Resolve($t) {
    if ($t -is [string]) { if (-not $labels.ContainsKey($t)) { throw "Unknown label $t" }; return [long]$labels[$t] }
    [long]$t
}
$segments = New-Object System.Collections.ArrayList
$out = New-Object System.Collections.Generic.List[byte]
[void]$segments.Add(@{ Base = [long]$CodeBase; Bytes = $out })
$pc = [long]$CodeBase
foreach ($it in $script:Items) {
    switch ($it.k) {
        'o' { $out = New-Object System.Collections.Generic.List[byte]; [void]$segments.Add(@{ Base = [long]$it.v; Bytes = $out }); $pc = $it.v }
        'b' { $out.AddRange([byte[]]$it.v); $pc += $it.v.Length }
        'a' { $out.AddRange([byte[]](Le32 (Resolve $it.v))); $pc += 4 }
        'r' { $out.AddRange([byte[]](Le32 (((Resolve $it.v) - ($pc + 4)) -band 0xFFFFFFFFL))); $pc += 4 }
        'r8' {
            $d = (Resolve $it.v) - ($pc + 1)
            if ($d -lt -128 -or $d -gt 127) { throw "Short jump to $($it.v) out of range ($d)" }
            $out.Add([byte]($d -band 0xFF)); $pc += 1
        }
    }
}

if ((Get-FileHash -LiteralPath $InPath -Algorithm SHA256).Hash -ne $VanillaSha) { throw "Input is not the vanilla exe" }
$bytes = [System.IO.File]::ReadAllBytes($InPath)

function Assert-Bytes([long]$va, [byte[]]$want, [string]$what) {
    for ($i = 0; $i -lt $want.Length; $i++) {
        if ($bytes[$va - $ImageBase + $i] -ne $want[$i]) { throw ("Unexpected bytes at 0x{0:X8} ({1})" -f ($va + $i), $what) }
    }
}
Assert-Bytes $FlagCall ([byte[]](0xE8, 0x78, 0x00, 0x1B, 0x00)) 'flag call'
Assert-Bytes $FrameHook ([byte[]](0x8B, 0x0D, 0x64, 0x36, 0xA8, 0x00)) 'frame hook'
Assert-Bytes $PhraseCall ([byte[]](0xE8, 0x15, 0x02, 0x00, 0x00)) 'phrase call'
foreach ($v in $VolumeSites) { Assert-Bytes $v ([byte[]](0xD8, 0x0D, 0x9C, 0x02, 0x86, 0x00)) 'volume slider multiply' }
Assert-Bytes $StreamLock ([byte[]](0xA1, 0x98, 0xC1, 0xA7, 0x00)) 'stream lock'
Assert-Bytes $StreamUnlock ([byte[]](0x68, 0x78, 0xC1, 0xA7, 0x00)) 'stream unlock'
Assert-Bytes $StreamStop ([byte[]](0x56, 0x8B, 0xF1, 0xE8, 0x98, 0x70, 0x01, 0x00)) 'stream instance stop'
Assert-Bytes $SoundDtCall ([byte[]](0xE8, 0x46, 0x24, 0xFD, 0xFF)) 'sound update frame-time call'
Assert-Bytes $MixerStartCall ([byte[]](0xE8, 0xE1, 0x43, 0x01, 0x00)) 'mixer thread start call'
Assert-Bytes ($OutroMovieCheck - 0xD) ([byte[]](0x55, 0x68, 0xA8, 0x3F, 0x8F, 0x00, 0xE8, 0x53, 0x7C, 0x0C, 0x00, 0x85, 0xC0, 0x74, 0x72)) 'outro state PlayMovie check'
Assert-Bytes $StreamAllocCall ([byte[]](0xE8, 0x05, 0x52, 0xFF, 0xFF)) 'stream channel allocation call'
Assert-Bytes $SaveListCompare ([byte[]](0x8B, 0x44, 0x24, 0x04, 0x8B, 0x48, 0x10, 0x8B, 0x54, 0x24, 0x08, 0x3B, 0x4A, 0x10, 0x1B, 0xC0, 0xF7, 0xD8, 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90)) 'save list comparator'
Assert-Bytes $MovieOpenCall ([byte[]](0xE8, 0x01, 0xFD, 0xFF, 0xFF)) 'movie open input object call'
Assert-Bytes 0x005BCE22 ([byte[]](0xE8, 0x99, 0xF4, 0xFF, 0xFF)) 'movie loop stop check (1)'
Assert-Bytes 0x005BD51D ([byte[]](0xE8, 0x9E, 0xED, 0xFF, 0xFF)) 'movie loop stop check (2)'
Assert-Bytes 0x005BDD60 ([byte[]](0xE8, 0x5B, 0xE5, 0xFF, 0xFF)) 'movie loop stop check (3)'
Assert-Bytes $MovieStopCheck ([byte[]](0x56, 0x57, 0x8B, 0xF9, 0xE8, 0x07, 0x14, 0x03, 0x00)) 'movie stop check'
Assert-Bytes $IatGetTickCount ([byte[]](0x80, 0x4C, 0x4E, 0x00)) 'GetTickCount import'
$spareHSha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes, $SpareH - $ImageBase, $SpareHLimit - $SpareH))) -replace '-', ''
if ($spareHSha -ne '181ACA05CDD4EED08A3F55EF270723736FC4FC8DA01E15E2C0051E8C895DF676') { throw "Unexpected bytes in unused function 0x4CCB80" }
Assert-Bytes ($StreamAllocCall - 0xC) ([byte[]](0x68, 0xC0, 0xE1, 0x6D, 0x00, 0x68, 0x00, 0x01, 0x00, 0x00, 0x6A, 0xFF)) 'stream allocation arguments'
Assert-Bytes $ChanAlloc ([byte[]](0x53, 0x55, 0x56, 0x57, 0x83, 0xCF, 0xFF, 0xBB, 0x40, 0x42, 0x0F, 0x00)) 'channel allocator'
Assert-Bytes $ChanRelease ([byte[]](0x56, 0xE8, 0x5A, 0xE5, 0x00, 0x00, 0x8B, 0x74, 0x24, 0x08)) 'channel release'
Assert-Bytes $StreamDtorCall ([byte[]](0xE8, 0x80, 0x00, 0x00, 0x00, 0x8B, 0x46, 0x70)) 'stream sound destructor stop call'
Assert-Bytes $StreamUnreg ([byte[]](0xA1, 0xA0, 0xC1, 0xA7, 0x00, 0x53, 0x8B, 0x58, 0x10)) 'stream sound unregister'
Assert-Bytes $MixerStartFn ([byte[]](0x6A, 0x02, 0x6A, 0x00, 0xC6, 0x05, 0x4C, 0xC3, 0xA7, 0x00, 0x00)) 'mixer thread start'
function HexBytes([string]$h) { [byte[]]($h -split ' ' | ForEach-Object { [Convert]::ToByte($_, 16) }) }
# fn2 from its push ebx to the end of its abort branch: CaveB0 relies on this exact stack layout and continues at 0x4E01A9.
Assert-Bytes 0x004E017E (HexBytes '53 6a 05 6a 07 e8 78 00 1b 00 83 c4 08 8a d8 e8 be 2b fd ff 8b 10 6a 7b 8b c8 ff 52 04 c1 e8 03 24 01 84 db 5b 74 13 84 c0 74 0f 8b 46 68 50 8b ce e8 bc fe ff ff 5e c2 04 00') 'fn2 abort branch'
# The two unused functions reused as code space (whole areas, so a different build cannot slip through).
Assert-Bytes $SpareA (HexBytes '53 6a 05 6a 07 e8 c6 00 1b 00 83 c4 08 8a d8 e8 0c 2c fd ff 8b 10 6a 7b 8b c8 ff 52 04 c1 e8 03 24 01 84 db 5b 74 0a 84 c0 74 06 b8 01 00 00 00 c3 33 c0 c3 90 90 90 90 90 90 90 90 90 90 90 90') 'unused function 0x4E0130'
Assert-Bytes $LoadDoneCall (HexBytes 'e8 5f fb ff ff') 'stream loader completion call'
Assert-Bytes ($LoadDoneCall - 4) (HexBytes '8b 4e 54 56') 'stream loader completion call setup'
$spareDSha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes, $SpareD - $ImageBase, $SpareDLimit - $SpareD))) -replace '-', ''
if ($spareDSha -ne 'E7699131C469F41105A2EC5B93C2139488D85EF7CA0D26F2AFA166C467539C28') { throw "Unexpected bytes in unused function 0x4CA8D0" }
Assert-Bytes 0x0052EACC (HexBytes 'c7 06 00 90 86 00') 'HUD constructor vtable write'
Assert-Bytes 0x00531072 (HexBytes '89 be 04 01 00 00') 'HUD mode store'
$spareESha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes, $SpareE - $ImageBase, $SpareELimit - $SpareE))) -replace '-', ''
if ($spareESha -ne 'DF52AEB6F3FC1620D7A6D985615C57A416710BD8689B632FD70CA752327A08F1') { throw "Unexpected bytes in unused functions 0x4CC810" }
$spareGSha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes, $SpareG - $ImageBase, $SpareGLimit - $SpareG))) -replace '-', ''
if ($spareGSha -ne 'E8ABC319C9A1619288423E63A00704AE8B0C2AA40BA28E52FEB560C5FE9A22D7') { throw "Unexpected bytes in unused function 0x4CCC10" }
Assert-Bytes 0x00409C7E (HexBytes 'c7 06 7c f7 83 00') 'GameCamera constructor vtable write'
Assert-Bytes 0x0040DF20 (HexBytes '83 b9 98 00 00 00 03 b0 01 75 0b 8b 81 90 00 00 00 85 c0 0f 94 c0 c3') 'GameCamera mode and path'
Assert-Bytes 0x004A9B30 (HexBytes 'e8 1b a9 2a 00 83 38 01 75 06 8b 40 08 8b 00 c3 33 c0 c3') 'world getter'
Assert-Bytes 0x00754450 (HexBytes 'a1 84 3c a8 00 c3') 'world state getter'
Assert-Bytes 0x004A9B90 (HexBytes '8b 41 44 85 c0 74 1e 8b 80 24 01 00 00') 'world camera getter'
$spareFSha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes, $SpareF - $ImageBase, $SpareFLimit - $SpareF))) -replace '-', ''
if ($spareFSha -ne 'AF5904A101B87AE461E9B99D282CD9935F362CB0D58788DEF95D587E5327D3D9') { throw "Unexpected bytes in unused function 0x49AB70" }
Assert-Bytes $GainSiteFull (HexBytes 'd9 47 14 d8 4e 1c d9 5e 40') 'group update final volume (full)'
Assert-Bytes ($GainSiteFull - 0x14) (HexBytes '8a 46 56 84 c0 8b 7c 24 30 74 09 c7 46 40 00 00 00 00 eb 09') 'group update mute test (full)'
Assert-Bytes ($GainSiteVol - 0x17) (HexBytes '8a 46 56 84 c0 74 0c c7 46 40 00 00 00 00 e9 e4 00 00 00 8b 44 24 30 d9 40 14 d8 4e 1c d9 5e 40') 'group update final volume (volume only)'
Assert-Bytes 0x006D2B07 (HexBytes '66 8b 02 66 3b c3 66 89 46 54') 'group name symbol at +0x54'
Assert-Bytes 0x006D2B36 (HexBytes 'c7 06 3c 6b 87 00') 'sound group vtable write'
Assert-Bytes 0x006D2E30 (HexBytes '83 ec 18 53 55 8b 6c 24 24 83 fd 05 56 57 8b f1') 'group update entry'
foreach ($v in $SliderSfxSites + $SliderVoSites + $SliderMusSites) {
    $rel = [BitConverter]::ToInt32($bytes, $v - $ImageBase + 1)
    if ($bytes[$v - $ImageBase] -ne 0xE8 -or ($v + 5 + $rel) -ne $SetGroupVolume) { throw ("No group volume call at 0x{0:X8}" -f $v) }
    Assert-Bytes ($v - 2) (HexBytes '8b c8') 'options volume call (mov ecx,eax)'
}
Assert-Bytes 0x004AB713 (HexBytes '8d 41 12') 'options: sfx symbol'
Assert-Bytes 0x004AB741 (HexBytes '8d 51 14') 'options: vo symbol'
Assert-Bytes 0x004AB773 (HexBytes '8d 51 18') 'options: music symbol'
Assert-Bytes 0x0055A27B (HexBytes '8d 51 12') 'startup: sfx symbol'
Assert-Bytes 0x0055A2A9 (HexBytes '8d 41 14') 'startup: vo symbol'
Assert-Bytes 0x0055A2DB (HexBytes '8d 41 18') 'startup: music symbol'
Assert-Bytes 0x006D2860 (HexBytes 'd9 44 24 04 56 d8 1d c4 f5 83 00 57 8b f1 df e0 f6 c4 05 7a 08 d9 05 c4 f5 83 00 eb 1d d9 44 24 0c d8 1d 14 f7 83 00 df e0 f6 c4 41 75 08 d9 05 14 f7 83 00 eb 04 d9 44 24 0c 8b 3e d9 5e 1c 8b ce e8 1a ff ff ff 50 6a 01 8b ce ff 57 0c 5f 5e c2 04 00') 'group volume setter (volume at +0x1C, ret 4)'
$spareCSha = ([BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes, $SpareC - $ImageBase, $SpareCLimit - $SpareC))) -replace '-', ''
if ($spareCSha -ne 'A4A4BEA0FFDED2D65E8877EEC3195C25F576D0A6FC881F1D544BAFBF477BBA6D') { throw "Unexpected bytes in unused function 0x4E8EE0" }
Assert-Bytes $SpareB (HexBytes '53 56 6a 05 6a 07 8b f1 e8 c3 ff 1a 00 83 c4 08 8a d8 e8 09 2b fd ff 8b 10 6a 7b 8b c8 ff 52 04 c1 e8 03 24 01 84 db 74 14 84 c0 74 10 8b 46 68 50 8b ce e8 08 fe ff ff 5e 5b c2 04 00 8b 46 18 85 c0 75 0b 8b 4e 6c 51 8b ce e8 f1 fd ff ff 5e 5b c2 04 00 90 90 90 90 90 90 90 90 90 90 90 90 8b 41 18 85 c0 75 13 8b 51 64 8b 01 c6 81 8a 00 00 00 01 89 54 24 04 ff 60 14 c2 04 00 90 90 90 8b 41 18 85 c0 75 13 8b 51 64 8b 01 c6 81 8a 00 00 00 01 89 54 24 04 ff 60 14 c2 04 00 90 90 90') 'unused functions 0x4E0230-0x4E02CF'
for ($i = $CodeBase - $ImageBase; $i -lt $CodeLimit - $ImageBase; $i++) {
    if ($bytes[$i] -ne 0) { throw "Spare code area is not empty" }
}
for ($i = $DataBase - $ImageBase; $i -lt $DataLimit - $ImageBase; $i++) {
    if ($bytes[$i] -ne 0) { throw "Spare data area is not empty" }
}

# Cover the new code with .text's declared size (the raw data already extends this far).
$pe = [BitConverter]::ToInt32($bytes, 0x3C)
$sectionTable = $pe + 24 + [BitConverter]::ToUInt16($bytes, $pe + 20)
if ([Text.Encoding]::ASCII.GetString($bytes, $sectionTable, 5) -ne '.text') { throw "First section is not .text" }
[Array]::Copy([BitConverter]::GetBytes([uint32]0x43E000), 0, $bytes, $sectionTable + 8, 4)
# Same for .rdata, so the data area is inside its declared size.
if ([Text.Encoding]::ASCII.GetString($bytes, $sectionTable + 40, 6) -ne '.rdata') { throw "Second section is not .rdata" }
[Array]::Copy([BitConverter]::GetBytes([uint32]0xA7000), 0, $bytes, $sectionTable + 40 + 8, 4)

# The reused functions are filled with int3 first, so whatever the new code does not cover cannot run as leftover code.
for ($i = $SpareA - $ImageBase; $i -lt $SpareALimit - $ImageBase; $i++) { $bytes[$i] = 0xCC }
for ($i = $SpareB - $ImageBase; $i -lt $SpareBLimit - $ImageBase; $i++) { $bytes[$i] = 0xCC }
for ($i = $SpareC - $ImageBase; $i -lt $SpareCLimit - $ImageBase; $i++) { $bytes[$i] = 0xCC }
for ($i = $SpareD - $ImageBase; $i -lt $SpareDLimit - $ImageBase; $i++) { $bytes[$i] = 0xCC }
for ($i = $SpareE - $ImageBase; $i -lt $SpareELimit - $ImageBase; $i++) { $bytes[$i] = 0xCC }
for ($i = $SpareF - $ImageBase; $i -lt $SpareFLimit - $ImageBase; $i++) { $bytes[$i] = 0xCC }
for ($i = $SpareG - $ImageBase; $i -lt $SpareGLimit - $ImageBase; $i++) { $bytes[$i] = 0xCC }
for ($i = $SpareH - $ImageBase; $i -lt $SpareHLimit - $ImageBase; $i++) { $bytes[$i] = 0xCC }
foreach ($seg in $segments) { [Array]::Copy($seg.Bytes.ToArray(), 0, $bytes, ($seg.Base - $ImageBase), $seg.Bytes.Count) }

function Rel5([long]$from, [string]$label) { [byte[]](Le32 (($labels[$label] - ($from + 5)) -band 0xFFFFFFFFL)) }
function Put([long]$va, [byte[]]$data) { [Array]::Copy($data, 0, $bytes, ($va - $ImageBase), $data.Length) }
Put $FlagCall ([byte[]](@(0xE8) + (Rel5 $FlagCall 'CaveB0')))
Put $FrameHook ([byte[]](@(0xE9) + (Rel5 $FrameHook 'Frame') + @(0x90)))
Put $PhraseCall ([byte[]](@(0xE8) + (Rel5 $PhraseCall 'CaveC')))
foreach ($v in $VolumeSites) { Put $v ([byte[]](@(0xE8) + (Rel5 $v 'VolCurve') + @(0x90))) }
Put $SoundDtCall ([byte[]](@(0xE8) + (Rel5 $SoundDtCall 'SoundDt')))
Put $MixerStartCall ([byte[]](@(0xE8) + (Rel5 $MixerStartCall 'MixerStart')))
Put $StreamAllocCall ([byte[]](@(0xE8) + (Rel5 $StreamAllocCall 'StreamAlloc')))
Put $OutroMovieCheck ([byte[]](0x90, 0x90))
# mov eax,[esp+4] / mov ecx,[eax+10] / sub ecx,31 / mov edx,[esp+8] / mov edx,[edx+10] / sub edx,31 / cmp ecx,edx /
# sbb eax,eax / neg eax / ret, then nops to the old padding's end
Put $SaveListCompare ([byte[]](0x8B, 0x44, 0x24, 0x04, 0x8B, 0x48, 0x10, 0x83, 0xE9, 0x31, 0x8B, 0x54, 0x24, 0x08, 0x8B, 0x52, 0x10, 0x83, 0xEA, 0x31, 0x3B, 0xCA, 0x1B, 0xC0, 0xF7, 0xD8, 0xC3, 0x90, 0x90, 0x90, 0x90, 0x90))
Put $MovieOpenCall ([byte[]](@(0xE8) + (Rel5 $MovieOpenCall 'MovieStart')))
foreach ($v in $MovieCheckSites) { Put $v ([byte[]](@(0xE8) + (Rel5 $v 'MovieCheck'))) }
Put $StreamDtorCall ([byte[]](@(0xE8) + (Rel5 $StreamDtorCall 'StreamDtor')))
Put $LoadDoneCall ([byte[]](@(0xE8) + (Rel5 $LoadDoneCall 'OnLoaded')))
Put $GainSiteFull ([byte[]](@(0xE8) + (Rel5 $GainSiteFull 'GainEdi') + @(0x90, 0x90, 0x90, 0x90)))
Put $GainSiteVol ([byte[]](@(0xE8) + (Rel5 $GainSiteVol 'GainEax') + @(0x90, 0x90, 0x90, 0x90)))
foreach ($v in $SliderSfxSites) { Put $v ([byte[]](@(0xE8) + (Rel5 $v 'SliderSfx'))) }
foreach ($v in $SliderVoSites) { Put $v ([byte[]](@(0xE8) + (Rel5 $v 'SliderVo'))) }
foreach ($v in $SliderMusSites) { Put $v ([byte[]](@(0xE8) + (Rel5 $v 'SliderMusic'))) }

[System.IO.File]::WriteAllBytes($OutPath, $bytes)
Write-Output ("CODE_END={0:X}" -f $labels['CodeEnd'])
Write-Output ("Labels: CaveB={0:X} IsHeld={1:X} CaveC={2:X} Frame={3:X}; code {4} bytes, data {5} bytes" -f $labels['CaveB'], $labels['IsHeld'], $labels['CaveC'], $labels['Frame'], $segments[0].Bytes.Count, $segments[8].Bytes.Count)
Write-Output ("Spare A: CaveB0={0:X} end {1:X} (limit {2:X}); spare B: StartForward={3:X} SoundDt={4:X} IsChapter={5:X} end {6:X} (limit {7:X})" -f `
    $labels['CaveB0'], $labels['SpareAEnd'], $SpareALimit, $labels['StartForward'], $labels['SoundDt'], $labels['IsChapter'], $labels['SpareBEnd'], $SpareBLimit)
Write-Output ("Spare C: FrameExtra={0:X} ChainCheck={1:X} OnLoaded={2:X} end {3:X} (limit {4:X})" -f $labels['FrameExtra'], $labels['ChainCheck'], $labels['OnLoaded'], $labels['SpareCEnd'], $SpareCLimit)
Write-Output ("Spare D: ScriptScene={0:X} end {1:X} (limit {2:X})" -f $labels['ScriptScene'], $labels['SpareDEnd'], $SpareDLimit)
Write-Output ("Spare E: HudRead={0:X} CamRead={1:X} NameCheck={2:X} end {3:X} (limit {4:X})" -f $labels['HudRead'], $labels['CamRead'], $labels['NameCheck'], $labels['SpareEEnd'], $SpareELimit)
Write-Output ("Spare F: FrameExtra2={0:X} FxTick={1:X} SliderSfx={2:X} GainEdi={3:X} GainEax={4:X} end {5:X} (limit {6:X})" -f $labels['FrameExtra2'], $labels['FxTick'], $labels['SliderSfx'], $labels['GainEdi'], $labels['GainEax'], $labels['SpareFEnd'], $SpareFLimit)
Write-Output ("Spare G: DoorGate={0:X} StreamAlloc={1:X} StreamDtor={2:X} end {3:X} (limit {4:X})" -f $labels['DoorGate'], $labels['StreamAlloc'], $labels['StreamDtor'], $labels['SpareGEnd'], $SpareGLimit)
Write-Output ("Spare H: MovieStart={0:X} MovieCheck={1:X} FrameExtra3={2:X} end {3:X} (limit {4:X})" -f $labels['MovieStart'], $labels['MovieCheck'], $labels['FrameExtra3'], $labels['SpareHEnd'], $SpareHLimit)
Write-Output "Multiplier=$Multiplier HoldSeconds=$HoldSeconds FadeSeconds=$FadeSeconds NoSkip=$NoSkip"
Write-Output "SHA256: $((Get-FileHash -LiteralPath $OutPath -Algorithm SHA256).Hash)"
