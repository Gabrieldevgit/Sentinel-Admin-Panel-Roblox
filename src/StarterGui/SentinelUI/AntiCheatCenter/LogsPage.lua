--!strict
--[[
	LogsPage.lua (Anti-Cheat Control Center, page 9: Logs and Help)

	Two tabs. Audit log: every anti-cheat action and config change on this
	server (who, what, when, old and new value), filterable by staff member,
	action type or date and searchable; Undo reverses a reversible action
	(exemptions, score resets, watch list, testing mode, mode / panic /
	module / config changes; the server checks the node again); Copy copies
	a line. The full history of every server is in Insights > Audit Log
	(action "anticheat"). Help: what each module and page does, the
	shortcut table, the commands, and Replay tour.

	Stable names: Page_Logs.{Tabs.{Chip_Auditlog, Chip_Help}, Bar.{Staff, Action,
	Date, Undo, Copy}, LogTable, Help.{ReplayTour, CommandsButton}}
--]]

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local LogsPage = {}

local PAGE_HELP = {
	{ "1 Overview", "Health at a glance: master switch, mode, Panic, cards, live feed, flags per minute." },
	{ "2 Live Flags", "Every flag from every server. Filter, pause, review, mark false positives, create cases, export CSV." },
	{ "3 Players", "Players here with score, status and ping. Watch, exempt, testing mode, reset, warn, kick, ban, spectate. Lookup for anyone else." },
	{ "4 Review Queue", "Score 80+, multi-module patterns and ban proposals. Approve ban, dismiss, escalate, evidence, notes, assign." },
	{ "5 Modules", "Each detection: on/off, weight, configure thresholds, test on yourself, reset." },
	{ "6 Exemptions", "Per-player and per-module exemptions with expiry, the watch list, rank exemption, watch alerts." },
	{ "7 Settings", "Mode and action bands, scoring, grace and lag, storage, alerts, cross-server; presets, import / export." },
	{ "8 Analytics", "Flags by module and over time, top players, actions, false-positive rate, cost per module, health." },
	{ "9 Logs & Help", "This page: the anti-cheat audit log with undo, and help." },
}

local SHORTCUTS = {
	{ "F7", "Open or close the Control Center (rebind: Keybinds page)" },
	{ "Esc", "Close the detail drawer first, then the window" },
	{ "Up / Down", "Move through the table rows or the sidebar" },
	{ "Enter", "Open the selected row or page" },
	{ "1 to 9", "Jump to sidebar pages 1 to 9" },
	{ "/", "Focus the search field (a flag id opens it)" },
	{ "Ctrl+K", "Command palette with anti-cheat commands first" },
	{ "R", "Refresh the current page" },
	{ "Right-click", "Row menu: Open, Watch, Exempt, Create case, Copy ID (long-press on touch)" },
}

function LogsPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 10)
	local api: any = { Live = true }
	local tab = "Audit log"
	local staff, action, date = "All staff", "All actions", "All dates"
	local entries: { any } = {}

	local tabs = Widgets.make("Frame", { Name = "Tabs", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 1 }, frame)
	Widgets.list(tabs, Enum.FillDirection.Horizontal, 6)
	local bar = Widgets.make("Frame", { Name = "Bar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, frame)
	local bl = Widgets.list(bar, Enum.FillDirection.Horizontal, 6)
	bl.Wraps = true

	local tbl = Widgets.Table(frame, {
		Name = "LogTable",
		Size = UDim2.new(1, 0, 0, 460),
		LayoutOrder = 3,
		Key = "Id",
		SortKey = "Id",
		Empty = "No anti-cheat actions on this server yet.",
		FilterPlaceholder = "Search the log...",
		Columns = {
			{ Key = "Time", Title = "When", Width = 0.12, Format = function(r)
				return Widgets.clock(r.Time)
			end },
			{ Key = "Actor", Title = "Who", Width = 0.13 },
			{ Key = "Action", Title = "Action", Width = 0.13 },
			{ Key = "Target", Title = "Target", Width = 0.13 },
			{ Key = "Message", Title = "What", Width = 0.29 },
			{ Key = "Old", Title = "Old -> new", Width = 0.12, Format = function(r)
				if r.Old == nil and r.New == nil then
					return ""
				end
				return ("%s -> %s"):format(tostring(r.Old), tostring(r.New))
			end },
			{ Key = "CanUndo", Title = "Undo", Width = 0.08, Format = function(r)
				return if r.Undone then "undone" elseif r.CanUndo then "yes" else "-"
			end },
		},
	})
	api.Table = tbl

	local help = Widgets.make("Frame", { Name = "Help", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Visible = false }, frame)
	Widgets.list(help, nil, 6)
	local helpRow = Center.ActionRow(help, 0)
	Widgets.button(helpRow, "Replay tour", { Name = "ReplayTour", Kind = "primary", OnClick = function()
		Center.Audit("replayed the welcome tour")
		Center.ReplayTour()
	end })
	Widgets.button(helpRow, "Commands list", { Name = "CommandsButton", OnClick = function()
		Center.Command("help anticheat")
		Widgets.copyBox("Anti-cheat commands", table.concat({
			";anticheat (;ac) [page]       open the Control Center",
			";acstatus                     mode, modules, flags, cost",
			";acmode observe|balanced|strict",
			";acmodule <name> on|off",
			";acscore <player>             score + recent flags",
			";acreset <player>             reset the score",
			";acexempt <player> [module] <duration> <reason>",
			";acunexempt <player> [module]",
			";acwatch <player> [why]",
			";acreview <flagId>",
			";actest <player>              testing mode on / off",
			";acexport [n]                 recent flags as CSV",
			";acpanic [off]                all automatic actions off",
			";acban <player> [reason]      ban (owner approval / confirm)",
			";acset <Section.Setting> <value>",
		}, "\n"))
	end })
	Widgets.label(help, "Pages", { Bold = true, LayoutOrder = 1 })
	for i, p in ipairs(PAGE_HELP) do
		Center.KV(help, p[1], p[2], 1 + i)
	end
	Widgets.label(help, "Shortcuts", { Bold = true, LayoutOrder = 20 })
	for i, s in ipairs(SHORTCUTS) do
		Center.KV(help, s[1], s[2], 20 + i)
	end
	Widgets.label(help, "Detection modules", { Bold = true, LayoutOrder = 40 })
	local moduleHelpOrder = 40
	local modulesLoaded = false

	local function applyFilters()
		local rows = {}
		local dayStart = os.time() - os.time() % 86400
		for _, e in ipairs(entries) do
			local okStaff = staff == "All staff" or e.Actor == staff
			local okAction = action == "All actions" or e.Action == action or e.Action:sub(1, #action + 1) == action .. "."
			local okDate = date == "All dates"
				or (date == "Today" and e.Time >= dayStart)
				or (date == "Last hour" and e.Time >= os.time() - 3600)
			if okStaff and okAction and okDate then
				table.insert(rows, e)
			end
		end
		tbl.SetRows(rows)
	end

	local function renderBar()
		for _, c in ipairs(bar:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		if tab ~= "Audit log" then
			return
		end
		local actors, actions = { "All staff" }, { "All actions" }
		for _, e in ipairs(entries) do
			if not table.find(actors, e.Actor) then
				table.insert(actors, e.Actor)
			end
			local group = e.Action:match("^([^%.]+)") or e.Action
			if not table.find(actions, group) then
				table.insert(actions, group)
			end
		end
		Widgets.select(bar, actors, staff, function(v)
			staff = v
			applyFilters()
		end, { Name = "Staff", Width = 140, LayoutOrder = 1 })
		Widgets.select(bar, actions, action, function(v)
			action = v
			applyFilters()
		end, { Name = "Action", Width = 140, LayoutOrder = 2 })
		Widgets.select(bar, { "All dates", "Today", "Last hour" }, date, function(v)
			date = v
			applyFilters()
		end, { Name = "Date", Width = 120, LayoutOrder = 3 })
		Widgets.button(bar, "Undo", { Name = "Undo", LayoutOrder = 4, Tooltip = "Reverse the selected action (needs the same permission)", OnClick = function()
			local r = tbl.Selected()[1]
			if not r then
				Center.Toast(false, "Click a log line first.")
				return
			end
			if not r.CanUndo then
				Center.Toast(false, "That action can't be undone.")
				return
			end
			Center.Act("undo", { Id = r.Id }, { Confirm = { Title = "Undo", Message = ("Reverse #%d: %s?"):format(r.Id, r.Message) } })
		end })
		Widgets.button(bar, "Copy", { Name = "Copy", LayoutOrder = 5, OnClick = function()
			local r = tbl.Selected()[1]
			if not r then
				Center.Toast(false, "Click a log line first.")
				return
			end
			Widgets.copyBox("Log line", ("#%d %s %s %s %s: %s"):format(r.Id, os.date("%Y-%m-%d %H:%M:%S", r.Time) :: string, r.Actor, r.Action, tostring(r.Target or ""), r.Message))
			Center.Audit("copied log line #" .. r.Id)
		end })
	end

	local chips = {}
	for i, name in ipairs({ "Audit log", "Help" }) do
		chips[name] = Widgets.chip(tabs, name, name == tab, function()
			tab = name
			for n, c in pairs(chips) do
				Widgets.SetActive(c, n == tab)
			end
			tbl.Root.Visible = tab == "Audit log"
			help.Visible = tab == "Help"
			api.Table = if tab == "Audit log" then tbl else nil
			renderBar()
			if tab == "Help" and not modulesLoaded then
				modulesLoaded = true
				local m = Center.Call("modules")
				for j, mod in ipairs((m and m.Modules) or {}) do
					moduleHelpOrder += 1
					Center.KV(help, mod.Name, mod.Description, 40 + j)
				end
			end
		end, { LayoutOrder = i })
	end

	function api.Refresh()
		local r = Center.Call("logs")
		if r and r.Ok then
			entries = r.Log
			applyFilters()
			renderBar()
		end
	end

	function api.Search(text: string)
		tbl.SetFilter(text)
	end

	renderBar()
	return api
end

return LogsPage
