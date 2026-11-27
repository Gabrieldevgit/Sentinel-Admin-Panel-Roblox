--!strict
--[[
	Note.lua

	Purpose:
		Registers "/note" and "/notes". Staff notes are freeform,
		non-punitive records ("keeps a smurf account, watch for alt
		evasion") distinct from Warnings (which are punitive and drive
		escalation). Kept as its own DataStore so notes and warnings never
		get confused in a search/audit view later.

	Dependencies:
		Types.lua (Shared)
		CommandRegistry.lua (Core)
--]]

local DataStoreService = game:GetService("DataStoreService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local CommandRegistry = require(script.Parent.Parent.Parent:WaitForChild("Core"):WaitForChild("CommandRegistry"))

local NoteStore = DataStoreService:GetDataStore("Sentinel_StaffNotes_v1")

export type NoteRecord = {
	AddedBy: string,
	Text: string,
	Timestamp: number,
	Kind: string?, -- nil = general staff note, "Investigation" (W15)
}

local function getNotes(userId: number): { NoteRecord }
	local ok, stored = pcall(function()
		return NoteStore:GetAsync(tostring(userId))
	end)
	return if ok and stored then stored else {}
end

local MAX_NOTES = 200

local function addNote(userId: number, addedBy: string, text: string, kind: string?)
	local notes = getNotes(userId)
	table.insert(notes, { AddedBy = addedBy, Text = text, Timestamp = os.time(), Kind = kind })
	while #notes > MAX_NOTES do
		table.remove(notes, 1)
	end
	local ok, err = pcall(function()
		NoteStore:SetAsync(tostring(userId), notes)
	end)
	if not ok then
		warn(("[Sentinel.Note] failed to persist note: %s"):format(tostring(err)))
	end
end

-- Exported (rather than the bare `true` most Commands/** files return) so
-- the Player Explorer's Notes tab (Phase 7F) can read notes without a
-- duplicate DataStore-reading implementation in UIBridge.lua — same
-- pattern Ban.lua already uses for GetActiveBan.
local NoteCommand = {
	GetNotes = getNotes,
	AddNote = addNote, -- AntiCheat: Review Queue "Add note"
}
require(script.Parent.Parent.Parent:WaitForChild("Systems"):WaitForChild("PlayerProfileService")).SetProviders({
	GetNotes = getNotes, -- W13 offline profiles
})

CommandRegistry.Register({
	Name = "note",
	Aliases = { "n" },
	Description = "Adds a staff note to a player's profile.",
	Usage = "/note target text",
	Permission = "moderation.notes",
	Category = "Moderation",
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local target = ctx.Targets[1]
		if not target then
			return { Success = false, Message = "No target found." }
		end
		local text = table.concat(ctx.Arguments, " ")
		if text == "" then
			return { Success = false, Message = "Note text cannot be empty." }
		end
		addNote(target.UserId, ctx.Executor.Name, text)
		return { Success = true, Message = ("Note added for %s."):format(target.Name) }
	end,
})

-- W15: investigation notes - kept with the staff notes (same store, same
-- node) but tagged, so the Player Explorer can show an investigation trail.
CommandRegistry.Register({
	Name = "investigate",
	Aliases = { "inote", "investigation" },
	Description = "Saves an investigation note on a player (shown on the Players page Notes tab, tagged Investigation).",
	Usage = "/investigate target text...",
	Permission = "moderation.notes",
	Category = "Moderation",
	TargetProtection = false, -- a private record, not an action on the player
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	Examples = { "investigate Player1 Teleports between plots, check speed logs" },
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local target = ctx.Targets[1]
		if not target then
			return { Success = false, Message = "No target found." }
		end
		local text = table.concat(ctx.Arguments, " ")
		if text == "" then
			return { Success = false, Message = "Investigation note text cannot be empty." }
		end
		addNote(target.UserId, ctx.Executor.Name, text, "Investigation")
		return { Success = true, Message = ("Investigation note saved for %s."):format(target.Name) }
	end,
})

CommandRegistry.Register({
	Name = "notes",
	TargetProtection = false, -- harmless/read-only: allowed on higher ranks
	Aliases = {},
	Description = "Lists staff notes for a player.",
	Usage = "/notes target",
	Permission = "moderation.notes",
	Category = "Moderation",
	Log = false,
	Undoable = false,
	RequiresTarget = true,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local target = ctx.Targets[1]
		if not target then
			return { Success = false, Message = "No target found." }
		end
		local notes = getNotes(target.UserId)
		if #notes == 0 then
			return { Success = true, Message = ("No notes on %s."):format(target.Name) }
		end
		local lines = {}
		for _, note in ipairs(notes) do
			table.insert(lines, ("[%s%s] %s"):format(if note.Kind then note.Kind .. " - " else "", note.AddedBy, note.Text))
		end
		return { Success = true, Message = table.concat(lines, " | ") }
	end,
})

return NoteCommand
