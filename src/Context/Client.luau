--!native
--!optimize 2

--> Dependencies <--
const Codec = require "../Utils/Codec"
const Message = require "../Utils/Message"
const Network = require "../Network/Client"

--> Types <--
type Changed = (Path: { any }, Value: any, Old: any) -> ()

export type Reflection = {
	Id: number,
	Token: string,
	Data: { [any]: any },

	Set: (self: Reflection, Path: { any }, Value: any) -> (),
	SetValues: (self: Reflection, Path: { any }, Values: { [any]: any }) -> (),
	TableInsert: (self: Reflection, Path: { any }, Value: any, Index: number?) -> number,
	TableRemove: (self: Reflection, Path: { any }, Index: number) -> any,
	Write: (self: Reflection, Name: string, ...any) -> (),

	OnChange: (self: Reflection, Callback: Changed) -> () -> (),
	OnSet: (self: Reflection, Path: { any }, Callback: (Value: any, Old: any) -> ()) -> () -> (),
	OnWrite: (self: Reflection, Name: string, Callback: (...any) -> ()) -> () -> (),
	OnDestroy: (self: Reflection, Callback: () -> ()) -> () -> (),

	Identify: (self: Reflection) -> string,
	IsActive: (self: Reflection) -> boolean,
}

--> Variables <--
const Keys: { [number]: string } = {}
const Reflections: { [number]: Reflection } = {}
const Listeners: { [string]: { (Reflection: Reflection) -> () } } = {}

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

function Helper.Remove(List: { any }, Entry: any): () -> ()
	return function()
		const Index = table.find(List, Entry)
		if Index then
			table.remove(List, Index)
		end
	end
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

function Helper.Same(A: { any }, B: { any }): boolean
	if #A ~= #B then
		return false
	end

	for Index, Key in A do
		if B[Index] ~= Key then
			return false
		end
	end

	return true
end

function Helper.Changed(Reflection: any, Path: { any }, Value: any, Old: any)
	for _, Callback in table.clone(Reflection._Changed) do
		Helper.Call(Callback, Path, Value, Old)
	end

	for _, Entry in table.clone(Reflection._Sets) do
		if Helper.Same(Entry.Path, Path) then
			Helper.Call(Entry.Callback, Value, Old)
		end
	end
end

