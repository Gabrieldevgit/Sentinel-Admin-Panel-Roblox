--!strict
--[[
	Framework.lua (W07)

	Command-framework commands:
		;undo / ;redo            reverse / replay your last undoable command
		;history [search]        your recent command results
		;cancel                  stop your running commands (countdown, ...)
		                         and drop a pending ;confirm
		;prefix [add|remove|set|reset] [prefixes...]   chat prefixes
		;preset <name>           run a saved preset
		;preset save <name> <command...> / delete <name> / list
		;template <name> [values...]   fill a template's placeholders in order
		;template list
		;favorite <command>      toggle a favorite command

	Presets and templates with "&&" chains are saved from the panel
	(Library page / command builder) — in chat, "&&" always splits commands.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local Core = Sentinel:WaitForChild("Core")
local Systems = Sentinel:WaitForChild("Systems")
local CommandRegistry = require(Core:WaitForChild("CommandRegistry"))
local CommandProcessor = require(Core:WaitForChild("Parser"):WaitForChild("CommandProcessor"))
local CommandHistory = require(Core:WaitForChild("CommandHistory"))
local ConfigService = require(Systems:WaitForChild("ConfigService"))
local CommandLibraryService = require(Systems:WaitForChild("CommandLibraryService"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

-- Folds the results of a nested chain into one result (keeps a pending
-- confirmation so the panel can still show its dialog).
local function merge(results: { any }): Result
	local ok, messages = true, {}
	local out: any = {}
	for _, r in ipairs(results) do
		ok = ok and r.Success
		if r.Message then
			table.insert(messages, r.Message)
		end
		if r.NeedsConfirmation then
			out.NeedsConfirmation, out.ConfirmId, out.Risk = true, r.ConfirmId, r.Risk
		end
	end
	out.Success = ok
	out.Message = table.concat(messages, " | ")
	out.Undoable = false
	return out
end

CommandRegistry.Register({
	Name = "undo",
	NoHistory = true, -- the commands it runs are recorded instead
	Aliases = { "z" },
	Description = "Reverses your most recent undoable command (freeze, mute, jail, ban, effects, coins, ...).",
	Usage = "/undo",
	Permission = "panel.open",
	Category = "Utility",
	Subcategory = "History",
	Cooldown = 0.5,
	Log = false, -- the inverse command logs itself
	Undoable = false,
	Examples = { "undo" },
	Execute = function(ctx: Ctx): Result
		local r: any = CommandProcessor.Undo(ctx.Executor)
		r.Undoable = false
		return r
	end,
} :: any)

CommandRegistry.Register({
	Name = "redo",
	NoHistory = true, -- the commands it runs are recorded instead
	Aliases = { "y" },
	Description = "Runs the command you last undid again.",
	Usage = "/redo",
	Permission = "panel.open",
	Category = "Utility",
	Subcategory = "History",
	Cooldown = 0.5,
	Log = false,
	Undoable = false,
	Execute = function(ctx: Ctx): Result
		local r: any = CommandProcessor.Redo(ctx.Executor)
		r.Undoable = false
		return r
	end,
} :: any)

CommandRegistry.Register({
	Name = "history",
	NoHistory = true, -- the commands it runs are recorded instead
	Aliases = { "hist" },
	Description = "Lists your recent commands with their result and how long they took.",
	Usage = "/history [search...]",
	Permission = "panel.open",
	Category = "Utility",
	Subcategory = "History",
	Cooldown = 1,
	Log = false,
	Undoable = false,
	Examples = { "history", "history freeze" },
	Execute = function(ctx: Ctx): Result
		local entries = CommandHistory.Get(ctx.Executor, { Search = table.concat(ctx.Arguments, " "), Limit = 8 })
		if #entries == 0 then
			return { Success = true, Message = "No matching commands in your history." }
		end
		local lines = {}
		for _, e in ipairs(entries) do
			table.insert(lines, ("%s %s (%s ms)%s"):format(
				if e.Success then "✓" else "✗",
				e.Input,
				tostring(e.DurationMs or 0),
				if e.State == "undone" then " [undone]" else ""
			))
		end
		local undo, redo = CommandHistory.Counts(ctx.Executor)
		return {
			Success = true,
			Message = ("%s\n%d undoable, %d redoable."):format(table.concat(lines, "\n"), undo, redo),
		}
	end,
} :: any)

CommandRegistry.Register({
	Name = "cancel",
	Aliases = { "stop" },
	Description = "Stops your running commands (e.g. a countdown) and drops a pending confirmation.",
	Usage = "/cancel",
	Permission = "panel.open",
	Category = "Utility",
	Subcategory = "History",
	Cooldown = 0.5,
	Log = true,
	Undoable = false,
	Execute = function(ctx: Ctx): Result
		local running = CommandRegistry.CancelRunning(ctx.Executor)
		local pending = CommandProcessor.CancelPending(ctx.Executor)
		if running == 0 and not pending then
			return { Success = false, Message = "Nothing to cancel." }
		end
		local parts = {}
		if running > 0 then
			table.insert(parts, ("stopped %d running command(s)"):format(running))
		end
		if pending then
			table.insert(parts, "dropped the pending confirmation")
		end
		return { Success = true, Message = "Cancelled: " .. table.concat(parts, ", ") .. "." }
	end,
} :: any)

CommandRegistry.Register({
	Name = "prefix",
	Aliases = { "prefixes" },
	Description = "Shows or changes the chat command prefixes for every server.",
	Usage = "/prefix [list|add|remove|set|reset] [prefixes...]",
	Permission = "config.prefix",
	Category = "Server",
	Subcategory = "Configuration",
	Cooldown = 2,
	Log = true,
	Undoable = false,
	Risk = "medium",
	Examples = { "prefix", "prefix add !", "prefix set ; !", "prefix reset" },
	Execute = function(ctx: Ctx): Result
		local action = (ctx.Arguments[1] or "list"):lower()
		local current = ConfigService.GetPrefixes()
		local allowed = table.concat(ConfigService.ALLOWED_PREFIXES, " ")
		local new: { string }
		if action == "list" then
			return { Success = true, Message = ("Prefixes: %s (allowed: %s)"):format(table.concat(current, " "), allowed) }
		elseif action == "reset" then
			new = { ";" }
		else
			local given = {}
			for i = 2, #ctx.Arguments do
				for ch in ctx.Arguments[i]:gmatch("%S") do
					if not table.find(ConfigService.ALLOWED_PREFIXES, ch) then
						return { Success = false, Message = ("'%s' can't be a prefix. Allowed: %s"):format(ch, allowed) }
					end
					if not table.find(given, ch) then
						table.insert(given, ch)
					end
				end
			end
			if #given == 0 then
				return { Success = false, Message = "Give at least one prefix, e.g. ;prefix add !" }
			end
			if action == "add" then
				new = current
				for _, p in ipairs(given) do
					if not table.find(new, p) then
						table.insert(new, p)
					end
				end
			elseif action == "remove" then
				new = {}
				for _, p in ipairs(current) do
					if not table.find(given, p) then
						table.insert(new, p)
					end
				end
				if #new == 0 then
					return { Success = false, Message = "At least one prefix must stay active." }
				end
			elseif action == "set" then
				new = given
			else
				return { Success = false, Message = "Usage: ;prefix [list|add|remove|set|reset] [prefixes...]" }
			end
		end
		local ok, err = ConfigService.Set("Prefixes", new, ctx.Executor)
		if not ok then
			return { Success = false, Message = err }
		end
		return { Success = true, Message = "Chat prefixes are now: " .. table.concat(new, " ") }
	end,
} :: any)

CommandRegistry.Register({
	Name = "preset",
	Aliases = { "pre" },
	Description = "Runs a saved command preset, or saves / deletes / lists your presets.",
	Usage = "/preset [name] [text...]",
	ArgHints = { name = { Description = "A preset name, or save / delete / list" } },
	Permission = "panel.open",
	Category = "Utility",
	Subcategory = "Library",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	Examples = { "preset list", "preset save calm slowmode 5", "preset calm" },
	Execute = function(ctx: Ctx): Result
		local first = ctx.Arguments[1]
		if not first or first:lower() == "list" then
			local lib = CommandLibraryService.Get(ctx.Executor)
			if #lib.Presets == 0 then
				return { Success = true, Message = "No presets yet. Save one with ;preset save <name> <command>." }
			end
			local lines = {}
			for _, p in ipairs(lib.Presets) do
				table.insert(lines, ("%s → %s"):format(p.Name, p.Text))
			end
			return { Success = true, Message = table.concat(lines, "\n") }
		end
		local verb = first:lower()
		if verb == "save" then
			local ok, msg = CommandLibraryService.Apply(ctx.Executor, "savePreset", {
				Name = ctx.Arguments[2],
				Text = table.concat(ctx.Arguments, " ", 3),
			})
			return { Success = ok, Message = msg }
		elseif verb == "delete" then
			local ok, msg = CommandLibraryService.Apply(ctx.Executor, "deletePreset", { Name = ctx.Arguments[2] })
			return { Success = ok, Message = msg }
		end
		local preset = CommandLibraryService.FindPreset(ctx.Executor, table.concat(ctx.Arguments, " "))
			or CommandLibraryService.FindPreset(ctx.Executor, first)
		if not preset then
			return { Success = false, Message = ("No preset named '%s'."):format(first) }
		end
		if preset.Text:lower():match("^preset%s") or preset.Text:lower():match("^pre%s") then
			return { Success = false, Message = "A preset can't run another preset." }
		end
		return merge(CommandProcessor.Process(ctx.Executor, preset.Text, { Source = "preset" }))
	end,
} :: any)

CommandRegistry.Register({
	Name = "template",
	Aliases = { "tpl" },
	Description = "Fills a command template's {placeholders} in order and runs it.",
	Usage = "/template [name] [values...]",
	ArgHints = { name = { Description = "A template name (quote it if it has spaces), or list" } },
	Permission = "panel.open",
	Category = "Utility",
	Subcategory = "Library",
	Cooldown = 1,
	Log = true,
	Undoable = false,
	Examples = { "template list", 'template "Spam warning" Player1' },
	Execute = function(ctx: Ctx): Result
		local first = ctx.Arguments[1]
		if not first or first:lower() == "list" then
			local lib = CommandLibraryService.Get(ctx.Executor)
			local lines = {}
			for _, list in ipairs({ lib.Templates, lib.BuiltinTemplates }) do
				for _, t in ipairs(list) do
					table.insert(lines, ("%s → %s"):format(t.Name, t.Text))
				end
			end
			return { Success = true, Message = table.concat(lines, "\n") }
		end
		local template = CommandLibraryService.FindTemplate(ctx.Executor, first)
		if not template then
			return { Success = false, Message = ("No template named '%s' (use quotes for names with spaces)."):format(first) }
		end
		local holders = CommandLibraryService.Placeholders(template.Text)
		local values = {}
		for i, holder in ipairs(holders) do
			values[holder.Name] = if i == #holders
				then table.concat(ctx.Arguments, " ", i + 1)
				else ctx.Arguments[i + 1]
		end
		local line, missing = CommandLibraryService.FillTemplate(template.Text, values)
		if not line then
			return { Success = false, Message = ("Template '%s' needs a value for {%s}."):format(template.Name, missing or "?") }
		end
		return merge(CommandProcessor.Process(ctx.Executor, line, { Source = "template" }))
	end,
} :: any)

CommandRegistry.Register({
	Name = "favorite",
	Aliases = { "fav" },
	Description = "Adds or removes a command from your favorites (shown first in the palette).",
	Usage = "/favorite command",
	ArgHints = { command = { Type = "command" } },
	Permission = "panel.open",
	Category = "Utility",
	Subcategory = "Library",
	Cooldown = 0.5,
	Log = false,
	Undoable = false,
	Examples = { "favorite freeze" },
	Execute = function(ctx: Ctx): Result
		local name = ctx.Arguments[1]
		local def = name and CommandRegistry.Resolve(name:lower())
		if not def then
			return { Success = false, Message = "Unknown command." }
		end
		local ok, msg = CommandLibraryService.Apply(ctx.Executor, "favorite", { Command = def.Name })
		return { Success = ok, Message = msg }
	end,
} :: any)

return true
