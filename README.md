# ComboLab: combo timing developer and trainer for Street Fighter 6

A REFramework mod plus a local web page.

- **Web page** (`ComboLab.html`): pick a character, type a combo in numpad notation, and send it to the game.
- **In-game overlay**: measures every press while you practise in Training mode.
- **Develop** mode builds a timing profile per combo step: when the press works, when the move actually comes out, when you are free to act, and how much hitstun the opponent had left.
- **Train** mode grades every press against that profile: early or late by N frames, with an optional spam blocker.

Training mode only. The mod does nothing online.

## Install

1. Install [REFramework](https://github.com/praydog/REFramework-nightly/releases) for SF6 (put `dinput8.dll` in the game folder).
2. Copy the `reframework` folder into your SF6 game folder (the one with `StreetFighter6.exe`), merging with the existing one and overwriting older ComboLab files. The overlay tag (DEVELOP / TRAIN) shows the loaded version.
3. Open `reframework/data/ComboLab/ComboLab.html` in **Chrome or Edge**.
4. Click **Choose folder** and select the SF6 game folder. The page finds `reframework/data/ComboLab` by itself.
   - The browser remembers the folder, but may ask you to click **Reconnect** in later sessions.
   - In Firefox, use **Export JSON** and drop the file into `reframework/data/ComboLab/combos/`.

On Linux/Proton, set the usual `WINEDLLOVERRIDES="dinput8=n,b"` for REFramework.

## Manage it from another screen or device

Run `reframework/data/ComboLab/run_server.bat` (or `python combolab_server.py`, Python 3.8+, no extra packages). It prints the address to open on your phone, tablet or second PC, e.g. `http://192.168.1.20:41236`. The page works the same as the local one; no folder picking needed.

- `--token yoursecret` makes the page ask for a shared secret once (stored in that browser).
- `--host 127.0.0.1` keeps it to this PC only. `--port` changes the port.
- Windows Firewall will ask the first time; allow it on private networks.

## Updating

The **Hub Sync** tab has an **Updates** card: **Check for updates**, then **Update now**. It replaces only program files: the mod's Lua, this page and the server scripts. Combos, profiles, sessions, config and hub settings are never touched, and the old files are kept in `reframework/data/ComboLab/.update/backup/`.

- **From the hub** (default): with the repo's `hub/docker-compose.yml` the hub hands out the program files straight from its checkout, so a `git pull` on the hub machine is enough for every PC to update from it (rebuild only when the hub itself changes). Nothing else to install.
- **From a git repo:** pick "A git repo" and enter its address (and a branch if it isn't the default). Needs git on the PC; a private repo needs its login set up in git (Git Credential Manager or an SSH key).
- If the server scripts changed, the server restarts by itself in a new window and the page reloads. If the mod changed, reset scripts in game: REFramework menu (Insert) → ScriptRunner → **Reset scripts**.
- A `.bat` file can't be replaced while it's running, so a changed one is saved next to it as `.new`; swap it in with the server closed.
- It never goes back: if the hub or repo has an older version than this PC (a hub not rebuilt since your last push), it says so and changes nothing. `run_update.bat apply force` goes back on purpose.
- Updates can only be started from the gaming PC itself (`http://localhost:41236`), or from any device when the server runs with `--token`, since they install code.
- Without the page: `run_update.bat` (or `python combolab_update.py check | apply | source hub | source git <url> [branch]`).

The first time, copy 1.14's files over by hand (or with a bundle); from then on the updater handles it.

## Sync profiles between machines (hub)

The hub is a small server for your own domain that merges every machine's timing samples into one profile per combo, and keeps combos in step. Run it behind your HTTPS reverse proxy; each gaming PC syncs to it with its own token.

**On the server** (Python 3.8+, no packages), from a clone of this repo:

```
python3 hub/combolab_hub.py add-machine living-room-pc     # prints that PC's token
python3 hub/combolab_hub.py serve                          # 127.0.0.1:8770, data in hub/data
```

Or with Docker, from the repo root:

```
docker compose -f hub/docker-compose.yml up -d --build
docker compose -f hub/docker-compose.yml run --rm hub add-machine living-room-pc
```

Point your proxy's subdomain at `127.0.0.1:8770` (`hub/Caddyfile.example`, `hub/nginx.example.conf`; there's also a systemd unit, `hub/combolab-hub.service`). Then set the admin password:

```
python3 hub/combolab_hub.py set-admin-password
docker compose -f hub/docker-compose.yml run --rm hub set-admin-password      # Docker
```

**Who can do what:**

| Who | Can |
|---|---|
| Anyone | Open the overview: machines, combos, sample counts, which machines recorded them |
| Sync machines (token) | Sync combos and profiles, back up and restore their own sessions |
| Approved viewer keys | Download everything as one JSON file |
| Admin (password, at `/admin`) | Approve or remove viewer keys, approve PCs asking to join, add or remove sync machines (a token made here is shown once), change the password |

**Exporting:**
- **From a browser:** open the hub's overview, type a name in the Export section and click **Request access**. The browser makes its own Ed25519 key; the private half can't be exported, even by the page. Once the admin approves the request on `/admin`, **Download everything** works from that browser. Each download signs a fresh one-time challenge.
- **With an SSH key** (ed25519, OpenSSH 8.1+):
  ```
  python combolab_export.py https://combolab.example.com --request "my laptop"
  python combolab_export.py https://combolab.example.com
  ```
  Or the admin pastes the `ssh-ed25519 ...` line into **Add key**.

**Admin security:**
- Admin sign-in uses a session cookie (HttpOnly, SameSite=Strict, Secure behind HTTPS, 12 hours).
- Five wrong passwords lock that address out for 15 minutes.
- The password is stored as a PBKDF2 hash.

Server-side backups: `combolab_hub.py export <folder>` writes everything out as plain JSON files. `allow-key`, `list-keys` and `remove-key` manage keys from the shell.

**On each gaming PC**, start **run_server.bat**, open the page from it (`http://localhost:41236`) and go to the **Hub Sync** tab:
1. Enter the hub's address and a name for this PC. It suggests the PC's hostname; letters, digits, `-`, `_` and `.` only.
2. Click **Ask to join**. The PC makes its own sync token and sends the hub only a hash of it.
3. Approve the request on the hub's `/admin` page under **Sync machines → Asking to join**. Syncing starts by itself, every 20 seconds while the server runs.

The Hub Sync tab also has:
- **Sync now**;
- **Rename:** each PC has a permanent hidden ID on the hub, and the name is only a label, so renaming changes nothing else;
- **Change hub** and **Disconnect**;
- connecting with a token from the admin page instead of asking to join.

The page's header shows the sync state ("Hub: synced just now" or "Hub: waiting for approval"). Without the page: `run_sync.bat setup https://combolab.example.com <token>`.

**What syncs:**

| Folder | How |
|---|---|
| `combos/` | Edits on any PC reach the others. New combos arrive automatically; one you delete on a PC stays deleted there. |
| `profiles/` | Merged. Every sample carries an ID, so an attempt is never counted twice, and samples from all machines add up (newest 300 per step). |
| `sessions/`, `bot/` | Backed up per machine. `run_sync.bat restore` brings them back on a fresh install. |

The game stays the only thing that writes `profiles/`. The agent drops the hub's merged copy in `shared/`, and the mod merges it in within a few seconds: straight away for combos that aren't loaded, and between attempts for the one that is (never while the bot is running). Resetting a profile on any machine resets it everywhere, and older samples from other machines don't come back. Profiles recorded before 1.7 merge fine too.

## Research bot (automatic profiles)

The bot plays combos for you in Training mode and sweeps each step's press timing frame by frame, so profiles come out exact without practice runs. It presses buttons through the same input hook the mod already reads from (the technique Wael3rd's SF6_Tools uses for playback), and it moves both fighters back into position between attempts.

