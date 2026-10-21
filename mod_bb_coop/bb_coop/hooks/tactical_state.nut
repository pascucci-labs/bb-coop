// Combat input.
// - Other player's brother: input is blocked (Combat.isRemoteTurn).
// - Synced battle (Host/Guest paired, or Loopback): input becomes a request to the
//   host instead of acting directly; see sync.nut.
// - Otherwise (hot-seat, or not connected): vanilla behaviour.

local function activeCID()
{
	local active = ::Tactical.TurnSequenceBar.getActiveEntity();
	return active == null ? null : ::BBCoop.Sync.getCID(active);
}

local function isBlocked()
{
	return ::BBCoop.Combat.isRemoteTurn() || ::BBCoop.Sync.isInputBlocked();
}

::BBCoop.Combat.requestTurnEnd <- function( _kind )
{
	local cid = activeCID();
	if (cid == null) return;
	::BBCoop.Sync.request({ kind = _kind, cid = cid });
}

::BBCoop.MH.hook("scripts/states/tactical_state", function(q) {
	q.init = @(__original) function()
	{
		local ret = __original();
		::BBCoop.Sync.onBattleStart();
		return ret;
	}

	q.setActionStateByMouseEvent = @(__original) function( _mouseEvent )
	{
		if (isBlocked()) return false;
		return __original(_mouseEvent);
	}

	q.setActionStateBySkillIndex = @(__original) function( _skillIndex )
	{
		if (isBlocked()) return;
		return __original(_skillIndex);
	}

	q.setActionStateBySkillId = @(__original) function( _skillId )
	{
		if (isBlocked()) return;
		return __original(_skillId);
	}

	// Second click on the same tile starts walking. In a synced battle, send it instead.
	q.executeEntityTravel = @(__original) function( _activeEntity, _mouseEvent )
	{
		__original(_activeEntity, _mouseEvent);
		if (!::BBCoop.Sync.Active || this.m.CurrentActionState != ::Const.Tactical.ActionState.TravelPath) return;

		this.m.CurrentActionState = null;
		this.Tactical.getNavigator().clearPath();
		this.Cursor.setCursor(::Const.UI.Cursor.Hand);
		local tile = ::BBCoop.Sync.tileOf(this.m.LastTileSelected);
		::BBCoop.Sync.request({ kind = "move", cid = ::BBCoop.Sync.getCID(_activeEntity), x = tile.x, y = tile.y });
	}

	q.executeEntitySkill = @(__original) function( _activeEntity, _targetTile )
	{
		if (!::BBCoop.Sync.Active) return __original(_activeEntity, _targetTile);

		local skill = _activeEntity.getSkills().getSkillByID(this.m.SelectedSkillID);
		if (skill == null || !skill.isUsable() || !skill.isAffordable()) return;
		if (_targetTile == null || skill.isTargeted() && this.wasInCameraMovementMode()) return;
		if (!skill.isUsableOn(_targetTile))
		{
			this.Cursor.setCursor(::Const.UI.Cursor.Denied);
			this.Tactical.EventLog.log("[color=" + ::Const.UI.Color.NegativeValue + "]Invalid target![/color]");
			return;
		}

		local tile = ::BBCoop.Sync.tileOf(_targetTile);
		::BBCoop.Sync.request({ kind = "skill", cid = ::BBCoop.Sync.getCID(_activeEntity), id = skill.getID(), x = tile.x, y = tile.y });

		this.Tooltip.reload();
		this.Tactical.TurnSequenceBar.deselectActiveSkill();
		this.Tactical.getHighlighter().clear();
		this.m.CurrentActionState = null;
		this.m.SelectedSkillID = null;
		this.updateCursorAndTooltip();
	}

	q.helper_handleContextualKeyInput = @(__original) function( _key )
	{
		if (_key.getState() != 0 || this.isInCharacterScreen()) return __original(_key);

		local key = _key.getKey();
		local isTurnKey = key == 16 || key == 39 || key == 28 || key == 40 || key == 44;
		if (!isTurnKey || _key.getModifier() == 1) return __original(_key);
		if (key == 16 && this.m.IsDeveloperModeEnabled) return __original(_key);
		if (isBlocked()) return true;
		if (!::BBCoop.Sync.Active) return __original(_key);

		local active = this.Tactical.TurnSequenceBar.getActiveEntity();
		if (active == null || !active.isPlayerControlled()) return true;

		if (key == 28) this.Tactical.TurnSequenceBar.onEndTurnAllButtonPressed();
		else ::BBCoop.Combat.requestTurnEnd(key == 40 || key == 44 ? "wait" : "endturn");
		return true;
	}

	q.onUpdate = @(__original) function()
	{
		// Hash the last action before anything else (AI included) can act this frame.
		::BBCoop.Sync.updateDigest();
		__original();
		::BBCoop.Sync.update();
		::BBCoop.Combat.onUpdate();
	}

	q.onFinish = @(__original) function()
	{
		::BBCoop.Combat.onCombatEnd();
		::BBCoop.Sync.onBattleEnd();
		return __original();
	}
});

