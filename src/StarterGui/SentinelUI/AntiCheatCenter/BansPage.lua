--!strict
--[[
	BansPage.lua (Anti-Cheat Control Center, page 5: Banned)

	Players banned by the anti-cheat (automatic bans and ;acban), from
	Sentinel's ban store (the same list as Moderation > Banned). Summary
	line (active, permanent, ending within 24 h) + the ban settings in use
	(Bans.BanDays, DefaultType, AllowPermanent). Filter chips: Anti-cheat
	bans / All bans (staff bans are shown read-only here - they are managed
	in Sentinel's Banned page). Text filter. Each card: name, UserId, time
	left or PERMANENT, who / when, reason; actions Unban (reason, undoable
	from Logs), Change length (days or permanent - permanent only when
	Bans.AllowPermanent is on), Player (drawer with flags and evidence).

	Seeing the page: anticheat.ban, moderation.banlist or moderation.ban.
	Unban / Change length: anticheat.ban (server-checked; "bans", "banLift",
	"banEdit" actions of AntiCheatBridge).

	Stable names: Page_Bans.{Summary, Filters.{Chip_<label>, Search},
	Items.Ban_<userId>.{Unban, Length, Player}}
--]]

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local BansPage = {}

local SCOPES = { "Anti-cheat bans", "All bans" }

local function left(seconds: number?): string
	if not seconds then
		return "PERMANENT"
	end
	if seconds >= 86400 then
		return ("%dd %dh left"):format(seconds // 86400, (seconds % 86400) // 3600)
	elseif seconds >= 3600 then
		return ("%dh %dm left"):format(seconds // 3600, (seconds % 3600) // 60)
	end
	return ("%dm left"):format(math.max(1, seconds // 60))
end

function BansPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 10)
	local api: any = {}
	local scope = SCOPES[1]
	local data: any = nil

	local summary = Widgets.label(frame, "Loading banned players...", { Name = "Summary", Color = Theme.Colors.TextSecondary, Wrap = true, AutoY = true, TextSize = 13, LayoutOrder = 1 })

	local filters = Widgets.make("Frame", { Name = "Filters", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 2 }, frame)
	Widgets.list(filters, Enum.FillDirection.Horizontal, 6)
	local chips = {}
	for i, s in ipairs(SCOPES) do
		chips[s] = Widgets.chip(filters, s, s == scope, function()
			scope = s
			for name, chip in pairs(chips) do
				Widgets.SetActive(chip, name == s)
			end
			api.Refresh()
		end, { LayoutOrder = i })
	end
	local search = Widgets.textbox(filters, "Filter name, id, reason", { Name = "Search", Size = UDim2.fromOffset(240, 28), LayoutOrder = 10 })

	local items = Widgets.make("Frame", { Name = "Items", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3 }, frame)
	Widgets.list(items, nil, 8)

	local function clearItems()
		for _, c in ipairs(items:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
	end

	local function lengthForm(b: any)
		local cfg = (data and data.Config) or {}
		local choices = { "1 day", "3 days", "7 days", ("%d days (default)"):format(cfg.BanDays or 15), "30 days", "Custom days" }
		if cfg.AllowPermanent == true then
			table.insert(choices, "Permanent")
		end
		Widgets.form("Change ban length - " .. tostring(b.Name), {
			{ Key = "Length", Label = "New length (from now)", Kind = "choice", Choices = choices, Default = choices[4] },
			{ Key = "Days", Label = "Custom days (only for Custom days)", Placeholder = "e.g. 14" },
		}, function(v)
			local payload: any = { UserId = b.UserId }
			if v.Length == "Permanent" then
				payload.Permanent = true
			elseif v.Length == "Custom days" then
				local n = tonumber(v.Days)
				if not n or n < 1 or n > 3650 or n % 1 ~= 0 then
					return "Custom days must be a whole number from 1 to 3650."
				end
				payload.Days = n
			else
				payload.Days = tonumber(v.Length:match("^(%d+)"))
			end
			Center.Act("banEdit", payload, { NoRefresh = true, OnDone = function()
				api.Refresh()
			end })
			return nil
		end, {
			SubmitText = "Change",
			Description = if cfg.AllowPermanent == true
				then "Permanent bans are allowed (Settings > Bans)."
				else "Permanent anti-cheat bans are disabled (Settings > Bans > AllowPermanent).",
		})
	end

	local function render()
		clearItems()
		if not data then
			return
		end
		local needle = search.Text:lower()
		local shown = 0
		for i, b in ipairs(data.Bans or {}) do
			local text = ("%s %d %s %s"):format(tostring(b.Name), b.UserId, tostring(b.Reason), tostring(b.BannedByName)):lower()
			if needle == "" or text:find(needle, 1, true) then
				shown += 1
				local isAC = b.Source == "anticheat"
				local card = Widgets.make("Frame", { Name = "Ban_" .. b.UserId, BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i }, items)
				Theme.corner(card, Theme.Radius.M)
				Theme.padding(card, 10)
				Widgets.list(card, nil, 5)
				Widgets.label(card, ("%s  (%d)   -   %s"):format(tostring(b.Name or "?"), b.UserId, left(b.SecondsLeft)), {
					Bold = true,
					LayoutOrder = 1,
					Color = if b.Permanent then Theme.Colors.Error else Theme.Colors.Text,
				})
				Widgets.label(card, ("%s | by %s | %s"):format(
					if isAC then "Anti-cheat ban" else "Staff ban",
					tostring(b.BannedByName or b.BannedBy or "?"),
					if b.IssuedAt then Widgets.ago(b.IssuedAt) else "?"
				), { TextSize = 13, Color = Theme.Colors.TextSecondary, LayoutOrder = 2 })
				Widgets.label(card, tostring(b.Reason or ""), { TextSize = 13, Wrap = true, AutoY = true, LayoutOrder = 3 })
				local row = Center.ActionRow(card, 4)
				if isAC then
					Widgets.button(row, "Unban", { Name = "Unban", Kind = "danger", Need = "Ban", OnClick = function()
						Widgets.form("Unban " .. tostring(b.Name), {
							{ Key = "Reason", Label = "Reason", Required = true, Placeholder = "false positive, appeal accepted..." },
						}, function(v)
							Center.Act("banLift", { UserId = b.UserId, Reason = v.Reason }, { NoRefresh = true, OnDone = function()
								api.Refresh()
							end })
							return nil
						end, { SubmitText = "Unban", Description = "Lifts the ban on every server. Undo it from Logs & Help." })
					end })
					Widgets.button(row, "Change length", { Name = "Length", Need = "Ban", OnClick = function()
						lengthForm(b)
					end })
				else
					Widgets.label(row, "Managed in Sentinel > Moderation > Banned", { TextSize = 12, Color = Theme.Colors.TextSecondary })
				end
				Widgets.button(row, "Player", { Name = "Player", OnClick = function()
					Center.OpenPlayer(b.UserId, b.Name)
				end })
			end
		end
		if shown == 0 then
			Widgets.label(items, if #(data.Bans or {}) == 0 then "No active bans." else "No bans match the filter.", { Color = Theme.Colors.TextSecondary })
		end
	end

	search:GetPropertyChangedSignal("Text"):Connect(render)

	function api.Refresh()
		local result = Center.Call("bans", { All = scope == "All bans" })
		if not result then
			return
		end
		if not result.Ok then
			data = nil
			clearItems()
			summary.Text = result.Message or "You can't see banned players."
			return
		end
		data = result
		local perm, soon = 0, 0
		for _, b in ipairs(result.Bans or {}) do
			if b.Permanent then
				perm += 1
			elseif (b.SecondsLeft or 0) < 86400 then
				soon += 1
			end
		end
		local cfg = result.Config or {}
		summary.Text = ("%d active %s (%d permanent, %d ending within 24 h).   Ban settings: %s, %d days%s.%s"):format(
			#(result.Bans or {}),
			if scope == "All bans" then "ban(s)" else "anti-cheat ban(s)",
			perm,
			soon,
			tostring(cfg.DefaultType or "temporary"),
			cfg.BanDays or 15,
			if cfg.AllowPermanent == true then ", permanent allowed" else ", permanent DISABLED",
			if result.Error then "  " .. tostring(result.Error) else ""
		)
		render()
	end

	return api
end

return BansPage
