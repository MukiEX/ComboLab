# ComboLab: combo timing developer and trainer for Street Fighter 6

A REFramework mod plus a local web page.

- **Web page** (`ComboLab.html`): pick a character, type a combo in numpad notation, and send it to the game.
- **In-game overlay**: measures every press while you practise in Training mode.
- **Develop** mode builds a timing profile per combo step: when the press works, when the move actually comes out, when you are free to act, and how much hitstun the opponent had left.
- **Train** mode grades every press against that profile: early or late by N frames, with an optional spam blocker.

Training mode only. The mod does nothing online.

## Install

1. Install [REFramework](https://github.com/praydog/REFramework-nightly/releases) for SF6 (put `dinput8.dll` in the game folder).
2. Extract this zip straight into your SF6 game folder (the one with `StreetFighter6.exe`), letting it merge into `reframework` and overwrite older ComboLab files. The overlay tag (DEVELOP / TRAIN) shows the loaded version.
3. Open `reframework/data/ComboLab/ComboLab.html` in **Chrome or Edge**.
4. Click **Choose folder** and select the SF6 game folder. The page finds `reframework/data/ComboLab` by itself.
   - The browser remembers the folder, but may ask you to click **Reconnect** in later sessions.
   - In Firefox, use **Export JSON** and drop the file into `reframework/data/ComboLab/combos/`.

On Linux/Proton, set the usual `WINEDLLOVERRIDES="dinput8=n,b"` for REFramework.

## Manage it from another screen or device

Run `reframework/data/ComboLab/run_server.bat` (or `python combolab_server.py`, Python 3.8+, no extra packages). It prints the address to open on your phone, tablet or second PC, e.g. `http://192.168.1.20:8765`. The page works the same as the local one; no folder picking needed.

- `--token yoursecret` makes the page ask for a shared secret once (stored in that browser).
- `--host 127.0.0.1` keeps it to this PC only. `--port` changes the port.
- Windows Firewall will ask the first time; allow it on private networks.

## Training bot (automatic profiles)

The bot plays combos for you in Training mode and sweeps each step's press timing frame by frame, so profiles come out exact without practice runs. It presses buttons through the same input hook the mod already reads from (the technique Wael3rd's SF6_Tools uses for playback), and it moves both fighters back into position between attempts.

**Before starting**, in SF6's Training settings:
- Dummy: **No guard**, standing.
- Drive gauge and Super gauge: **infinite** (or auto-recover); life auto-recover on.
- For combos marked PC: Counter setting on **Punish Counter**.
- Keep your hands off the controller: any real input stops the bot.
- Playing offline is safest, and remove `dinput8.dll` before going online.

**Start it** from the web page's **Training bot** card (this combo, or every combo for the character), from the REFramework menu (ComboLab > Training bot), or with **F10** for the current combo. F10 again stops it.

**What it does for each combo:**
1. Finds each step's window: with earlier steps at their middle timing, it tries the step on every frame until it has seen it work and then fail 4 frames in a row, then re-tests the edges.
2. Sweet-spot pass: plays the full combo varying one step across its window, so the profile learns which part keeps the next step alive.
3. Checks the full combo at the final target timings and reports how many were clean.

Position comes from the combo name ("corner" in the name means corner) unless you override it. Results, including why a combo failed, show in the web page and are saved to `reframework/data/ComboLab/bot/<id>.json`.

**Speed:** each attempt takes about 4–6 seconds (most of it waiting for the dummy to get up). A 4-step combo takes around 100 attempts at 2 repeats, about 8 minutes; long combos take longer. Use 1 repeat and turn off the sweet-spot pass for a quick first pass.

**Not supported yet:** jump-in starters (j.X as the first step) and Modern controls; those are skipped with a reason. Charge moves hold the charge direction automatically, which can turn a neutral normal right before them into a crouching one.

## Workflow

1. In the web page, choose a character and type the combo, for example
   `2LP > 2LP, 5LK > DR > 5LP, 5HP > DR > 5HK, 5MP~4HP > [2]8HK`.
   - `>` means cancel, `,` means link, `~` means chain or target combo.
   - `cr.MK`, `j.HP`, `[2]8HK`, `236P`, `DR`, `DI`, `66`, `SA2` and Modern buttons (`L M H SP`) all work.
   - Click a step chip to change what counts as its trigger press, or whether it is a hit or a movement step.
2. Click **Develop in game** and go to Training mode.
3. Do the combo many times.
   - Each attempt adds samples; the cyan windows grow as you go.
   - Drop it early and late on purpose too: those failures pin the window edges down.
