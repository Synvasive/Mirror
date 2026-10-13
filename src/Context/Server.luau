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
	Kind: number,
	Path: { any },
	Value: any,
	Index: number?,
	Name: string?,
	Args: { any }?,
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
	Creates: { [Reflection]: boolean },
	Destroys: { number },
}

export type Reflection = {
	Id: number,
	Token: string,
	Data: { [any]: any },

	Set: (self: Reflection, Path: { any }, Value: any) -> (),
	SetUnreliable: (self: Reflection, Path: { any }, Value: any) -> (),
	SetValues: (self: Reflection, Path: { any }, Values: { [any]: any }) -> (),
	TableInsert: (self: Reflection, Path: { any }, Value: any, Index: number?) -> number,
	TableRemove: (self: Reflection, Path: { any }, Index: number) -> any,
	Write: (self: Reflection, Name: string, ...any) -> ...any,

	Replicate: (self: Reflection) -> (),
	DontReplicate: (self: Reflection) -> (),
	Subscribe: (self: Reflection, Player: Player) -> (),
	Unsubscribe: (self: Reflection, Player: Player) -> (),

	Identify: (self: Reflection) -> string,
	IsActive: (self: Reflection) -> boolean,
	Destroy: (self: Reflection) -> (),
}

--> Constants <--
const Limit = 900

--> Variables <--
const KeyIds: { [string]: number } = {}
const KeyList: { string } = {}

const Reflections: { [number]: Reflection } = {}
const Viewers: { [Player]: Viewer } = {}
const Dirty: { Reflection } = {}

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
function Helper.Visible(Reflection: any, Player: Player): boolean
	return Reflection._Everyone or Reflection._Subscribers[Player] == true
end

function Helper.Mark(Reflection: any)
	if not Reflection._Dirty then
		Reflection._Dirty = true
		table.insert(Dirty, Reflection)
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

function Helper.Node(Data: { [any]: any }, Path: { any }, Depth: number): { [any]: any }
	local Node = Data

	for Index = 1, Depth do
		const Key = Path[Index]
		local Child = Node[Key]

		if type(Child) ~= "table" then
			Child = {}
			Node[Key] = Child
		end

		Node = Child
	end

	return Node
end

function Helper.Sendable(Path: { any }): boolean
	for _, Key in Path do
		if not Codec.Sendable(Key) then
			return false
		end
	end

	return true
end

function Helper.Push(Reflection: any, Op: Op)
	if Reflection._Writing > 0 or not Helper.Sendable(Op.Path) then
		return
	end

	for _, Pending in Reflection._Pending :: { Op } do
		Pending.Unreliable = false
	end

	Reflection._Barrier = true
	table.clear(Reflection._Index)
	table.insert(Reflection._Pending, Op)
	Helper.Mark(Reflection)
end

