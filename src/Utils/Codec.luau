--!native
--!optimize 2

--> Types <--
export type Writer = {
	Buffer: buffer,
	Cursor: number,
	Extras: { any },
	Intern: (Text: string) -> number,
}

export type Reader = {
	Buffer: buffer,
	Cursor: number,
	Extras: { any },
	Extra: number,
	Keys: { [number]: string },
}

--> Constants <--
const Tag = {
	Nil = 0,
	False = 1,
	True = 2,
	Int = 3,
	Negative = 4,
	Double = 5,
	Single = 6,
	Key = 7,
	String = 8,
	Table = 9,
	Array = 10,
	Vector3 = 11,
	Vector2 = 12,
	CFrame = 13,
	Color3 = 14,
	Color3Bytes = 15,
	Enum = 16,
	UDim = 17,
	UDim2 = 18,
	BrickColor = 19,
	NumberRange = 20,
	Rect = 21,
	Buffer = 22,
	Extra = 23,
}

const Interned = 64
const Depth = 64
const Exact = 2 ^ 53

const Unsendable = {
	["function"] = true,
	["thread"] = true,
	["userdata"] = true,
}

--> Variables <--
const Scratch = buffer.create(4)

--> Main <--
const Codec = {
	Tag = Tag,
}

--> Writer <--
function Codec.Sendable(Value: any): boolean
	return not Unsendable[typeof(Value)]
end

function Codec.Writer(Size: number?, Intern: (Text: string) -> number): Writer
	return {
		Buffer = buffer.create(Size or 256),
		Cursor = 0,
		Extras = {},
		Intern = Intern,
	}
end

function Codec.Reserve(Writer: Writer, Size: number)
	const Need = Writer.Cursor + Size
	local Length = buffer.len(Writer.Buffer)

	if Need <= Length then
		return
	end

	while Length < Need do
		Length *= 2
	end

	const Grown = buffer.create(Length)
	buffer.copy(Grown, 0, Writer.Buffer, 0, Writer.Cursor)
	Writer.Buffer = Grown
end

function Codec.U8(Writer: Writer, Value: number)
	Codec.Reserve(Writer, 1)
	buffer.writeu8(Writer.Buffer, Writer.Cursor, Value)
	Writer.Cursor += 1
end

function Codec.F32(Writer: Writer, Value: number)
	Codec.Reserve(Writer, 4)
	buffer.writef32(Writer.Buffer, Writer.Cursor, Value)
	Writer.Cursor += 4
end

function Codec.Varint(Writer: Writer, Value: number)
	Codec.Reserve(Writer, 8)

	const Buffer = Writer.Buffer
	local Cursor = Writer.Cursor

	while Value >= 128 do
		buffer.writeu8(Buffer, Cursor, Value % 128 + 128)
		Value //= 128
		Cursor += 1
	end

	buffer.writeu8(Buffer, Cursor, Value)
	Writer.Cursor = Cursor + 1
end

function Codec.Text(Writer: Writer, Text: string)
	const Length = #Text
	Codec.Varint(Writer, Length)
	Codec.Reserve(Writer, Length)
	buffer.writestring(Writer.Buffer, Writer.Cursor, Text)
	Writer.Cursor += Length
end

function Codec.Bytes(Writer: Writer, Source: buffer, Offset: number, Length: number)
	Codec.Reserve(Writer, Length)
	buffer.copy(Writer.Buffer, Writer.Cursor, Source, Offset, Length)
	Writer.Cursor += Length
end

