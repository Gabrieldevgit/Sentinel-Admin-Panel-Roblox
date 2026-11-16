--!strict
--[[
	CommandHistory.lua (W07)

	Purpose:
		Per-player command result history plus the undo / redo stacks.
		CommandProcessor records every link it dispatches; ;history and the
		Library page read it back, ;undo / ;redo use the stacks.

	What can be undone:
		A successful command whose definition has
			- Undo = function(ctx, result) ... (custom, uses result.UndoData), or
			- Inverse = "<command>" (run with the same targets), or
			- an entry in INVERSES below (defaults for existing commands),
		and whose result didn't say Undoable = false.

	History lives in server memory (cleared when the player leaves); the
	last commands a player typed are persisted separately by
	Systems/CommandLibraryService ("Recent").

	Public API:
		CommandHistory.Record(executor, def, ctx, result, source) -> id
		CommandHistory.Get(player, { Search?, Limit?, Before? }) -> { entry }
		CommandHistory.InverseFor(def) -> (inverseName?, keepArguments)
		CommandHistory.CanUndo(def, result) -> boolean
		CommandHistory.PeekUndo(player) / PeekRedo(player) -> record?
		CommandHistory.MarkUndone(player, record) / MarkRedone(player, record)
		CommandHistory.DropUndo(player, record) / DropRedo(player, record)
		CommandHistory.Counts(player) -> (undo, redo)
--]]

local Players = game:GetService("Players")

local CommandHistory = {}

local MAX_ENTRIES = 200
local MAX_STACK = 30

-- Default inverses for commands that predate W07. `true` = keep the
-- modifier and arguments (amounts, item names); otherwise the inverse
-- runs on the same targets with no arguments.
local INVERSES: { [string]: { any } } = {
	freeze = { "unfreeze" }, unfreeze = { "freeze" },
	jail = { "unjail" }, unjail = { "jail" },
	mute = { "unmute" }, unmute = { "mute" },
	blacklist = { "unblacklist" }, unblacklist = { "blacklist" },
	whitelist = { "unwhitelist" }, unwhitelist = { "whitelist" },
	god = { "ungod" }, ungod = { "god" },
	fly = { "unfly" }, unfly = { "fly" },
	noclip = { "clip" }, clip = { "noclip" },
	spin = { "unspin" }, unspin = { "spin" },
	stun = { "unstun" }, unstun = { "stun" },
	ragdoll = { "unragdoll" }, unragdoll = { "ragdoll" },
	forcefield = { "unforcefield" }, unforcefield = { "forcefield" },
	invisible = { "visible" }, visible = { "invisible" },
	fire = { "unfire" }, unfire = { "fire" },
	smoke = { "unsmoke" }, unsmoke = { "smoke" },
	sparkles = { "unsparkles" }, unsparkles = { "sparkles" },
	glow = { "unglow" }, unglow = { "glow" },
	blind = { "unblind" }, unblind = { "blind" },
	lockserver = { "unlockserver" }, unlockserver = { "lockserver" },
	speed = { "resetspeed" },
	jumppower = { "resetjump" },
	bighead = { "normalhead" },
	smallhead = { "normalhead" },
	givecurrency = { "removecurrency", true }, removecurrency = { "givecurrency", true },
	addxp = { "removexp", true }, removexp = { "addxp", true },
	giveitem = { "removeitem", true }, removeitem = { "giveitem", true },
}

export type Record = {
	Id: number,
	Time: number,
	Command: string,
	Input: string,
	Source: string,
	Success: boolean,
	Message: string?,
	DurationMs: number?,
	TargetNames: { string },
	Undoable: boolean,
	State: string, -- "done" | "undone"
	-- server-only replay data
	Def: any,
	Targets: { Player },
	Modifier: string?,
	Arguments: { string },
	Result: any,
}

type PlayerHistory = { Entries: { Record }, Undo: { Record }, Redo: { Record } }

local histories: { [number]: PlayerHistory } = {}
local nextId = 0

local function historyFor(userId: number): PlayerHistory
	local h = histories[userId]
	if not h then
		h = { Entries = {}, Undo = {}, Redo = {} }
		histories[userId] = h
	end
	return h
end

Players.PlayerRemoving:Connect(function(player: Player)
	histories[player.UserId] = nil
end)

function CommandHistory.InverseFor(def: any): (string?, boolean)
	if type(def.Inverse) == "string" then
		return def.Inverse, def.InverseKeepsArguments == true
	end
	local entry = INVERSES[def.Name]
	if entry then
		return entry[1], entry[2] == true
	end
	return nil, false
end

