--!native
--!optimize 2

--> Services <--
const Players = game:GetService("Players")
const RunService = game:GetService("RunService")

--> Dependencies <--
const Codec = require "../Utils/Codec"
const Message = require "../Utils/Message"
const Network = require "../Network/Server"

--> Types <--
type Op = {
	Path: { any },
	Value: any,
	Unreliable: boolean,
	Dead: boolean,
}

type Segment = {
	Start: number,
	Length: number,
	Keys: { number },
	Extras: { any },
	Unreliable: boolean,
}

type Viewer = {
	Ready: boolean,
	Known: { [number]: boolean },
	Creates: { [Replica]: boolean },
	Destroys: { number },
}

export type Replica = {
	Id: number,
	Token: string,
	Data: { [any]: any },

	Set: (self: Replica, Path: { any }, Value: any) -> (),
	SetUnreliable: (self: Replica, Path: { any }, Value: any) -> (),
	Replicate: (self: Replica) -> (),
	Subscribe: (self: Replica, Player: Player) -> (),
	Unsubscribe: (self: Replica, Player: Player) -> (),
	Destroy: (self: Replica) -> (),
}

--> Constants <--
const Limit = 900

--> Variables <--
const KeyIds: { [string]: number } = {}
const KeyList: { string } = {}

const Replicas: { [number]: Replica } = {}
const Viewers: { [Player]: Viewer } = {}
const Dirty: { Replica } = {}

local Used: { number } = {}
local Count = 0

const Frame = Codec.Writer(4096, function(Text: string): number
	local Id = KeyIds[Text]
	if not Id then
		table.insert(KeyList, Text)
		Id = #KeyList
		KeyIds[Text] = Id
	end

	table.insert(Used, Id)
	return Id
end)

const Out = Codec.Writer(1024, Frame.Intern)
const Loose = Codec.Writer(Limit, Frame.Intern)

--> Main <--
const Mirror = {}
const Class = {}
Class.__index = Class

const Helper = {}

--> Helper <--
function Helper.Visible(Replica: any, Player: Player): boolean
	return Replica._Everyone or Replica._Subscribers[Player] == true
end

function Helper.Mark(Replica: any)
	if not Replica._Dirty then
		Replica._Dirty = true
		table.insert(Dirty, Replica)
	end
end

