// Combat: whose turn it is, and the "waiting for..." banner.
::BBCoop.Combat <- {
	LastActiveID = -1,

	function getActiveEntity()
	{
		if (!("TurnSequenceBar" in ::Tactical) || ::Tactical.TurnSequenceBar == null) return null;
		return ::Tactical.TurnSequenceBar.getActiveEntity();
	}

	// True when it's a brother's turn that the player at this PC doesn't own.
	function isRemoteTurn()
	{
		local active = this.getActiveEntity();
		if (active == null || !active.isPlayerControlled()) return false;
		return !::BBCoop.Ownership.canControl(active);
	}

	function refresh()
	{
		this.LastActiveID = -1;
	}

	// Called every frame from tactical_state.onUpdate. Only does work when the active entity changes.
	function onUpdate()
	{
		if (!::BBCoop.isEnabled())
		{
			if (this.LastActiveID != -2) ::BBCoop.Connection.call("hideBanner", null);
			this.LastActiveID = -2;
			return;
		}

		local active = this.getActiveEntity();
		local id = active == null ? null : active.getID();
		if (id == this.LastActiveID) return;
		this.LastActiveID = id;

		if (active == null || !active.isPlayerControlled() || !::BBCoop.Ownership.isBrother(active))
		{
			::BBCoop.Connection.call("hideBanner", null);
			return;
		}

		local owner = ::BBCoop.Ownership.getOwner(active);
		if (owner == 0) owner = 1;
		local ownerName = ::BBCoop.getPlayerName(owner);

		local text;
		local kind;
		if (::BBCoop.isHotseat())
		{
			text = ownerName + "'s turn: " + active.getName();
			kind = owner == 1 ? "p1" : "p2";
		}
		else if (this.isRemoteTurn())
		{
			text = "Waiting for " + ownerName + ": " + active.getName();
			kind = "waiting";
		}
		else
		{
			text = "Your turn: " + active.getName();
			kind = owner == 1 ? "p1" : "p2";
		}

		// Online: a sound and a flash so a player who looked away notices their turn.
		// Hot-seat skips it (you're both at the screen).
		local alert = kind != "waiting" && !::BBCoop.isHotseat() && ::BBCoop.getSetting("TurnAlert");
		if (alert) ::Sound.play("sounds/new_round_01.wav", ::Const.Sound.Volume.Tactical);
		::BBCoop.Connection.call("showBanner", { text = text, kind = kind, alert = alert, color = kind == "waiting" ? null : ::BBCoop.getPlayerColor(owner) });
	}

	function onCombatEnd()
	{
		this.LastActiveID = -1;
		::BBCoop.Connection.call("hideBanner", null);
	}
};