**Before starting**, in SF6's Training settings:
- Dummy: **No guard**, standing.
- Drive gauge and Super gauge: **infinite** (or auto-recover); life auto-recover on.
- For combos marked PC: Counter setting on **Punish Counter**.
- Keep your hands off the controller: any real input stops the bot.
- Playing offline is safest, and remove `dinput8.dll` before going online.

**Start it** from the **Research bot** card on the Profiling tab (this combo, or every combo for the character), from the REFramework menu (ComboLab > Research bot), or with **F10** for the current combo. F10 again stops it.

**What it does for each combo:**
1. Finds each step's window: with earlier steps at their middle timing, it tries the step on every frame until it has seen it work and then fail 4 frames in a row, then re-tests the edges.
2. Sweet-spot pass: plays the full combo varying one step across its window, so the profile learns which part keeps the next step alive.
3. Checks the full combo at the final target timings and reports how many were clean.

**A batch:** shift-click (a range) or Ctrl-click (one at a time) combos in the sidebar, then **Profile N selected combos**. A plain click goes back to a single combo.

**Profile all combos for this character** skips combos that are already at 100% (unless **Replace existing profile** is ticked) and runs experimental combos last. It gives up on an experimental combo after 30 attempts in a row with nothing working, so a combo that doesn't actually work can't eat the whole run.

