// Self-test for relay.js: starts it, connects a fake host and guest, checks pairing,
// forwarding, the seat limit, the session key and the keep-alive. Usage: node test_relay.js
"use strict";

const { spawn } = require("child_process");
const path = require("path");
const assert = require("assert");
const net = require("net");

const PORT = 17777;
const URL = "ws://127.0.0.1:" + PORT;
const CRLF = String.fromCharCode(13, 10);

const sockets = [];
function client(role, name, key) {
	return new Promise((resolve, reject) => {
		const ws = new WebSocket(URL);
		sockets.push(ws);
		const inbox = [];
		const waiters = [];
		ws.onmessage = (e) => {
			const msg = JSON.parse(e.data);
			const w = waiters.findIndex((x) => x.type === msg.type);
			if (w >= 0) waiters.splice(w, 1)[0].resolve(msg);
			else inbox.push(msg);
		};
		ws.onopen = () => {
			ws.send(JSON.stringify({ type: "hello", data: { role, name, version: "0.1.0", protocol: 1, key } }));
			resolve({
				ws,
				send: (type, data) => ws.send(JSON.stringify({ type, data })),
				next: (type) => {
					const i = inbox.findIndex((m) => m.type === type);
					if (i >= 0) return Promise.resolve(inbox.splice(i, 1)[0]);
					return new Promise((res, rej) => {
						waiters.push({ type, resolve: res });
						setTimeout(() => rej(new Error(`${name}: timed out waiting for ${type}`)), 2000);
					});
				},
				closed: new Promise((res) => (ws.onclose = res)),
			});
		};
		ws.onerror = () => reject(new Error("could not connect"));
	});
}

// Raw TCP client that joins as guest and then never answers anything, like a crashed game.
function silentGuest() {
	return new Promise((resolve) => {
		const sock = net.connect(PORT, "127.0.0.1", () => {
			sock.write(["GET / HTTP/1.1", "Host: x", "Upgrade: websocket", "Connection: Upgrade",
				"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", "Sec-WebSocket-Version: 13", "", ""].join(CRLF));
			const body = Buffer.from(JSON.stringify({ type: "hello", data: { role: "guest", name: "Ghost", version: "0.1.0", key: "s3cret" } }));
			const mask = Buffer.from([1, 2, 3, 4]);
			const payload = Buffer.from(body.map((b, i) => b ^ mask[i & 3]));
			sock.write(Buffer.concat([Buffer.from([0x81, 0x80 | 126, body.length >> 8, body.length & 255]), mask, payload]));
			resolve(sock);
		});
		sock.on("data", () => {}); // read and ignore, never reply
		sock.on("error", () => {});
	});
}

(async () => {
	// Pings every 200 ms; a connection silent for 600 ms is dropped.
	const relay = spawn(process.execPath, [path.join(__dirname, "relay.js"), "--port", String(PORT), "--key", "s3cret", "--ping", "200"], { stdio: ["ignore", "pipe", "inherit"] });
	await new Promise((res) => relay.stdout.once("data", res));
	let failed = false;
	let dead = null;

	try {
		const host = await client("host", "Alice", "s3cret");
		assert.equal((await host.next("welcome")).data.role, "host");

		const guest = await client("guest", "Bob", "s3cret");
		await guest.next("welcome");
		assert.equal((await guest.next("peer_joined")).data.name, "Alice");
		assert.equal((await host.next("peer_joined")).data.name, "Bob");
		console.log("ok  pairing");

		guest.send("ping", { t: 1.5 });
		assert.deepEqual((await host.next("ping")).data, { t: 1.5 });
		host.send("owners", { "1": 1, "2": 2 });
		assert.deepEqual((await guest.next("owners")).data, { "1": 1, "2": 2 });
		console.log("ok  forwarding both ways");

		const big = "x".repeat(200000);
		host.send("save", { blob: big });
		assert.equal((await guest.next("save")).data.blob.length, big.length);
		console.log("ok  large message (200 KB)");

		const second = await client("guest", "Eve", "s3cret");
		assert.match((await second.next("error")).data.message, /already a guest/);
		await second.closed;
		console.log("ok  second guest refused");

		const wrong = await client("guest", "Mallory", "nope");
		assert.match((await wrong.next("error")).data.message, /Wrong session key/);
		await wrong.closed;
		console.log("ok  wrong key refused");

		guest.ws.close();
		assert.equal((await host.next("peer_left")).data.name, "Bob");
		console.log("ok  peer_left on disconnect");

		const back = await client("guest", "Bob", "s3cret");
		assert.equal((await back.next("peer_joined")).data.name, "Alice");
		assert.equal((await host.next("peer_joined")).data.name, "Bob");
		console.log("ok  guest can rejoin");

		// Node's WebSocket answers pings itself, like the game's, so idle players stay linked.
		await new Promise((res) => setTimeout(res, 1000));
		host.send("ping", { t: 2 });
		assert.deepEqual((await back.next("ping")).data, { t: 2 });
		console.log("ok  idle but answering pings: stays connected");

		back.ws.close();
		await host.next("peer_left");
		dead = await silentGuest();
		assert.equal((await host.next("peer_joined")).data.name, "Ghost");
		assert.equal((await host.next("peer_left")).data.name, "Ghost");
		const again = await client("guest", "Bob", "s3cret");
		await again.next("welcome");
		console.log("ok  silent connection dropped and seat freed");
	} catch (e) {
		failed = true;
		console.error("FAIL", e.message);
	}

	if (dead) dead.destroy();
	sockets.forEach((ws) => ws.close());
	relay.kill();
	process.exitCode = failed ? 1 : 0;
})();
