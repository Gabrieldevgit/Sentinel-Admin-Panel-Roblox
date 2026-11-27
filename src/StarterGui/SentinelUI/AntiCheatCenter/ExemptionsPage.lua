--!strict
--[[
	ExemptionsPage.lua (Anti-Cheat Control Center, page 6)

	Two tabs. Exemptions (player, module, reason, who added it, expiry) and
	Watchlist (player, since, why, score; plus players in Testing mode).
	Add exemption (player, module or all, duration, required reason),
	Remove (confirmed), Extend, Rank exemption (minimum rank exempt
	automatically), Watch alerts toggle (alert staff when a watched player
	joins any server).

	Stable names: Page_Exemptions.{Tabs.{Chip_Exemptions, Chip_Watchlist},
	Bar.{AddExemption, Remove, Extend, RankExempt, WatchAlerts, AddWatch},
	ExemptionTable, WatchTable}
--]]

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local ExemptionsPage = {}

local EXTEND = { ["30 minutes"] = 1800, ["1 hour"] = 3600, ["1 day"] = 86400, ["7 days"] = 604800 }

function ExemptionsPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 10)
	local api: any = {}
	local tab = "Exemptions"
	local data: any = nil

	local tabs = Widgets.make("Frame", { Name = "Tabs", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 1 }, frame)
	Widgets.list(tabs, Enum.FillDirection.Horizontal, 6)
	local bar = Widgets.make("Frame", { Name = "Bar", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, frame)
	local bl = Widgets.list(bar, Enum.FillDirection.Horizontal, 6)
	bl.Wraps = true

	local exTable = Widgets.Table(frame, {
		Name = "ExemptionTable",
		Size = UDim2.new(1, 0, 0, 440),
		LayoutOrder = 3,
		Key = "Id",
		SortKey = "At",
		Empty = "No exemptions. Staff at or above the exempt rank are skipped automatically.",
		Columns = {
			{ Key = "Name", Title = "Player", Width = 0.16 },
			{ Key = "Module", Title = "Module", Width = 0.16 },
			{ Key = "Reason", Title = "Reason", Width = 0.3 },
			{ Key = "By", Title = "Added by", Width = 0.14 },
			{ Key = "ExpiresAt", Title = "Expires", Width = 0.2, Sort = function(r)
				return r.ExpiresAt or math.huge
			end, Format = function(r)
				if not r.ExpiresAt then
					return "permanent"
				end
				local left = r.ExpiresAt - os.time()
				return if left > 86400 then ("in %dd"):format(left // 86400) elseif left > 3600 then ("in %dh"):format(left // 3600) else ("in %dm"):format(math.max(0, left // 60))
			end },
		},
		OnContext = function(r, pos)
			Center.RowMenu("player", r, pos)
		end,
	})
	local watchTable = Widgets.Table(frame, {
		Name = "WatchTable",
		Size = UDim2.new(1, 0, 0, 440),
		LayoutOrder = 4,
		Key = "UserId",
		SortKey = "Since",
		Empty = "Nobody is watched or in Testing mode.",
		Columns = {
			{ Key = "Name", Title = "Player", Width = 0.2 },
			{ Key = "Since", Title = "Since", Width = 0.14, Format = function(r)
				return Widgets.ago(r.Since)
			end },
			{ Key = "Why", Title = "Why", Width = 0.36 },
			{ Key = "By", Title = "By", Width = 0.14 },
			{ Key = "Score", Title = "Score", Width = 0.12, Format = function(r)
				return ("%.0f"):format(r.Score or 0)
			end },
		},
		OnOpen = function(r)
			Center.OpenPlayer(r.UserId, r.Name)
		end,
		OnContext = function(r, pos)
			Center.RowMenu("player", r, pos)
		end,
	})

	local function renderBar()
		for _, c in ipairs(bar:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		if tab == "Exemptions" then
			Widgets.button(bar, "Add exemption", { Name = "AddExemption", Kind = "primary", Need = "Exempt", LayoutOrder = 1, OnClick = function()
				Center.ExemptForm(nil)
			end })
			Widgets.button(bar, "Remove", { Name = "Remove", Need = "Exempt", LayoutOrder = 2, OnClick = function()
				local r = exTable.Selected()[1]
				if not r then
					Center.Toast(false, "Click an exemption first.")
					return
				end
				Center.Act("exemptRemove", { Id = r.Id }, { Confirm = { Title = "Remove exemption", Message = ("Remove %s's %s exemption?"):format(r.Name, r.Module) } })
			end })
			Widgets.button(bar, "Extend", { Name = "Extend", Need = "Exempt", LayoutOrder = 3, OnClick = function()
				local r = exTable.Selected()[1]
				if not r then
					Center.Toast(false, "Click an exemption first.")
					return
				end
				Widgets.form("Extend " .. r.Name .. "'s exemption", { { Key = "By", Label = "Add", Kind = "choice", Choices = { "30 minutes", "1 hour", "1 day", "7 days" }, Default = "1 hour" } }, function(v)
					Center.Act("exemptExtend", { Id = r.Id, Seconds = EXTEND[v.By] })
					return nil
				end, { SubmitText = "Extend" })
			end })
		else
			Widgets.button(bar, "Watch a player", { Name = "AddWatch", Kind = "primary", Need = "Exempt", LayoutOrder = 1, OnClick = function()
				Widgets.form("Watch a player", { { Key = "Player", Label = "UserId (in this server: use the Players page)", Required = true }, { Key = "Why", Label = "Why", Required = true } }, function(v)
					local id = tonumber(v.Player)
					if not id then
						return "Enter a UserId."
					end
					Center.Act("watchAdd", { UserId = id, Why = v.Why })
					return nil
				end, { SubmitText = "Watch" })
			end })
			Widgets.button(bar, "Remove", { Name = "Remove", Need = "Exempt", LayoutOrder = 2, OnClick = function()
				local r = watchTable.Selected()[1]
				if not r then
					Center.Toast(false, "Click a row first.")
					return
				end
				if r.Testing then
					Center.Act("testing", { UserId = r.UserId, On = false })
				else
					Center.Act("watchRemove", { UserId = r.UserId }, { Confirm = { Title = "Remove from watch list", Message = ("Stop watching %s?"):format(r.Name) } })
				end
			end })
		end
		local ranks = { "None" }
		for _, rank in ipairs((data and data.Ranks) or {}) do
			table.insert(ranks, rank.Name)
		end
		Widgets.label(bar, "Exempt rank:", { Color = Theme.Colors.TextSecondary, Size = UDim2.fromOffset(86, 30), LayoutOrder = 10 })
		Widgets.select(bar, ranks, (data and data.ExemptRank) or "Admin", function(v)
			Center.Act("exemptRank", { Rank = v }, { Confirm = { Title = "Rank exemption", Message = if v == "None" then "Check every player, staff included?" else ("Skip every check for players ranked %s or higher?"):format(v) } })
		end, { Name = "RankExempt", Need = "Config", Width = 130, LayoutOrder = 11, Tooltip = "Players at or above this rank are never checked" })
		local alertsOn = data == nil or data.WatchAlerts ~= false
		Widgets.button(bar, if alertsOn then "Watch alerts: on" else "Watch alerts: off", { Name = "WatchAlerts", Need = "Config", LayoutOrder = 12, Tooltip = "Alert staff when a watched player joins any server", OnClick = function()
			Center.Act("watchAlerts", { On = not alertsOn })
		end })
	end

	local chips = {}
	for i, name in ipairs({ "Exemptions", "Watchlist" }) do
		chips[name] = Widgets.chip(tabs, name, name == tab, function()
			tab = name
			for n, c in pairs(chips) do
				Widgets.SetActive(c, n == tab)
			end
			exTable.Root.Visible = tab == "Exemptions"
			watchTable.Root.Visible = tab == "Watchlist"
			api.Table = if tab == "Exemptions" then exTable else watchTable
			renderBar()
		end, { LayoutOrder = i })
	end
	watchTable.Root.Visible = false
	api.Table = exTable

	function api.Refresh()
		local result = Center.Call("exemptions")
		if not result or not result.Ok then
			return
		end
		data = result
		exTable.SetRows(result.Exemptions)
		local rows = {}
		for _, w in ipairs(result.Watch) do
			table.insert(rows, w)
		end
		for _, t in ipairs(result.Testing) do
			table.insert(rows, { UserId = t.UserId, Name = t.Name, Since = t.At, Why = "Testing mode (checks log only)", By = t.By, Score = 0, Testing = true })
		end
		watchTable.SetRows(rows)
		renderBar()
	end

	function api.Search(text: string)
		api.Table.SetFilter(text)
	end

	renderBar()
	return api
end

return ExemptionsPage