function Codec.Write(Writer: Writer, Value: any, Level: number?)
	const Kind = typeof(Value)

	if Value == nil then
		Codec.U8(Writer, Tag.Nil)
	elseif Kind == "boolean" then
		Codec.U8(Writer, if Value then Tag.True else Tag.False)
	elseif Kind == "number" then
		if Value == Value // 1 and math.abs(Value) < Exact then
			Codec.U8(Writer, if Value >= 0 then Tag.Int else Tag.Negative)
			Codec.Varint(Writer, math.abs(Value))
		else
			buffer.writef32(Scratch, 0, Value)
			if buffer.readf32(Scratch, 0) == Value then
				Codec.U8(Writer, Tag.Single)
				Codec.F32(Writer, Value)
			else
				Codec.U8(Writer, Tag.Double)
				Codec.Reserve(Writer, 8)
				buffer.writef64(Writer.Buffer, Writer.Cursor, Value)
				Writer.Cursor += 8
			end
		end
	elseif Kind == "string" then
		if #Value <= Interned then
			Codec.U8(Writer, Tag.Key)
			Codec.Varint(Writer, Writer.Intern(Value))
		else
			Codec.U8(Writer, Tag.String)
			Codec.Text(Writer, Value)
		end
	elseif Kind == "table" then
		const Next = (Level or 0) + 1
		assert(Next <= Depth, "Mirror: tables nested too deep (cycle?)")

		local Count = 0
		for Key, Item in Value do
			if Codec.Sendable(Key) and Codec.Sendable(Item) then
				Count += 1
			end
		end

		if Count > 0 and Count == #Value then
			Codec.U8(Writer, Tag.Array)
			Codec.Varint(Writer, Count)
			for Index = 1, Count do
				Codec.Write(Writer, Value[Index], Next)
			end
		else
			Codec.U8(Writer, Tag.Table)
			Codec.Varint(Writer, Count)
			for Key, Item in Value do
				if Codec.Sendable(Key) and Codec.Sendable(Item) then
					Codec.Write(Writer, Key, Next)
					Codec.Write(Writer, Item, Next)
				end
			end
		end
	elseif Kind == "Vector3" then
		Codec.U8(Writer, Tag.Vector3)
		Codec.F32(Writer, Value.X)
		Codec.F32(Writer, Value.Y)
		Codec.F32(Writer, Value.Z)
	elseif Kind == "Vector2" then
		Codec.U8(Writer, Tag.Vector2)
		Codec.F32(Writer, Value.X)
		Codec.F32(Writer, Value.Y)
	elseif Kind == "CFrame" then
		const Axis, Angle = Value:ToAxisAngle()
		const Rotation = Axis * Angle
		Codec.U8(Writer, Tag.CFrame)
		Codec.F32(Writer, Value.X)
		Codec.F32(Writer, Value.Y)
		Codec.F32(Writer, Value.Z)
		Codec.F32(Writer, Rotation.X)
		Codec.F32(Writer, Rotation.Y)
		Codec.F32(Writer, Rotation.Z)
	elseif Kind == "Color3" then
		const R, G, B = math.round(Value.R * 255), math.round(Value.G * 255), math.round(Value.B * 255)
		if R / 255 == Value.R and G / 255 == Value.G and B / 255 == Value.B then
			Codec.U8(Writer, Tag.Color3Bytes)
			Codec.U8(Writer, R)
			Codec.U8(Writer, G)
			Codec.U8(Writer, B)
		else
			Codec.U8(Writer, Tag.Color3)
			Codec.F32(Writer, Value.R)
			Codec.F32(Writer, Value.G)
			Codec.F32(Writer, Value.B)
		end
	elseif Kind == "EnumItem" then
		Codec.U8(Writer, Tag.Enum)
		Codec.Varint(Writer, Writer.Intern(tostring(Value.EnumType)))
		Codec.Varint(Writer, Value.Value)
	elseif Kind == "UDim" then
		Codec.U8(Writer, Tag.UDim)
		Codec.F32(Writer, Value.Scale)
		Codec.F32(Writer, Value.Offset)
	elseif Kind == "UDim2" then
		Codec.U8(Writer, Tag.UDim2)
		Codec.F32(Writer, Value.X.Scale)
		Codec.F32(Writer, Value.X.Offset)
		Codec.F32(Writer, Value.Y.Scale)
		Codec.F32(Writer, Value.Y.Offset)
	elseif Kind == "BrickColor" then
		Codec.U8(Writer, Tag.BrickColor)
		Codec.Varint(Writer, Value.Number)
	elseif Kind == "NumberRange" then
		Codec.U8(Writer, Tag.NumberRange)
		Codec.F32(Writer, Value.Min)
		Codec.F32(Writer, Value.Max)
	elseif Kind == "Rect" then
		Codec.U8(Writer, Tag.Rect)
		Codec.F32(Writer, Value.Min.X)
		Codec.F32(Writer, Value.Min.Y)
		Codec.F32(Writer, Value.Max.X)
		Codec.F32(Writer, Value.Max.Y)
	elseif Kind == "buffer" then
		const Length = buffer.len(Value)
		Codec.U8(Writer, Tag.Buffer)
		Codec.Varint(Writer, Length)
		Codec.Bytes(Writer, Value, 0, Length)
	else
		if Unsendable[Kind] then
			Codec.U8(Writer, Tag.Nil)
			return
		end

		Codec.U8(Writer, Tag.Extra)
		table.insert(Writer.Extras, Value)
	end
end

--> Reader <--
function Codec.Reader(Buffer: buffer, Extras: { any }?, Keys: { [number]: string }): Reader
	return {
		Buffer = Buffer,
		Cursor = 0,
		Extras = Extras or {},
		Extra = 0,
		Keys = Keys,
	}
end

function Codec.ReadU8(Reader: Reader): number
	const Value = buffer.readu8(Reader.Buffer, Reader.Cursor)
	Reader.Cursor += 1
	return Value
end

function Codec.ReadF32(Reader: Reader): number
	const Value = buffer.readf32(Reader.Buffer, Reader.Cursor)
	Reader.Cursor += 4
	return Value
