# Battle Brothers Co-op — Design

Two players on two PCs share one company. Every brother belongs to one player.
Only the owner can act with that brother in combat or manage them in camp.
The host is the admin: they control the world map and can reassign brothers.

## Findings (2026-10-17)

- Game: Steam, `D:/SteamLibrary/steamapps/common/Battle Brothers`, no mods installed.
- Logic: 3,104 compiled Squirrel scripts (`.cnut`) in `data/data_001.dat`.
  These need decompiling (BBBuilder or bbkit) before we can read them and hook them.
- UI: HTML/JS on Coherent GT. `CoherentGTCore.dll` contains a WebSocket
  implementation, so the UI layer can likely open a socket. This is the only
  network channel available, because Squirrel has no networking.

## Architecture

```
 Host PC (admin)                         Guest PC
 ┌────────────────────┐                 ┌────────────────────┐
 │ Squirrel mod       │                 │ Squirrel mod       │
 │   ↕ JS bridge      │                 │   ↕ JS bridge      │
 │ UI JS (WebSocket) ─┼──► relay ◄──────┼─ UI JS (WebSocket) │
 └────────────────────┘   server        └────────────────────┘
                     (small Node/Python app on the host;
                      the guest connects to the host's IP or a tunnel)
```

**Sync model: host-authoritative lockstep.**
- Both games run the same campaign. The host's game is the source of truth.
- Only *commands* go over the wire (move brother to tile, use skill X on tile,
  wait, end turn, equip item, pick perk, assign owner).
- Before running each command, the host sends an RNG seed and both sides call
  `Math.seedRandom(seed)`, so rolls (hit chance, damage, morale) match.
- AI turns run only on the host. The host records what the AI did and sends
  those actions as commands. The guest never runs its own AI.
- After each action, both sides hash the state (positions, HP, AP, fatigue,
  morale, armor). If the hashes differ, the host sends a correcting snapshot.
- When a session starts, the host sends its save file through the relay, so
  both sides begin from the same state.

## Ownership (needed whatever the network design)

- Each brother gets a flag `coop.owner` = `1` (host) or `2` (guest), stored with
  the save via `getFlags()`.
- When a brother is hired, ownership is assigned by rule: alternating
  (default), the player with fewer brothers, or always to the host. The admin
  picks the rule in MSU settings.
- The admin can reassign any brother from the character screen or roster
  (an owner badge on the portrait; click to toggle).
- In combat, when it's the other player's brother's turn, local input is
  blocked and a "Waiting for Player 2…" banner shows.

## Saving and quitting

- **Saving:** vanilla can only save on the world map, not during combat; the engine
  has no mid-battle save. Either player can request a save on the world map. The host
  saves, then tells the guest to save to the same slot name at the same moment, so the
  two save files stay identical and either PC can resume.
- **Quitting:** either player can quit at any time.
  - On the world map, the game pauses and the other player sees "X left". Resume by
    both loading the latest co-op save.
  - In combat, the game pauses and waits for the player to reconnect. The admin can
    choose "Take over their brothers" to finish the fight alone.
  - Saves don't depend on being linked, so a session can always be continued, even solo.

## Shared decisions (voting)

Any window where the company makes a choice is a vote:
event options, contract offers and negotiation, "engage or retreat" when meeting
enemies, and the combat result screen.

- Each player clicks an option. Their pick shows on both screens ("P1 ✓ / P2 …").
- When both pick the same option, it runs on both PCs.
- The admin (Player 1) also gets "Force this choice", which runs their pick immediately.
- Only the host runs the event's logic, using a seed shared with the guest, so
  random outcomes match.

## Brother editing ("Retraining")

So one player isn't stuck with bad recruits, either player can retrain their own
brother for **1000 crowns** from the shared treasury. The admin can retrain anyone's.

- xBreditor (Nexus mod 294) was checked and can't be used directly. The downloaded file
  is the Legends build, it replaces vanilla `ui/main.html` and `ui/screens.js` with
  2022 copies (which breaks the current game and MSU), and it's a free cheat editor
  with no cost or ownership rules.
- Plan: a small editor built into this mod, borrowing xBreditor's ideas but written
  against vanilla, MSU and the ownership/sync system. Every edit is a command sent to
  the other PC, so both games apply it.
- Which fields can be edited is still open (see "Open questions").

## Phases

