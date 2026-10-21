// The Co-op panel: one place to pick how you play, set your name/badge/colour, and
// connect. Settings are stored in the MSU settings (saved as soon as they change),
// but players never need the MSU screen.

::BBCoop.Panel <- {
	// Badge colours offered in the panel, as MSU "r,g,b,a" values.
	Colors = [
		"47,95,168,1",   // blue
		"168,57,47,1",   // red
		"52,128,64,1",   // green
		"196,140,32,1",  // gold
		"120,60,150,1",  // purple
		"36,140,150,1",  // teal
		"200,100,40,1",  // orange
		"90,90,90,1"     // grey
	],

	// alone | host | join | hotseat | loopback
	function getHow()
	{
		if (!::BBCoop.isEnabled()) return "alone";
		if (::BBCoop.isHost()) return "host";
		if (::BBCoop.isGuest()) return "join";
		if (::BBCoop.isLoopback()) return "loopback";
		return "hotseat";
	}

	function isInBattle()
	{
		return ::BBCoop.Sync.Active || ::BBCoop.Combat.getActiveEntity() != null;
	}

	function setSetting( _id, _value )
	{
		::BBCoop.Mod.ModSettings.getSetting(_id).set(_value);
	}

	function setHow( _how )
	{
		if (_how == this.getHow()) return null;
		if (this.isInBattle()) return "Finish the battle first, then change how you play.";

		local C = ::BBCoop.Const.Mode;
		local modes = { host = C.Host, join = C.Guest, hotseat = C.Hotseat, loopback = C.Loopback };
		if (_how != "alone" && !(_how in modes)) return "Unknown choice: " + _how;

		::BBCoop.Net.disconnect();
		::BBCoop.Net.LastError = null;
		if (_how in modes) this.setSetting("Mode", modes[_how]);
		this.setSetting("Enabled", _how != "alone"); // runs onEnabledChanged when it changes
		::BBCoop.updateStatus();
		::BBCoop.refreshStyles();
		return null;
	}

	// Host or Join with an address set, and not connected yet: connect.
	function autoConnect()
	{
		local net = ::BBCoop.Net;
		if (!::BBCoop.isEnabled() || !(::BBCoop.isHost() || ::BBCoop.isGuest())) return;
		if (net.State != "offline" || strip(::BBCoop.getSetting("RelayAddress")) == "") return;
		net.connect();
	}

	// ---- Join codes ------------------------------------------------------------
	// A join code is the relay address plus the key: "bb.example.com/secret".
	// wss:// is the default and is left out; ws:// stays in the code.

	function makeJoinCode( _address, _key )
	{
		local address = strip(_address);
		if (address.find("wss://") == 0) address = address.slice(6);
		while (address.len() > 0 && address.slice(-1) == "/") address = address.slice(0, -1);
		local key = strip(_key);
		return key == "" ? address : address + "/" + key;
	}

	// Returns { address, key } or null.
	function parseJoinCode( _code )
	{
		local code = strip(_code);
		if (code == "") return null;
		local scheme = "wss://";
		foreach (s in ["wss://", "ws://"])
		{
			if (code.find(s) == 0)
			{
				scheme = s;
				code = code.slice(s.len());
				break;
			}
		}
		local slash = code.find("/");
		local host = slash == null ? code : code.slice(0, slash);
		local key = slash == null ? "" : code.slice(slash + 1);
		if (host == "" || host.find(" ") != null) return null;
		return { address = scheme + host, key = key };
	}

	function isLocalAddress( _address )
	{
		return _address.find("127.0.0.1") != null || _address.find("localhost") != null;
	}

	// ---- Data for the UI -------------------------------------------------------

	function getProfile( _player )
	{
		local style = ::BBCoop.getPlayerStyle(_player);
		return {
			player = _player,
			name = ::BBCoop.getPlayerName(_player),
			tag = ::BBCoop.getSetting("Player" + _player + "Tag"),
			color = style.color,
			colorValue = ::BBCoop.getSetting("Player" + _player + "Color"),
			preview = style.tag
		};
	}

	function getData()
	{
		local how = this.getHow();
		local address = ::BBCoop.getSetting("RelayAddress");
		local key = ::BBCoop.getSetting("SessionKey");
		local local_ = ::BBCoop.getLocalPlayer();

		local colors = [];
		foreach (c in this.Colors)
		{
			local p = split(c, ",");
			colors.push({ value = c, css = "rgb(" + p[0] + "," + p[1] + "," + p[2] + ")" });
		}

		local profiles = [];
		if (how == "host" || how == "join") profiles.push(this.getProfile(local_));
		else if (how != "alone") profiles = [ this.getProfile(1), this.getProfile(2) ];

		local joinCodeNote = null;
		if (how == "host" && this.isLocalAddress(address))
			joinCodeNote = "This address only works on your own PC. For your friend, the relay must run somewhere they can reach (for example your server), and its address goes here.";

		local rules = [];
		foreach (r in [::BBCoop.Const.HireRule.Alternate, ::BBCoop.Const.HireRule.Fewest, ::BBCoop.Const.HireRule.Host]) rules.push(r);

		return {
			how = how,
			inBattle = this.isInBattle(),
			status = ::BBCoop.Net.getStatus(),
			error = ::BBCoop.Net.LastError,
			profiles = profiles,
			colors = colors,
			address = address,
			key = key,
			joinCode = this.makeJoinCode(address, key),
			joinCodeNote = joinCodeNote,
			isAdmin = ::BBCoop.isAdmin(),
			hireRule = ::BBCoop.getSetting("HireRule"),
			hireRules = rules,
			turnAlert = ::BBCoop.getSetting("TurnAlert"),
			version = ::BBCoop.Version
		};
	}

	// ---- Actions from the UI -----------------------------------------------------
	// Each returns an error message or null.

	function act( _args )
	{
		local net = ::BBCoop.Net;
		switch (_args.action)
		{
			case "setHow":
				return this.setHow(_args.value);

			case "setProfile":
				local player = _args.player.tointeger();
				if (player != 1 && player != 2) return "Unknown player";
				local field = _args.field;
				local value = strip(_args.value + "");
				if (field == "Name")
				{
					if (value == "") return "The name can't be empty.";
					if (value.len() > 24) value = value.slice(0, 24);
				}
				else if (field == "Tag")
				{
					if (value.len() > 4) value = value.slice(0, 4);
				}
				else if (field != "Color") return "Unknown field";
				this.setSetting("Player" + player + field, value);
				return null;

			case "setHireRule":
				if (!::BBCoop.isAdmin()) return "Only " + ::BBCoop.getPlayerName(1) + " can change this.";
				this.setSetting("HireRule", _args.value);
				return null;

			case "setAddress":
				local address = strip(_args.value + "");
				if (address != "" && address.find("ws://") != 0 && address.find("wss://") != 0) address = "wss://" + address;
				this.setSetting("RelayAddress", address);
				return null;

			case "setKey":
				this.setSetting("SessionKey", strip(_args.value + ""));
				return null;

			case "setTurnAlert":
				this.setSetting("TurnAlert", _args.value == true);
				return null;

			case "join":
				local parsed = this.parseJoinCode(_args.value + "");
				if (parsed == null) return "That doesn't look like a join code. It should look like bb.example.com/secret.";
				if (this.getHow() != "join")
				{
					local error = this.setHow("join");
					if (error != null) return error;
				}
				net.disconnect();
				this.setSetting("RelayAddress", parsed.address);
				this.setSetting("SessionKey", parsed.key);
				net.connect();
				return null;

			// Main menu: Solo Campaign / Host Campaign / Join Campaign.
			case "enterLobby":
				local error = this.setHow(_args.value);
				if (error != null) return error;
				this.autoConnect();
				return null;

			// Back out of the Host/Join screen.
			case "leaveLobby":
				net.LastError = null;
				net.disconnect();
				::BBCoop.updateStatus();
				return null;

			// New/Load/Scenarios pressed. Host or Join but not linked: play solo.
			case "beforeCampaign":
				if ((::BBCoop.isHost() || ::BBCoop.isGuest()) && ::BBCoop.isEnabled() && !net.isPaired())
				{
					net.disconnect();
					net.LastError = null;
					this.setSetting("Enabled", false);
					::BBCoop.toast("Not linked with another player, so this campaign is solo.");
				}
				return null;

			case "autoConnect":
				this.autoConnect();
				return null;

			case "connect":
				net.connect();
				return null;

			case "disconnect":
				net.LastError = null;
				net.disconnect();
				return null;

			case "ping":
				net.ping();
				return null;
		}
		return "Unknown action: " + _args.action;
	}
};
