#!/usr/bin/env node
// BB Co-op relay: pairs one host and one guest and forwards messages between them.
// No dependencies. Usage: node relay.js [--port 7777] [--key secret]
"use strict";

const http = require("http");
const crypto = require("crypto");

const args = process.argv.slice(2);
function arg(name, fallback) {
	const i = args.indexOf("--" + name);
	return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
}
const PORT = parseInt(arg("port", process.env.BBCOOP_PORT || "7777"), 10);
const KEY = String(arg("key", process.env.BBCOOP_KEY || "")).trim();
const MAX_MESSAGE = 64 * 1024 * 1024; // save files can be big

// Keep-alive. Proxies such as Cloudflare drop a WebSocket that is silent for about
// 100 s, and players often sit idle that long. The relay pings every PING_MS, and
// drops a connection it hasn't heard from in DEAD_MS so a crashed game frees its seat.
const PING_MS = parseInt(arg("ping", process.env.BBCOOP_PING_MS || "25000"), 10);
const DEAD_MS = PING_MS * 3;

const log = (...m) => console.log(new Date().toISOString().slice(11, 19), ...m);

// ---- Minimal WebSocket (RFC 6455) ----------------------------------------------

class Socket {
	constructor(raw) {
		this.raw = raw;
		this.buffer = Buffer.alloc(0);
		this.fragments = [];
		this.open = true;
		this.onmessage = () => {};
		this.onclose = () => {};
		this.lastHeard = Date.now();
		this.heartbeat = setInterval(() => {
			if (Date.now() - this.lastHeard > DEAD_MS) {
				this.raw.destroy();
				this.closed();
				return;
			}
			this.frame(0x9, Buffer.alloc(0));
		}, PING_MS);
		raw.on("data", (chunk) => { this.lastHeard = Date.now(); this.receive(chunk); });
		raw.on("close", () => this.closed());
		raw.on("error", () => this.closed());
	}

	receive(chunk) {
		this.buffer = Buffer.concat([this.buffer, chunk]);
		for (;;) {
			const b = this.buffer;
			if (b.length < 2) return;
			const fin = (b[0] & 0x80) !== 0;
			const opcode = b[0] & 0x0f;
			const masked = (b[1] & 0x80) !== 0;
			let len = b[1] & 0x7f;
			let offset = 2;
			if (len === 126) {
				if (b.length < 4) return;
				len = b.readUInt16BE(2);
				offset = 4;
			} else if (len === 127) {
				if (b.length < 10) return;
				len = Number(b.readBigUInt64BE(2));
				offset = 10;
			}
			if (len > MAX_MESSAGE) return this.close(1009, "message too big");
			const maskOffset = offset;
			if (masked) offset += 4;
			if (b.length < offset + len) return;

			let payload = Buffer.from(b.subarray(offset, offset + len));
			if (masked) {
				const mask = b.subarray(maskOffset, maskOffset + 4);
				for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
			}
			this.buffer = b.subarray(offset + len);

			if (opcode === 0x8) return this.close(1000, "");
			if (opcode === 0x9) { this.frame(0xa, payload); continue; } // ping -> pong
			if (opcode === 0xa) continue;
			if (opcode === 0x1 || opcode === 0x2 || opcode === 0x0) {
				this.fragments.push(payload);
				if (fin) {
					const text = Buffer.concat(this.fragments).toString("utf8");
					this.fragments = [];
					this.onmessage(text);
				}
			}
		}
	}

	frame(opcode, payload) {
		if (!this.open) return;
		const len = payload.length;
		let header;
		if (len < 126) {
			header = Buffer.from([0x80 | opcode, len]);
		} else if (len < 65536) {
			header = Buffer.alloc(4);
			header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(len, 2);
		} else {
			header = Buffer.alloc(10);
			header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(len), 2);
		}
		this.raw.write(Buffer.concat([header, payload]));
	}

	send(obj) {
		this.frame(0x1, Buffer.from(JSON.stringify(obj), "utf8"));
	}

	close(code, reason) {
		if (!this.open) return;
		const body = Buffer.alloc(2 + Buffer.byteLength(reason));
		body.writeUInt16BE(code, 0);
		body.write(reason, 2);
		this.frame(0x8, body);
		this.raw.end();
		this.closed();
	}

	closed() {
		if (!this.open) return;
		this.open = false;
		clearInterval(this.heartbeat);
		this.onclose();
	}
}

