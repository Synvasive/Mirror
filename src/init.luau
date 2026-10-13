--> Services <--
const RunService = game:GetService("RunService")

--> Main <--
return if RunService:IsServer() then require "@self/Context/Server" else require "@self/Context/Client"
