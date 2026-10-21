// Squirrel side of the BBCoopConnection JS object (ui/mods/bb_coop/coop.js).
this.coop_connection <- ::inherit("scripts/mods/msu/js_connection", {
	m = {},

	function create()
	{
		this.m.ID = "BBCoopConnection";
	}

	function call( _function, _data )
	{
		if (this.m.JSHandle != null)
		{
			this.m.JSHandle.asyncCall(_function, _data);
		}
	}

	// ---- Called from JS ----

	function onNetEvent( _event )
	{
		::BBCoop.Net.onEvent(_event.type, "data" in _event ? _event.data : null);
	}

	// Errors thrown in calls from JS don't reliably reach log.html, so catch and report them.
	function guarded( _name, _function )
	{
		try
		{
			return _function();
		}
		catch (error)
		{
			::logError("[BBCoop] " + _name + " failed: " + error);
			::BBCoop.toast("Co-op error in " + _name + ": " + error);
			return { error = "" + error, menu = null };
		}
	}

	function findBrother( _id, _caller )
	{
		local bro = ::BBCoop.Ownership.findByEntityID(_id.tointeger());
		if (bro == null)
		{
			::BBCoop.log(_caller + ": no brother with entity ID " + _id + " in the roster (" + ::World.getPlayerRoster().getSize() + " brothers)");
		}
		return bro;
	}

	// Badge clicked: open the co-op menu for that brother. Returns { error?, menu }.
	function onQueryCoopMenu( _entityID )
	{
		return this.guarded("onQueryCoopMenu", function() {
			::BBCoop.log("Open co-op menu for entity " + _entityID);
			local bro = this.findBrother(_entityID, "onQueryCoopMenu");
			if (bro == null) return { error = "Couldn't find this brother. Close and reopen the character screen.", menu = null };
			return { error = null, menu = ::BBCoop.Retrain.getMenuData(bro) };
		}.bindenv(this));
	}

	function onToggleOwner( _entityID )
	{
		return this.guarded("onToggleOwner", function() {
			local bro = this.findBrother(_entityID, "onToggleOwner");
			if (bro == null) return { error = "Brother not found", menu = null };
			::BBCoop.Ownership.toggleOwner(bro);
			::BBCoop.Retrain.refreshScreen();
			return { error = null, menu = ::BBCoop.Retrain.getMenuData(bro) };
		}.bindenv(this));
	}

	// _data = { id, op, remove?, add? }. Returns { error?, menu }.
	function onRetrain( _data )
	{
		return this.guarded("onRetrain", function() {
			local bro = this.findBrother(_data.id, "onRetrain");
			if (bro == null) return { error = "Brother not found", menu = null };
			local error = ::BBCoop.Retrain.perform(bro, _data.op, _data);
			return { error = error, menu = ::BBCoop.Retrain.getMenuData(bro) };
		}.bindenv(this));
	}

	// ---- Co-op panel and status light ----

	function onQueryStatus( _ = null )
	{
		return ::BBCoop.Net.getStatus();
	}

	function onQueryPanel( _ = null )
	{
		return this.guarded("onQueryPanel", function() {
			return { error = null, panel = ::BBCoop.Panel.getData() };
		}.bindenv(this));
	}

	// { action, value?, player?, field? } -> { error, panel }
	function onPanelAction( _args )
	{
		return this.guarded("onPanelAction", function() {
			local error = ::BBCoop.Panel.act(_args);
			return { error = error, panel = ::BBCoop.Panel.getData() };
		}.bindenv(this));
	}
});
