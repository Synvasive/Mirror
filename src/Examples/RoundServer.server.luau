local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Mirror = require(ReplicatedStorage.Mirror)

local Round = Mirror.new("Round", {
	State = "Intermission",
	Time = 30,
	Scores = {},
})

Round:Replicate()

while true do
	for Time = 30, 0, -1 do
		Round:SetUnreliable({ "Time" }, Time)
		task.wait(1)
	end

	Round:Set({ "State" }, if Round.Data.State == "Intermission" then "Playing" else "Intermission")
end