function Helper.Key(Path: { any }): string?
	const Parts = table.create(#Path)

	for Index, Key in Path do
		const Kind = type(Key)
		if Kind == "string" then
			Parts[Index] = Key
		elseif Kind == "number" then
			Parts[Index] = "#" .. Key
		else
			return nil
		end
	end

	return table.concat(Parts, "\0")
end

function Helper.Apply(Data: { [any]: any }, Path: { any }, Value: any)
	local Node = Data
	const Last = #Path

	for Index = 1, Last - 1 do
		const Key = Path[Index]
		local Child = Node[Key]

		if type(Child) ~= "table" then
			Child = {}
			Node[Key] = Child
		end

		Node = Child
	end

	Node[Path[Last]] = Value
end

function Helper.Queue(Replica: any, Path: { any }, Value: any, IsUnreliable: boolean)
	assert(#Path > 0 and #Path < 256, "Mirror: path needs 1 to 255 keys")
	Helper.Apply(Replica.Data, Path, Value)

	if not Codec.Sendable(Value) then
		return
	end

	for _, Key in Path do
		if not Codec.Sendable(Key) then
			return
		end
	end

	const Pending = Replica._Pending
	const Key = Helper.Key(Path)

	if Key then
		const Previous = Replica._Index[Key]
		if Previous then
			Pending[Previous].Dead = true
		end

		Replica._Index[Key] = #Pending + 1
	end

	table.insert(Pending, {
		Path = table.clone(Path),
		Value = Value,
		Unreliable = IsUnreliable,
		Dead = false,
	})

	Helper.Mark(Replica)
end

function Helper.Segment(IsUnreliable: boolean, Write: () -> ()): Segment?
	const Start = Frame.Cursor
	Used = {}
	Frame.Extras = {}

	const Success, Problem = pcall(Write)
	if not Success then
		Frame.Cursor = Start
		warn(`Mirror: skipped a change that couldn't be encoded: {Problem}`)
		return nil
	end

	return {
		Start = Start,
		Length = Frame.Cursor - Start,
		Keys = Used,
		Extras = Frame.Extras,
		Unreliable = IsUnreliable,
	}
end

function Helper.Define(Writer: Codec.Writer, Viewer: Viewer, Keys: { number })
	const Known = Viewer.Known

	for _, Id in Keys do
		if Known[Id] then
			continue
		end

		Known[Id] = true
		Codec.U8(Writer, Message.Key)
		Codec.Varint(Writer, Id)
		Codec.Text(Writer, KeyList[Id])
	end
end

function Helper.Knows(Viewer: Viewer, Keys: { number }): boolean
	for _, Id in Keys do
		if not Viewer.Known[Id] then
			return false
		end
	end

	return true
end

function Helper.Copy(Writer: Codec.Writer, Extras: { any }, Segment: Segment)
	Codec.Bytes(Writer, Frame.Buffer, Segment.Start, Segment.Length)
	table.move(Segment.Extras, 1, #Segment.Extras, #Extras + 1, Extras)
end

function Helper.Send(Event: { Fire: (Player: Player, Payload: buffer, Extras: any) -> () }, Player: Player, Writer: Codec.Writer, Extras: { any })
	if Writer.Cursor == 0 then
		return
	end

	const Payload = buffer.create(Writer.Cursor)
	buffer.copy(Payload, 0, Writer.Buffer, 0, Writer.Cursor)
	Event.Fire(Player, Payload, if #Extras > 0 then Extras else nil)

	Writer.Cursor = 0
end

function Helper.Ready(Player: Player)
	const Viewer = Viewers[Player]
	if not Viewer or Viewer.Ready then
		return
	end

	Viewer.Ready = true

	for _, Replica in Replicas do
		if Helper.Visible(Replica, Player) then
			Viewer.Creates[Replica] = true
		end
	end
end

--> Methods <--
function Mirror.new(Token: string, Data: { [any]: any }?): Replica
	Count += 1

	const Replica = setmetatable({
		Id = Count,
		Token = Token,
		Data = Data or {},

		_Everyone = false,
		_Subscribers = {},
		_Pending = {},
		_Index = {},
		_Dirty = false,
	}, Class) :: any

	Replicas[Replica.Id] = Replica
	return Replica
end

function Mirror.Flush()
	if #Dirty == 0 and next(Viewers) == nil then
		return
	end

	Frame.Cursor = 0

	const Encoded: { [Replica]: { Segment } } = {}
	const Snapshots: { [Replica]: Segment | false } = {}

	for _, Replica in Dirty :: { any } do
		const Segments = {}

		for _, Op in Replica._Pending :: { Op } do
			if Op.Dead then
				continue
			end

			const Segment = Helper.Segment(Op.Unreliable, function()
				Codec.U8(Frame, Message.Set)
				Codec.Varint(Frame, Replica.Id)
				Codec.U8(Frame, #Op.Path)

				for _, Key in Op.Path do
					Codec.Write(Frame, Key)
				end

				Codec.Write(Frame, Op.Value)
			end)

			if Segment then
				table.insert(Segments, Segment)
			end
		end

		Encoded[Replica] = Segments
		Replica._Pending = {}
		Replica._Index = {}
		Replica._Dirty = false
	end

	table.clear(Dirty)

	for Player, Viewer in Viewers do
		if not Viewer.Ready then
			continue
		end

		const Extras = {}
		const LooseExtras = {}

		for _, Id in Viewer.Destroys do
			Codec.U8(Out, Message.Destroy)
			Codec.Varint(Out, Id)
		end

		table.clear(Viewer.Destroys)

		for Replica in Viewer.Creates do
			local Snapshot = Snapshots[Replica]
			if Snapshot == nil then
				Snapshot = Helper.Segment(false, function()
					Codec.U8(Frame, Message.Create)
					Codec.Varint(Frame, Replica.Id)
					Codec.Write(Frame, Replica.Token)
					Codec.Write(Frame, Replica.Data)
				end)

				Snapshots[Replica] = Snapshot or false
			end

			if not Snapshot then
				continue
			end

			Helper.Define(Out, Viewer, Snapshot.Keys)
			Helper.Copy(Out, Extras, Snapshot)
		end

		for Replica, Segments in Encoded do
			if Viewer.Creates[Replica] or not Helper.Visible(Replica, Player) then
				continue
			end

			for _, Segment in Segments do
				if Segment.Unreliable and Segment.Length <= Limit and Helper.Knows(Viewer, Segment.Keys) then
					if Loose.Cursor + Segment.Length > Limit then
						Helper.Send(Network.Unreliable, Player, Loose, LooseExtras)
						table.clear(LooseExtras)
					end

					Helper.Copy(Loose, LooseExtras, Segment)
				else
					Helper.Define(Out, Viewer, Segment.Keys)
					Helper.Copy(Out, Extras, Segment)
				end
			end
		end

		table.clear(Viewer.Creates)

		Helper.Send(Network.Reliable, Player, Out, Extras)
		Helper.Send(Network.Unreliable, Player, Loose, LooseExtras)
	end

	Network.StepReplication()
end

--> Class <--
function Class.Set(Replica: Replica, Path: { any }, Value: any)
	Helper.Queue(Replica, Path, Value, false)
end

function Class.SetUnreliable(Replica: Replica, Path: { any }, Value: any)
	Helper.Queue(Replica, Path, Value, true)
end

function Class.Replicate(Replica: any)
	Replica._Everyone = true

	for Player, Viewer in Viewers do
		if Viewer.Ready then
			Viewer.Creates[Replica] = true
		end
	end
end

function Class.Subscribe(Replica: any, Player: Player)
	const Visible = Helper.Visible(Replica, Player)
	Replica._Subscribers[Player] = true

	const Viewer = Viewers[Player]
	if Viewer and Viewer.Ready and not Visible then
		Viewer.Creates[Replica] = true
	end
end

function Class.Unsubscribe(Replica: any, Player: Player)
	if not Replica._Subscribers[Player] then
		return
	end

	Replica._Subscribers[Player] = nil

	const Viewer = Viewers[Player]
	if Viewer and Viewer.Ready and not Helper.Visible(Replica, Player) then
		if Viewer.Creates[Replica] then
			Viewer.Creates[Replica] = nil
		else
			table.insert(Viewer.Destroys, Replica.Id)
		end
	end
end

function Class.Destroy(Replica: any)
	if not Replicas[Replica.Id] then
		return
	end

	Replicas[Replica.Id] = nil

	for Player, Viewer in Viewers do
		if not Viewer.Ready or not Helper.Visible(Replica, Player) then
			continue
		end

		if Viewer.Creates[Replica] then
			Viewer.Creates[Replica] = nil
		else
			table.insert(Viewer.Destroys, Replica.Id)
		end
	end

	if Replica._Dirty then
		const Index = table.find(Dirty, Replica)
		if Index then
			table.remove(Dirty, Index)
		end
	end

	Replica._Everyone = false
	table.clear(Replica._Subscribers)
end

--> Setup <--
const function Join(Player: Player)
	Viewers[Player] = {
		Ready = false,
		Known = {},
		Creates = {},
		Destroys = {},
	}
end

Players.PlayerAdded:Connect(Join)
Players.PlayerRemoving:Connect(function(Player)
	Viewers[Player] = nil

	for _, Replica in Replicas :: { [number]: any } do
		Replica._Subscribers[Player] = nil
	end
end)

for _, Player in Players:GetPlayers() do
	Join(Player)
end

Network.Ready.On(Helper.Ready)
RunService.Heartbeat:Connect(Mirror.Flush)

--> Main <--
return Mirror
