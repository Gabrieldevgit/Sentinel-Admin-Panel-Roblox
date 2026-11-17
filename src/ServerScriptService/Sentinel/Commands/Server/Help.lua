--[[
	Help.lua

	Purpose:
		;help [command] — command documentation in chat (W06). Without an
		argument it says how many commands you can use; with one it prints
		the signature, description, permission, aliases and examples. Only
		commands the player may run are described, so it never reveals
		commands above their rank. In the palette, typing "help <command>"
		opens the full docs viewer instead.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(Shared:WaitForChild("Types"))
local UsageSpec = require(Shared:WaitForChild("UsageSpec"))

local Core = script.Parent.Parent.Parent:WaitForChild("Core")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local PermissionSystem = require(Core:WaitForChild("PermissionSystem"))
local CommandPolicy = require(Core:WaitForChild("CommandPolicy"))

local function canRun(player: Player, def: any): boolean
	if def.Public ~= true and not PermissionSystem.Has(player, def.Permission) then
		return false
	end
	if CommandPolicy.IsOwnerOnly(def) then
		return table.find(PermissionSystem.GetRoles(player), "Owner") ~= nil
	end
	return true
end

CommandRegistry.Register({
	Name = "help",
	Aliases = { "docs", "?" },
	Description = "Shows how to use a command (or how many you can use).",
	Usage = "/help [command]",
	ArgHints = { command = { Type = "command", Description = "The command to explain" } },
	Examples = { "help ban", "help" },
	Permission = "panel.open",
	Category = "Utility",
	Cooldown = 1,
	Log = false,
	Undoable = false,
	Execute = function(ctx: Types.CommandContext): Types.CommandResult
		local player = ctx.Executor
		local name = ctx.Arguments[1]
		if not name then
			local count = 0
			for _, def in ipairs(CommandRegistry.All()) do
				if canRun(player, def) then
					count += 1
				end
			end
			return {
				Success = true,
				Message = ("You can use %d commands. Try ;help <command>, or press Ctrl+K for the palette."):format(count),
			}
		end

		local def = CommandRegistry.Resolve(name:lower())
		if not def or not canRun(player, def) then
			return { Success = false, Message = ("No command '%s' available to you."):format(name) }
		end
		local parts = {
			("%s %s — %s"):format(def.Name, UsageSpec.Signature((def :: any).Args or {}), def.Description),
			"Permission: " .. def.Permission,
		}
		if #def.Aliases > 0 then
			table.insert(parts, "Aliases: " .. table.concat(def.Aliases, ", "))
		end
		local risk = CommandPolicy.GetRisk(def)
		if risk ~= "low" then
			table.insert(parts, "Risk: " .. risk)
		end
		local examples = UsageSpec.Examples(def, nil)
		if #examples > 0 then
			table.insert(parts, "e.g. ;" .. examples[1])
		end
		return { Success = true, Message = table.concat(parts, " · ") }
	end,
})

return true