function Helper.Path(Path: { any })
	Codec.U8(Frame, #Path)

	for _, Key in Path do
		Codec.Write(Frame, Key)
	end
end

function Helper.Encode(Reflection: any, Op: Op)
	Codec.U8(Frame, Op.Kind)
	Codec.Varint(Frame, Reflection.Id)

	if Op.Kind == Message.Write then
		const Args = Op.Args :: { any }
		Codec.Write(Frame, Op.Name)
		Codec.U8(Frame, Args.n)

		for Index = 1, Args.n do
			Codec.Write(Frame, Args[Index])
		end

		return
	end

	Helper.Path(Op.Path)

	if Op.Kind == Message.Insert or Op.Kind == Message.Remove then
		Codec.Varint(Frame, Op.Index :: number)
	end

	if Op.Kind ~= Message.Remove then
		Codec.Write(Frame, Op.Value)
	end
end

function Helper.Queue(Reflection: any, Path: { any }, Value: any, IsUnreliable: boolean)
	assert(#Path > 0 and #Path < 256, "Mirror: path needs 1 to 255 keys")
	Helper.Node(Reflection.Data, Path, #Path - 1)[Path[#Path]] = Value

	if Reflection._Writing > 0 or not Codec.Sendable(Value) then
		return
	end

	if not Helper.Sendable(Path) then
		return
	end

	const Pending = Reflection._Pending
	const Key = Helper.Key(Path)

	if Key then
		const Previous = Reflection._Index[Key]
		if Previous then
			Pending[Previous].Dead = true
		end

		Reflection._Index[Key] = #Pending + 1
	end

	table.insert(Pending, {
		Kind = Message.Set,
		Path = table.clone(Path),
		Value = Value,
		Unreliable = IsUnreliable and not Reflection._Barrier,
		Dead = false,
	})

	Helper.Mark(Reflection)
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

	for _, Reflection in Reflections do
		if Helper.Visible(Reflection, Player) then
			Viewer.Creates[Reflection] = true
		end
	end
end

--> Methods <--
function Mirror.new(Token: string, Data: { [any]: any }?, WriteLib: ModuleScript?): Reflection
	Count += 1

	const Reflection = setmetatable({
		Id = Count,
		Token = Token,
		Data = Data or {},

		_Module = WriteLib,
		_Lib = if WriteLib then require(WriteLib) :: any else nil,
		_Writing = 0,
		_Barrier = false,

		_Everyone = false,
		_Subscribers = {},
		_Pending = {},
		_Index = {},
		_Dirty = false,
	}, Class) :: any

	Reflections[Reflection.Id] = Reflection
	return Reflection
end

function Mirror.FromId(Id: number): Reflection?
	return Reflections[Id]
end

function Mirror.Flush()
	if #Dirty == 0 and next(Viewers) == nil then
		return
	end

	Frame.Cursor = 0

	const Encoded: { [Reflection]: { Segment } } = {}
	const Snapshots: { [Reflection]: Segment | false } = {}

	for _, Reflection in Dirty :: { any } do
		const Segments = {}

		for _, Op in Reflection._Pending :: { Op } do
			if Op.Dead then
				continue
			end

			const Segment = Helper.Segment(Op.Unreliable, function()
				Helper.Encode(Reflection, Op)
			end)

			if Segment then
				table.insert(Segments, Segment)
			end
		end

		Encoded[Reflection] = Segments
		Reflection._Pending = {}
		Reflection._Index = {}
		Reflection._Dirty = false
		Reflection._Barrier = false
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

		for Reflection in Viewer.Creates do
			local Snapshot = Snapshots[Reflection]
			if Snapshot == nil then
				Snapshot = Helper.Segment(false, function()
					Codec.U8(Frame, Message.Create)
					Codec.Varint(Frame, Reflection.Id)
					Codec.Write(Frame, Reflection.Token)
					Codec.Write(Frame, Reflection.Data)
					Codec.Write(Frame, Reflection._Module)
				end)

				Snapshots[Reflection] = Snapshot or false
			end

			if not Snapshot then
				continue
			end

			Helper.Define(Out, Viewer, Snapshot.Keys)
			Helper.Copy(Out, Extras, Snapshot)
		end

		for Reflection, Segments in Encoded do
			if Viewer.Creates[Reflection] or not Helper.Visible(Reflection, Player) then
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
function Class.Set(Reflection: Reflection, Path: { any }, Value: any)
	Helper.Queue(Reflection, Path, Value, false)
end

function Class.SetUnreliable(Reflection: Reflection, Path: { any }, Value: any)
	Helper.Queue(Reflection, Path, Value, true)
end

function Class.SetValues(Reflection: Reflection, Path: { any }, Values: { [any]: any })
	const Size = #Path

	for Key, Value in Values do
		const Full = table.clone(Path)
		Full[Size + 1] = Key
		Helper.Queue(Reflection, Full, Value, false)
	end
end

function Class.TableInsert(Reflection: Reflection, Path: { any }, Value: any, Index: number?): number
	assert(#Path < 256, "Mirror: path needs fewer than 256 keys")

	const List = Helper.Node(Reflection.Data, Path, #Path)
	const At = Index or #List + 1
	table.insert(List, At, Value)

	Helper.Push(Reflection, {
		Kind = Message.Insert,
		Path = table.clone(Path),
		Index = At,
		Value = Value,
		Unreliable = false,
		Dead = false,
	})

	return At
end

function Class.TableRemove(Reflection: Reflection, Path: { any }, Index: number): any
	assert(#Path < 256, "Mirror: path needs fewer than 256 keys")

	const List = Helper.Node(Reflection.Data, Path, #Path)
	const Value = table.remove(List, Index)

	Helper.Push(Reflection, {
		Kind = Message.Remove,
		Path = table.clone(Path),
		Index = Index,
		Unreliable = false,
		Dead = false,
	})

	return Value
end

function Class.Write(Reflection: any, Name: string, ...: any): ...any
	const Writer = Reflection._Lib and Reflection._Lib[Name]
	assert(Writer, `Mirror: no write function named "{Name}" for {Reflection:Identify()}`)

	const Args = table.pack(...)
	assert(Args.n < 256, "Mirror: writes take fewer than 256 arguments")

	Reflection._Writing += 1
	const Results = table.pack(pcall(Writer, Reflection, ...))
	Reflection._Writing -= 1

	if not Results[1] then
		error(Results[2], 2)
	end

	Helper.Push(Reflection, {
		Kind = Message.Write,
		Path = {},
		Name = Name,
		Args = Args,
		Unreliable = false,
		Dead = false,
	})

	return table.unpack(Results, 2, Results.n)
end

function Class.Identify(Reflection: Reflection): string
	return `[Id:{Reflection.Id};Token:{Reflection.Token}]`
end

function Class.IsActive(Reflection: Reflection): boolean
	return Reflections[Reflection.Id] == Reflection
end

function Class.Replicate(Reflection: any)
	Reflection._Everyone = true

	for Player, Viewer in Viewers do
		if Viewer.Ready then
			Viewer.Creates[Reflection] = true
		end
	end
end

function Class.DontReplicate(Reflection: any)
	if not Reflection._Everyone then
		return
	end

	Reflection._Everyone = false

	for Player, Viewer in Viewers do
		if not Viewer.Ready or Helper.Visible(Reflection, Player) then
			continue
		end

		if Viewer.Creates[Reflection] then
			Viewer.Creates[Reflection] = nil
		else
			table.insert(Viewer.Destroys, Reflection.Id)
		end
	end
end

function Class.Subscribe(Reflection: any, Player: Player)
	const Visible = Helper.Visible(Reflection, Player)
	Reflection._Subscribers[Player] = true

	const Viewer = Viewers[Player]
	if Viewer and Viewer.Ready and not Visible then
		Viewer.Creates[Reflection] = true
	end
end

function Class.Unsubscribe(Reflection: any, Player: Player)
	if not Reflection._Subscribers[Player] then
		return
	end

	Reflection._Subscribers[Player] = nil

	const Viewer = Viewers[Player]
	if Viewer and Viewer.Ready and not Helper.Visible(Reflection, Player) then
		if Viewer.Creates[Reflection] then
			Viewer.Creates[Reflection] = nil
		else
			table.insert(Viewer.Destroys, Reflection.Id)
		end
	end
end

function Class.Destroy(Reflection: any)
	if not Reflections[Reflection.Id] then
		return
	end

	Reflections[Reflection.Id] = nil

	for Player, Viewer in Viewers do
		if not Viewer.Ready or not Helper.Visible(Reflection, Player) then
			continue
		end

		if Viewer.Creates[Reflection] then
			Viewer.Creates[Reflection] = nil
		else
			table.insert(Viewer.Destroys, Reflection.Id)
		end
	end

	if Reflection._Dirty then
		const Index = table.find(Dirty, Reflection)
		if Index then
			table.remove(Dirty, Index)
		end
	end

	Reflection._Everyone = false
	table.clear(Reflection._Subscribers)
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

	for _, Reflection in Reflections :: { [number]: any } do
		Reflection._Subscribers[Player] = nil
	end
end)

for _, Player in Players:GetPlayers() do
	Join(Player)
end

Network.Ready.On(Helper.Ready)
RunService.Heartbeat:Connect(Mirror.Flush)

--> Main <--
return Mirror