| # | Phase | Result | Risk |
|---|-------|--------|------|
| 0 | Setup and spikes | Scripts decompiled, MH+MSU installed, WebSocket proven in-game | Low; needs you to run the game once |
| 1 | Ownership | Owner flag, assignment on hire, admin reassign UI, badges | Low |
| 2 | Relay and session | Relay server, connect/lobby screen, save transfer | Medium |
| 3 | Combat lockstep | Commands, seeded RNG, AI replay, hash check and resync | **High**: this is where desyncs happen |
| 4 | Camp/management sync | Equipment, perks, formation, hiring, retraining for 1000 crowns | Medium |
| 5 | World map | Host drives; voting on events/contracts; synced save; quit/rejoin | Medium |

## Status (2026-10-17)

Built (`mod_bb_coop/`, installed as `data/mod_bb_coop.zip`):
- Owner flag + campaign UID per brother; assignment on hire with 3 rules; starting
  company split automatically.
- Owner badge (P1/P2) on character-screen portraits; the admin clicks it to reassign.
- Combat: banner showing whose turn it is; in Host/Guest mode, clicks, skill hotkeys,
  end turn, wait and "end round" are blocked for the other player's brothers.
- Network: WebSocket client in the UI, relay server (`relay/relay.js`, self-test
  passes), hello/pairing, ping, campaign-match check, host→guest owner sync.

Retraining (1000 crowns: attributes, talents, trait swap, perk reset) works in-game.

**Architecture change (2026-10-18):** two independent campaigns can't stay identical,
because the world map runs on real-time randomness. So the host runs the only real
campaign and the guest's game is a mirror. Guest actions are requests the host carries
out. MSU's serialization emulator can turn a brother (or other game objects) into plain
data, which will be used to send state snapshots to the guest.

Phase 3 started (`bb_coop/sync.nut`, `hooks/combat_sync.nut`, `hooks/tactical_state.nut`):
- One ordered record stream from host to guest: move, skill, wait, skipround (commands);
  AI path and AI skill (captured on the host); endturn (every turn end on the host).
- Guest: clicks become requests, its AI is off, and it only ends turns from the stream.
- RNG reseeded from (battle seed, counter) at every action, movement step and turn start.
- Digest (positions, HP, armor, AP, fatigue, morale) after each action settles; the
  guest compares it and reports desyncs to log.html.
- Loopback test mode runs the host side solo, with requests passing through JSON.

Added 2026-10-18: "Co-op enabled" on/off switch (off = plain single player); each
player sets their own name, badge text (up to 4 letters) and colour, sent to the other
PC on linking; portraits of brothers you don't control are faded and grey (character
screen and combat turn bar).

Added 2026-10-20, Co-op panel (`bb_coop/panel.nut`, panel code in `coop.js`): a status
light at the top right (grey off, blue local, yellow connecting/waiting, green linked,
red offline/problem) opens the panel. The panel has: Play alone / Host / Join, with
Hot-seat and Loopback under "More options"; host connection settings and a join code
(`address/key`; wss:// is the default and is left out); a join box for the guest; name,
badge and colour presets; the hire rule; and the your-turn alert (sound and banner flash).
Changes save immediately into the MSU settings. Network failures are reworded with what
to do (unreachable relay, wrong key, seat taken, version mismatch, different campaign).

Main menu (2026-10-20): the first screen has Solo Campaign, Host Campaign, Join Campaign,
Options, Tutorial Videos, Credits and Quit. Solo → New/Load/Scenarios with co-op off.
Host/Join → a lobby (status, the host's join code with Copy, the guest's join box, a link
to the Co-op panel) that connects automatically, plus New/Load/Scenarios and Back.
Starting a campaign from the main menu while linked plays together; while not linked it
plays solo (co-op is switched off). The in-game Load button isn't affected.

Not yet: starting the same battle on the guest (needs host→guest battle setup and
combatant snapshots), desync correction, AI item swaps, the battle result, voting,
synced saves.

## Open questions

- Decided 2026-10-17: target **vanilla** (not Legends). Retraining options are reroll
  attributes, reroll talents, swap traits, and reset perks, each costing 1000 crowns.

## Fallback

If phase 3 proves too unreliable, phases 0–1 plus Steam Remote Play Together
(or Parsec) still give online co-op: the guest streams the host's screen, and
the ownership system shows whose brother is acting.
