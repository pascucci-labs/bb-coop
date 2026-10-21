::BBCoop.MH.hook("scripts/entity/tactical/player", function(q) {
	q.onHired = @(__original) function()
	{
		__original();
		::BBCoop.Retrain.recordStartRoll(this);
		::BBCoop.Ownership.assignNewBrother(this);
	}
});
