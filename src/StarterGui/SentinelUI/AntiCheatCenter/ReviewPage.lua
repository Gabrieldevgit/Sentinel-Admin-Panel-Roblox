--!strict
--[[
	ReviewPage.lua (Anti-Cheat Control Center, page 4: Review Queue)

	Players the system wants a human to decide on: score 80 or more,
	repeated multi-module patterns and ban proposals (automatic game bans
	always land here unless a pattern ban is allowed). Each item: Approve ban
	(;acban - anticheat.ban, owner approval / confirm), Dismiss (not a
	cheater; score reduced by Bands.DismissReduce %), Escalate (Owner
	notified), Evidence (timeline of the item's flags), Add note, Assign to
	me. Status filter chips.

	Stable names: Page_Review.{Filters.Chip_<status>, Items.Item_<id>.{Approve,
	Dismiss, Escalate, Evidence, AddNote, Assign}}
--]]

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local ReviewPage = {}

local STATUSES = { "Open items", "Escalated", "Approved", "Dismissed", "All" }

function ReviewPage.Build(frame: ScrollingFrame, Center: any): any
	Widgets.list(frame, nil, 10)
	local api: any = { Live = true }
	local status = "Open items"

	local filters = Widgets.make("Frame", { Name = "Filters", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 1 }, frame)
	Widgets.list(filters, Enum.FillDirection.Horizontal, 6)
	local chips = {}
	for i, s in ipairs(STATUSES) do
		chips[s] = Widgets.chip(filters, s, s == status, function()
			status = s
			for name, chip in pairs(chips) do
				Widgets.SetActive(chip, name == s)
			end
			api.Refresh()
		end, { LayoutOrder = i })
	end

	local items = Widgets.make("Frame", { Name = "Items", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, frame)
	Widgets.list(items, nil, 8)

	local function evidence(item: any)
		Center.OpenDrawer(("Review #%d - %s"):format(item.Id, item.Name), function(body)
			Center.KV(body, "Score", ("%.0f"):format(item.Score), 1)
			Center.KV(body, "Modules", table.concat(item.Modules, ", "), 2)
			Center.KV(body, "Proposed", item.Proposed, 3)
			Center.KV(body, "Status", item.Status .. (if item.AssignedTo then " (" .. item.AssignedTo .. ")" else ""), 4)
			for i, n in ipairs(item.Notes or {}) do
				Center.KV(body, "Note by " .. n.By, n.Text, 4 + i)
			end
			Widgets.label(body, "Timeline", { Bold = true, LayoutOrder = 20 })
			local result = Center.Call("player", { UserId = item.UserId })
			local flags = (result and result.Flags) or {}
			table.sort(flags, function(a, b)
				return a.Time < b.Time
			end)
			for i, f in ipairs(flags) do
				local b = Widgets.button(body, ("%s  %s sev %d  +%.1f  %s"):format(Widgets.clock(f.Time), f.Module, f.Severity, f.Points or 0, f.Reason), { Name = "T_" .. i, Width = 10, LayoutOrder = 20 + i, OnClick = function()
					Center.OpenFlag(f.Id)
				end })
				b.Size = UDim2.new(1, 0, 0, 26)
				b.TextXAlignment = Enum.TextXAlignment.Left
				b.TextTruncate = Enum.TextTruncate.AtEnd
			end
			if #flags == 0 then
				Widgets.label(body, "Flags are no longer in this server's memory.", { Color = Theme.Colors.TextSecondary, LayoutOrder = 21 })
			end
		end)
	end

	function api.Refresh()
		local filter = if status == "Open items" then nil elseif status == "All" then "all" else status
		local result = Center.Call("queue", { Status = filter })
		if not result or not result.Ok then
			return
		end
		for _, c in ipairs(items:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local list = {}
		for _, item in ipairs(result.Items) do
			local open = item.Status == "Open" or item.Status == "Assigned" or item.Status == "Escalated"
			if status ~= "Open items" or open then
				table.insert(list, item)
			end
		end
		if #list == 0 then
			Widgets.label(items, "The queue is empty.", { Color = Theme.Colors.TextSecondary })
		end
		for i, item in ipairs(list) do
			local card = Widgets.make("Frame", { Name = "Item_" .. item.Id, BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i }, items)
			Theme.corner(card, Theme.Radius.M)
			Theme.padding(card, 10)
			Widgets.list(card, nil, 6)
			Widgets.label(card, ("#%d  %s  -  score %.0f  -  %s"):format(item.Id, item.Name, item.Score, item.Status), { Bold = true, LayoutOrder = 1, Color = if item.Status == "Escalated" then Theme.Colors.Warning else Theme.Colors.Text })
			Widgets.label(card, ("Proposed: %s | modules: %s | %s%s"):format(
				if item.Proposed == "ban" then "BAN" else "staff review",
				table.concat(item.Modules, ", "),
				Widgets.ago(item.CreatedAt),
				if item.AssignedTo then " | handled by " .. item.AssignedTo else ""
			), { TextSize = 13, Color = Theme.Colors.TextSecondary, Wrap = true, AutoY = true, LayoutOrder = 2 })
			Widgets.label(card, item.Reason, { TextSize = 13, Wrap = true, AutoY = true, LayoutOrder = 3 })
			local row = Center.ActionRow(card, 4)
			local closed = item.Status == "Approved" or item.Status == "Dismissed"
			if not closed then
				Widgets.button(row, "Approve ban", { Name = "Approve", Kind = "danger", Need = "Ban", OnClick = function()
					Center.Command(("acban %s review #%d: %s"):format(tostring(item.UserId), item.Id, table.concat(item.Modules, ", ")))
					Center.Toast(true, "Ban sent - confirm it, or wait for the Owner's approval.")
					task.delay(2, api.Refresh)
				end })
				Widgets.button(row, "Dismiss", { Name = "Dismiss", Need = "Review", OnClick = function()
					Center.Act("queueDismiss", { Id = item.Id }, { Confirm = { Title = "Dismiss #" .. item.Id, Message = ("Close this item as not a cheater and reduce %s's score?"):format(item.Name) } })
				end })
				Widgets.button(row, "Escalate", { Name = "Escalate", Need = "Review", OnClick = function()
					Center.Act("queueEscalate", { Id = item.Id })
				end })
				Widgets.button(row, "Assign to me", { Name = "Assign", Need = "Review", OnClick = function()
					Center.Act("queueAssign", { Id = item.Id })
				end })
			end
			Widgets.button(row, "Evidence", { Name = "Evidence", OnClick = function()
				evidence(item)
			end })
			Widgets.button(row, "Add note", { Name = "AddNote", Need = "Review", OnClick = function()
				Widgets.form("Note on #" .. item.Id, { { Key = "Text", Label = "Note", Kind = "multi", Required = true } }, function(v)
					Center.Act("queueNote", { Id = item.Id, Text = v.Text })
					return nil
				end)
			end })
		end
	end

	return api
end

return ReviewPage
