// Combat sync: the host runs the real battle, the guest runs a mirror of it.
//
// - The host is the single source of truth. Every action that happens on the host
//   (its own commands, the guest's requests, AI moves and attacks, turn ends) becomes a
//   record in one ordered stream that is sent to the guest.
// - The guest never acts on its own: its clicks become requests to the host, its AI is
//   switched off, and it only advances turns when the stream says so.
// - Random rolls: before every action, movement step and turn start, both PCs reseed
//   the RNG from (battle seed, counter). Same state + same seed = same rolls.
// - After each action the host sends a digest (hash of positions, HP, armor, AP,
//   fatigue, morale). The guest compares and reports drift.
//
// Loopback mode (one PC): requests go out to the UI and back as JSON before running,
// and the stream is built and logged, so this path can be tested without a second PC.
::BBCoop.Sync <- {
	Active = false,
	BattleSeed = 0,
	ActionIndex = 0,    // counts actions; both PCs must agree
	NextCID = 1,
	Actors = {},        // combat ID -> actor
	Queue = [],         // records waiting to run (host: commands; guest: the stream)
	Current = null,     // record being run
	Move = null,        // { index, steps } while a synced movement is in progress
	AICapture = null,   // host: AI move being recorded
	InExecutor = false, // true while the executor itself drives the game
	Digests = {},       // guest: own digest per action index, until the host's arrives
	Stats = null,
	BattleNumber = 0,

	// ---- Setup ----

	function isEnabled()
	{
		if (!::BBCoop.isEnabled()) return false;
		if (::BBCoop.isLoopback()) return true;
		return !::BBCoop.isHotseat() && ::BBCoop.Net.isPaired();
	}

	function isHostSide()
	{
		return ::BBCoop.isLoopback() || ::BBCoop.isHost();
	}

	function isGuestSide()
	{
		return this.Active && ::BBCoop.isGuest();
	}

	function onBattleStart()
	{
		this.Active = this.isEnabled();
		this.ActionIndex = 0;
		this.Queue = [];
		this.Current = null;
		this.Move = null;
		this.AICapture = null;
		this.InExecutor = false;
		this.Digests = {};
		this.PendingDigest = null;
		this.Stats = { records = 0, requests = 0, digests = 0, mismatches = 0 };
		if (!this.Active) return;

		if (this.isHostSide())
		{
			this.BattleSeed = ::World.State.getCombatSeed();
			if (this.BattleSeed == 0) this.BattleSeed = 1;
			this.send("battle_seed", { seed = this.BattleSeed });
		}
		::BBCoop.log("Synced battle started (seed " + this.BattleSeed + ", " + (this.isHostSide() ? "host" : "guest") + ")");
		this.reseed(0x5EED);
	}

	function onBattleEnd()
	{
		if (this.Active && this.Stats != null)
		{
			::BBCoop.log("Synced battle ended: " + this.Stats.records + " records, " + this.Stats.requests + " requests, " + this.Stats.digests + " digests checked, " + this.Stats.mismatches + " mismatches");
		}
		this.Active = false;
		this.Actors = {};
		this.NextCID = 1;
		this.BattleNumber++;
	}

	// ---- Combat IDs ----
	// Entity IDs differ between PCs, so actors get a combat ID in placement order.

	// Brothers keep their objects between battles, so IDs are tagged with the battle number.
	function registerActor( _actor )
	{
		if ("BBCoopBattle" in _actor.m && _actor.m.BBCoopBattle == this.BattleNumber) return;
		_actor.m.BBCoopBattle <- this.BattleNumber;
		_actor.m.BBCoopCID <- this.NextCID++;
		this.Actors[_actor.m.BBCoopCID] <- _actor;
	}

	function getCID( _actor )
	{
		this.registerActor(_actor);
		return _actor.m.BBCoopCID;
	}

	function getActor( _cid )
	{
		_cid = _cid.tointeger();
		if (!(_cid in this.Actors)) return null;
		local a = this.Actors[_cid];
		return a.isAlive() && a.isPlacedOnMap() ? a : null;
	}

	function tileOf( _tile )
	{
		return { x = _tile.SquareCoords.X, y = _tile.SquareCoords.Y };
	}

	function getTile( _rec )
	{
		return ::Tactical.getTileSquare(_rec.x.tointeger(), _rec.y.tointeger());
	}

	// ---- RNG ----

	function seedFor( _a, _b = 0 )
	{
		local h = this.BattleSeed & 0x7FFFFFFF;
		h = (h * 1103515245 + _a * 2654435 + 12345) & 0x7FFFFFFF;
		h = (h * 1103515245 + _b * 40503 + 6789) & 0x7FFFFFFF;
		return h == 0 ? 1 : h;
	}

	function reseed( _a, _b = 0 )
	{
		::Math.seedRandom(this.seedFor(_a, _b));
	}

	// ---- Who acts ----

	function isAIDriven( _actor )
	{
		if (!_actor.isPlayerControlled()) return true;
		if (::Tactical.State != null && ::Tactical.State.isAutoRetreat()) return true;
		return _actor.getMoraleState() == ::Const.MoraleState.Fleeing;
	}

	function isBusy()
	{
		return this.Current != null || this.Queue.len() != 0 || this.Move != null;
	}

	// Should local input be ignored right now?
	function isInputBlocked()
	{
		if (!this.Active) return false;
		if (this.isBusy()) return true;
		return false;
	}

	// ---- Networking ----

	function send( _type, _data )
	{
		if (::BBCoop.isLoopback()) return;
		::BBCoop.Net.send(_type, _data);
	}

	// Host -> guest stream.
	function emit( _rec )
	{
		this.Stats.records++;
		::BBCoop.log("rec #" + _rec.index + " " + _rec.kind + (("cid" in _rec) ? " cid " + _rec.cid : ""));
		this.send("stream", _rec);
	}

	// ---- Local input ----

	// Local player issued a command. Host/loopback queue it; the guest asks the host.
	function request( _rec )
	{
		if (::BBCoop.isLoopback())
		{
			// Round trip through the UI as JSON, like a real network message.
			::BBCoop.Connection.call("loopback", { type = "request", data = _rec });
		}
		else if (::BBCoop.isGuest())
		{
			::BBCoop.Net.send("request", _rec);
		}
		else
		{
			this.onRequest(_rec, true);
		}
	}

	// Host: a command arrived (from the local player, or from the guest).
	function onRequest( _rec, _isLocal )
	{
		if (!this.Active || !this.isHostSide()) return;
		this.Stats.requests++;

		local actor = this.getActor(_rec.cid);
		local active = ::Tactical.TurnSequenceBar.getActiveEntity();
		if (actor == null || active == null || actor.getID() != active.getID())
		{
			::BBCoop.log("Dropped request " + _rec.kind + ": not that brother's turn");
			return;
		}
		if (!_isLocal && !::BBCoop.isLoopback() && ::BBCoop.Ownership.getOwner(actor) != 2)
		{
			::BBCoop.log("Dropped guest request for a brother the guest doesn't own");
			return;
		}
		this.Queue.push(_rec);
	}

	// Guest: a record from the host's stream.
	function onStream( _rec )
	{
		if (!this.isGuestSide()) return;
		this.Queue.push(_rec);
	}

	// ---- Executor (runs every frame from tactical_state.onUpdate) ----

	function update()
	{
		if (!this.Active || ::Tactical.State == null || ::Tactical.State.isBattleEnded()) return;

		if (this.Current == null)
		{
			if (this.PendingDigest != null) return; // let the previous action settle first
			if (this.Queue.len() == 0 || !this.canStart()) return;
			this.Current = this.Queue.remove(0);
			this.start(this.Current);
		}
		else if (this.step(this.Current))
		{
			this.finish(this.Current);
			this.Current = null;
		}
	}

	function canStart()
	{
		if (::Time.hasEventScheduled(::TimeUnit.Virtual) || ::Tactical.State.isPaused()) return false;
		local active = ::Tactical.TurnSequenceBar.getActiveEntity();
		if (active != null && (::Tactical.getNavigator().isTravelling(active) || active.isPlayingRenderAnimation())) return false;
		return this.Move == null;
	}

	function start( _rec )
	{
		// Host numbers commands as they run; the guest checks the host's numbering.
		if (this.isHostSide())
		{
			_rec.index <- this.ActionIndex;
		}
		else if ("index" in _rec && _rec.index.tointeger() != this.ActionIndex && _rec.kind != "endturn")
		{
			::logWarning("[BBCoop] stream index " + _rec.index + " but expected " + this.ActionIndex);
		}

		_rec.done <- false;
		_rec.turnPosition <- ::Tactical.TurnSequenceBar.m.TurnPosition;
		local actor = "cid" in _rec ? this.getActor(_rec.cid) : null;

		if (_rec.kind == "move" || _rec.kind == "skill" || _rec.kind == "path" || _rec.kind == "wait")
		{
			if (actor == null)
			{
				::logWarning("[BBCoop] record " + _rec.kind + " for missing actor " + _rec.cid);
				_rec.done = true;
				return;
			}
			this.reseed(this.ActionIndex);
			this.ActionIndex++;
		}

		switch (_rec.kind)
		{
			case "move":
				if (this.isHostSide()) this.emit(_rec);
				if (!this.findPlayerPath(actor, this.getTile(_rec))) _rec.done = true;
				else this.Move = { index = _rec.index.tointeger(), steps = 0 };
				break;

			case "path":
				// AI movement replay on the guest: walk the recorded tiles one at a time.
				_rec.step <- 0;
				this.Move = { index = _rec.index.tointeger(), steps = 0 };
				if (!this.startPathStep(actor, _rec)) _rec.done = true;
				break;

			case "skill":
				if (this.isHostSide()) this.emit(_rec);
				local skill = actor.getSkills().getSkillByID(_rec.id);
				local tile = this.getTile(_rec);
				if (skill == null || !skill.isUsable() || !skill.isAffordable() || !skill.isUsableOn(tile))
				{
					::logWarning("[BBCoop] skill " + _rec.id + " can't be used here");
				}
				else
				{
					this.InExecutor = true;
					skill.use(tile);
					this.InExecutor = false;
					if (actor.isAlive()) ::Tactical.TurnSequenceBar.updateEntity(actor.getID());
				}
				_rec.done = true;
				break;

			case "wait":
			case "endturn":
			case "skipround":
				if (this.isHostSide() && _rec.kind != "endturn") this.emit(_rec);
				if (_rec.kind == "skipround")
				{
					foreach (cid in _rec.cids)
					{
						local a = this.getActor(cid);
						if (a != null) a.setSkipTurn(true);
					}
				}
				break; // advanced in step(), which retries until the turn moves on

			default:
				::logWarning("[BBCoop] unknown record " + _rec.kind);
				_rec.done = true;
		}
	}

	// Returns true when the record is finished.
	function step( _rec )
	{
		if (_rec.done && this.Move == null) return true;
		local actor = "cid" in _rec ? this.getActor(_rec.cid) : null;

		switch (_rec.kind)
		{
			case "move":
			case "path":
				if (actor == null || !actor.isAlive())
				{
					this.Move = null;
					return true;
				}
				if (::Tactical.getNavigator().travel(actor, actor.getActionPoints(), actor.getFatigueMax() - actor.getFatigue()))
				{
					return false; // still walking
				}
				::Tactical.TurnSequenceBar.updateEntity(actor.getID());
				if (_rec.kind == "path" && _rec.step < _rec.tiles.len() && this.startPathStep(actor, _rec))
				{
					return false;
				}
				this.Move = null;
				return true;

			case "wait":
			case "endturn":
			case "skipround":
				if (::Tactical.TurnSequenceBar.m.TurnPosition != _rec.turnPosition) return true;
				this.InExecutor = true;
				if (_rec.kind == "wait" && actor != null)
				{
					local waited = ::Tactical.TurnSequenceBar.entityWaitTurn(actor);
					if (waited == false) ::Tactical.TurnSequenceBar.initNextTurn();
				}
				else
				{
					::Tactical.TurnSequenceBar.initNextTurn();
				}
				this.InExecutor = false;
				return ::Tactical.TurnSequenceBar.m.TurnPosition != _rec.turnPosition;
		}
		return true;
	}

	function finish( _rec )
	{
		if (_rec.kind == "endturn" || _rec.kind == "skipround") return; // not actions; no digest
		this.PendingDigest = _rec.index.tointeger();
	}

	// Both PCs: once an action's delayed effects have played out, hash the battle.
	// Runs before the game's own update each frame, so nothing else acts first.
	function updateDigest()
	{
		if (!this.Active || this.PendingDigest == null) return;
		if (::Time.hasEventScheduled(::TimeUnit.Virtual) || this.Move != null) return;
		local index = this.PendingDigest;
		this.PendingDigest = null;
		local digest = this.computeDigest();
		if (this.isHostSide()) this.send("digest", { index = index, hash = digest.hash });
		else this.checkDigest(index, digest, null);
	}

	// Same path settings the game uses for player clicks (tactical_state.computeEntityPath).
	function findPlayerPath( _actor, _tile )
	{
		local nav = ::Tactical.getNavigator();
		local settings = nav.createSettings();
		settings.ActionPointCosts = _actor.getActionPointCosts();
		settings.FatigueCosts = _actor.getFatigueCosts();
		settings.FatigueCostFactor = ::Const.Movement.FatigueCostFactor;
		settings.ActionPointCostPerLevel = _actor.getLevelActionPointCost();
		settings.FatigueCostPerLevel = _actor.getLevelFatigueCost();
		settings.ZoneOfControlCost = 4;
		settings.AlliedFactions = _actor.getAlliedFactions();
		settings.Faction = _actor.getFaction();
		settings.AllowZoneOfControlPassing = true;
		settings.IsPlayer = _actor.isPlayerControlled();
		if (!nav.findPath(_actor.getTile(), _tile, settings, 0)) return false;
		settings.ZoneOfControlCost = 0;
		return nav.getCostForPath(_actor, settings, _actor.getActionPoints(), _actor.getFatigueMax() - _actor.getFatigue()).Tiles != 0;
	}

	function startPathStep( _actor, _rec )
	{
		while (_rec.step < _rec.tiles.len())
		{
			local tile = this.getTile(_rec.tiles[_rec.step]);
			_rec.step++;
			if (tile.ID == _actor.getTile().ID) continue;
			local nav = ::Tactical.getNavigator();
			local settings = nav.createSettings();
			settings.ActionPointCosts = _actor.getActionPointCosts();
			settings.FatigueCosts = _actor.getFatigueCosts();
			settings.FatigueCostFactor = ::Const.Movement.FatigueCostFactor;
			settings.ActionPointCostPerLevel = _actor.getLevelActionPointCost();
			settings.FatigueCostPerLevel = _actor.getLevelFatigueCost();
			settings.ZoneOfControlCost = 0;
			settings.AlliedFactions = _actor.getAlliedFactions();
			settings.Faction = _actor.getFaction();
			settings.AllowZoneOfControlPassing = true;
			if (nav.findPath(_actor.getTile(), tile, settings, 0)) return true;
			::logWarning("[BBCoop] path replay: no route to step " + _rec.step);
			return false;
		}
		return false;
	}

	// ---- Movement reseeding (called from actor hooks, on both PCs) ----

	function onMovementStart( _actor )
	{
		if (!this.Active) return;
		if (this.Move == null && this.isHostSide() && this.isAIDriven(_actor) && this.isActive(_actor))
		{
			// Host: an AI actor starts walking. Record it as one action.
			this.Move = { index = this.ActionIndex, steps = 0 };
			this.AICapture = { kind = "path", index = this.ActionIndex, cid = this.getCID(_actor), tiles = [] };
			this.ActionIndex++;
		}
		if (this.Move != null) this.reseed(this.Move.index, this.Move.steps);
	}

	function onMovementStep( _actor, _tile )
	{
		if (!this.Active || this.Move == null) return;
		this.Move.steps++;
		this.reseed(this.Move.index, this.Move.steps);
		if (this.AICapture != null) this.AICapture.tiles.push(this.tileOf(_tile));
	}

	function onMovementFinish( _actor )
	{
		if (!this.Active || this.AICapture == null) return;
		local rec = this.AICapture;
		this.AICapture = null;
		this.Move = null;
		this.emit(rec);
		this.PendingDigest = rec.index;
	}

	function isActive( _actor )
	{
		local active = ::Tactical.TurnSequenceBar.getActiveEntity();
		return active != null && active.getID() == _actor.getID();
	}

	// ---- AI skill capture (host) ----
	// Returns the record to emit, or null. Called right before skill.use runs.

	function beforeSkillUse( _skill, _tile, _forFree )
	{
		if (!this.Active || !this.isHostSide() || this.InExecutor || _forFree || _tile == null) return null;
		local user = _skill.getContainer().getActor();
		if (user == null || !this.isAIDriven(user) || !this.isActive(user)) return null;

		local rec = { kind = "skill", index = this.ActionIndex, cid = this.getCID(user), id = _skill.getID() };
		local t = this.tileOf(_tile);
		rec.x <- t.x;
		rec.y <- t.y;
		this.reseed(this.ActionIndex);
		this.ActionIndex++;
		return rec;
	}

	function afterSkillUse( _rec )
	{
		this.emit(_rec);
		this.PendingDigest = _rec.index;
	}

	PendingDigest = null,

	// ---- Turn order ----

	// Host: a turn ended (any cause). Called after initNextTurn actually advanced.
	function onTurnAdvanced()
	{
		if (!this.Active || !this.isHostSide()) return;
		if (this.Current != null && (this.Current.kind == "wait" || this.Current.kind == "skipround")) return;
		this.emit({ kind = "endturn", index = this.ActionIndex });
	}

	// Guest: may the game advance the turn by itself? Only the stream decides.
	function mayAdvanceTurn()
	{
		if (!this.isGuestSide() || this.InExecutor) return true;
		return ::Tactical.TurnSequenceBar.getActiveEntity() == null;
	}

	function onTurnStart( _actor )
	{
		if (!this.Active) return;
		this.reseed(0x7000 + ::Tactical.TurnSequenceBar.m.TurnPosition, ::Tactical.TurnSequenceBar.getCurrentRound());
	}

	// ---- Digests ----

	function computeDigest()
	{
		local h = 17;
		local parts = [];
		local cids = [];
		foreach (cid, a in this.Actors) cids.push(cid);
		cids.sort();

		foreach (cid in cids)
		{
			local a = this.Actors[cid];
			local alive = a.isAlive() && a.isPlacedOnMap();
			local v = [cid, alive ? 1 : 0];
			if (alive)
			{
				local t = a.getTile();
				v.extend([t.SquareCoords.X, t.SquareCoords.Y, a.getHitpoints(), a.getArmor(::Const.BodyPart.Head), a.getArmor(::Const.BodyPart.Body), a.getActionPoints(), a.getFatigue(), a.getMoraleState()]);
			}
			foreach (x in v)
			{
				h = (h * 31 + x.tointeger()) & 0x7FFFFFFF;
			}
			parts.push(v);
		}
		return { hash = h, parts = parts };
	}

	// Guest: compare own digest with the host's for the same action.
	function checkDigest( _index, _mine, _hostHash )
	{
		if (_mine != null) this.Digests[_index] <- _mine;
		if (_hostHash != null) this.Digests["host" + _index] <- _hostHash;
		if (!(_index in this.Digests) || !(("host" + _index) in this.Digests)) return;

		local mine = this.Digests[_index];
		local theirs = this.Digests["host" + _index];
		delete this.Digests[_index];
		delete this.Digests["host" + _index];
		this.Stats.digests++;

		if (mine.hash != theirs.tointeger())
		{
			this.Stats.mismatches++;
			::logWarning("[BBCoop] DESYNC after action " + _index + ". Guest state: " + this.describeParts(mine.parts));
			::BBCoop.toast("Battle out of sync after action " + _index + " (details in log.html)");
			::BBCoop.Net.send("desync", { index = _index });
		}
	}

	function describeParts( _parts )
	{
		local s = "";
		foreach (v in _parts)
		{
			s += "[";
			foreach (i, x in v) s += (i > 0 ? "," : "") + x;
			s += "] ";
		}
		return s;
	}
};

// ---- Message handlers ----

::BBCoop.Net.on("battle_seed", function( _data ) {
	::BBCoop.Sync.BattleSeed = _data.seed.tointeger();
	::BBCoop.log("Battle seed from host: " + _data.seed);
});

::BBCoop.Net.on("request", function( _data ) {
	::BBCoop.Sync.onRequest(_data, ::BBCoop.isLoopback());
});

::BBCoop.Net.on("stream", function( _data ) {
	::BBCoop.Sync.onStream(_data);
});

::BBCoop.Net.on("digest", function( _data ) {
	if (::BBCoop.Sync.isGuestSide()) ::BBCoop.Sync.checkDigest(_data.index.tointeger(), null, _data.hash);
});

::BBCoop.Net.on("desync", function( _data ) {
	::logWarning("[BBCoop] Guest reports DESYNC after action " + _data.index + ". Host state: " + ::BBCoop.Sync.describeParts(::BBCoop.Sync.computeDigest().parts));
	::BBCoop.toast("Battle out of sync with " + ::BBCoop.Net.PeerName + " after action " + _data.index);
});
