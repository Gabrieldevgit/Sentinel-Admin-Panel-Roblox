--!strict
--[[
	AnalyticsPage.lua (Anti-Cheat Control Center, page 8: Analytics and
	Performance)

	Is the system accurate and cheap? Charts: flags by module, flags over
	time, top 10 flagged players, actions by type. Accuracy: false-positive
	rate per module (from staff marks). Performance: ms of server time per
	second per module, memory, remote calls per second. Health: DataStore
	and MessagingService status, queue sizes, last error. Range selector
	(1 hour / 24 hours / 7 days), module filter chips, Recommend (threshold
	suggestions from the false-positive data - never applied
	automatically), Export (the numbers as text).

	Counts are this server's (flags shared by other servers show on Live
	Flags). Stable names: Page_Analytics.{Toolbar.{Range_<r>, Recommend,
	Export}, ModuleFilter.Chip_<Module>, Charts.<chart>}
--]]

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local AnalyticsPage = {}

function AnalyticsPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 10)
	local api: any = {}
	local range = "24h"
	local selected: { [string]: boolean } = {}
	local last: any = nil

	local bar = Widgets.make("Frame", { Name = "Toolbar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1 }, frame)
	Widgets.list(bar, Enum.FillDirection.Horizontal, 6)
	local rangeChips = {}
	for i, r in ipairs({ { "1h", "1 hour" }, { "24h", "24 hours" }, { "7d", "7 days" } }) do
		rangeChips[r[1]] = Widgets.chip(bar, r[2], r[1] == range, function()
			range = r[1]
			for k, c in pairs(rangeChips) do
				Widgets.SetActive(c, k == range)
			end
			api.Refresh()
		end, { Name = "Range_" .. r[1], LayoutOrder = i })
	end
	Widgets.button(bar, "Recommend", { Name = "Recommend", LayoutOrder = 10, Tooltip = "Suggestions only - nothing is changed", OnClick = function()
		local r = Center.Call("recommend")
		if r and r.Ok then
			Widgets.form("Recommendations", {}, function()
				return nil
			end, { SubmitText = "OK", Description = "- " .. table.concat(r.Suggestions, "\n- ") .. "\n\nNothing was changed. Apply what you agree with on the Modules or Settings page." })
			Center.Audit("viewed recommendations")
		end
	end })
	Widgets.button(bar, "Export", { Name = "Export", LayoutOrder = 11, OnClick = function()
		if not last then
			return
		end
		local lines = { ("Sentinel AntiCheat analytics (%s, this server)"):format(last.Range), ("Total flags: %d"):format(last.Total) }
		table.insert(lines, "Flags by module:")
		for m, n in pairs(last.ByModule) do
			table.insert(lines, ("  %s: %d"):format(m, n))
		end
		table.insert(lines, "Top players:")
		for _, p in ipairs(last.TopPlayers) do
			table.insert(lines, ("  %s: %d flags, %.1f points"):format(p.Name, p.Flags, p.Points))
		end
		table.insert(lines, "Actions:")
		for k, n in pairs(last.Actions) do
			table.insert(lines, ("  %s: %d"):format(k, n))
		end
		table.insert(lines, "False-positive rate:")
		for m, a in pairs(last.Accuracy) do
			table.insert(lines, ("  %s: %.1f%% of %d reviewed"):format(m, a.Rate, a.Reviewed))
		end
		table.insert(lines, ("Performance: %.3f ms/s total, %.1f checks/s, %d MB memory, %.1f remote calls/s"):format(last.Performance.MsPerSec, last.Performance.ChecksPerSec, last.Performance.MemoryMb, last.RemoteCalls))
		for m, p in pairs(last.Performance.Modules) do
			table.insert(lines, ("  %s: %.3f ms/s, %d checks, %d errors"):format(m, p.MsPerSec, p.Checks, p.Errors))
		end
		Widgets.copyBox("Analytics", table.concat(lines, "\n"))
		Center.Audit("exported analytics")
	end })

	local filter = Widgets.make("Frame", { Name = "ModuleFilter", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, frame)
	local fl = Widgets.list(filter, Enum.FillDirection.Horizontal, 4)
	fl.Wraps = true
	for i, name in ipairs(Center.ModuleNames or {}) do
		local chip
		chip = Widgets.chip(filter, name, false, function()
			selected[name] = if selected[name] then nil else true
			Widgets.SetActive(chip, selected[name] == true)
			api.Refresh()
		end, { LayoutOrder = i })
	end

	local charts = Widgets.make("Frame", { Name = "Charts", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3 }, frame)
	Widgets.list(charts, nil, 10)

	local function sorted(map: { [string]: number }, max: number?): { any }
		local list = {}
		for k, v in pairs(map) do
			table.insert(list, { Label = k, Value = v })
		end
		table.sort(list, function(a, b)
			return a.Value > b.Value
		end)
		while max and #list > max do
			table.remove(list)
		end
		return list
	end

	function api.Refresh()
		local r = Center.Call("analytics", { Range = range, Modules = selected })
		if not r or not r.Ok then
			return
		end
		last = r
		for _, c in ipairs(charts:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		Widgets.label(charts, ("Flags over time (%s, %d total)"):format(r.Range, r.Total), { Bold = true, LayoutOrder = 1 })
		local values, labels = {}, {}
		for i, h in ipairs(r.ByHour) do
			values[i] = h.Count
			labels[i] = ("%s: %d"):format(os.date("%m-%d %H:00", h.Hour) :: string, h.Count)
		end
		Widgets.sparkline(charts, values, { Name = "OverTime", Labels = labels, LayoutOrder = 2 })
		Widgets.bars(charts, sorted(r.ByModule), { Name = "ByModule", Title = "Flags by module", LayoutOrder = 3 })
		local top = {}
		for _, p in ipairs(r.TopPlayers) do
			table.insert(top, { Label = p.Name, Value = p.Flags })
		end
		Widgets.bars(charts, top, { Name = "TopPlayers", Title = "Top 10 flagged players", LayoutOrder = 4, Color = Theme.Colors.Warning })
		Widgets.bars(charts, sorted(r.Actions), { Name = "Actions", Title = "Actions by type", LayoutOrder = 5, Color = Theme.Colors.Error })
		local accuracy = {}
		for m, a in pairs(r.Accuracy) do
			table.insert(accuracy, { Label = ("%s (%d reviewed)"):format(m, a.Reviewed), Value = a.Rate })
		end
		table.sort(accuracy, function(a, b)
			return a.Value > b.Value
		end)
		Widgets.bars(charts, accuracy, { Name = "Accuracy", Title = "False-positive rate per module (%)", LayoutOrder = 6, Format = function(v)
			return ("%.1f%%"):format(v)
		end, Empty = "No reviewed flags yet." })
		local perf = {}
		for m, p in pairs(r.Performance.Modules) do
			table.insert(perf, { Label = m, Value = p.MsPerSec })
		end
		table.sort(perf, function(a, b)
			return a.Value > b.Value
		end)
		Widgets.bars(charts, perf, { Name = "Performance", Title = ("Server cost: %.3f ms/s total (budget %.1f), %.1f checks/s, intervals x%.2f"):format(r.Performance.MsPerSec, r.Performance.Budget or 2, r.Performance.ChecksPerSec, r.Performance.CostFactor or 1), LayoutOrder = 7, Format = function(v)
			return ("%.3f"):format(v)
		end })
		Widgets.label(charts, ("Memory %d MB  |  Remote calls %.1f / s  |  %d players tracked"):format(r.Performance.MemoryMb, r.RemoteCalls, r.Performance.Players), { LayoutOrder = 8 })
		Widgets.label(charts, "Health", { Bold = true, LayoutOrder = 9 })
		for i, s in ipairs(r.Health.Stores) do
			Widgets.label(charts, ("%s: %s | %s | queued %d | writes %d | failures %d%s"):format(
				s.Name,
				if s.Ok then "OK" else "FAILING",
				if s.Live then "DataStore" else "memory only (Studio / not running)",
				s.Pending,
				s.Writes,
				s.Failures,
				if s.LastError then " | last error: " .. s.LastError else ""
			), { TextSize = 13, Wrap = true, AutoY = true, LayoutOrder = 9 + i, Color = if s.Ok then Theme.Colors.Text else Theme.Colors.Error })
		end
		Widgets.label(charts, ("MessagingService (cross-server): %s"):format(if r.Health.CrossServer.Ok then "OK" else ("unavailable - " .. tostring(r.Health.CrossServer.Error))), { TextSize = 13, Wrap = true, AutoY = true, LayoutOrder = 20, Color = if r.Health.CrossServer.Ok then Theme.Colors.Text else Theme.Colors.Warning })
	end

	return api
end

return AnalyticsPage
