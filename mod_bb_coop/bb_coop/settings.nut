// Co-op settings. Players change them in the Co-op panel (panel.nut); MSU only stores
// them between sessions. Every setting is hidden from MSU's settings screen, which
// shows a single line pointing to the panel instead.
local C = ::BBCoop.Const;
local page = ::BBCoop.Mod.ModSettings.addPage("General");

page.addTitle("PanelHint", "Co-op settings are in the Co-op panel: click the Co-op light at the top right of the screen.");

local hidden = [];
local function add( _setting )
{
	hidden.push(_setting);
	return _setting;
}

local enabled = add(page.addBooleanSetting("Enabled", false, "Co-op enabled"));
enabled.addAfterChangeCallback(function( _oldValue ) {
	::BBCoop.onEnabledChanged();
});

add(page.addEnumSetting("Mode", C.Mode.Hotseat, [C.Mode.Hotseat, C.Mode.Host, C.Mode.Guest, C.Mode.Loopback], "Play mode"));

// Online, each player sets their own name, badge and colour; they're sent to the
// other PC when you link up and whenever you change them.
local function addPlayer( _n, _defaultColor )
{
	local settings = [
		add(page.addStringSetting("Player" + _n + "Name", "Player " + _n, "Player " + _n + " name")),
		add(page.addStringSetting("Player" + _n + "Tag", "P" + _n, "Player " + _n + " badge")),
		add(page.addColorPickerSetting("Player" + _n + "Color", _defaultColor, "Player " + _n + " colour"))
	];
	foreach (setting in settings)
	{
		setting.addAfterChangeCallback(function( _oldValue ) {
			::BBCoop.onPlayerStyleChanged(_n);
		});
	}
}
addPlayer(1, "47,95,168,1");
addPlayer(2, "168,57,47,1");

add(page.addEnumSetting("HireRule", C.HireRule.Alternate, [C.HireRule.Alternate, C.HireRule.Fewest, C.HireRule.Host], "New brothers go to"));
add(page.addBooleanSetting("TurnAlert", true, "Your-turn alert"));
add(page.addStringSetting("RelayAddress", "ws://127.0.0.1:7777", "Relay address"));
add(page.addStringSetting("SessionKey", "", "Session key"));

// MSU hides "new campaign only" settings everywhere except the new-campaign screen,
// and only shows them there if they're also flagged "NewCampaign", which these aren't.
foreach (setting in hidden)
{
	setting.getData().NewCampaignOnly <- true;
}

// Every launch starts solo: co-op only switches on when the player picks Host Campaign
// or Join Campaign (or Host/Join in the Co-op panel). MSU loads the saved settings in
// root_state.onInit; our hook wraps MSU's, so this runs after the load. The change
// callbacks are skipped: nothing is running yet.
::BBCoop.MH.hook("scripts/root_state", function(q) {
	q.onInit = @(__original) function()
	{
		__original();
		::BBCoop.Mod.ModSettings.getSetting("Enabled").set(false, false, true, true, false, false);
	}
});