**Re-running a combo** keeps its profile and starts from what's already there: for each step with a measured window, the bot first checks that window's edges (about four attempts), and only searches if they no longer hold. Tick **Replace existing profile** to start from scratch instead. Steps with no measured window start from the frame-data prediction.

Position comes from the combo name ("corner" in the name means corner) unless you override it. Before each attempt the bot checks that both fighters actually ended up in place: it re-applies the move for a few frames if the game puts them back, and stops that combo with a reason if they still aren't there. Results, including why a combo failed, show in the web page and are saved to `reframework/data/ComboLab/bot/<id>.json`.

**Research speed** (experimental): runs the battle faster than real time while the bot works, up to 1.5x. It uses Training's own Game Speed setting: the menu only offers 100% and 50%, but the game has every step from 50% to 150%. Everything is counted in game frames, so the windows come out the same, just sooner. Click **Test speed settings** once (Training mode, a combo loaded, hands off for about 15 seconds): it tries each speed setting it can find (RE Engine's global game speed and any "speed" value in Training's settings) at 2x and keeps only one that really runs more frames per second, not one that just speeds up animations. Then pick 1.5x–4x on the Research bot card. The speed only applies while the bot runs and goes back to normal as soon as it stops. The REFramework menu has the same under ComboLab > Research speed, with the frames per second it's getting.

**Speed:** each attempt takes about 4–6 seconds (most of it waiting for the dummy to get up). A 4-step combo takes around 100 attempts at 2 repeats, about 8 minutes; long combos take longer. Use 1 repeat and turn off the sweet-spot pass for a quick first pass.

**Jump-in starters** (j.X as the first step): the bot first measures your character's forward jump (from far apart: how long it's in the air and how far it goes), then looks for a spacing just short of that distance and the latest press during the jump that still hits as an air attack, i.e. as deep as possible. Then it profiles the rest of the combo from there. The distance and timing it found are saved in the combo, so later runs skip the search (unless **Replace existing profile** is ticked, or the saved one stops hitting). Cross-ups aren't searched for: the bot always jumps in from the front.

**Not supported yet:** Modern controls; those combos are skipped with a reason. Charge moves hold the charge direction automatically, which can turn a neutral normal right before them into a crouching one.

## Dummy settings per combo

With **Set the dummy for each combo** on (Profiling tab, on by default), loading a combo in Training sets the dummy the way the combo needs it, through the same settings as Training's menu:
- **Counter:** Punish Counter for a combo that starts with Drive Impact (a DI only crumples on a punish counter, and the Punish Counter setting makes every hit one), or with "PC" / "punish counter" in its name; Counter Hit with "CH" / "counter" in the name; otherwise normal hits.
- **Stance:** crouching with "crouch" in the name, otherwise standing.
- **Guard:** off while the research bot runs, then back to what you had.
- **Steps that never hit:** a power-up like Juri's Feng Shui Engine activation (`214214P` / SA2) has no hitbox, so as a normal step it would fail every time. It's timed like a movement step instead: the move coming out is the step. Juri's is known by name; any other is caught from the game's frame data the first time it comes out without connecting (the overlay says so, and the profile remembers it). You can also set a step to **Movement** yourself in Combo Database (Edit > step > kind).
- **Getting back up:** the research bot and song mode's next count-in wait until the dummy is back in its standing (or crouching) pose, so a Drive Impact crumple or a knockdown plays out before the next attempt. The resting pose is learned as it goes; a pose held for 3 seconds also counts (a stance change), and the bot gives up waiting after 7 seconds.

