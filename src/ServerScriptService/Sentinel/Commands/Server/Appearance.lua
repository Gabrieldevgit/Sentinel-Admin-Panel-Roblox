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
	;theme export                       a code for your current colours (W08)
	;theme import <code>                use a code as your Custom theme

	;keybind                            your shortcuts (W08)
	;keybind <action> <key|none>        panel, closepanel, palette, quickfly,
	                                    quicknoclip, quickgod, nextpage, prevpage
	;keybind add <key> <command...>     custom shortcut that runs a command
	;keybind remove <key>
	;keybind reset / default ...

	;notifyprefs [setting] [value]      toasts, sound, duration, position

	;layout [setting] [value]           mode (auto|desktop|mobile), compact,
	                                    statusbar, labels (W09)
	;layout pin <page> / unpin <page>   favorite pages (also ;pin / ;unpin)
	;layout tabs <s1,s2,...>            section tabs in this order
	;layout hide|show <section>         one section tab
	;layout move <section> <position>

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
	if section == "Keys" then
		local binds = prefs.Keys.Custom or {}
		table.insert(lines, ("custom shortcuts (%d): ;keybind add <key> <command>"):format(#binds))
		for _, bind in ipairs(binds) do
			table.insert(lines, ("  %s -> %s"):format(bind.Key, bind.Command))
		end
	elseif section == "Layout" then
		table.insert(lines, "tabs = " .. table.concat(prefs.Layout.Tabs or {}, ", ") .. "    ;layout tabs | hide | show | move")
		local pinned = prefs.Layout.Pinned or {}
		table.insert(lines, "pinned = " .. (if #pinned > 0 then table.concat(pinned, ", ") else "(none)") .. "    ;layout pin | unpin <page>")
	end
	return table.concat(lines, "\n")
end

-- Sub-commands beyond "<setting> <value>" (personal only).
local function customBinds(ctx: Ctx): { any }
	return PrefsService.GetEffective(ctx.Executor).Keys.Custom or {}
end

local function layoutList(ctx: Ctx, field: string): { string }
	return table.clone(PrefsService.GetEffective(ctx.Executor).Layout[field] or {})
end

local function saveLayout(ctx: Ctx, field: string, list: { string }, message: string): Result
	local ok, err = PrefsService.SetPersonal(ctx.Executor, { Layout = { [field] = list } })
	return { Success = ok, Message = if ok then message else err }
end

local function pagesHint(): string
	return "Pages: " .. table.concat(UIPrefs.PAGE_IDS, ", ")
end
local function sectionsHint(): string
	return "Sections: " .. table.concat(UIPrefs.NAV_SECTIONS, ", ")
end

local function pin(ctx: Ctx, name: string?, on: boolean): Result
	local page = UIPrefs.FindPage(name)
	if not page then
		return { Success = false, Message = "Unknown page. " .. pagesHint() }
	end
	local list = layoutList(ctx, "Pinned")
	local index = table.find(list, page)
	if on then
		if index then
			return { Success = true, Message = page .. " is already pinned." }
		end
		if #list >= UIPrefs.MAX_PINNED then
			return { Success = false, Message = ("You can pin %d pages."):format(UIPrefs.MAX_PINNED) }
		end
		table.insert(list, page)
		return saveLayout(ctx, "Pinned", list, "Pinned " .. page .. ".")
	end
	if not index then
		return { Success = false, Message = page .. " is not pinned." }
	end
	table.remove(list, index)
	return saveLayout(ctx, "Pinned", list, "Unpinned " .. page .. ".")
end

local function sectionArg(args: { string }): (string?, Result?)
	local id = UIPrefs.FindSection(args[2])
	if not id then
		return nil, { Success = false, Message = "Unknown section. " .. sectionsHint() }
	end
	return id, nil
end

local extras: { [string]: { [string]: (Ctx, { string }) -> Result } } = {
	Layout = {
		pin = function(ctx: Ctx, args: { string }): Result
			return pin(ctx, args[2], true)
		end,
		unpin = function(ctx: Ctx, args: { string }): Result
			return pin(ctx, args[2], false)
		end,
		tabs = function(ctx: Ctx, args: { string }): Result
			local list = {}
			for _, part in ipairs(string.split(table.concat(args, ",", 2), ",")) do
				local name = part:match("^%s*(.-)%s*$") :: string
				if name ~= "" then
					local id = UIPrefs.FindSection(name)
					if not id then
						return { Success = false, Message = ("Unknown section '%s'. %s"):format(name, sectionsHint()) }
					end
					if not table.find(list, id) then
						table.insert(list, id)
					end
				end
			end
			if #list == 0 then
				return { Success = false, Message = "Usage: ;layout tabs Dashboard,Players,Moderation  (" .. sectionsHint() .. ")" }
			end
			return saveLayout(ctx, "Tabs", list, "Section tabs: " .. table.concat(list, ", ") .. ".")
		end,
		hide = function(ctx: Ctx, args: { string }): Result
			local id, failure = sectionArg(args)
			if not id then
				return failure :: Result
			end
			local list = layoutList(ctx, "Tabs")
			local index = table.find(list, id)
			if not index then
				return { Success = true, Message = id .. " is already hidden." }
			end
			if #list == 1 then
				return { Success = false, Message = "Keep at least one section tab." }
			end
			table.remove(list, index)
			return saveLayout(ctx, "Tabs", list, "Hid the " .. id .. " tab.")
		end,
		show = function(ctx: Ctx, args: { string }): Result
			local id, failure = sectionArg(args)
			if not id then
				return failure :: Result
			end
			local list = layoutList(ctx, "Tabs")
			if table.find(list, id) then
				return { Success = true, Message = id .. " is already shown." }
			end
			table.insert(list, id)
			return saveLayout(ctx, "Tabs", list, "Showing the " .. id .. " tab.")
		end,
		move = function(ctx: Ctx, args: { string }): Result
			local id = UIPrefs.FindSection(args[2])
			local position = tonumber(args[3])
			if not id or not position then
				return { Success = false, Message = "Usage: ;layout move <section> <position>  (" .. sectionsHint() .. ")" }
			end
			local list = layoutList(ctx, "Tabs")
			local index = table.find(list, id)
			if not index then
				return { Success = false, Message = id .. " is hidden; ;layout show " .. id .. " first." }
			end
			table.remove(list, index)
			table.insert(list, math.clamp(math.floor(position), 1, #list + 1), id)
			return saveLayout(ctx, "Tabs", list, "Section tabs: " .. table.concat(list, ", ") .. ".")
		end,
	},
	Panel = {
		export = function(ctx: Ctx, _args: { string }): Result
			local palette = UIPrefs.ResolvePalette(PrefsService.GetEffective(ctx.Executor).Panel)
			return { Success = true, Message = "Theme code (share it; others use ;theme import <code>):\n" .. UIPrefs.EncodeTheme(palette) }
		end,
		import = function(ctx: Ctx, args: { string }): Result
			local custom, err = UIPrefs.DecodeTheme(table.concat(args, "", 2))
			if not custom then
				return { Success = false, Message = "Import failed: " .. tostring(err) .. "." }
			end
			local ok, message = PrefsService.SetPersonal(ctx.Executor, { Panel = { Theme = "Custom", Custom = custom } })
			return { Success = ok, Message = if ok then "Imported as your Custom theme." else message }
		end,
	},
	Keys = {
		add = function(ctx: Ctx, args: { string }): Result
			local key = args[2] and UIPrefs.ParseKey(args[2])
			local command = table.concat(args, " ", 3)
			if not key or key == "None" then
				return { Success = false, Message = "Usage: ;keybind add <key> <command...>  (key like K, F7, Ctrl+K)" }
			end
			if command == "" then
				return { Success = false, Message = "Give the command the key runs, e.g. ;keybind add Ctrl+H heal me" }
			end
			local kept = {}
			for _, bind in ipairs(customBinds(ctx)) do
				if bind.Key ~= key then
					table.insert(kept, bind)
				end
			end
			if #kept >= UIPrefs.MAX_CUSTOM_BINDS then
				return { Success = false, Message = ("You can have %d custom shortcuts."):format(UIPrefs.MAX_CUSTOM_BINDS) }
			end
			table.insert(kept, { Key = key, Command = command })
			local ok, message = PrefsService.SetPersonal(ctx.Executor, { Keys = { Custom = kept } })
			return { Success = ok, Message = if ok then ("%s now runs: %s"):format(key, command) else message }
		end,
		remove = function(ctx: Ctx, args: { string }): Result
			local key = args[2] and UIPrefs.ParseKey(args[2])
			local binds = customBinds(ctx)
			local kept = {}
			for _, bind in ipairs(binds) do
				if bind.Key ~= key then
					table.insert(kept, bind)
				end
			end
			if #kept == #binds then
				return { Success = false, Message = "No custom shortcut on that key." }
			end
			local ok, message = PrefsService.SetPersonal(ctx.Executor, { Keys = { Custom = kept } })
			return { Success = ok, Message = if ok then ("Removed the shortcut on %s."):format(tostring(key)) else message }
		end,
	},
}

local function run(ctx: Ctx, section: string, commandName: string): Result
	-- Public commands (no single node): staff, or ranks with commandbar.use.
	if section ~= "CommandBar" and not PermissionSystem.Has(ctx.Executor, "panel.open") then
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
	local extra = extras[section]
	if setting and extra and extra[setting:lower()] and not forDefault then
		return extra[setting:lower()](ctx, args)
	end
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
		setting = {
			Type = "choice",
			Choices = (function()
				local list = settingNames("Panel")
				table.insert(list, "export")
				table.insert(list, "import")
				return list
			end)(),
			Description = "A setting, export, import, reset, or default",
		},
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

local keyChoices = settingNames("Keys")
table.insert(keyChoices, "add")
table.insert(keyChoices, "remove")

CommandRegistry.Register({
	Name = "keybind",
	Aliases = { "keybinds", "shortcut" },
	Description = "Shows or changes your keyboard shortcuts, and adds custom key -> command shortcuts.",
	Usage = "/keybind [setting] [value] [extra...]",
	ArgHints = {
		setting = { Type = "choice", Choices = keyChoices, Description = "A shortcut, add, remove, reset or default" },
		value = { Type = "string", Description = "A key like F6, K, Ctrl+K (or none)" },
		extra = { Type = "text", Description = "The command, for add" },
	},
	Permission = "panel.open",
	Public = true, -- checked in run()
	Category = "Utility",
	Subcategory = "Appearance",
	Cooldown = 0.5,
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "keybind", "keybind quickfly Ctrl+F", "keybind add Ctrl+H heal me", "keybind remove Ctrl+H" },
	Execute = function(ctx: Ctx): Result
		return run(ctx, "Keys", "keybind")
	end,
} :: any)

CommandRegistry.Register({
	Name = "notifyprefs",
	Aliases = { "toasts" },
	Description = "Shows or changes your notification preferences (or the server default with 'default').",
	Usage = "/notifyprefs [setting] [value] [extra]",
	ArgHints = {
		setting = { Type = "choice", Choices = settingNames("Notifications"), Description = "A setting, reset, or default" },
		value = { Type = "string", Description = "The new value" },
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
	Examples = { "notifyprefs", "notifyprefs sound on", "notifyprefs position topright" },
	Execute = function(ctx: Ctx): Result
		return run(ctx, "Notifications", "notifyprefs")
	end,
} :: any)

local layoutChoices = settingNames("Layout")
for _, extra in ipairs({ "pin", "unpin", "tabs", "hide", "show", "move" }) do
	table.insert(layoutChoices, extra)
end

CommandRegistry.Register({
	Name = "layout",
	Aliases = { "panellayout" },
	Description = "Shows or changes the panel layout: mobile / desktop, compact mode, status bar, section tabs and pinned pages.",
	Usage = "/layout [setting] [value] [extra...]",
	ArgHints = {
		setting = { Type = "choice", Choices = layoutChoices, Description = "A setting, pin, unpin, tabs, hide, show, move, reset or default" },
		value = { Type = "string", Description = "The new value, a page or a section" },
		extra = { Type = "text", Description = "More values (move position, server default value)" },
	},
	Permission = "panel.open",
	Public = true, -- checked in run()
	Category = "Utility",
	Subcategory = "Appearance",
	Cooldown = 0.5,
	Log = false,
	Undoable = false,
	RequiresTarget = false,
	Examples = { "layout", "layout compact on", "layout mode mobile", "layout pin Ranks", "layout hide Insights", "layout move Server 2" },
	Execute = function(ctx: Ctx): Result
		return run(ctx, "Layout", "layout")
	end,
} :: any)

local function pinCommand(name: string, aliases: { string }, on: boolean)
	CommandRegistry.Register({
		Name = name,
		Aliases = aliases,
		Description = if on then "Pins a panel page to your favorite pages." else "Removes a page from your favorite pages.",
		Usage = "/" .. name .. " page",
		ArgHints = { page = { Type = "choice", Choices = UIPrefs.PAGE_IDS, Description = "A panel page" } },
		Permission = "panel.open",
		Category = "Utility",
		Subcategory = "Appearance",
		Cooldown = 0.5,
		Log = false,
		Undoable = false,
		RequiresTarget = false,
		Inverse = if on then "unpin" else "pin",
		InverseKeepsArguments = true,
		Examples = { name .. " Ranks" },
		Execute = function(ctx: Ctx): Result
			return pin(ctx, ctx.Arguments[1], on)
		end,
	} :: any)
end
pinCommand("pin", { "favpage" }, true)
pinCommand("unpin", { "unfavpage" }, false)

return true
