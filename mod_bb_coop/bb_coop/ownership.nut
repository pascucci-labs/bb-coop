// Which player owns each brother.
// Owner is stored as a flag on the brother: 1 = Player 1 (host/admin), 2 = Player 2 (guest).
// Each brother also gets a campaign-unique UID. Entity IDs differ between game sessions,
// but the UID is saved, so both PCs can refer to the same brother.
::BBCoop.Ownership <- {
	LastRosterSize = -1,

	function isBrother( _entity )
	{
		return _entity != null && ::isKindOf(_entity, "player");
	}

	function getOwner( _bro )
	{
		local flags = _bro.getFlags();
		return flags.has(::BBCoop.Const.FlagOwner) ? flags.getAsInt(::BBCoop.Const.FlagOwner) : 0;
	}

	function hasOwner( _bro )
	{
		return this.getOwner(_bro) != 0;
	}

	function setOwner( _bro, _player )
	{
		this.ensureUID(_bro);
		_bro.getFlags().set(::BBCoop.Const.FlagOwner, _player);
	}

	function ensureUID( _bro )
	{
		local flags = _bro.getFlags();
		if (flags.has(::BBCoop.Const.FlagUID)) return;

		// A counter, not Math.rand: drawing random numbers here would shift the RNG
		// and make two linked games disagree.
		local stats = ::World.Statistics.getFlags();
		local uid = stats.has(::BBCoop.Const.StatNextUID) ? stats.getAsInt(::BBCoop.Const.StatNextUID) : 1;
		stats.set(::BBCoop.Const.StatNextUID, uid + 1);
		flags.set(::BBCoop.Const.FlagUID, uid);
	}

	function getUID( _bro )
	{
		local flags = _bro.getFlags();
		return flags.has(::BBCoop.Const.FlagUID) ? flags.getAsInt(::BBCoop.Const.FlagUID) : 0;
	}

	function findByUID( _uid )
	{
		foreach (bro in ::World.getPlayerRoster().getAll())
		{
			if (this.getUID(bro) == _uid) return bro;
		}
		return null;
	}

	function findByEntityID( _id )
	{
		foreach (bro in ::World.getPlayerRoster().getAll())
		{
			if (bro.getID() == _id) return bro;
		}
		return null;
	}

	function countOwned( _player )
	{
		local n = 0;
		foreach (bro in ::World.getPlayerRoster().getAll())
		{
			if (this.getOwner(bro) == _player) n++;
		}
		return n;
	}

	function pickOwnerForNewBrother()
	{
		local C = ::BBCoop.Const;
		switch (::BBCoop.getSetting("HireRule"))
		{
			case C.HireRule.Host:
				return 1;

			case C.HireRule.Fewest:
				return this.countOwned(1) <= this.countOwned(2) ? 1 : 2;

			default:
				local stats = ::World.Statistics.getFlags();
				local next = stats.has(C.StatNextOwner) ? stats.getAsInt(C.StatNextOwner) : 1;
				stats.set(C.StatNextOwner, next == 1 ? 2 : 1);
				return next;
		}
	}

	// Called when a brother joins. Only the admin decides; the guest receives owners from the host.
	function assignNewBrother( _bro )
	{
		if (!::BBCoop.isEnabled() || !::BBCoop.isAdmin() || this.hasOwner(_bro)) return;

		local player = this.pickOwnerForNewBrother();
		this.setOwner(_bro, player);
		::BBCoop.toast(_bro.getName() + " joins " + ::BBCoop.getPlayerName(player) + "'s side");
		::BBCoop.Net.sendOwners();
	}

	// Covers brothers who joined without onHired(), such as a new campaign's starting company.
	function assignUnowned()
	{
		if (!::BBCoop.isAdmin()) return;

		local roster = ::World.getPlayerRoster().getAll();
		local changed = false;

		// Starting companies are split in roster order, so the result is the same on every PC.
		foreach (bro in roster)
		{
			if (!this.hasOwner(bro))
			{
				this.setOwner(bro, this.pickOwnerForNewBrother());
				changed = true;
			}
		}

		if (changed) ::BBCoop.Net.sendOwners();
	}

	// Cheap check, run from world_state.onUpdate: only sweeps when the roster size changes.
	function onWorldUpdate()
	{
		if (!::BBCoop.isEnabled()) return;
		local size = ::World.getPlayerRoster().getSize();
		if (size == this.LastRosterSize) return;
		this.LastRosterSize = size;
		this.assignUnowned();
	}

	// Can the player at this PC act with this brother right now?
	function canControl( _bro )
	{
		if (!this.isBrother(_bro) || !::BBCoop.isEnabled() || ::BBCoop.isHotseat() || ::BBCoop.isLoopback()) return true;

		local owner = this.getOwner(_bro);
		if (owner == 0) owner = 1; // unassigned brothers belong to the host
		return owner == ::BBCoop.getLocalPlayer();
	}

	// Admin clicked an owner badge.
	function toggleOwner( _bro )
	{
		if (!::BBCoop.isAdmin())
		{
			::BBCoop.toast("Only " + ::BBCoop.getPlayerName(1) + " can reassign brothers");
			return;
		}

		local player = this.getOwner(_bro) == 2 ? 1 : 2;
		this.setOwner(_bro, player);
		::BBCoop.toast(_bro.getName() + " now follows " + ::BBCoop.getPlayerName(player));
		::BBCoop.Net.sendOwners();
		::BBCoop.Combat.refresh();
	}

	// UID -> owner, sent from host to guest.
	function getOwnersTable()
	{
		local result = {};
		foreach (bro in ::World.getPlayerRoster().getAll())
		{
			this.ensureUID(bro);
			result[this.getUID(bro).tostring()] <- this.getOwner(bro);
		}
		return result;
	}

	function applyOwnersTable( _table )
	{
		local missing = 0;
		foreach (uid, owner in _table)
		{
			local bro = this.findByUID(uid.tointeger());
			if (bro == null)
			{
				missing++;
				continue;
			}
			bro.getFlags().set(::BBCoop.Const.FlagOwner, owner.tointeger());
		}

		if (missing > 0)
		{
			::BBCoop.toast(missing + " of the host's brothers aren't in your company. Load the same save as the host.");
		}
		::BBCoop.Combat.refresh();
	}

	function getBadgeData( _bro )
	{
		local owner = this.getOwner(_bro);
		local style = ::BBCoop.getPlayerStyle(owner);
		return {
			owner = owner,
			name = style.name,
			tag = style.tag,
			color = style.color,
			mine = this.canControl(_bro), // false: greyed out on this PC
			canEdit = ::BBCoop.isAdmin()
		};
	}
};
