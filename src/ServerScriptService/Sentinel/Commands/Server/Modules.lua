--!strict
--[[
	Modules.lua (W-FINAL.1) - Module Manager commands.

		;modules                                  list modules + status (modules.view)
		;module <id> [info]                       details, settings, warnings (modules.view)
		;module <id> on|enable                    (modules.activate)
		;module <id> off|disable                  (modules.disable)
		;module <id> set <setting> <value>        (modules.configure)
		;module <id> reset                        defaults (modules.configure, confirm)

	No default rank has modules.* - the Owner (`*`) controls modules; grant
	nodes with ;rankperm. See Systems/ModuleService.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local ModuleService = require(Sentinel:WaitForChild("Systems"):WaitForChild("ModuleService"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local function moduleIds(): { string }
	local ids = {}
	for _, m in ipairs(ModuleService.List()) do
		table.insert(ids, m.Id)
	end
	return ids
end

CommandRegistry.Register({
	Name = "modules",
	Aliases = { "modulelist" },
	Description = "Lists the Sentinel modules (optional gameplay systems) and their status.",
	Usage = "/modules",
	Permission = "modules.view",
	Category = "Server",
	Subcategory = "Modules",
	Cooldown = 1,
	Log = false,
	RequiresTarget = false,
	Execute = function(_ctx: CommandContext): CommandResult
		local list = ModuleService.List()
		if #list == 0 then
			return { Success = true, Message = "No modules are installed." }
		end
		local lines = { ("%d module(s):"):format(#list) }
		for _, m in ipairs(list) do
			local warn = if #m.Warnings > 0 then (" - %d warning(s)"):format(#m.Warnings) else ""
			table.insert(lines, ("%s (%s) v%s [%s] - %s%s"):format(m.Name, m.Id, m.Version, m.Status, m.Category, warn))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
} :: any)

CommandRegistry.Register({
	Name = "module",
	Aliases = { "mod", "sentinelmodule" },
	Description = "Shows, enables, disables or configures one Sentinel module.",
	Usage = "/module id [action] [setting] [value...]",
	ArgHints = {
		id = { Type = "string", Description = "Module id", Suggestions = moduleIds },
		action = { Type = "string", Description = "info | on | off | set | reset", Suggestions = { "info", "on", "off", "set", "reset" } },
		setting = { Type = "string", Description = "Setting name (for set)" },
		value = { Type = "string", Description = "New value (for set)" },
	},
	Examples = { "module shifttorun", "module shifttorun on", "module shifttorun set SprintSpeed 30", "module shifttorun set Stamina on", "module shifttorun reset" },
	Permission = "modules.view",
	Category = "Server",
	Subcategory = "Modules",
	Cooldown = 1,
	Log = true,
	RequiresTarget = false,
	Risk = "high", -- only reset asks to confirm (ConfirmWhen)
	ConfirmWhen = function(arguments: { string }): boolean
		return (arguments[2] or ""):lower() == "reset"
	end,
	Execute = function(ctx: CommandContext): CommandResult
		local id = ModuleService.Find(ctx.Arguments[1])
		if not id then
			return { Success = false, Message = ("Unknown module '%s'. Try ;modules."):format(tostring(ctx.Arguments[1] or "")) }
		end
		local action = (ctx.Arguments[2] or "info"):lower()
		local executor = ctx.Executor
		local function need(node: string): CommandResult?
			if not PermissionSystem.Has(executor, node) then
				return { Success = false, Message = ("You need %s for that."):format(node) }
			end
			return nil
		end
		if action == "info" or action == "status" then
			local d = ModuleService.Get(id)
			local lines = {
				("%s v%s [%s] - %s"):format(d.Name, d.Version, d.Status, d.Description),
			}
			if d.Error then
				table.insert(lines, "Error: " .. d.Error)
			end
			for _, w in ipairs(d.Warnings) do
				table.insert(lines, "Warning: " .. w)
			end
			local settings = {}
			for _, f in ipairs(d.Schema) do
				table.insert(settings, ("%s=%s"):format(f.Key, tostring(d.Config[f.Key])))
			end
			table.insert(lines, "Settings: " .. table.concat(settings, ", "))
			if d.Diagnostics then
				local diag = {}
				for k, v in pairs(d.Diagnostics) do
					table.insert(diag, ("%s=%s"):format(k, tostring(v)))
				end
				table.sort(diag)
				table.insert(lines, "Diagnostics: " .. table.concat(diag, ", "))
			end
			return { Success = true, Message = table.concat(lines, "\n") }
		elseif action == "on" or action == "enable" or action == "activate" then
			local denied = need("modules.activate")
			if denied then
				return denied
			end
			local ok, msg = ModuleService.SetEnabled(id, true, executor)
			return { Success = ok, Message = msg }
		elseif action == "off" or action == "disable" or action == "deactivate" then
			local denied = need("modules.disable")
			if denied then
				return denied
			end
			local ok, msg = ModuleService.SetEnabled(id, false, executor)
			return { Success = ok, Message = msg }
		elseif action == "set" then
			local denied = need("modules.configure")
			if denied then
				return denied
			end
			local key = ctx.Arguments[3]
			local value = table.concat(ctx.Arguments, " ", 4)
			if not key or value == "" then
				return { Success = false, Message = "Usage: ;module <id> set <setting> <value>" }
			end
			local ok, msg = ModuleService.SetValue(id, key, value, executor)
			return { Success = ok, Message = msg }
		elseif action == "reset" then
			local denied = need("modules.configure")
			if denied then
				return denied
			end
			local ok, msg = ModuleService.ResetConfig(id, executor)
			return { Success = ok, Message = msg }
		end
		return { Success = false, Message = "Action must be info, on, off, set or reset." }
	end,
} :: any)

return {}
