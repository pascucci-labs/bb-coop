::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onUpdate = @(__original) function()
	{
		__original();
		::BBCoop.Ownership.onWorldUpdate();
	}

	// A save was loaded or a campaign started: re-check owners and resync the guest.
	q.onShow = @(__original) function()
	{
		__original();
		::BBCoop.Ownership.LastRosterSize = -1;
		::BBCoop.Net.send("campaign_info", ::BBCoop.Net.getCampaignInfo());
		::BBCoop.Net.sendOwners();
	}
});
