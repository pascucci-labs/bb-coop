::BBCoop.Const <- {
	ProtocolVersion = 1,

	// Play mode values, as stored in the MSU settings.
	Mode = {
		Hotseat = "Hot-seat (same PC)",
		Host = "Host (Player 1, admin)",
		Guest = "Guest (Player 2)",
		Loopback = "Loopback test (solo)"
	},

	// Who gets a newly joined brother.
	HireRule = {
		Alternate = "Alternate between players",
		Fewest = "Player with fewer brothers",
		Host = "Always Player 1"
	},

	// Per-brother flags (saved with the campaign).
	FlagOwner = "BBCoop.Owner",
	FlagUID = "BBCoop.UID",

	// Campaign-wide counters, kept in World.Statistics flags.
	StatNextOwner = "BBCoop.NextOwner",
	StatNextUID = "BBCoop.NextUID"
};

::BBCoop.log <- function( _text )
{
	::logInfo("[BBCoop] " + _text);
}

::BBCoop.getSetting <- function( _id )
{
	return ::BBCoop.Mod.ModSettings.getSetting(_id).getValue();
}

// Master switch. When off, the game plays as normal single player: no badges, no
// blocked input, no network, no owner assignment.
::BBCoop.isEnabled <- function()
{
	return ::BBCoop.getSetting("Enabled");
}

::BBCoop.getMode <- function()
{
	return ::BBCoop.getSetting("Mode");
}

::BBCoop.isHotseat <- function()
{
	return ::BBCoop.getMode() == ::BBCoop.Const.Mode.Hotseat;
}

::BBCoop.isHost <- function()
{
	return ::BBCoop.getMode() == ::BBCoop.Const.Mode.Host;
}

// Solo test of the combat-sync path: acts like a host whose commands make a round trip
// through the UI as JSON before they run.
::BBCoop.isLoopback <- function()
{
	return ::BBCoop.getMode() == ::BBCoop.Const.Mode.Loopback;
}

::BBCoop.isGuest <- function()
{
	return ::BBCoop.getMode() == ::BBCoop.Const.Mode.Guest;
}

// Which player sits at this PC. In hot-seat both do, so this returns 0.
::BBCoop.getLocalPlayer <- function()
{
	if (::BBCoop.isGuest()) return 2;
	if (::BBCoop.isHost()) return 1;
	return 0; // hot-seat and loopback: both players sit here
}

// Player 1 is the admin: they can reassign brothers and change the hire rule.
::BBCoop.isAdmin <- function()
{
	return !::BBCoop.isGuest();
}

::BBCoop.getPlayerName <- function( _player )
{
	return ::BBCoop.getSetting(_player == 2 ? "Player2Name" : "Player1Name");
}

// Short text on the portrait badge (a few letters).
::BBCoop.getPlayerTag <- function( _player )
{
	local tag = strip(::BBCoop.getSetting(_player == 2 ? "Player2Tag" : "Player1Tag"));
	if (tag == "") tag = "P" + (_player == 2 ? 2 : 1);
	return tag.len() > 4 ? tag.slice(0, 4) : tag;
}

// Badge and banner colour as a CSS string. MSU stores colours as "r,g,b,a".
::BBCoop.getPlayerColor <- function( _player )
{
	local parts = split(::BBCoop.getSetting(_player == 2 ? "Player2Color" : "Player1Color"), ",");
	if (parts.len() < 3) return _player == 2 ? "rgb(168,57,47)" : "rgb(47,95,168)";
	return "rgb(" + parts[0] + "," + parts[1] + "," + parts[2] + ")";
}

// Everything the UI needs to draw a player's badge.
::BBCoop.getPlayerStyle <- function( _player )
{
	if (_player != 1 && _player != 2) return { name = "Unassigned", tag = "?", color = "rgb(102,102,102)" };
	return { name = ::BBCoop.getPlayerName(_player), tag = ::BBCoop.getPlayerTag(_player), color = ::BBCoop.getPlayerColor(_player) };
}

::BBCoop.isInCampaign <- function()
{
	return ("State" in ::World) && ::World.State != null && ("Assets" in ::World) && ::World.Assets != null;
}

::BBCoop.toast <- function( _text )
{
	::BBCoop.log(_text);
	::BBCoop.Connection.call("showToast", _text);
}

// A player's name, badge or colour changed. Online, send our own to the other PC.
::BBCoop.onPlayerStyleChanged <- function( _player )
{
	if (_player == ::BBCoop.getLocalPlayer()) ::BBCoop.Net.sendProfile();
	::BBCoop.refreshStyles();
}

// Update the status light (and the panel, if it's open).
::BBCoop.updateStatus <- function()
{
	::BBCoop.Connection.call("setNetStatus", ::BBCoop.Net.getStatus());
}

// Redraw badges and the turn banner.
::BBCoop.refreshStyles <- function()
{
	::BBCoop.Combat.refresh();
	::BBCoop.Retrain.refreshScreen();
}

::BBCoop.onEnabledChanged <- function()
{
	if (::BBCoop.isEnabled())
	{
		::BBCoop.Ownership.LastRosterSize = -1; // assign brothers hired while it was off
		::BBCoop.toast("Co-op turned on");
	}
	else
	{
		::BBCoop.Net.disconnect();
		::BBCoop.Connection.call("hideBanner", null);
		::BBCoop.toast("Co-op turned off.");
	}
	::BBCoop.updateStatus();
	::BBCoop.refreshStyles();
}
