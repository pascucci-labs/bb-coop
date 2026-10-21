// Network layer. Squirrel can't open sockets, so the UI's JavaScript (Coherent GT)
// holds the WebSocket. Squirrel -> JS goes through Connection.call(); JS -> Squirrel
// arrives in onEvent().
//
// Message format (JSON): { type = "...", data = ... }
// Relay messages: hello, welcome, peer_joined, peer_left, error.
// Everything else passes straight through the relay to the other player.
::BBCoop.Net <- {
	State = "offline", // offline | connecting | connected | paired
	PeerName = null,
	PeerVersion = null,
	Handlers = {},
	LastError = null,       // plain-language problem shown in the panel, with what to do
	GotRelayError = false,  // the relay explained why it closed; don't overwrite that
	Leaving = false,        // we closed the connection ourselves

	function isPaired()
	{
		return this.State == "paired";
	}

	function connect()
	{
		if (!::BBCoop.isEnabled())
		{
			::BBCoop.toast("Co-op is off. Open the Co-op panel and pick Host or Join first.");
			return;
		}
		if (::BBCoop.isHotseat() || ::BBCoop.isLoopback())
		{
			::BBCoop.toast("Open the Co-op panel and pick Host or Join first.");
			return;
		}
		if (this.State != "offline")
		{
			::BBCoop.toast("Already connected (" + this.State + ")");
			return;
		}

		local url = ::BBCoop.getSetting("RelayAddress");
		if (strip(url) == "")
		{
			this.setError(::BBCoop.isGuest() ? "Paste the host's join code first." : "Set the relay address first.");
			return;
		}
		this.LastError = null;
		this.GotRelayError = false;
		this.Leaving = false;
		this.State = "connecting";
		::BBCoop.toast("Connecting to " + url + " ...");
		::BBCoop.Connection.call("netConnect", {
			url = url,
			hello = {
				type = "hello",
				data = {
					role = ::BBCoop.isHost() ? "host" : "guest",
					name = ::BBCoop.getPlayerName(::BBCoop.getLocalPlayer()),
					version = ::BBCoop.Version,
					protocol = ::BBCoop.Const.ProtocolVersion,
					key = strip(::BBCoop.getSetting("SessionKey"))
				}
			}
		});
	}

	function disconnect()
	{
		if (this.State != "offline") this.Leaving = true;
		::BBCoop.Connection.call("netDisconnect", null);
	}

	function setError( _text )
	{
		this.LastError = _text;
		::BBCoop.toast(_text);
		::BBCoop.updateStatus();
	}

	// The relay's reasons for refusing us, reworded with what to do about it.
	function explainRelayError( _message )
	{
		local host = ::BBCoop.isHost();
		if (_message.find("session key") != null)
		{
			return host
				? "The Session key doesn't match the relay's. It must be exactly what the relay was started with (--key)."
				: "The key in your join code doesn't match the relay's. Ask the host for the join code again.";
		}
		if (_message.find("already a") != null)
		{
			local role = host ? "host" : "guest";
			return "Someone is already connected as the " + role + ". If that was you a moment ago, wait about a minute for the old connection to time out, then connect again.";
		}
		return "The relay refused the connection: " + _message;
	}

	// This player's name, badge text and colour, for the other PC.
	function getProfile()
	{
		local n = ::BBCoop.getLocalPlayer();
		if (n == 0) return null;
		return {
			player = n,
			name = ::BBCoop.getSetting("Player" + n + "Name"),
			tag = ::BBCoop.getSetting("Player" + n + "Tag"),
			color = ::BBCoop.getSetting("Player" + n + "Color")
		};
	}

	function sendProfile()
	{
		local profile = this.getProfile();
		if (profile != null) this.send("profile", profile);
	}

	function send( _type, _data = null )
	{
		if (this.State != "connected" && this.State != "paired") return false;
		::BBCoop.Connection.call("netSend", { type = _type, data = _data });
		return true;
	}

	function on( _type, _function )
	{
		this.Handlers[_type] <- _function;
	}

	// Called from JS.
	function onEvent( _type, _data )
	{
		switch (_type)
		{
			case "open":
				this.State = "connected";
				::BBCoop.log("Socket open");
				break;

			case "message":
				this.dispatch(_data);
				break;

			case "close":
				local wasPaired = this.isPaired();
				local wasOpen = this.State != "connecting";
				local peer = this.PeerName;
				this.State = "offline";
				this.PeerName = null;
				if (this.Leaving || this.GotRelayError)
				{
					::BBCoop.log("Disconnected");
				}
				else if (!wasOpen)
				{
					local url = ::BBCoop.getSetting("RelayAddress");
					local hint = ::BBCoop.isHost()
						? (::BBCoop.Panel.isLocalAddress(url) ? " Is the relay running? Start it with: node relay\\relay.js --key yourkey" : " Is the relay running, and is the address right?")
						: " Check that the host's relay is running, and that you pasted the whole join code.";
					this.setError("Can't reach the relay at " + url + "." + hint);
				}
				else if (wasPaired)
				{
					this.setError("Lost the connection to " + (peer != null ? peer : "the other player") + ". Press Connect to try again.");
				}
				else
				{
					this.setError("Lost the connection to the relay. Press Connect to try again.");
				}
				this.Leaving = false;
				break;

			case "error":
				// A close event always follows and explains it; just log the detail.
				::BBCoop.log("Network error: " + (_data != null && "message" in _data ? _data.message : "unknown"));
				break;
		}
		::BBCoop.updateStatus();
	}

	function dispatch( _msg )
	{
		if (_msg == null || !("type" in _msg)) return;
		local data = "data" in _msg ? _msg.data : null;

		if (_msg.type in this.Handlers)
		{
			try
			{
				this.Handlers[_msg.type](data);
			}
			catch (error)
			{
				::logError("[BBCoop] handler '" + _msg.type + "' failed: " + error);
			}
		}
		else
		{
			::BBCoop.log("No handler for message type " + _msg.type);
		}
	}

	// For the status light: state is off | local | offline | connecting | waiting | linked.
	function getStatus()
	{
		if (!::BBCoop.isEnabled()) return { state = "off", short = "Co-op", text = "Co-op: off", detail = "Co-op is off. Click to set it up." };
		if (::BBCoop.isHotseat()) return { state = "local", short = "Hot-seat", text = "Co-op: hot-seat", detail = "Both players on this PC" };
		if (::BBCoop.isLoopback()) return { state = "local", short = "Loopback", text = "Co-op: loopback test", detail = "Solo test of online combat" };

		local you = ::BBCoop.isHost() ? "Hosting" : "Joining";
		switch (this.State)
		{
			case "paired": return { state = "linked", short = this.PeerName, text = "Co-op: linked with " + this.PeerName, detail = "Linked with " + this.PeerName + ". " + you + " via " + ::BBCoop.getSetting("RelayAddress") };
			case "connected": return { state = "waiting", short = "Waiting", text = "Co-op: waiting for the other player", detail = "Connected to " + ::BBCoop.getSetting("RelayAddress") + ". Waiting for the other player." };
			case "connecting": return { state = "connecting", short = "Connecting", text = "Co-op: connecting...", detail = "Connecting to " + ::BBCoop.getSetting("RelayAddress") };
		}
		return { state = "offline", short = "Offline", text = "Co-op: not connected", detail = this.LastError != null ? this.LastError : "Not connected. Click to connect." };
	}

	function ping()
	{
		if (!this.send("ping", { t = ::Time.getRealTimeF() }))
		{
			::BBCoop.toast("Not connected");
		}
	}

	// Host -> guest: who owns which brother.
	function sendOwners()
	{
		if (!::BBCoop.isHost() || !this.isPaired() || !::BBCoop.isInCampaign()) return;
		this.send("owners", ::BBCoop.Ownership.getOwnersTable());
	}

	// Both sides describe their campaign, so a mismatch can be spotted early.
	function getCampaignInfo()
	{
		if (!::BBCoop.isInCampaign()) return null;
		return {
			company = ::World.Assets.getName(),
			day = ::World.getTime().Days,
			brothers = ::World.getPlayerRoster().getSize()
		};
	}
};

