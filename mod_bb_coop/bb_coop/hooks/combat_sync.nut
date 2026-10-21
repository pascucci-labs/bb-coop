// Hooks that keep the two battles in step: combat IDs, RNG reseeding at movement steps
// and turn starts, AI capture on the host, and AI switched off on the guest.

::BBCoop.MH.hook("scripts/entity/tactical/actor", function(q) {
	q.onPlacedOnMap = @(__original) function()
	{
		__original();
		::BBCoop.Sync.registerActor(this);
	}

	q.onMovementStart = @(__original) function( _tile, _numTiles )
	{
		::BBCoop.Sync.onMovementStart(this);
		return __original(_tile, _numTiles);
	}

	q.onMovementStep = @(__original) function( _tile, _levelDifference )
	{
		local ret = __original(_tile, _levelDifference);
		::BBCoop.Sync.onMovementStep(this, _tile);
		return ret;
	}

	q.onMovementFinish = @(__original) function( _tile )
	{
		local ret = __original(_tile);
		::BBCoop.Sync.onMovementFinish(this);
		return ret;
	}

});

// hookTree: also wraps subclasses that override onTurnStart, so the reseed comes first.
// Reseeding twice with the same value (subclass + base) is harmless.
::BBCoop.MH.hookTree("scripts/entity/tactical/actor", function(q) {
	q.onTurnStart = @(__original) function()
	{
		::BBCoop.Sync.onTurnStart(this);
		return __original();
	}
});

::BBCoop.MH.hook("scripts/skills/skill", function(q) {
	q.use = @(__original) function( _targetTile, _forFree = false )
	{
		local rec = ::BBCoop.Sync.beforeSkillUse(this, _targetTile, _forFree);
		local ret = __original(_targetTile, _forFree);
		if (rec != null) ::BBCoop.Sync.afterSkillUse(rec);
		return ret;
	}
});

::BBCoop.MH.hook("scripts/ai/tactical/agent", function(q) {
	q.think = @(__original) function( _evaluateOnly = false )
	{
		local sync = ::BBCoop.Sync;
		if (sync.Active)
		{
			// Guest: the host's AI decides, and its actions arrive in the stream.
			if (sync.isGuestSide()) return;
			// Host: don't think (thinking uses the RNG) until the last action has settled.
			if (::Time.hasEventScheduled(::TimeUnit.Virtual) || sync.Current != null || sync.PendingDigest != null) return;
		}
		return __original(_evaluateOnly);
	}
});
