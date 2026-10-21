// Retraining: pay 1000 crowns to reroll a brother's attributes or talents, swap a trait,
// or reset his perks. Brothers belong to someone, so only the owner (or the admin) can do it.
//
// Sync: the PC that retrains rolls the new values, then sends the *result* to the other
// PC, which copies it exactly. No shared RNG needed.
::BBCoop.Retrain <- {
	Cost = 1000,
	StartFlag = "BBCoop.Start.",
	Attributes = ["Hitpoints", "Bravery", "Stamina", "MeleeSkill", "RangedSkill", "MeleeDefense", "RangedDefense", "Initiative"],
	TraitInfo = null,

	// ---- Rules ----

	function canRetrain( _bro )
	{
		if (::BBCoop.isHotseat() || ::BBCoop.isAdmin()) return true;
		return ::BBCoop.Ownership.canControl(_bro);
	}

	function isInCombat()
	{
		return ("State" in ::Tactical) && ::Tactical.State != null;
	}

	function getBlockReason( _bro )
	{
		if (this.isInCombat()) return "Retraining isn't possible during combat";
		if (!this.canRetrain(_bro)) return "Only " + ::BBCoop.getPlayerName(::BBCoop.Ownership.getOwner(_bro)) + " or the admin can retrain " + _bro.getName();
		if (::World.Assets.getMoney() < this.Cost) return "Retraining costs " + this.Cost + " crowns";
		return null;
	}

	// ---- Starting roll ----
	// Base stats include level-up gains and event bonuses, so rerolling replaces only
	// the starting roll: new base = current base - old roll + new roll.
	// The roll is saved when a brother joins; existing brothers at level 1 can still be
	// recorded, because nothing has been added on top yet.

	function recordStartRoll( _bro )
	{
		if (this.hasStartRoll(_bro) || _bro.getLevel() > 1) return;
		local b = _bro.getBaseProperties();
		foreach (a in this.Attributes)
		{
			_bro.getFlags().set(this.StartFlag + a, b[a]);
		}
	}

	function hasStartRoll( _bro )
	{
		return _bro.getFlags().has(this.StartFlag + "Hitpoints");
	}

	function getRanges( _bro )
	{
		// Same table as character_background.buildAttributes().
		local r = {
			Hitpoints = [50, 60], Bravery = [30, 40], Stamina = [90, 100], MeleeSkill = [47, 57],
			RangedSkill = [32, 42], MeleeDefense = [0, 5], RangedDefense = [0, 5], Initiative = [100, 110]
		};
		local c = _bro.getBackground().onChangeAttributes();
		foreach (a in this.Attributes)
		{
			r[a][0] += c[a][0];
			r[a][1] += c[a][1];
		}
		return r;
	}

	// ---- Traits ----

	function getTraitInfo()
	{
		if (this.TraitInfo == null)
		{
			this.TraitInfo = {};
			foreach (t in ::Const.CharacterTraits)
			{
				local trait = ::new(t[1]);
				this.TraitInfo[t[0]] <- { id = t[0], script = t[1], name = trait.getName(), icon = trait.getIcon(), excluded = trait.m.Excluded };
			}
		}
		return this.TraitInfo;
	}

	// Traits a retrain may remove: the random ones from Const.CharacterTraits, not
	// backgrounds, origin traits or injuries.
	function getRemovableTraits( _bro )
	{
		local info = this.getTraitInfo();
		local result = [];
		foreach (skill in _bro.getSkills().query(::Const.SkillType.Trait))
		{
			if (skill.getID() in info) result.push(info[skill.getID()]);
		}
		return result;
	}

	function isTraitAllowed( _bro, _id, _removing )
	{
		local info = this.getTraitInfo();
		if (!(_id in info)) return false;
		foreach (t in this.getRemovableTraits(_bro))
		{
			if (t.id == _removing) continue;
			if (t.id == _id || info[_id].excluded.find(t.id) != null || t.excluded.find(_id) != null) return false;
		}
		return true;
	}

	// ---- Compute: roll new values, return a result table ----

	function compute( _bro, _op, _args )
	{
		switch (_op)
		{
			case "attributes":
				if (!this.hasStartRoll(_bro)) return { error = _bro.getName() + "'s starting roll wasn't recorded before he levelled up, so his attributes can't be rerolled" };
				local ranges = this.getRanges(_bro);
				local values = {};
				foreach (a in this.Attributes)
				{
					values[a] <- ::Math.rand(ranges[a][0], ranges[a][1]);
				}
				return { op = "attributes", rolls = values };

			case "talents":
				local old = { talents = clone _bro.m.Talents, levels = this.cloneLevels(_bro) };
				_bro.m.Talents = [];
				_bro.fillTalentValues();
				_bro.m.Attributes = [];
				local applied = _bro.getLevel() - 1 - _bro.getLevelUps();
				_bro.fillAttributeLevelUpValues(::Math.max(0, ::Const.XP.MaxLevelWithPerkpoints - 1 - applied));
				local result = { op = "talents", talents = clone _bro.m.Talents, levels = this.cloneLevels(_bro) };
				_bro.m.Talents = old.talents;
				_bro.m.Attributes = old.levels;
				return result;

			case "trait":
				local remove = "remove" in _args ? _args.remove : null;
				local add = "add" in _args ? _args.add : null;
				if (remove == null && add == null) return { error = "Pick a trait to remove or to add" };
				if (remove != null && !_bro.getSkills().hasSkill(remove)) return { error = "He doesn't have that trait" };
				if (add != null && !this.isTraitAllowed(_bro, add, remove)) return { error = "That trait conflicts with one he already has" };
				return { op = "trait", remove = remove, add = add };

			case "perks":
				if (_bro.m.PerkPointsSpent == 0) return { error = _bro.getName() + " hasn't spent any perk points" };
				return { op = "perks" };
		}
		return { error = "Unknown retrain option " + _op };
	}

	function cloneLevels( _bro )
	{
		local result = [];
		foreach (list in _bro.m.Attributes)
		{
			result.push(clone list);
		}
		return result;
	}

	// ---- Apply a result (same code on both PCs) ----

	function apply( _bro, _r )
	{
		switch (_r.op)
		{
			case "attributes":
				local b = _bro.getBaseProperties();
				foreach (a in this.Attributes)
				{
					local roll = _r.rolls[a].tointeger();
					b[a] = b[a] - _bro.getFlags().getAsInt(this.StartFlag + a) + roll;
					_bro.getFlags().set(this.StartFlag + a, roll);
				}
				break;

			case "talents":
				_bro.m.Talents = [];
				foreach (t in _r.talents) _bro.m.Talents.push(t.tointeger());
				_bro.m.Attributes = [];
				foreach (list in _r.levels)
				{
					local copy = [];
					foreach (v in list) copy.push(v.tointeger());
					_bro.m.Attributes.push(copy);
				}
				break;

			case "trait":
				if (_r.remove != null) _bro.getSkills().removeByID(_r.remove);
				if (_r.add != null) _bro.getSkills().add(::new(this.getTraitInfo()[_r.add].script));
				break;

			case "perks":
				// Same as the Potion of Oblivion.
				local perks = _bro.m.PerkPointsSpent;
				local hasStudent = _bro.getLevel() >= 11 && _bro.getSkills().hasSkill("perk.student");
				if (hasStudent) perks--;
				_bro.m.PerkPoints += perks;
				_bro.m.PerkPointsSpent = hasStudent ? 1 : 0;
				_bro.getSkills().removeByType(::Const.SkillType.Perk);
				if (hasStudent) _bro.getSkills().add(::new("scripts/skills/perks/perk_student"));
				break;
		}

		_bro.getSkills().update();
		_bro.setHitpoints(::Math.min(_bro.getHitpoints(), _bro.getHitpointsMax()));
		::World.Assets.addMoney(-this.Cost);
		this.refreshScreen();
	}

	function describe( _r )
	{
		switch (_r.op)
		{
			case "attributes": return "rerolled attributes";
			case "talents": return "rerolled talents";
			case "perks": return "reset perks";
			case "trait":
				local info = this.getTraitInfo();
				local parts = [];
				if (_r.remove != null) parts.push("lost " + info[_r.remove].name);
				if (_r.add != null) parts.push("gained " + info[_r.add].name);
				return parts.len() == 2 ? parts[0] + " and " + parts[1] : parts[0];
		}
		return _r.op;
	}

	// ---- Entry points ----

	// Local player clicked a retrain option. Returns an error string or null.
	function perform( _bro, _op, _args )
	{
		local reason = this.getBlockReason(_bro);
		if (reason != null) return reason;

		local r = this.compute(_bro, _op, _args);
		if ("error" in r) return r.error;

		this.apply(_bro, r);
		::BBCoop.toast(_bro.getName() + " " + this.describe(r) + " (-" + this.Cost + " crowns)");
		::BBCoop.Net.send("retrain", { uid = ::BBCoop.Ownership.getUID(_bro), result = r });
		return null;
	}

	// The other player retrained a brother.
	function onRemote( _data )
	{
		local bro = ::BBCoop.Ownership.findByUID(_data.uid.tointeger());
		if (bro == null)
		{
			::BBCoop.toast("The other player retrained a brother you don't have. Your campaigns are out of sync.");
			return;
		}
		this.apply(bro, _data.result);
		::BBCoop.toast(::BBCoop.Net.PeerName + ": " + bro.getName() + " " + this.describe(_data.result));
	}

	function refreshScreen()
	{
		if (::BBCoop.isInCampaign() && "CharacterScreen" in ::World.State.m && ::World.State.m.CharacterScreen != null)
		{
			::World.State.m.CharacterScreen.loadBrothersList();
		}
	}

	// Everything the co-op menu needs for one brother.
	function getMenuData( _bro )
	{
		this.recordStartRoll(_bro);

		local info = this.getTraitInfo();
		local all = [];
		foreach (id, t in info)
		{
			all.push({ id = id, name = t.name, icon = t.icon });
		}
		all.sort(@(a, b) a.name <=> b.name);

		local traits = [];
		foreach (t in this.getRemovableTraits(_bro))
		{
			traits.push({ id = t.id, name = t.name, icon = t.icon });
		}

		return {
			id = _bro.getID(),
			name = _bro.getName(),
			badge = ::BBCoop.Ownership.getBadgeData(_bro),
			cost = this.Cost,
			money = ::World.Assets.getMoney(),
			blocked = this.getBlockReason(_bro),
			canRerollAttributes = this.hasStartRoll(_bro),
			hasSpentPerks = _bro.m.PerkPointsSpent > 0,
			traits = traits,
			allTraits = all
		};
	}
};

::BBCoop.Net.on("retrain", function( _data ) {
	::BBCoop.Retrain.onRemote(_data);
});
