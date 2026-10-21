::include("bb_coop/core");
::include("bb_coop/settings");
::include("bb_coop/ownership");
::include("bb_coop/net");
::include("bb_coop/combat");
::include("bb_coop/retrain");
::include("bb_coop/sync");
::include("bb_coop/panel");

foreach (file in ::IO.enumerateFiles("bb_coop/hooks"))
{
	::include(file);
}

::Hooks.registerJS("ui/mods/bb_coop/coop.js");
::Hooks.registerCSS("ui/mods/bb_coop/coop.css");

::BBCoop.Connection <- ::new("scripts/mods/bb_coop/coop_connection");
::MSU.UI.registerConnection(::BBCoop.Connection);

::BBCoop.log("Loaded v" + ::BBCoop.Version);
