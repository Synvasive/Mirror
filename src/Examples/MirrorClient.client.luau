local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Mirror = require(ReplicatedStorage.Mirror)

Mirror.OnNew("Round", function(Round)
	print("Round:", Round.Data.State, Round.Data.Time)

	Round:OnChange(function(Path, Value, Old)
		print(table.concat(Path, "/"), Old, "->", Value)
	end)
end)

Mirror.OnNew("Inventory", function(Inventory)
	if Inventory.Data.Owner ~= Players.LocalPlayer.UserId then
		return
	end

	print("Gold:", Inventory.Data.Gold)

	Inventory:OnChange(function(Path, Value)
		if Path[1] == "Items" then
			print("Item", Path[2], "is now", Value and Value.Name)
		end
	end)

	Inventory:OnDestroy(function()
		print("Inventory removed")
	end)
end)