// ---- Session: one host seat, one guest seat ----------------------------------------

const seats = { host: null, guest: null };
const other = (role) => (role === "host" ? seats.guest : seats.host);

function onConnection(socket, address) {
	let role = null;
	let name = null;

	socket.onmessage = (text) => {
		let msg;
		try { msg = JSON.parse(text); } catch (e) { return; }

		if (role === null) {
			if (msg.type !== "hello" || !msg.data) return socket.close(1002, "expected hello");
			const d = msg.data;
			if (KEY !== "" && String(d.key || "").trim() !== KEY) {
				const sent = String(d.key || "");
				log(`rejected ${address}: wrong session key (${sent === "" ? "the game's Session key setting is empty" : `got ${sent.length} characters, expected ${KEY.length}`})`);
				socket.send({ type: "error", data: { message: "Wrong session key" } });
				return socket.close(1008, "bad key");
			}
			if (d.role !== "host" && d.role !== "guest") return socket.close(1002, "bad role");
			if (seats[d.role] !== null) {
				socket.send({ type: "error", data: { message: "There is already a " + d.role + " connected" } });
				return socket.close(1008, "seat taken");
			}
			role = d.role;
			name = String(d.name || role);
			seats[role] = { socket, name, version: d.version };
			log(`${role} "${name}" joined from ${address} (mod ${d.version})`);
			socket.send({ type: "welcome", data: { role } });

			const peer = other(role);
			if (peer) {
				socket.send({ type: "peer_joined", data: { name: peer.name, version: peer.version } });
				peer.socket.send({ type: "peer_joined", data: { name, version: d.version } });
			}
			return;
		}

		const peer = other(role);
		if (peer) peer.socket.frame(0x1, Buffer.from(text, "utf8"));
	};

	socket.onclose = () => {
		if (role === null || seats[role] === null || seats[role].socket !== socket) return;
		seats[role] = null;
		log(`${role} "${name}" left`);
		const peer = other(role);
		if (peer) peer.socket.send({ type: "peer_left", data: { name } });
	};
}

const server = http.createServer((req, res) => {
	res.writeHead(200, { "Content-Type": "text/plain" });
	res.end(`BB Co-op relay. host: ${seats.host ? seats.host.name : "-"}, guest: ${seats.guest ? seats.guest.name : "-"}\n`);
});

server.on("upgrade", (req, raw, head) => {
	const key = req.headers["sec-websocket-key"];
	if (!key || (req.headers.upgrade || "").toLowerCase() !== "websocket") {
		raw.end("HTTP/1.1 400 Bad Request\r\n\r\n");
		return;
	}
	const accept = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
	raw.write(
		"HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\nConnection: Upgrade\r\n" +
		`Sec-WebSocket-Accept: ${accept}\r\n\r\n`
	);
	raw.setNoDelay(true);
	// Behind Cloudflare and Nginx, the socket address is the proxy's; use the header.
	const address = req.headers["cf-connecting-ip"] || req.headers["x-forwarded-for"] || raw.remoteAddress;
	const socket = new Socket(raw);
	onConnection(socket, address);
	if (head && head.length > 0) socket.receive(head); // bytes sent before our reply
});

// Stop cleanly on `podman stop` / Ctrl+C.
for (const signal of ["SIGINT", "SIGTERM"]) {
	process.on(signal, () => {
		log("stopping");
		for (const seat of Object.values(seats)) if (seat) seat.socket.close(1001, "relay stopping");
		server.close();
		setTimeout(() => process.exit(0), 200).unref();
	});
}

server.listen(PORT, "0.0.0.0", () => {
	log(`BB Co-op relay listening on port ${PORT}${KEY ? " (session key required)" : ""}`);
	log("Host connects to ws://127.0.0.1:" + PORT + ", the guest to ws://<host address>:" + PORT);
});
