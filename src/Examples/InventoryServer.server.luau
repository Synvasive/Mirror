local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Mirror = require(ReplicatedStorage.Mirror)

local Inventories = {}

Players.PlayerAdded:Connect(function(Player)
	local Inventory = Mirror.new("Inventory", {
		Owner = Player.UserId,
		Gold = 0,
		Items = {},
	})

	Inventory:Subscribe(Player)
	Inventories[Player] = Inventory

	Inventory:Set({ "Items", 1 }, { Name = "Iron Sword", Damage = 10 })
	Inventory:Set({ "Gold" }, 100)
end)

Players.PlayerRemoving:Connect(function(Player)
	local Inventory = Inventories[Player]
	if Inventory then
		Inventory:Destroy()
		Inventories[Player] = nil
	end
end)
