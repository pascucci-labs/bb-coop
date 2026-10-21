// Add owner info to the brother data the character screen receives.
::BBCoop.MH.hook("scripts/ui/global/data_helper", function(q) {
	q.convertEntityToUIData = @(__original) function( _entity, _activeEntity )
	{
		local result = __original(_entity, _activeEntity);
		if (::BBCoop.isEnabled() && ::BBCoop.Ownership.isBrother(_entity))
		{
			result.bbcoop <- ::BBCoop.Ownership.getBadgeData(_entity);
		}
		return result;
	}
});