function CommandHistory.CanUndo(def: any, result: any): boolean
	if not result.Success or result.Undoable == false or result.Cancelled then
		return false
	end
	return type(def.Undo) == "function" or (CommandHistory.InverseFor(def)) ~= nil
end

local function push(stack: { Record }, record: Record)
	table.insert(stack, record)
	if #stack > MAX_STACK then
		table.remove(stack, 1)
	end
end

-- source: "chat" | "panel" | "undo" | "redo" | ...
function CommandHistory.Record(executor: Player, def: any, ctx: any, result: any, source: string?): number
	if def.NoHistory then
		return 0
	end
	local h = historyFor(executor.UserId)
	nextId += 1
	local names = {}
	for _, p in ipairs(ctx.Targets or {}) do
		table.insert(names, p.Name)
	end
	local src = source or "panel"
	local undoable = src ~= "undo" and CommandHistory.CanUndo(def, result)
	local record: Record = {
		Id = nextId,
		Time = os.time(),
		Command = def.Name,
		Input = ctx.RawInput or def.Name,
		Source = src,
		Success = result.Success == true,
		Message = result.Message,
		DurationMs = result.DurationMs,
		TargetNames = names,
		Undoable = undoable,
		State = "done",
		Def = def,
		Targets = table.clone(ctx.Targets or {}),
		Modifier = ctx.Modifier,
		Arguments = table.clone(ctx.Arguments or {}),
		Result = result,
	}
	table.insert(h.Entries, record)
	if #h.Entries > MAX_ENTRIES then
		table.remove(h.Entries, 1)
	end
	if undoable then
		push(h.Undo, record)
		if src ~= "redo" then
			table.clear(h.Redo) -- a new action invalidates the redo stack
		end
	end
	result.HistoryId = record.Id
	return record.Id
end

local function lowerContains(haystack: string?, needle: string): boolean
	return haystack ~= nil and string.find(haystack:lower(), needle, 1, true) ~= nil
end

-- Client-safe copies, newest first.
function CommandHistory.Get(player: Player, options: any?): { any }
	local h = historyFor(player.UserId)
	local opts = options or {}
	local search = if type(opts.Search) == "string" and opts.Search ~= "" then opts.Search:lower() else nil
	local limit = if type(opts.Limit) == "number" then math.clamp(math.floor(opts.Limit), 1, MAX_ENTRIES) else 50
	local failedOnly = opts.FailedOnly == true
	local out = {}
	for i = #h.Entries, 1, -1 do
		local r = h.Entries[i]
		local match = (not search)
			or lowerContains(r.Input, search)
			or lowerContains(r.Command, search)
			or lowerContains(r.Message, search)
			or lowerContains(table.concat(r.TargetNames, " "), search)
		if match and (not failedOnly or not r.Success) then
			table.insert(out, {
				Id = r.Id,
				Time = r.Time,
				Command = r.Command,
				Input = r.Input,
				Source = r.Source,
				Success = r.Success,
				Message = r.Message,
				DurationMs = r.DurationMs,
				Targets = r.TargetNames,
				Undoable = r.Undoable and r.State == "done",
				State = r.State,
			})
			if #out >= limit then
				break
			end
		end
	end
	return out
end

function CommandHistory.PeekUndo(player: Player): Record?
	local stack = historyFor(player.UserId).Undo
	return stack[#stack]
end

function CommandHistory.PeekRedo(player: Player): Record?
	local stack = historyFor(player.UserId).Redo
	return stack[#stack]
end

local function remove(stack: { Record }, record: Record)
	local i = table.find(stack, record)
	if i then
		table.remove(stack, i)
	end
end

function CommandHistory.MarkUndone(player: Player, record: Record)
	local h = historyFor(player.UserId)
	remove(h.Undo, record)
	record.State = "undone"
	push(h.Redo, record)
end

function CommandHistory.MarkRedone(player: Player, record: Record)
	remove(historyFor(player.UserId).Redo, record)
end

function CommandHistory.DropUndo(player: Player, record: Record)
	remove(historyFor(player.UserId).Undo, record)
end

function CommandHistory.DropRedo(player: Player, record: Record)
	remove(historyFor(player.UserId).Redo, record)
end

function CommandHistory.Counts(player: Player): (number, number)
	local h = historyFor(player.UserId)
	return #h.Undo, #h.Redo
end

-- Undo a specific history entry (Library page "Undo" button): only the
-- newest undoable entry can be undone, to keep state consistent.
function CommandHistory.IsTopOfUndo(player: Player, id: number): boolean
	local top = CommandHistory.PeekUndo(player)
	return top ~= nil and top.Id == id
end

return CommandHistory