end

function Codec.ReadVarint(Reader: Reader): number
	const Buffer = Reader.Buffer
	local Cursor = Reader.Cursor
	local Value, Scale = 0, 1

	while true do
		const Byte = buffer.readu8(Buffer, Cursor)
		Cursor += 1
		Value += (Byte % 128) * Scale

		if Byte < 128 then
			break
		end

		Scale *= 128
	end

	Reader.Cursor = Cursor
	return Value
end

function Codec.ReadText(Reader: Reader): string
	const Length = Codec.ReadVarint(Reader)
	const Text = buffer.readstring(Reader.Buffer, Reader.Cursor, Length)
	Reader.Cursor += Length
	return Text
end

function Codec.Read(Reader: Reader): any
	const Kind = Codec.ReadU8(Reader)

	if Kind == Tag.Nil then
		return nil
	elseif Kind == Tag.False then
		return false
	elseif Kind == Tag.True then
		return true
	elseif Kind == Tag.Int then
		return Codec.ReadVarint(Reader)
	elseif Kind == Tag.Negative then
		return -Codec.ReadVarint(Reader)
	elseif Kind == Tag.Single then
		return Codec.ReadF32(Reader)
	elseif Kind == Tag.Double then
		const Value = buffer.readf64(Reader.Buffer, Reader.Cursor)
		Reader.Cursor += 8
		return Value
	elseif Kind == Tag.Key then
		return Reader.Keys[Codec.ReadVarint(Reader)]
	elseif Kind == Tag.String then
		return Codec.ReadText(Reader)
	elseif Kind == Tag.Array then
		const Count = Codec.ReadVarint(Reader)
		const Value = table.create(Count)
		for Index = 1, Count do
			Value[Index] = Codec.Read(Reader)
		end
		return Value
	elseif Kind == Tag.Table then
		const Value = {}
		for _ = 1, Codec.ReadVarint(Reader) do
			const Key = Codec.Read(Reader)
			Value[Key] = Codec.Read(Reader)
		end
		return Value
	elseif Kind == Tag.Vector3 then
		return Vector3.new(Codec.ReadF32(Reader), Codec.ReadF32(Reader), Codec.ReadF32(Reader))
	elseif Kind == Tag.Vector2 then
		return Vector2.new(Codec.ReadF32(Reader), Codec.ReadF32(Reader))
	elseif Kind == Tag.CFrame then
		const Position = Vector3.new(Codec.ReadF32(Reader), Codec.ReadF32(Reader), Codec.ReadF32(Reader))
		const Rotation = Vector3.new(Codec.ReadF32(Reader), Codec.ReadF32(Reader), Codec.ReadF32(Reader))
		const Angle = Rotation.Magnitude

		if Angle < 1e-6 then
			return CFrame.new(Position)
		end

		return CFrame.fromAxisAngle(Rotation / Angle, Angle) + Position
	elseif Kind == Tag.Color3 then
		return Color3.new(Codec.ReadF32(Reader), Codec.ReadF32(Reader), Codec.ReadF32(Reader))
	elseif Kind == Tag.Color3Bytes then
		return Color3.fromRGB(Codec.ReadU8(Reader), Codec.ReadU8(Reader), Codec.ReadU8(Reader))
	elseif Kind == Tag.Enum then
		const Type = Reader.Keys[Codec.ReadVarint(Reader)]
		return (Enum :: any)[Type]:FromValue(Codec.ReadVarint(Reader))
	elseif Kind == Tag.UDim then
		return UDim.new(Codec.ReadF32(Reader), Codec.ReadF32(Reader))
	elseif Kind == Tag.UDim2 then
		return UDim2.new(Codec.ReadF32(Reader), Codec.ReadF32(Reader), Codec.ReadF32(Reader), Codec.ReadF32(Reader))
	elseif Kind == Tag.BrickColor then
		return BrickColor.new(Codec.ReadVarint(Reader))
	elseif Kind == Tag.NumberRange then
		return NumberRange.new(Codec.ReadF32(Reader), Codec.ReadF32(Reader))
	elseif Kind == Tag.Rect then
		return Rect.new(Codec.ReadF32(Reader), Codec.ReadF32(Reader), Codec.ReadF32(Reader), Codec.ReadF32(Reader))
	elseif Kind == Tag.Buffer then
		const Length = Codec.ReadVarint(Reader)
		const Value = buffer.create(Length)
		buffer.copy(Value, 0, Reader.Buffer, Reader.Cursor, Length)
		Reader.Cursor += Length
		return Value
	elseif Kind == Tag.Extra then
		Reader.Extra += 1
		return Reader.Extras[Reader.Extra]
	end

	error(`Mirror: unknown value tag {Kind}`)
end

--> Main <--
return Codec
