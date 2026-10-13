# Mirror
Lightweight table replication for Roblox. Mirror keeps a server table in sync with the clients that should see it, sending only what changed as compact buffers over [Blink](https://github.com/1Axen/Blink).

## Features

- **Delta replication**: Only changed paths are sent, batched once per frame
- **Per-player visibility**: Replicate to everyone, or subscribe specific players
- **Buffer encoding**: Numbers, strings, vectors, CFrames, colors and more are packed into a binary format
- **String interning**: Repeated keys and short strings are sent once per player, then referenced by id
- **Unreliable updates**: High-frequency values can skip the reliable queue
- **Change coalescing**: Multiple writes to the same path in one frame send only the latest value
- **Late joiners**: Players receive a full snapshot of everything visible to them when they load in
- **Write functions**: Run the same mutation on the server and every client, sending only the function name and arguments
- **Familiar API**: `Set`, `SetValues`, `TableInsert`, `TableRemove`, `Write`, `OnSet` and `FromId` work like Replica's, so most projects port with a few renames

## Installation

### Wally
Add Mirror to your `wally.toml`:
```toml
[dependencies]
Mirror = "synvasive/mirror@1.0.0"
```
Then run:
```bash
wally install
```

### Manual
Copy the `src` folder into `ReplicatedStorage` and require `init.luau` as `Mirror`.

Mirror must be required on the client for anything to replicate. The client tells the server it's ready when the module loads.

## Usage
### Server

```luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Mirror = require(ReplicatedStorage.Mirror)

local Round = Mirror.new("Round", {
	State = "Intermission",
	Time = 30,
})

Round:Replicate()
Round:Set({ "State" }, "Playing")
Round:SetUnreliable({ "Time" }, 29)

Players.PlayerAdded:Connect(function(Player)
	local Inventory = Mirror.new("Inventory", {
		Owner = Player.UserId,
		Items = {},
	})

	Inventory:Subscribe(Player)
	Inventory:Set({ "Items", 1 }, { Name = "Iron Sword", Damage = 10 })
end)
```

### Client

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Mirror = require(ReplicatedStorage.Mirror)

Mirror.OnNew("Round", function(Round)
	print(Round.Data.State)

	Round:OnChange(function(Path, Value, Old)
		print(table.concat(Path, "/"), Old, "->", Value)
	end)
end)
```

## API

### Server

#### `Mirror.new(Token, Data?, WriteLib?)`
Creates a reflection. `Token` is the name clients listen for with `Mirror.OnNew`. `Data` becomes the reflection's table. Read it through `Reflection.Data`, but write through the methods below so changes replicate. `WriteLib` is an optional ModuleScript of write functions, see [Write Functions](#write-functions).

| Method | Description |
|---|---|
| `Reflection:Set(Path, Value)` | Sets a value at `Path` (an array of keys) and replicates it reliably |
| `Reflection:SetUnreliable(Path, Value)` | Same as `Set`, but sent unreliably when possible. Use it for values where only the latest matters |
| `Reflection:SetValues(Path, Values)` | Sets every key in `Values` inside the table at `Path` |
| `Reflection:TableInsert(Path, Value, Index?)` | Inserts into the array at `Path` and returns the index it was inserted at |
| `Reflection:TableRemove(Path, Index)` | Removes from the array at `Path` and returns the removed value |
| `Reflection:Write(Name, ...)` | Runs a write function on the server and every client, and returns its results |
| `Reflection:Replicate()` | Makes the reflection visible to every player |
| `Reflection:DontReplicate()` | Undoes `Replicate`, so only subscribed players keep seeing the reflection |
| `Reflection:Subscribe(Player)` | Makes the reflection visible to one player |
| `Reflection:Unsubscribe(Player)` | Hides the reflection from a subscribed player |
| `Reflection:Identify()` | Returns a readable `[Id:1;Token:Round]` string for debugging |
| `Reflection:IsActive()` | Returns `false` once the reflection is destroyed |
| `Reflection:Destroy()` | Removes the reflection from every client |

#### `Mirror.FromId(Id)`
Returns the reflection with that id, if it still exists.

#### `Mirror.Flush()`
Sends all pending changes. Runs automatically every `Heartbeat`.

### Client

#### `Mirror.OnNew(Token, Callback)`
Calls `Callback(Reflection)` for every existing and future reflection with that token. Returns a function that disconnects the listener.

#### `Mirror.FromId(Id)`
Returns the reflection with that id, if the client can see it.

| Member | Description |
|---|---|
| `Reflection.Id` | Server-assigned id |
| `Reflection.Token` | Token the reflection was created with |
| `Reflection.Data` | The replicated table, kept up to date |
| `Reflection:OnChange(Callback)` | Calls `Callback(Path, Value, Old)` after each change. Returns a disconnect function |
| `Reflection:OnSet(Path, Callback)` | Calls `Callback(Value, Old)` when exactly `Path` changes. Returns a disconnect function |
| `Reflection:OnWrite(Name, Callback)` | Calls `Callback(...)` with the arguments after a write function runs. Returns a disconnect function |
| `Reflection:OnDestroy(Callback)` | Calls `Callback()` when the reflection is destroyed or hidden. Returns a disconnect function |
| `Reflection:Identify()`, `Reflection:IsActive()` | Same as on the server |

Client reflections also have `Set`, `SetValues`, `TableInsert`, `TableRemove` and `Write`. They only change the local copy and exist so write functions can run on the client.

`OnChange` fires for every kind of change. For `TableInsert` and `TableRemove`, `Path` ends with the index, `Value` is the inserted value and `Old` is the removed value.

## Write Functions

A write function changes a reflection the same way on the server and on every client, so only its name and arguments are sent. Put them in a ModuleScript the client can see, such as one in `ReplicatedStorage`:

```luau
return {
	Give = function(Inventory, Item)
		Inventory:TableInsert({ "Items" }, Item)
		Inventory:Set({ "Count" }, #Inventory.Data.Items)
	end,
}
```

```luau
local Inventory = Mirror.new("Inventory", { Items = {}, Count = 0 }, ReplicatedStorage.InventoryWrites)
Inventory:Write("Give", "Iron Sword")
```

Write functions must only depend on the reflection's data and their arguments, so every client reaches the same result as the server. Changes made inside them are not sent separately.

## Supported Values

`nil`, `boolean`, `number`, `string`, `table` (arrays and dictionaries, nested up to 64 levels), `Vector3`, `Vector2`, `CFrame`, `Color3`, `EnumItem`, `UDim`, `UDim2`, `BrickColor`, `NumberRange`, `Rect` and `buffer` are encoded into the buffer. Other values, such as Instances, are passed alongside it using Roblox's own serialization. Functions and threads are skipped.

## Unreliable Updates

`SetUnreliable` sends through an `UnreliableRemoteEvent`, so a change may be dropped or arrive out of order. Mirror falls back to the reliable channel when a change is larger than 900 bytes, uses a key the player hasn't received yet, or shares a frame with a `TableInsert`, `TableRemove` or `Write` on the same reflection. Avoid `SetUnreliable` on paths inside arrays you insert into or remove from, since a late unreliable change could land on a shifted index.

## Networking

The networking layer in `src/Network` is generated by Blink from [`Mirror.blink`](Mirror.blink). To regenerate it:
```bash
blink Mirror.blink -y
```

## Examples

Working examples for a public round state and private per-player inventories can be found in [`src/Examples`](src/Examples).

## License

MIT, see [LICENSE](LICENSE)