function Helper.Set(Reflection: any, Path: { any }, Value: any)
	const Node = Helper.Node(Reflection.Data, Path, #Path - 1)
	const Key = Path[#Path]
	const Old = Node[Key]

	Node[Key] = Value
	Helper.Changed(Reflection, Path, Value, Old)
end

function Helper.Insert(Reflection: any, Path: { any }, Value: any, Index: number?): number
	const List = Helper.Node(Reflection.Data, Path, #Path)
	const At = Index or #List + 1
	table.insert(List, At, Value)

	const Full = table.clone(Path)
	table.insert(Full, At)
	Helper.Changed(Reflection, Full, Value, nil)

	return At
end

function Helper.Take(Reflection: any, Path: { any }, Index: number): any
	const List = Helper.Node(Reflection.Data, Path, #Path)
	const Value = table.remove(List, Index)

	const Full = table.clone(Path)
	table.insert(Full, Index)
	Helper.Changed(Reflection, Full, nil, Value)

	return Value
end

function Helper.Write(Reflection: any, Name: string, Args: { any })
	if Reflection._Lib == nil then
		Reflection._Lib = if Reflection._Module then require(Reflection._Module) :: any else false
	end

	const Writer = Reflection._Lib and Reflection._Lib[Name]
	if not Writer then
		warn(`Mirror: no write function named "{Name}" for {Reflection:Identify()}`)
		return
	end

	Helper.Call(Writer, Reflection, table.unpack(Args, 1, Args.n))

	for _, Entry in table.clone(Reflection._Writes) do
		if Entry.Name == Name then
			Helper.Call(Entry.Callback, table.unpack(Args, 1, Args.n))
		end
	end
end

function Helper.ReadPath(Reader: Codec.Reader): { any }
	const Size = Codec.ReadU8(Reader)
	const Path = table.create(Size)

	for Index = 1, Size do
		Path[Index] = Codec.Read(Reader)
	end

	return Path
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
			const Module = Codec.Read(Reader)

			const Reflection = setmetatable({
				Id = Id,
				Token = Token,
				Data = if type(Data) == "table" then Data else {},

				_Module = Module,
				_Lib = nil,

				_Changed = {},
				_Sets = {},
				_Writes = {},
				_Destroyed = {},
			}, Class) :: any

			Reflections[Id] = Reflection

			for _, Callback in table.clone(Listeners[Token] or {}) do
				Helper.Call(Callback, Reflection)
			end
		elseif Kind == Message.Set then
			const Reflection = Reflections[Codec.ReadVarint(Reader)]
			const Path = Helper.ReadPath(Reader)
			const Value = Codec.Read(Reader)

			if Reflection then
				Helper.Set(Reflection, Path, Value)
			end
		elseif Kind == Message.Insert then
			const Reflection = Reflections[Codec.ReadVarint(Reader)]
			const Path = Helper.ReadPath(Reader)
			const Index = Codec.ReadVarint(Reader)
			const Value = Codec.Read(Reader)

			if Reflection then
				Helper.Insert(Reflection, Path, Value, Index)
			end
		elseif Kind == Message.Remove then
			const Reflection = Reflections[Codec.ReadVarint(Reader)]
			const Path = Helper.ReadPath(Reader)
			const Index = Codec.ReadVarint(Reader)

			if Reflection then
				Helper.Take(Reflection, Path, Index)
			end
		elseif Kind == Message.Write then
			const Reflection = Reflections[Codec.ReadVarint(Reader)]
			const Name = Codec.Read(Reader)
			const Count = Codec.ReadU8(Reader)
			const Args = table.create(Count) :: { any }

			for Index = 1, Count do
				Args[Index] = Codec.Read(Reader)
			end

			Args.n = Count

			if Reflection then
				Helper.Write(Reflection, Name, Args)
			end
		elseif Kind == Message.Destroy then
			const Id = Codec.ReadVarint(Reader)
			const Reflection = Reflections[Id] :: any

			if Reflection then
				Reflections[Id] = nil

				for _, Callback in table.clone(Reflection._Destroyed) do
					Helper.Call(Callback)
				end

				table.clear(Reflection._Changed)
				table.clear(Reflection._Sets)
				table.clear(Reflection._Writes)
				table.clear(Reflection._Destroyed)
			end
		else
			error(`Mirror: unknown message {Kind}`)
		end
	end
end

--> Methods <--
function Mirror.OnNew(Token: string, Callback: (Reflection: Reflection) -> ()): () -> ()
	const List = Listeners[Token] or {}
	Listeners[Token] = List
	table.insert(List, Callback)

	for _, Reflection in Reflections do
		if Reflection.Token == Token then
			task.spawn(Callback, Reflection)
		end
	end

	return Helper.Remove(List, Callback)
end

function Mirror.FromId(Id: number): Reflection?
	return Reflections[Id]
end

Mirror.Get = Mirror.FromId

--> Class <--
function Class.Set(Reflection: any, Path: { any }, Value: any)
	Helper.Set(Reflection, Path, Value)
end

function Class.SetValues(Reflection: any, Path: { any }, Values: { [any]: any })
	const Size = #Path

	for Key, Value in Values do
		const Full = table.clone(Path)
		Full[Size + 1] = Key
		Helper.Set(Reflection, Full, Value)
	end
end

function Class.TableInsert(Reflection: any, Path: { any }, Value: any, Index: number?): number
	return Helper.Insert(Reflection, Path, Value, Index)
end

function Class.TableRemove(Reflection: any, Path: { any }, Index: number): any
	return Helper.Take(Reflection, Path, Index)
end

function Class.Write(Reflection: any, Name: string, ...: any)
	Helper.Write(Reflection, Name, table.pack(...))
end

function Class.OnChange(Reflection: any, Callback: Changed): () -> ()
	table.insert(Reflection._Changed, Callback)
	return Helper.Remove(Reflection._Changed, Callback)
end

function Class.OnSet(Reflection: any, Path: { any }, Callback: (Value: any, Old: any) -> ()): () -> ()
	const Entry = { Path = table.clone(Path), Callback = Callback }
	table.insert(Reflection._Sets, Entry)
	return Helper.Remove(Reflection._Sets, Entry)
end

function Class.OnWrite(Reflection: any, Name: string, Callback: (...any) -> ()): () -> ()
	const Entry = { Name = Name, Callback = Callback }
	table.insert(Reflection._Writes, Entry)
	return Helper.Remove(Reflection._Writes, Entry)
end

function Class.OnDestroy(Reflection: any, Callback: () -> ()): () -> ()
	table.insert(Reflection._Destroyed, Callback)
	return Helper.Remove(Reflection._Destroyed, Callback)
end

function Class.Identify(Reflection: Reflection): string
	return `[Id:{Reflection.Id};Token:{Reflection.Token}]`
end

function Class.IsActive(Reflection: Reflection): boolean
	return Reflections[Reflection.Id] == Reflection
end

--> Setup <--
Network.Reliable.On(Helper.Receive)
Network.Unreliable.On(Helper.Receive)
Network.Ready.Fire(nil)
Network.StepReplication()

--> Main <--
return Mirror
