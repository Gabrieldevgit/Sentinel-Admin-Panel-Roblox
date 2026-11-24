--!strict
--[[
	Music.lua (HD Admin gap: Music / Pitch / Volume)

		;music <id|off> [volume] [pitch]   (song, play)   server-wide looped track
		;stopmusic                         (nomusic)
		;volume <0-10>                     (vol)
		;pitch <0.1-5>
		;nowplaying                        (np)

	Node environment.music (Admin+ via environment.*). ;music, ;stopmusic,
	;volume and ;pitch are undoable (the previous track / setting comes
	back). See Systems/MusicService.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local MusicService = require(Sentinel:WaitForChild("Systems"):WaitForChild("MusicService"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local function restoreUndo(_ctx: CommandContext, result: any): CommandResult
	local ok, message = MusicService.Restore((result.UndoData or {}).Previous)
	return { Success = ok, Message = message }
end

local function stop(): CommandResult
	local before = MusicService.Snapshot()
	if not MusicService.Stop() then
		return { Success = false, Message = "No music is playing." }
	end
	return { Success = true, Message = "Music stopped.", Undoable = true, UndoData = { Previous = before } } :: any
end

CommandRegistry.Register({
	Name = "music",
	Aliases = { "song", "playmusic" },
	Description = "Plays a looped Roblox audio track for everyone in this server. ';music off' stops it.",
	Usage = "/music id [volume] [pitch]",
	ArgHints = {
		id = { Type = "string", Description = "Audio asset id, or off", Suggestions = { "off" } },
		volume = { Type = "number", Min = 0, Max = 10, Description = "0-10 (default 0.5)", Suggestions = { "0.5", "1", "2" } },
		pitch = { Type = "number", Min = 0.1, Max = 5, Description = "0.1-5 (default 1)", Suggestions = { "0.8", "1", "1.2" } },
	},
	Examples = { "music 1837849285", "music 1837849285 1 1.1", "music off" },
	Permission = "environment.music",
	Category = "Environment",
	Subcategory = "Music",
	Cooldown = 2,
	Log = true,
	Undoable = true,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local raw = ctx.Arguments[1]
		if raw and (raw:lower() == "off" or raw:lower() == "stop") then
			return stop()
		end
		local id = MusicService.ParseId(raw)
		if not id then
			return { Success = false, Message = "Usage: /music <audio id> [volume 0-10] [pitch 0.1-5], or /music off" }
		end
		local volume = tonumber(ctx.Arguments[2])
		local pitch = tonumber(ctx.Arguments[3])
		if ctx.Arguments[2] and not volume then
			return { Success = false, Message = "Volume must be a number (0-10)." }
		end
		if ctx.Arguments[3] and not pitch then
			return { Success = false, Message = "Pitch must be a number (0.1-5)." }
		end
		local before = MusicService.Snapshot()
		local ok, message = MusicService.Play(id, volume, pitch, ctx.Executor.Name)
		return { Success = ok, Message = message, Undoable = ok, UndoData = { Previous = before } } :: any
	end,
	Undo = restoreUndo,
} :: any)

CommandRegistry.Register({
	Name = "stopmusic",
	Aliases = { "nomusic", "musicoff" },
	Description = "Stops the server music.",
	Usage = "/stopmusic",
	Permission = "environment.music",
	Category = "Environment",
	Subcategory = "Music",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = false,
	Execute = function(_ctx: CommandContext): CommandResult
		return stop()
	end,
	Undo = restoreUndo,
} :: any)

local function setter(name: string, aliases: { string }, label: string, usage: string, hint: any, apply: (number) -> (boolean, string))
	CommandRegistry.Register({
		Name = name,
		Aliases = aliases,
		Description = ("Changes the server music %s."):format(label),
		Usage = usage,
		ArgHints = { value = hint },
		Permission = "environment.music",
		Category = "Environment",
		Subcategory = "Music",
		Cooldown = 1,
		Log = true,
		Undoable = true,
		RequiresTarget = false,
		Execute = function(ctx: CommandContext): CommandResult
			local value = tonumber(ctx.Arguments[1])
			if not value then
				return { Success = false, Message = ("Usage: %s"):format(usage) }
			end
			local before = MusicService.Snapshot()
			local ok, message = apply(value)
			return { Success = ok, Message = message, Undoable = ok, UndoData = { Previous = before } } :: any
		end,
		Undo = function(_ctx: CommandContext, result: any): CommandResult
			local prev = (result.UndoData or {}).Previous
			if not prev then
				return { Success = false, Message = "Nothing to undo." }
			end
			local ok, message
			if name == "volume" then
				ok, message = MusicService.SetVolume(prev.Volume)
			else
				ok, message = MusicService.SetPitch(prev.Pitch)
			end
			return { Success = ok, Message = message }
		end,
	} :: any)
end

setter(
	"volume",
	{ "vol", "musicvolume" },
	"volume (0-10)",
	"/volume value",
	{ Type = "number", Min = 0, Max = 10, Description = "0-10", Suggestions = { "0.3", "0.5", "1", "2" } },
	MusicService.SetVolume
)
setter(
	"pitch",
	{ "musicpitch" },
	"pitch / speed (0.1-5)",
	"/pitch value",
	{ Type = "number", Min = 0.1, Max = 5, Description = "0.1-5", Suggestions = { "0.8", "1", "1.2", "1.5" } },
	MusicService.SetPitch
)

CommandRegistry.Register({
	Name = "nowplaying",
	Aliases = { "np", "currentsong" },
	Description = "Shows the server music track, volume and pitch.",
	Usage = "/nowplaying",
	Permission = "environment.music",
	Category = "Environment",
	Subcategory = "Music",
	Cooldown = 1,
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	NoHistory = true,
	Execute = function(_ctx: CommandContext): CommandResult
		local status = MusicService.Status()
		if not status then
			return { Success = true, Message = "No music is playing." }
		end
		return {
			Success = true,
			Message = ("Now playing '%s' (%d) - volume %s, pitch %s, started by %s%s."):format(
				status.Title,
				status.Id,
				tostring(status.Volume),
				tostring(status.Pitch),
				status.By,
				if status.Loaded then "" else " (not loaded)"
			),
		}
	end,
} :: any)

return true
