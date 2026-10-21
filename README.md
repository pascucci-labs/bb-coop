# BB Co-op

A free mod for **Battle Brothers** that lets two players run one campaign
together online, each on their own PC. Every brother belongs to one player,
and only that player can act with them in combat or manage them in camp. The
host is the admin: they drive the world map and can reassign brothers.

> **Work in progress.** Ownership, hiring rules, retraining and the relay
> connection work. Shared battles, a mirrored campaign, voting and synced
> saves are still being built. See [DESIGN.md](DESIGN.md) for the plan and
> current status.

## Requirements

- Battle Brothers (vanilla; **Legends is not supported**)
- [Modern Hooks](https://www.nexusmods.com/battlebrothers/mods/685) (built against 0.6.0)
- [MSU](https://www.nexusmods.com/battlebrothers/mods/479) 1.9.0 or later
- [Node.js](https://nodejs.org/) on whichever PC runs the relay

## Install

1. Install Modern Hooks and MSU.
2. Download `mod_bb_coop.zip` from the Releases page and put it in the game's
   `data` folder, next to the other mod zips. Don't unzip it.
3. Both players need the same version of the mod.

## Playing together

The game can't open network connections on its own, so the two games talk
through a small **relay** server. One person runs the relay; both games
connect to it.

1. Start the relay (see below).
2. **Host:** on the main menu, choose **Host Campaign**. The lobby shows a
   **join code**. Copy it and send it to your friend.
3. **Guest:** choose **Join Campaign** and paste the join code.
4. When the status light turns green you're linked. Start or load the
   campaign from the lobby.

## Host your own relay

The relay is one file with no dependencies: `relay/relay.js`. Each relay
holds one session at a time (one host and one guest), so every group runs
its own.

```sh
node relay/relay.js --port 7777 --key pick-a-secret
```

- `--port`: the port to listen on (default 7777).
- `--key`: a session key. Both players need it, and anyone without it is
  refused. Always set one if the relay is reachable from the internet.

The host's game connects to `ws://127.0.0.1:7777`. The guest connects to
`ws://<host's public address>:7777`, so the relay's PC must be reachable from
the guest:

- **Same PC as the host:** forward the port (TCP 7777) on your router to that
  PC, and allow it through the firewall. The guest uses your public IP.
- **A server or VPS:** run the relay there and both players connect to it.
- **A tunnel** (for example Cloudflare Tunnel, ngrok or Tailscale): useful if
  you can't forward ports. A tunnel that gives you an `https` address gives
  you a `wss://` relay address.

The join code is the relay address plus the key, for example
`ws://203.0.113.5:7777/pick-a-secret`. Keep the `ws://` at the front when the
relay is a plain address: a code without a prefix is treated as `wss://`
(secure WebSocket), and whether the game can make `wss://` connections at all
hasn't been tested yet.

The relay pings both games every 25 seconds and drops a connection that has
been silent for 75 seconds, so a crashed game frees its seat. Run
`node relay/test_relay.js` to check a relay build.

## Building from source

`python build.py` syntax-checks every script, zips `mod_bb_coop/` into
`dist/mod_bb_coop.zip` and copies it to the game's data folder
(`--no-install` skips the copy). It expects:

- Node.js, for checking the UI JavaScript;
- BBBuilder unpacked in
  `tools/BBbuilder-main/` (it provides `sq_taro.exe`, the Squirrel checker);
- the game at the path set in `build.py` (`GAME_DATA`); edit it to match
  your install.

The decompiled game scripts (`vanilla/`), third-party mods (`libs/`) and
build tools (`tools/`) are deliberately not in this repository.

## License

[MIT](LICENSE). Battle Brothers is © Overhype Studios; this mod contains
none of the game's files.