Each combo can override both in Combo Database (Edit > Dummy counter / Dummy stance). **Training settings for this combo** (Profiling tab) covers any other Training setting, such as character-specific ones like Juri's unlimited Feng Shui Engine: press **Remember settings**, change the setting in SF6's Training menu, press **What changed?**, tick what belongs and save it to the combo (or to every combo in its section). It's set whenever that combo loads and put back when another one loads. The combo header shows what the dummy is set to. Turning the option off puts your own settings back. The field names come from Wael3rd's SF6_Tools (MIT).

## Fighter placement for your own practice

**Song mode** can put the fighters back in place at every count-in (Training tab > Overlay and notes > *Song: put the fighters back in place at each count-in*): midscreen, or the corner for corner combos.

Corner combos (any with "corner" in the name) put both fighters in the corner you're facing when the combo loads, and again between attempts once you've been idle for about a second. Turn it off with **Corner combos: place fighters in the corner** on the Profiling tab. The REFramework menu has **Place fighters in the corner now** / **Midscreen now** buttons and a spacing slider. SF6's own option works too: hold left or right while pressing the reset-position button in Training.

## The web page

Three tabs along the top:

- **Combo Training:** the combo list for one character on the left, the selected combo on the right with two big sub-tabs.
  - Each combo in the list is coloured by how far it's profiled: dark red with nothing found, turning green as it fills in. Windows count for two thirds and sweet spots for the last third (the last step has no sweet spot, so its window counts in full). A window counts as found once it has three clean presses and a failed press just outside each edge.
  - Clicking a combo loads it in game, in the mode of the open sub-tab. Switching sub-tabs switches the game's mode too.
  - **Profiling** (game in Develop): how far it's profiled, **Profile in game**, **Reset profile**, profiling options, the **Research bot** and the timing profile chart and table.
  - **Training** (game in Train): **Train in game**, today's attempts and streak, session options (Train view, song mode, motion arrows, spam blocker, overlay layout) and the training history. Options go to the game as you change them.
- **Combo Database:** every character in a grid; pick one to see their combos with their profiled %, and add, edit, import or delete them.
  - **Experimental** combos have their own section. New and imported combos start out experimental (untick it if you know the combo works). One is verified automatically after its first clean run, yours or the bot's, and **Mark verified** / **Mark experimental** flips it by hand.
- **Hub Sync:** the data folder and the hub connection (below).

## Workflow

1. In **Combo Database**, pick a character, click **+ New combo** and type it, for example
   `2LP > 2LP, 5LK > DR > 5LP, 5HP > DR > 5HK, 5MP~4HP > [2]8HK`.
   - `>` means cancel, `,` means link, `~` means chain or target combo.
   - `DR` after `>` is a Drive Rush cancel (timed on MP+MK). A `DR` that starts the combo or follows a `,` is a raw Drive Rush from standing (Parry, then 66), timed on the second forward, which is when the rush starts.
   - `cr.MK`, `j.HP`, `[2]8HK`, `236P`, `DR`, `DI`, `66`, `SA2` and Modern buttons (`L M H SP`) all work.
   - Click a step chip to change what counts as its trigger press, or whether it is a hit or a movement step.
   - `Section: name` groups it under that section in the lists.
2. In **Combo Training → Profiling**, click the combo (or **Profile in game**) and go to Training mode.
3. Do the combo many times, or let the research bot do it.
   - Each attempt adds samples; the cyan windows grow as you go.
   - Drop it early and late on purpose too: those failures pin the window edges down.
