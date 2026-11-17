--!strict
--[[
	Appearance.lua (UI redesign)

	;commandbar                         your command bar settings
	;commandbar <setting> <value>       change one (preset, position, width,
	                                    opacity, fontsize, maxlines, rows, key)
	;commandbar reset                   follow the server default again
	;commandbar default <setting> <value>   set the server default (config.ui)
	;commandbar default reset

	;theme                              your panel theme settings
	;theme <setting> <value>            theme, accent, animations, scale
	;theme reset / ;theme default ...   as above

	The command bar works for ranks with "commandbar.use" (VIP by default)
	as well as staff, so these commands are how a VIP - who has no panel -
	customises it. The Appearance page does the same through SetUIPrefsRemote.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local Types = require(SentinelShared:WaitForChild("Types"))
local UIPrefs = require(SentinelShared:WaitForChild("UIPrefs"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local PrefsService = require(Sentinel:WaitForChild("Systems"):WaitForChild("PrefsService"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local function settingNames(section: string): { string }
	local names = { "reset", "default" }
	for _, field in ipairs(UIPrefs.ORDER[section]) do
		table.insert(names, field:lower())
	end
	return names
end

local function listing(section: string, prefs: any, title: string): string
	local lines = { title }
	for _, field in ipairs(UIPrefs.ORDER[section]) do
		table.insert(lines, ("%s = %s    %s"):format(field:lower(), tostring(prefs[section][field]), UIPrefs.Describe(section, field)))
	end
	return table.concat(lines, "\n")
end

local function run(ctx: Ctx, section: string, commandName: string): Result
	-- Public commands (no single node): staff, or ranks with commandbar.use.
	if section == "Panel" and not PermissionSystem.Has(ctx.Executor, "panel.open") then
		return { Success = false, Message = "You do not have permission to do that." }
	elseif not PrefsService.CanUseCommandBar(ctx.Executor) then
		return { Success = false, Message = "You do not have permission to do that." }
	end
	local args = table.clone(ctx.Arguments)
	local forDefault = false
	if args[1] and args[1]:lower() == "default" then
		if not PermissionSystem.Has(ctx.Executor, "config.ui") then
			return { Success = false, Message = "Only ranks with config.ui (Owner) can change the server default." }
		end
		forDefault = true
		table.remove(args, 1)
	end
	local setting = args[1]
	if not setting then
		if forDefault then
			return { Success = true, Message = listing(section, UIPrefs.Merge(UIPrefs.BUILTIN, PrefsService.GetDefaults()), "Server default:") }
		end
		return { Success = true, Message = listing(section, PrefsService.GetEffective(ctx.Executor), "Your settings (;" .. commandName .. " <setting> <value>):") }
	end
	if setting:lower() == "reset" then
		local ok, message
		if forDefault then
			ok, message = PrefsService.ResetDefaults(section, ctx.Executor)
		else
			ok, message = PrefsService.ResetPersonal(ctx.Executor, section)
		end
		return { Success = ok, Message = message }
	end
	local _, field = UIPrefs.Find(setting, section)
	if not field then
		return { Success = false, Message = ("Unknown setting '%s'. Settings: %s"):format(setting, table.concat(settingNames(section), ", ", 3)) }
	end
	if not args[2] then
		return { Success = false, Message = ("%s: %s"):format(field:lower(), UIPrefs.Describe(section, field)) }
	end
	local value, err = UIPrefs.Parse(section, field, args[2])
	if value == nil then
		return { Success = false, Message = ("%s: %s."):format(field:lower(), err or "invalid value") }
	end
	local ok, message
	if forDefault then
		ok, message = PrefsService.SetDefaults({ [section] = { [field] = value } }, ctx.Executor)
	else
		ok, message = PrefsService.SetPersonal(ctx.Executor, { [section] = { [field] = value } })
	end
	return { Success = ok, Message = if ok then ("%s%s set to %s."):format(if forDefault then "Server default " else "", field:lower(), tostring(value)) else message }
end

CommandRegistry.Register({
	Name = "commandbar",
	Aliases = { "cmdbar", "bar" },
	Description = "Shows or changes how your command bar looks (or the server default with 'default').",
	Usage = "/commandbar [setting] [value] [extra]",
	ArgHints = {
		setting = { Type = "choice", Choices = settingNames("CommandBar"), Description = "A setting, reset, or default" },
		value = { Type = "string", Description = "The new value (or a setting name after 'default')" },
		extra = { Type = "string", Description = "The value, when changing the server default" },
	},
	Permission = "commandbar.use",
	Public = true, -- checked in run(): staff or commandbar.use
	Category = "Utility",
	Subcategory = "Appearance",
	Cooldown = 0.5,
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "commandbar", "commandbar position bottom", "commandbar preset carbon", "commandbar default preset classic" },
	Execute = function(ctx: Ctx): Result
		return run(ctx, "CommandBar", "commandbar")
	end,
} :: any)

CommandRegistry.Register({
	Name = "theme",
	Aliases = { "paneltheme" },
	Description = "Shows or changes your panel theme, accent, animations and size (or the server default with 'default').",
	Usage = "/theme [setting] [value] [extra]",
	ArgHints = {
		setting = { Type = "choice", Choices = settingNames("Panel"), Description = "A setting, reset, or default" },
		value = { Type = "string", Description = "The new value (or a setting name after 'default')" },
		extra = { Type = "string", Description = "The value, when changing the server default" },
	},
	Permission = "panel.open",
	Public = true, -- checked in run()
	Category = "Utility",
	Subcategory = "Appearance",
	Cooldown = 0.5,
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "theme", "theme theme ocean", "theme accent cyan", "theme default theme midnight" },
	Execute = function(ctx: Ctx): Result
		return run(ctx, "Panel", "theme")
	end,
} :: any)

return true
