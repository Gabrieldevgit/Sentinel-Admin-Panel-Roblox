--!strict
--[[
	PlayersPage.lua (Anti-Cheat Control Center, page 3)

	Every player in this server: avatar, name, score (bar), top module,
	flags today, status (Clean / Watched / Exempt / Testing), ping, rank.
	Row click = player drawer (score graph, flag history, exemptions,
	notes, every action). The action bar works on the selected row: Watch,
	Exempt, Testing mode, Reset score, Warn, Kick, Ban (Sentinel's ban
	prompt -> ;acban, owner approval), Spectate, Correct. Lookup finds a
	player who is not here (stored flag history, exemptions, watch).

	Stable names: Page_Players.{Lookup.{LookupBox, LookupButton},
	Actions.<button>, PlayerTable}
--]]

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local PlayersPage = {}

local STATUS_COLORS = {
	Clean = function()
		return Theme.Colors.Success
	end,
	Watched = function()
		return Theme.Colors.Warning
	end,
	Exempt = function()
		return Theme.Colors.Accent
	end,
	Testing = function()
		return Theme.Colors.TextSecondary
	end,
}

function PlayersPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 10)
	local api: any = { Live = true }

	local lookup = Widgets.make("Frame", { Name = "Lookup", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = 1 }, frame)
	Widgets.list(lookup, Enum.FillDirection.Horizontal, 6)
	local box = Widgets.textbox(lookup, "Look up any player by name or UserId", { Name = "LookupBox", Size = UDim2.fromOffset(300, 30), LayoutOrder = 1 })
	local function doLookup()
		local q = box.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if q == "" then
			return
		end
		Center.OpenDrawer("Lookup: " .. q, function(body)
			local r = Center.Call("lookup", { Query = q })
			if not r or not r.Ok then
				Widgets.label(body, (r and r.Message) or "Not found.", { Color = Theme.Colors.TextSecondary, Wrap = true, AutoY = true })
				return
			end
			Widgets.label(body, ("%s (%d)%s"):format(r.Name, r.UserId, if r.Online then " - in this server" else ""), { Bold = true, TextSize = 15, LayoutOrder = 1 })
			Center.KV(body, "Watch", if r.Watch then r.Watch.Why else "not watched", 2)
			local ex = {}
			for _, e in ipairs(r.Exemptions or {}) do
				table.insert(ex, ("%s: %s"):format(e.Module, e.Reason))
			end
			Center.KV(body, "Exemptions", if #ex > 0 then table.concat(ex, "\n") else "none", 3)
			local actions = Center.ActionRow(body, 4)
			Center.PlayerButtons(actions, { UserId = r.UserId, Name = r.Name, Online = r.Online, Watched = r.Watch ~= nil })
			Widgets.label(body, ("Stored flags (%d)"):format(#r.Flags), { Bold = true, LayoutOrder = 10 })
			for i, f in ipairs(r.Flags) do
				Widgets.label(body, ("%s  %s sev %d  %s"):format(os.date("%Y-%m-%d %H:%M", f.Time) :: string, f.Module, f.Severity, f.Reason), { TextSize = 12, Wrap = true, AutoY = true, LayoutOrder = 10 + i })
			end
		end)
	end
	box.FocusLost:Connect(function(enter)
		if enter then
			doLookup()
		end
	end)
	Widgets.button(lookup, "Lookup", { Name = "LookupButton", LayoutOrder = 2, OnClick = doLookup })

	local actions = Widgets.make("Frame", { Name = "Actions", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, frame)
	local al = Widgets.list(actions, Enum.FillDirection.Horizontal, 6)
	al.Wraps = true
	local hint = Widgets.label(actions, "Select a player to act on them.", { Name = "Hint", Color = Theme.Colors.TextSecondary, Size = UDim2.fromOffset(240, 30), LayoutOrder = 0 })
	local selectedRow: any = nil

	local function renderActions()
		for _, c in ipairs(actions:GetChildren()) do
			if c:IsA("GuiObject") and c ~= hint then
				c:Destroy()
			end
		end
		hint.Visible = selectedRow == nil
		if selectedRow then
			local name = Widgets.label(actions, selectedRow.Name .. ":", { Bold = true, Size = UDim2.fromOffset(0, 30), LayoutOrder = 0 })
			name.AutomaticSize = Enum.AutomaticSize.X
			Center.PlayerButtons(actions, {
				UserId = selectedRow.UserId,
				Name = selectedRow.Name,
				Online = true,
				Testing = selectedRow.Status == "Testing",
				Watched = selectedRow.Status == "Watched",
			})
		end
	end

	local tbl = Widgets.Table(frame, {
		Name = "PlayerTable",
		Size = UDim2.new(1, 0, 0, 470),
		LayoutOrder = 3,
		Key = "UserId",
		SortKey = "Score",
		RowHeight = 34,
		Empty = "No players in this server.",
		FilterPlaceholder = "Search by name or ID...",
		Columns = {
			{ Key = "Avatar", Title = "", Width = 0.06, Image = function(r)
				return ("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48"):format(math.abs(r.UserId))
			end },
			{ Key = "Name", Title = "Name", Width = 0.17, Format = function(r)
				return if r.DisplayName and r.DisplayName ~= r.Name then ("%s (@%s)"):format(r.DisplayName, r.Name) else r.Name
			end },
			{ Key = "Score", Title = "Score", Width = 0.18, Bar = function(r)
				return (r.Score or 0) / 100
			end, Color = function(r)
				return if r.Score >= 60 then Theme.Colors.Error elseif r.Score >= 20 then Theme.Colors.Warning else Theme.Colors.Success
			end, Format = function(r)
				return ("%.0f"):format(r.Score or 0)
			end },
			{ Key = "TopModule", Title = "Top module", Width = 0.16 },
			{ Key = "FlagsToday", Title = "Flags today", Width = 0.1 },
			{ Key = "Status", Title = "Status", Width = 0.1, Color = function(r)
				local c = STATUS_COLORS[r.Status]
				return if c then c() else nil
			end },
			{ Key = "Ping", Title = "Ping", Width = 0.08, Format = function(r)
				return ("%d ms"):format(r.Ping or 0)
			end },
			{ Key = "Rank", Title = "Rank", Width = 0.15 },
			{ Key = "UserId", Title = "ID", Width = 0, Format = function(r)
				return tostring(r.UserId)
			end },
		},
		OnOpen = function(r)
			selectedRow = r
			renderActions()
			Center.OpenPlayer(r.UserId, r.Name)
		end,
		OnContext = function(r, pos)
			Center.RowMenu("player", r, pos)
		end,
	})
	api.Table = tbl

	function api.Refresh()
		local result = Center.Call("players")
		if result and result.Ok then
			tbl.SetRows(result.Players)
			if selectedRow then
				local found = nil
				for _, r in ipairs(result.Players) do
					if r.UserId == selectedRow.UserId then
						found = r
					end
				end
				if not found or found.Status ~= selectedRow.Status then
					selectedRow = found
					renderActions()
				end
			end
		end
	end

	function api.OnShow()
		tbl.SetLoading(true)
		api.Refresh()
	end

	function api.Search(text: string)
		tbl.SetFilter(text)
	end

	renderActions()
	return api
end

return PlayersPage