// ---- Message handlers -------------------------------------------------------

::BBCoop.Net.on("welcome", function( _data ) {
	::BBCoop.toast("Connected. Waiting for the other player...");
});

::BBCoop.Net.on("peer_joined", function( _data ) {
	local net = ::BBCoop.Net;
	net.State = "paired";
	net.LastError = null;
	net.PeerName = _data.name;
	net.PeerVersion = _data.version;
	::BBCoop.toast(_data.name + " joined the session");

	if (_data.version != ::BBCoop.Version)
	{
		::BBCoop.Net.setError(_data.name + " has co-op mod version " + _data.version + " and you have " + ::BBCoop.Version + ". You both need the same version, or things will go wrong.");
	}

	net.send("campaign_info", net.getCampaignInfo());
	net.sendProfile();
	net.sendOwners();
	::BBCoop.updateStatus();
});

::BBCoop.Net.on("peer_left", function( _data ) {
	local net = ::BBCoop.Net;
	::BBCoop.toast((net.PeerName != null ? net.PeerName : "The other player") + " left the session");
	net.State = "connected";
	net.PeerName = null;
	::BBCoop.updateStatus();
});

::BBCoop.Net.on("error", function( _data ) {
	local net = ::BBCoop.Net;
	net.GotRelayError = true;
	net.setError(net.explainRelayError(_data.message + ""));
});

::BBCoop.Net.on("ping", function( _data ) {
	::BBCoop.Net.send("pong", _data);
});

::BBCoop.Net.on("pong", function( _data ) {
	local ms = ((::Time.getRealTimeF() - _data.t) * 1000).tointeger();
	::BBCoop.toast("Ping to " + ::BBCoop.Net.PeerName + ": " + ms + " ms");
});

::BBCoop.Net.on("campaign_info", function( _data ) {
	local mine = ::BBCoop.Net.getCampaignInfo();
	if (_data == null || mine == null) return; // one side is still in the main menu

	if (_data.company != mine.company || _data.day.tointeger() != mine.day || _data.brothers.tointeger() != mine.brothers)
	{
		::BBCoop.Net.setError("You're not in the same campaign. Theirs: " + _data.company + ", day " + _data.day + ", " + _data.brothers + " brothers. Both load the same save.");
	}
	else
	{
		::BBCoop.toast("Campaigns match: " + mine.company + ", day " + mine.day);
	}
});

::BBCoop.Net.on("owners", function( _data ) {
	if (!::BBCoop.isGuest() || !::BBCoop.isInCampaign()) return;
	::BBCoop.Ownership.applyOwnersTable(_data);
});

// The other player's name, badge and colour. Stored in our settings for their slot,
// without running the change callbacks (so it isn't sent back).
::BBCoop.Net.on("profile", function( _data ) {
	local n = _data.player.tointeger();
	if ((n != 1 && n != 2) || n == ::BBCoop.getLocalPlayer()) return;
	local settings = ::BBCoop.Mod.ModSettings;
	settings.getSetting("Player" + n + "Name").set(_data.name, true, true, true, false, false);
	settings.getSetting("Player" + n + "Tag").set(_data.tag, true, true, true, false, false);
	settings.getSetting("Player" + n + "Color").set(_data.color, true, true, true, false, false);
	::BBCoop.refreshStyles();
});
