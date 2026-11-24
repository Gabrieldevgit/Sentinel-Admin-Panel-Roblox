--!strict
--[[
	ChatTags.lua (HD Admin gap: ChatTag / ChatTagColor)

		;chattag <players> <text...> [color=<name|#hex|r,g,b>]   (tag)
		;unchattag <players>                                     (removechattag, untag)
		;chattags [on|off]   rank tags in chat on / off for every server
		                     (view = panel.open, change = config.edit)

	A custom tag replaces the rank tag for this server until the player
	leaves or ;unchattag. With no custom tag, players show their top
	Sentinel rank in the rank's colour (Systems/ChatTagService).
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Systems = Sentinel:WaitForChild("Systems")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local ChatTagService = require(Systems:WaitForChild("ChatTagService"))
local ConfigService = require(Systems:WaitForChild("ConfigService"))
local TextFilterService = require(Systems:WaitForChild("TextFilterService"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

CommandRegistry.Register({
	Name = "chattag",
	Aliases = { "tag", "settag" },
	Description = "Puts a tag before a player's name in chat (this server, until they leave). Add color=<name|#hex|r,g,b> to colour it. Replaces their rank tag.",
	Usage = "/chattag target text...",
	ArgHints = {
		text = { Type = "text", Description = "Tag text (max 20 characters), optionally ending with color=red / color=#ff8800" },
	},
	Permission = "player.chattag",
	Category = "Player",
	Subcategory = "Chat",
	Cooldown = 1,
	Log = true,
	Undoable = true,
	RequiresTarget = true,
	DefaultSelf = false,
	Examples = { "chattag me Builder", "chattag Player1 Event Winner color=gold", "chattag others Guest color=#88ccff" },
	Execute = function(ctx: CommandContext): CommandResult
		local words = table.clone(ctx.Arguments)
		local color: Color3? = nil
		for i = #words, 1, -1 do
			local value = words[i]:match("^[cC][oO][lL][oO][rR]=(.+)$")
			if value then
				color = ChatTagService.ParseColor(value)
				if not color then
					return {
						Success = false,
						Message = ("Unknown colour '%s'. Use a name (%s), #rrggbb or r,g,b."):format(
							value,
							table.concat(ChatTagService.COLOR_NAMES, ", ")
						),
					}
				end
				table.remove(words, i)
			end
		end
		local raw = table.concat(words, " ")
		if raw == "" then
			return { Success = false, Message = "Give the tag text, e.g. ;chattag me Builder color=gold" }
		end
		-- Everyone in the server reads the tag: filter it like a broadcast.
		local filtered = TextFilterService.ForBroadcast(ctx.Executor.UserId, raw)
		if not filtered then
			return { Success = false, Message = TextFilterService.FAILED_MESSAGE }
		end
		local text = ChatTagService.Clean(filtered)
		if text == "" then
			return { Success = false, Message = "That tag is empty after removing unsupported characters." }
		end

		local previous = {}
		for _, target in ipairs(ctx.Targets) do
			local old = ChatTagService.GetCustom(target)
			previous[target.UserId] = if old then { Text = old.Text, Color = old.Color } else false
			ChatTagService.SetCustom(target, text, color)
		end
		return {
			Success = true,
			Message = ("Chat tag [%s] set on %d player(s)."):format(text, #ctx.Targets),
			Undoable = true,
			UndoData = { Previous = previous },
		} :: any
	end,
	Undo = function(ctx: CommandContext, result: any): CommandResult
		local previous = (result.UndoData or {}).Previous or {}
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			local old = previous[target.UserId]
			if old ~= nil and target.Parent then
				if old then
					ChatTagService.SetCustom(target, old.Text, old.Color)
				else
					ChatTagService.SetCustom(target, nil)
				end
				count += 1
			end
		end
		return { Success = true, Message = ("Restored the chat tag of %d player(s)."):format(count) }
	end,
} :: any)

CommandRegistry.Register({
	Name = "unchattag",
	Aliases = { "removechattag", "untag", "cleartag" },
	Description = "Removes a custom chat tag; the player goes back to their rank tag (if rank tags are on).",
	Usage = "/unchattag target",
	Permission = "player.chattag",
	Category = "Player",
	Subcategory = "Chat",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = true,
	DefaultSelf = true,
	Execute = function(ctx: CommandContext): CommandResult
		local count = 0
		for _, target in ipairs(ctx.Targets) do
			if ChatTagService.GetCustom(target) then
				count += 1
			end
			ChatTagService.SetCustom(target, nil)
		end
		return { Success = true, Message = ("Removed %d custom chat tag(s)."):format(count) }
	end,
} :: any)

CommandRegistry.Register({
	Name = "chattags",
	Aliases = { "ranktags" },
	Description = "Shows or switches rank tags in chat ([Owner], [Admin], ... in the rank colour) for every server.",
	Usage = "/chattags [on|off]",
	Permission = "panel.open",
	Category = "Player",
	Subcategory = "Chat",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "chattags", "chattags off" },
	Execute = function(ctx: CommandContext): CommandResult
		local arg = (ctx.Arguments[1] or ""):lower()
		if arg == "" then
			local on = ConfigService.Get("RankChatTags") ~= false
			return { Success = true, Message = "Rank chat tags are " .. (if on then "on." else "off.") }
		end
		if arg ~= "on" and arg ~= "off" then
			return { Success = false, Message = "Use ;chattags on or ;chattags off." }
		end
		if not PermissionSystem.Has(ctx.Executor, "config.edit") then
			return { Success = false, Message = "Changing this needs the config.edit permission." }
		end
		local ok, err = ConfigService.Set("RankChatTags", arg == "on", ctx.Executor)
		if not ok then
			return { Success = false, Message = err or "Could not save the setting." }
		end
		ChatTagService.RefreshAll()
		return { Success = true, Message = "Rank chat tags " .. (if arg == "on" then "on" else "off") .. " (all servers)." }
	end,
} :: any)

return true
