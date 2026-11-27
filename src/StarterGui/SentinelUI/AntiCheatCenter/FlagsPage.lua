--!strict
--[[
	FlagsPage.lua (Anti-Cheat Control Center, page 2: Live Flags)

	A real-time table of every flag from every server (this server's plus
	the high-severity flags other servers share). Filters: module, severity
	range, player, time range, server, only unreviewed. Pause / Resume
	freezes live updates. Row click = flag drawer; right-click = menu.
	Mark reviewed (selected rows), Mark false positive, Create case,
	Export (CSV of the filtered rows).

	Stable names: Page_Flags.{Toolbar.{PauseButton, Module, Sev_<range>,
	Range, PlayerBox, ServerBox, Chip_Onlyunreviewed}, Actions.{MarkReviewed,
	FalsePositive, CreateCase, Export}, FlagTable}
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AntiCheatTypes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("AntiCheatTypes"))
local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local FlagsPage = {}

local RANGES = { ["Last hour"] = 3600, ["24 hours"] = 86400, ["7 days"] = 604800, ["All"] = 0 }
local SEVERITIES = { { "All", 1, 10 }, { "1-3", 1, 3 }, { "4-6", 4, 6 }, { "7-10", 7, 10 } }

function FlagsPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 10)
	local paused = false
	local filter: any = { Module = nil, MinSeverity = 1, MaxSeverity = 10, Player = "", Server = "", Unreviewed = false, Range = "24 hours" }
	local api: any = { Live = true }

	local bar = Widgets.make("Frame", { Name = "Toolbar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1 }, frame)
	local bl = Widgets.list(bar, Enum.FillDirection.Horizontal, 6)
	bl.Wraps = true
	bl.VerticalAlignment = Enum.VerticalAlignment.Center
	local pause
	pause = Widgets.button(bar, "Pause", { Name = "PauseButton", Width = 80, LayoutOrder = 1, Tooltip = "Freeze live updates", OnClick = function()
		paused = not paused
		pause.Text = if paused then "Resume" else "Pause"
		Widgets.SetActive(pause, paused)
		if not paused then
			api.Refresh()
		end
	end })
	local moduleOptions = { "All modules" }
	for _, name in ipairs(Center.ModuleNames or {}) do
		table.insert(moduleOptions, name)
	end
	Widgets.select(bar, moduleOptions, "All modules", function(v)
		filter.Module = if v == "All modules" then nil else v
		api.Refresh()
	end, { Name = "Module", Width = 170, LayoutOrder = 2 })
	local sevChips = {}
	for i, s in ipairs(SEVERITIES) do
		sevChips[i] = Widgets.chip(bar, "Sev " .. s[1], i == 1, function()
			filter.MinSeverity, filter.MaxSeverity = s[2], s[3]
			for j, chip in ipairs(sevChips) do
				Widgets.SetActive(chip, j == i)
			end
			api.Refresh()
		end, { Name = "Sev_" .. s[1]:gsub("%-", "to"), LayoutOrder = 2 + i })
	end
	Widgets.select(bar, { "Last hour", "24 hours", "7 days", "All" }, "24 hours", function(v)
		filter.Range = v
		api.Refresh()
	end, { Name = "Range", Width = 110, LayoutOrder = 8 })
	local playerBox = Widgets.textbox(bar, "Player", { Name = "PlayerBox", Size = UDim2.fromOffset(120, 28), LayoutOrder = 9 })
	playerBox.FocusLost:Connect(function()
		filter.Player = playerBox.Text
		api.Refresh()
	end)
	local serverBox = Widgets.textbox(bar, "Server", { Name = "ServerBox", Size = UDim2.fromOffset(100, 28), LayoutOrder = 10 })
	serverBox.FocusLost:Connect(function()
		filter.Server = serverBox.Text
		api.Refresh()
	end)
	local unrev
	unrev = Widgets.chip(bar, "Only unreviewed", false, function()
		filter.Unreviewed = not filter.Unreviewed
		Widgets.SetActive(unrev, filter.Unreviewed)
		api.Refresh()
	end, { LayoutOrder = 11 })

	local actions = Widgets.make("Frame", { Name = "Actions", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = 2 }, frame)
	Widgets.list(actions, Enum.FillDirection.Horizontal, 6)

	local tbl: any
	tbl = Widgets.Table(frame, {
		Name = "FlagTable",
		Size = UDim2.new(1, 0, 0, 470),
		LayoutOrder = 3,
		Multi = true,
		Key = "Id",
		SortKey = "Time",
		Empty = "No flags match. A clean server shows nothing here.",
		FilterPlaceholder = "Filter rows (any column)...",
		Columns = {
			{ Key = "Time", Title = "Time", Width = 0.1, Format = function(r)
				return Widgets.clock(r.Time)
			end },
			{ Key = "Name", Title = "Player", Width = 0.13 },
			{ Key = "Module", Title = "Module", Width = 0.15 },
			{ Key = "Severity", Title = "Sev", Width = 0.06, Bold = true, Color = function(r)
				return AntiCheatTypes.SeverityColor(r.Severity)
			end },
			{ Key = "Confidence", Title = "Conf", Width = 0.07, Format = function(r)
				return ("%d%%"):format(math.floor((r.Confidence or 0) * 100))
			end },
			{ Key = "ScoreAfter", Title = "Score", Width = 0.07, Format = function(r)
				return ("%.0f"):format(r.ScoreAfter or 0)
			end },
			{ Key = "Reason", Title = "Reason", Width = 0.32, Color = function(r)
				return if r.FalsePositive then Theme.Colors.TextSecondary elseif r.Reviewed then Theme.Colors.TextSecondary else nil
			end, Format = function(r)
				return (if r.FalsePositive then "[FP] " elseif r.Reviewed then "[ok] " else "") .. tostring(r.Reason)
			end },
			{ Key = "Server", Title = "Server", Width = 0.1 },
		},
		OnOpen = function(r)
			Center.OpenFlag(r.Id)
		end,
		OnContext = function(r, pos)
			Center.RowMenu("flag", r, pos)
		end,
	})
	api.Table = tbl

	local function selection(): { any }
		local list = tbl.Selected()
		if #list == 0 then
			Center.Toast(false, "Select one or more rows first (checkbox or click).")
		end
		return list
	end
	Widgets.button(actions, "Mark reviewed", { Name = "MarkReviewed", Need = "Review", LayoutOrder = 1, OnClick = function()
		local ids = {}
		for _, r in ipairs(selection()) do
			table.insert(ids, r.Id)
		end
		if #ids > 0 then
			Center.Act("markReviewed", { Ids = ids }, { OnDone = function()
				tbl.ClearSelection()
			end })
		end
	end })
	Widgets.button(actions, "Mark false positive", { Name = "FalsePositive", Need = "Review", LayoutOrder = 2, OnClick = function()
		local r = selection()[1]
		if r then
			Center.Act("falsePositive", { Id = r.Id }, { Confirm = { Title = "Mark as false positive", Message = ("Lower %s's weight for %s and remove this flag's points?"):format(r.Module, r.Name) } })
		end
	end })
	Widgets.button(actions, "Create case", { Name = "CreateCase", Need = "Review", LayoutOrder = 3, OnClick = function()
		local r = selection()[1]
		if r then
			Center.Act("createCase", { Id = r.Id })
		end
	end })
	Widgets.button(actions, "Export", { Name = "Export", LayoutOrder = 4, Tooltip = "Copy the filtered rows as CSV", OnClick = function()
		Widgets.copyBox("Flags (CSV)", Widgets.csv(tbl))
		Center.Audit(("exported %d flag row(s) as CSV"):format(#tbl.View()))
	end })

	function api.Refresh()
		if paused then
			return
		end
		local range = RANGES[filter.Range] or 0
		local result = Center.Call("flags", {
			Module = filter.Module,
			MinSeverity = filter.MinSeverity,
			MaxSeverity = filter.MaxSeverity,
			Player = if filter.Player ~= "" then filter.Player else nil,
			Server = if filter.Server ~= "" then filter.Server else nil,
			Unreviewed = filter.Unreviewed,
			Since = if range > 0 then os.time() - range else nil,
		})
		if result and result.Ok then
			tbl.SetRows(result.Flags)
		end
	end

	function api.OnShow()
		tbl.SetLoading(true)
		api.Refresh()
	end

	function api.Search(text: string)
		tbl.SetFilter(text)
	end

	return api
end

return FlagsPage