4. When the combo is green enough, switch to the **Training** sub-tab (or press **F5** in game).
   - Each press now lands on the bar as a tick inside or outside the window.
   - A drop tells you which step failed and by how many frames.
   - Turn on **Spam blocker** (F8) to fail runs where you pressed a step's button more than once.
   - **Spearmint Twintails view** (F11, or Train view in the page): each upcoming step is a note that flies in and lands on a target ring exactly on that step's target frame. A countdown hand makes one lap per note: it leaves 12 o'clock when the previous note lands and is back at 12 o'clock exactly when the next one lands; the cyan arc it passes through is the window and the white arc is the sweet spot. Each press gets a judgement: SWEET, GOOD, EARLY/LATE by N frames, or why it dropped. Later notes are predicted from each move's usual startup and corrected as the moves actually come out. Notes are the same size as the target ring, and the one you're about to hit is brighter than the rest. Punches fly in from the left and kicks from the right (Drive Rush, DI and supers rise from below), with an option to swap sides. Note colours: **Classic** (light red, medium white, heavy blue) or **SF6** (light blue, medium yellow, heavy red). "Note flight" sets how many frames each note is in the air.
   - **Text size** (session options or the REFramework menu, default 1.4): makes the overlay's text bigger or smaller on top of the overall overlay scale, from 0.75 to 2.5, up to 4K. A combo too long for the screen at that size gets a smaller notation line so it still fits.
   - **Motion arrows** (on by default; session options or the REFramework menu): shows motions as arrows instead of numpad numbers, in the overlay and on the web page. `623HP` becomes a Z with its head pointing forward plus HP, `236` reads as down curving into a forward arrow, `41236` is a "C" ending forward, `360` a circle, `214214` two quarter circles, `[2]8` a held down arrow then up, and `66` two forward arrows. Arrows are drawn for the 1P side (facing right), the way the notation is written.
   - **Strike Fixation view** (Train view dropdown, or F11 to cycle): a DDR-style chart with four lanes, **motion | light | medium | heavy**. Each step is a row of notes that rises to the receptors at the top and lands on the step's target frame.
     - **Motion lane:** the motion as an arrow (623 as a Z, 214 as a quarter circle, `[↓]↑` for charge), or DR / DI / SA as text.
     - **Strength lanes:** P, K or PK in the strength's lane, in the note palette's colours. A button of any strength (`236K`) or an OD (`236PP`) is one bar across all three.
     - **Window:** the cyan bracket around each row is that step's press window.
     - **Feedback:** receptors flash with the judgement, and a combo counter counts up.
     - The lanes can sit left, centre or right of the screen (session options).
   - **Apple Addict Attack view** (Train view dropdown, or F11 to cycle): an Ongeki-style highway seen in perspective. Notes come down toward the judgement line and land on each step's target frame.
     - **Lanes:** LP, MP and HP on the left, LK, MK and HK on the right, in SF6's colours (light blue, medium yellow, heavy red).
     - **Walls:** the orange left wall is Drive Rush and Parry, the right wall is Drive Impact, and supers light both.
     - **Two-button notes:** an OD (`PP` / `KK`) is one bar across two lanes, and a throw is a note on each side. Held buttons (`236[PP]`) have a tail.
     - **Lever rail:** the purple rail is the stick (back on the left, neutral in the middle, forward on the right), with big green arrows for each direction of a motion. An arrow that crosses a button note turns into an outline so both stay readable. A charge (`[4]6`) is a thick segment held at the back.
     - **Apple:** the red apple on the judgement line follows your stick.
     - **Window:** the cyan box behind a note is its press window, and the brighter band is the sweet spot.
     - **HUD:** SWEET / GOOD / DROP counts for this combo, your clean-run streak, and the dummy as the "enemy" with the combo's hits and damage.
     - "Lane position" (left / centre / right) applies here too.
   - **Song mode** (on by default; Train, any view): instead of starting when your first hit lands, a count-in plays (3, 2, 1) and step 1 gets its own note on the downbeat. The rest of the combo follows on a fixed timeline at its ideal cadence (each step's target frame plus its usual startup), with notes visible from further out (80 frames by default). After each attempt it re-arms when you're idle. If the first note goes by untouched, or two notes in a row do, it restarts with a new count-in. **Follow my hits** re-times the remaining notes from the moves that actually come out, so the guide stays exact if you're early or late on one step. In bar view the playhead is larger and brighter, starts in a count-in section in front of step 1 (its beat ticks light up 3, 2, 1) and reaches step 1 on the downbeat, then runs along the bar following the song.
   - **Rhythm guide:** once a step's move starts, a glowing playhead runs through the next segment in real game frames and flashes on the middle of the window (white notches mark it). Between attempts a dimmer playhead loops the whole combo's cadence: each step's mid-window press plus that move's usual press-to-startup delay. Both can be switched off in the session options.

| Key | Action |
|---|---|
| F5 | Profiling (Develop) / Training (Train) |
| F6 | next combo |
| F7 | detail table (Develop; off by default, and F7 can be switched off in the options) |
| F8 | spam blocker |
| F9 | hide overlay |
| F10 | research bot (current combo) |
| F11 | Train view |

The same options are in the REFramework menu (Insert), under **ComboLab**. That menu also has a **Diagnostics** section.

## Windows predicted from the game's frame data

Once ComboLab knows which move each step is (after the move has come out once), it reads both moves' frame data straight from the game and predicts the step's window before you've practised it. The data path comes from alphaZomega's MMDK (MIT).

| Data | Used for |
|---|---|
| Startup, recovery, active frames | Link windows: you can act once the previous move recovers |
| Cancel ranges and which moves they allow | Cancel and chain windows |
| Hitstun and hitstop, with counter-hit / Punish Counter variants | When the opponent recovers ("PC" or "CH" in the combo name picks those) |

- **Bar:** a predicted window shows as a hollow cyan box until real samples replace it. Train mode can grade against it straight away.
- **Bot:** checks the predicted edges first (one press just outside and just inside each edge). When they hold, the window is found in four attempts instead of a search; when they don't, it searches as before.
- **Calibration:** steps whose edges get pinned down by misses on both sides are compared with their prediction, and the average offset (per cancel / link) is applied to later predictions once three such steps exist.
- **Web page:** the profile tab draws predicted windows as dashed boxes. The table's **Frame data** column shows each prediction and how far the measured window was from it.
- **Diagnostics** (REFramework menu) lists each step's startup, recovery, hitstun, hitstop, on-hit advantage, cancel ranges, and predicted vs measured window. **Re-read frame data** refreshes after a game patch.

Predictions are approximate:
- They assume the hit lands on the first active frame.
- Multi-hit moves, projectiles and juggles (where hitstun depends on the air state) can be off.
- Combos that depend on spacing can't be predicted at all.

Turn it off with **Predict windows from frame data** in the session options.

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
| `config.json` | game | Options, hotkeys, this PC's sample tag (`machine_id`) |
| `sync.json` | `run_sync.bat setup` | Hub address and this PC's token |
| `shared/` | sync agent | Merged profiles from the hub and sync status (the game merges them into `profiles/`) |

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

## If the game crashes

- **Changes to the game happen on the game's thread.** Dummy and Training settings, game speed and fighter teleports are queued and applied at the start of the game's own update (REFramework's `UpdateBehavior`), not from the overlay's frame callback, so they never race the game. The REFramework log says which one is in use at startup ("game-state changes run on: ...").
- **Breadcrumbs:** before each of those changes ComboLab notes what it's about to do in `crumbs.json`, plus a heartbeat every 2 seconds. If the game closes within a few seconds of one of them, the next start logs it and the page header shows "Last time the game closed right after: ..." (hover for the steps before it, click to dismiss). Send that line along with `re2_framework_log.txt` from the game folder.
- **To rule ComboLab's settings out:** turn off **Set the dummy and Training settings for each combo** (Profiling tab). Then loading a combo changes nothing in the game.

## Development

`tests/` holds the pure-Lua engine tests, a mocked-REFramework integration test, the overlay previewer and the notation parser test. Run them from the repository root:

```
lua tests/sim.lua
lua tests/integ.lua
node tests/parser.test.js
lua tests/bot_test.lua
lua tests/plans_test.lua
lua tests/motion_test.lua
lua tests/predict_test.lua
lua tests/movedata_test.lua
python3 tests/hub_test.py
```