::BBCoop.MH.hook("scripts/ui/screens/tactical/modules/turn_sequence_bar/turn_sequence_bar", function(q) {
	q.onNextTurnButtonPressed = @(__original) function()
	{
		if (isBlocked()) return;
		if (!::BBCoop.Sync.Active) return __original();
		if (this.getActiveEntity() == null || !this.getActiveEntity().isPlayerControlled()) return;
		::BBCoop.Combat.requestTurnEnd("endturn");
	}

	q.onWaitTurnButtonPressed = @(__original) function()
	{
		if (isBlocked()) return;
		if (!::BBCoop.Sync.Active) return __original();
		if (this.getActiveEntity() == null || !this.getActiveEntity().isPlayerControlled()) return;
		::BBCoop.Combat.requestTurnEnd("wait");
	}

	// "End round" only skips the brothers the local player owns.
	q.onEndTurnAllButtonPressed = @(__original) function()
	{
		if ((!::BBCoop.isEnabled() || ::BBCoop.isHotseat()) && !::BBCoop.Sync.Active) return __original();
		if (this.m.IsSkippingRound || this.getActiveEntity() == null || !this.getActiveEntity().isPlayerControlled()) return;
		if (isBlocked()) return;

		this.Tactical.State.showDialogPopup("End Round", "Have all your own characters skip their turn until the next round starts?", function ()
		{
			local cids = [];
			foreach (e in this.m.CurrentEntities)
			{
				if (e.isPlayerControlled() && ::BBCoop.Ownership.canControl(e)) cids.push(::BBCoop.Sync.getCID(e));
			}

			if (::BBCoop.Sync.Active)
			{
				::BBCoop.Sync.request({ kind = "skipround", cid = activeCID(), cids = cids });
				return;
			}
			foreach (cid in cids)
			{
				::BBCoop.Sync.getActor(cid).setSkipTurn(true);
			}
			this.initNextTurn();
		}.bindenv(this), null);
	}

	// Owner info for the portraits in the turn order bar (greys out other players' brothers).
	q.convertEntityToUIData = @(__original) function( _entity, isLastEntity = false )
	{
		local result = __original(_entity, isLastEntity);
		if (::BBCoop.isEnabled() && ::BBCoop.Ownership.isBrother(_entity))
		{
			result.bbcoop <- ::BBCoop.Ownership.getBadgeData(_entity);
		}
		return result;
	}

	// Guest: only the host's stream ends turns. Host: report every turn end.
	q.initNextTurn = @(__original) function( _force = false )
	{
		if (!::BBCoop.Sync.mayAdvanceTurn()) return;
		local position = this.m.TurnPosition;
		local ret = __original(_force);
		if (this.m.TurnPosition != position) ::BBCoop.Sync.onTurnAdvanced();
		return ret;
	}

	q.initNextTurnBecauseOfWait = @(__original) function()
	{
		if (!::BBCoop.Sync.mayAdvanceTurn()) return;
		return __original();
	}
});
