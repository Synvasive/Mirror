--!native
--!optimize 2

--> Dependencies <--
const Codec = require "../Utils/Codec"
const Message = require "../Utils/Message"
const Network = require "../Network/Client"

--> Types <--
type Changed = (Path: { any }, Value: any, Old: any) -> ()

export type Replica = {
	Id: number,
	Token: string,
	Data: { [any]: any },

	OnChange: (self: Replica, Callback: Changed) -> () -> (),
	OnDestroy: (self: Replica, Callback: () -> ()) -> () -> (),
}

--> Variables <--
const Keys: { [number]: string } = {}
const Replicas: { [number]: Replica } = {}
const Listeners: { [string]: { (Replica: Replica) -> () } } = {}

--> Main <--
const Mirror = {}
const Class = {}
Class.__index = Class

const Helper = {}

--> Helper <--
function Helper.Call(Callback: (...any) -> (), ...: any)
	const Success, Result = pcall(Callback, ...)
	if not Success then
		task.spawn(error, Result, 0)
	end
end

function Helper.Remove(List: { any }, Callback: any): () -> ()
	return function()
		const Index = table.find(List, Callback)
		if Index then
			table.remove(List, Index)
		end
	end
end

function Helper.Apply(Replica: any, Path: { any }, Value: any)
	local Node = Replica.Data
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

	const Old = Node[Path[Last]]
	Node[Path[Last]] = Value

	for _, Callback in table.clone(Replica._Changed) do
		Helper.Call(Callback, Path, Value, Old)
	end
end

function Helper.Receive(Payload: buffer, Extras: { any }?)
	const Reader = Codec.Reader(Payload, Extras, Keys)
	const Length = buffer.len(Payload)

	while Reader.Cursor < Length do
		const Kind = Codec.ReadU8(Reader)

		if Kind == Message.Key then
			const Id = Codec.ReadVarint(Reader)
			Keys[Id] = Codec.ReadText(Reader)
		elseif Kind == Message.Create then
			const Id = Codec.ReadVarint(Reader)
			const Token = Codec.Read(Reader)
			const Data = Codec.Read(Reader)

			const Replica = setmetatable({
				Id = Id,
				Token = Token,
				Data = if type(Data) == "table" then Data else {},

				_Changed = {},
				_Destroyed = {},
			}, Class) :: any

			Replicas[Id] = Replica

			for _, Callback in table.clone(Listeners[Token] or {}) do
				Helper.Call(Callback, Replica)
			end
		elseif Kind == Message.Set then
			const Id = Codec.ReadVarint(Reader)
			const Size = Codec.ReadU8(Reader)
			const Path = table.create(Size)

			for Index = 1, Size do
				Path[Index] = Codec.Read(Reader)
			end

			const Value = Codec.Read(Reader)
			const Replica = Replicas[Id]

			if Replica then
				Helper.Apply(Replica, Path, Value)
			end
		elseif Kind == Message.Destroy then
			const Id = Codec.ReadVarint(Reader)
			const Replica = Replicas[Id] :: any

			if Replica then
				Replicas[Id] = nil

				for _, Callback in table.clone(Replica._Destroyed) do
					Helper.Call(Callback)
				end

				table.clear(Replica._Changed)
				table.clear(Replica._Destroyed)
			end
		else
			error(`Mirror: unknown message {Kind}`)
		end
	end
end

--> Methods <--
function Mirror.OnNew(Token: string, Callback: (Replica: Replica) -> ()): () -> ()
	const List = Listeners[Token] or {}
	Listeners[Token] = List
	table.insert(List, Callback)

	for _, Replica in Replicas do
		if Replica.Token == Token then
			task.spawn(Callback, Replica)
		end
	end

	return Helper.Remove(List, Callback)
end

function Mirror.Get(Id: number): Replica?
	return Replicas[Id]
end

--> Class <--
function Class.OnChange(Replica: any, Callback: Changed): () -> ()
	table.insert(Replica._Changed, Callback)
	return Helper.Remove(Replica._Changed, Callback)
end

function Class.OnDestroy(Replica: any, Callback: () -> ()): () -> ()
	table.insert(Replica._Destroyed, Callback)
	return Helper.Remove(Replica._Destroyed, Callback)
end

--> Setup <--
Network.Reliable.On(Helper.Receive)
Network.Unreliable.On(Helper.Receive)
Network.Ready.Fire(nil)
Network.StepReplication()

--> Main <--
return Mirror
