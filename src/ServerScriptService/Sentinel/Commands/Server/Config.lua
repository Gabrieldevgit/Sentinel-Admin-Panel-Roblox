--!strict
--[[
	Config.lua (W08)

	;config                       list the administration settings
	;config <setting>             show one, with its format
	;config <setting> <value...>  change it            (node config.edit)
	;config reset <setting>       back to the default  (node config.edit)

	Settings and formats live in Systems/AdminConfig. Viewing needs the panel
	(panel.open); changing needs config.edit (Owner via "*").
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local AdminConfig = require(Sentinel:WaitForChild("Systems"):WaitForChild("AdminConfig"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local function settingChoices(): { string }
	local list = { "reset" }
	for _, key in ipairs(AdminConfig.Keys()) do
		table.insert(list, key)
	end
	return list
end

CommandRegistry.Register({
	Name = "config",
	Aliases = { "cfg", "settings" },
	Description = "Shows or changes the server's administration settings (prefixes, cooldowns, ban defaults, escalation, required reasons, log retention, default permissions).",
	Usage = "/config [setting] [value...]",
	ArgHints = {
		setting = { Type = "choice", Choices = settingChoices, Description = "A setting, or reset" },
		value = { Type = "text", Description = "The new value (see ;config <setting>)" },
	},
	Permission = "panel.open",
	Category = "Server",
	Subcategory = "Configuration",
	Cooldown = 0.5,
	Log = true,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "config", "config defaultban 7d", "config escalation 3:kick 5:ban:1d", "config reset cooldownscale" },
	Execute = function(ctx: Ctx): Result
		local args = ctx.Arguments
		if #args == 0 then
			local lines = { "Administration settings (;config <setting> <value>):" }
			local group = nil
			for _, entry in ipairs(AdminConfig.Entries()) do
				if entry.Group ~= group then
					group = entry.Group
					table.insert(lines, "[" .. entry.Group .. "]")
				end
				table.insert(lines, ("  %s = %s"):format(entry.Key, entry.Text))
			end
			return { Success = true, Message = table.concat(lines, "\n") }
		end

		local first = args[1]:lower()
		local resetting = first == "reset"
		local name = if resetting then args[2] else args[1]
		if not name then
			return { Success = false, Message = "Which setting? " .. table.concat(AdminConfig.Keys(), ", ") }
		end
		local entry = AdminConfig.Find(name)
		if not entry then
			return { Success = false, Message = ("Unknown setting '%s'. Settings: %s"):format(name, table.concat(AdminConfig.Keys(), ", ")) }
		end
		if not resetting and #args == 1 then
			return {
				Success = true,
				Message = ("%s = %s\n%s\nExample: ;config %s %s"):format(entry.Key, AdminConfig.Format(entry), entry.Description, entry.Key, entry.Example),
			}
		end
		if not PermissionSystem.Has(ctx.Executor, "config.edit") then
			return { Success = false, Message = "Changing settings needs config.edit." }
		end
		if resetting then
			local ok, message = AdminConfig.Reset(name, ctx.Executor)
			return { Success = ok, Message = message }
		end
		local ok, message = AdminConfig.Set(name, table.concat(args, " ", 2), ctx.Executor)
		return { Success = ok, Message = message }
	end,
} :: any)

return true