4. When every step has a window, press **F5** in game (or click **Train in game**).
   - Each press now lands on the bar as a tick inside or outside the window.
   - A drop tells you which step failed and by how many frames.
   - Turn on **Spam blocker** (F8) to fail runs where you pressed a step's button more than once.
   - **Spearmint Twintails view** (F11, or Train view in the page): each upcoming step is a note that flies in and lands on a target ring exactly on that step's target frame. A countdown hand sweeps the ring and lands at 12 o'clock on the target frame; the cyan arc it passes through is the window and the white arc is the sweet spot. Each press gets a judgement: SWEET, GOOD, EARLY/LATE by N frames, or why it dropped. Later notes are predicted from each move's usual startup and corrected as the moves actually come out. Punches fly in from the left and kicks from the right (Drive Rush, DI and supers rise from below), with an option to swap sides. Note colours: **Classic** (light red, medium white, heavy blue) or **SF6** (light blue, medium yellow, heavy red). "Note flight" sets how many frames each note is in the air.
   - **Rhythm guide:** once a step's move starts, a glowing playhead runs through the next segment in real game frames and flashes on the middle of the window (white notches mark it). Between attempts a dimmer playhead loops the whole combo's cadence: each step's mid-window press plus that move's usual press-to-startup delay. Both can be switched off in the session options.

| Key | Action |
|---|---|
| F5 | Develop / Train |
| F6 | next combo |
| F7 | detail table (Develop) |
| F8 | spam blocker |
| F9 | hide overlay |

The same options are in the REFramework menu (Insert), under **ComboLab**. That menu also has a **Diagnostics** section.

## What is measured

- **Clock.** Everything is counted in game frames, ticked by a hook on `nBattle.cPlayer.pl_input_sub`. If that hook ever stops firing, the mod falls back to render frames, and Diagnostics shows the tick source.
- **Anchor.** Each step is measured from the frame the *previous step's action started*. That offset stays constant for a given combo, hitstop included.

| Value | Meaning |
|---|---|
| press (p) | Frame of the step's trigger press, after the anchor |
| came out (q) | Frame the step's action started. Buffered presses come out later than they were pressed. |
| free at (o) | Links only: when the previous move recovered |
| hit lands (k) and hitstun left (r) | When this step connected, and the opponent's hitstun just before it. **k + r** is when they would have recovered. |
| window | Press range seen in clean runs |
| estimated edge | Window widened from early/late drops, and for links from `p + r - 1` (±1f) |

**How a step is detected:**

- **Hit steps** are recognised by your combo counter going up during a new action that followed a press of that step's button.
- **Movement steps** (DR, dash, jump) succeed when the action comes out.
- **Action IDs** are learned from the first clean run. After that, a different move connecting counts as a wrong move.
- **Neutral actions** (standing, crouching, walking) are learned while you're idle, so do not mash buttons while standing around.

**Failure reasons:**

| Reason | Meaning |
|---|---|
| early | Pressed before the window; the input was eaten |
| late | Came out after the opponent recovered, got blocked, or whiffed |
| wrong move | A different move came out and hit |
| missed | No input seen for that step |
| spam | Extra presses of the step's button (Train with spam blocker only) |

## Files (all in `reframework/data/ComboLab/`)

| File | Written by | Contents |
|---|---|---|
| `combos/<id>.json` | web page | Combo definition: steps, trigger masks, hash |
| `command.json` | web page | Load combo / mode / options / reset (polled twice a second) |
| `profiles/<id>.json` | game | Samples, learned action IDs and windows per step |
| `sessions/<id>.json` | game | Last 500 attempts |
| `status.json` | game | Heartbeat, mode, last result |
| `config.json` | game | Options, hotkeys |

Editing a combo's steps changes its hash, and the old profile resets the next time it is loaded.

## Caveats

- **Not yet tested in the live game.** Game field names come from the community SF6 scripts:
  - WistfulHopes' info display (`gBattle.Player.mcPlayer`, `ActionPart._Engine`, `damage_time`, `guard_time`)
  - Wael3rd's SF6_Tools (`pl_input_new`, `pl_sw_new`, `rl_dir`, `pl_input_sub`, `TrainingManager` fighter ID)
  - LL5271's scripts (`mcTeam[i].mComboCount`)

  The engine logic is covered by a frame simulator, but the first in-game check should be the **Diagnostics** panel. Act and frame should change, `held` should change when you press buttons, and the combo count should go up on hits.
- **Modern control bits** are taken from Wael3rd's probed table and may need adjusting.
- **Projectile hits** after you have recovered are credited to your last non-neutral action. Combos that rely on a fireball landing late may bind oddly.
- **Juggles:** hitstun-left (`damage_time`) may read 0 while the opponent is airborne. Those samples simply give no estimate.

## Development

`tests/` holds the pure-Lua engine tests, a mocked-REFramework integration test, the overlay previewer and the notation parser test. Run them from the repository root:

```
lua tests/sim.lua
lua tests/integ.lua
node tests/parser.test.js
lua tests/bot_test.lua
lua tests/plans_test.lua
```
