--!strict
--[[
	Center.lua (Sentinel AntiCheat - Anti-Cheat Control Center)

	Purpose:
		The Control Center window (ScreenGui "SentinelAntiCheat"): one window,
		three areas.
		  Top bar   title, master switch, mode badge, status pill
		            (Healthy / Degraded / Off), global search ("/"), bell
		            (alerts, Mark all read), close (X)
		  Sidebar   the 10 pages (keys 1-9, 0 = Logs) with unread badges; on phones it
		            folds into a menu button
		  Main      the page; a detail drawer (flag / player) slides over it
		            from the right and closes with Esc or its X
		Desktop: drag the top bar, resize from the bottom-right corner.
		Phones (touch-only or a screen < 760 px wide): full screen.

		Only players the server says have anticheat.view get the window
		(Center.Init asks "access" first and builds nothing otherwise);
		every action is checked again on the server (AntiCheatBridge).

		Keys while open: F7 toggle (init.client), Esc drawer -> modal ->
		window, Up / Down rows (or the sidebar), Enter open, 1-9 / 0 pages,
		/ search, R refresh, Ctrl+K palette with anti-cheat commands first.

	Stable names (Studio MCP): PlayerGui.SentinelAntiCheat.Window.{TopBar.{
		MasterSwitch, ModeBadge, StatusPill, Search, BellButton, CloseButton},
		Sidebar.Nav_<PageId>, Main.Page_<PageId>, Drawer.{Title, CloseButton,
		Body}, PanicBanner}

	Public API:
		Center.Init(deps) -> boolean (false = no access)
		Center.Open(page?) / Close() / Toggle() / IsOpen() / IsBuilt()
		Center.ShowPage(id), Center.Refresh()
		Center.Call(action, payload) -> result?
		Center.Act(action, payload, opts?)   -- confirm (ConfirmDialog) + toast + refresh
		Center.Command(text)                 -- a Sentinel command (ExecuteCommandRemote)
		Center.Toast(ok, message)
		Center.OpenDrawer(title, build) / CloseDrawer()
		Center.OpenFlag(id) / OpenPlayer(userId, name?) / RowMenu(kind, row, position)
		Center.Can(key), Center.Status, Center.Badge (fn set by init.client)
--]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local AntiCheatTypes = require(Shared:WaitForChild("AntiCheatTypes"))

local Theme = require(script.Parent.Parent:WaitForChild("Theme"))
local Widgets = require(script.Parent:WaitForChild("Widgets"))

local Center: any = {}

local localPlayer = Players.LocalPlayer
local remote: RemoteFunction? = nil
local deps: any = {}
local built = false
local isOpen = false
local access: any = nil
local screen: ScreenGui? = nil
local window: Frame? = nil
local main: Frame? = nil
local drawer: Frame? = nil
local sidebar: Frame? = nil
local pages: { [string]: any } = {}
local navButtons: { [string]: TextButton } = {}
local currentPage = "Overview"
local navCursor = 1
local alerts: { any } = {}
local unreadAlerts = 0
local statusWidgets: any = {}
local searchBox: TextBox? = nil
local refreshQueued = false

Center.Status = nil :: any

local PAGE_MODULES = {
	Overview = "OverviewPage",
	Flags = "FlagsPage",
	Players = "PlayersPage",
	Review = "ReviewPage",
	Bans = "BansPage",
	Modules = "ModulesPage",
	Exemptions = "ExemptionsPage",
	Settings = "SettingsPage",
	Analytics = "AnalyticsPage",
	Logs = "LogsPage",
}

local PAGE_GLYPHS = {
	Overview = "O", Flags = "F", Players = "P", Review = "R", Bans = "B", Modules = "M",
	Exemptions = "E", Settings = "S", Analytics = "A", Logs = "L",
}

-- ---------------------------------------------------------------------------
-- Server calls
-- ---------------------------------------------------------------------------
function Center.Toast(ok: boolean, message: string?)
	if not message or message == "" then
		return
	end
	local nc = deps.NotificationCenter
	if nc and nc.Notify then
		nc.Notify({ Kind = if ok then "success" else "error", Title = "Anti-Cheat", Message = message })
	end
end

function Center.Call(action: string, payload: any?): any
	if not remote then
		return nil
	end
	local ok, result = pcall(function()
		return (remote :: RemoteFunction):InvokeServer(action, payload)
	end)
	if not ok or type(result) ~= "table" then
		Center.Toast(false, "The server did not answer (rate limit or error). Try again.")
		return nil
	end
	return result
end

function Center.Can(key: string): boolean
	return access ~= nil and access.Can ~= nil and access.Can[key] == true
end

-- opts = { Confirm = { Title, Message }, NoRefresh, OnDone(result) }
function Center.Act(action: string, payload: any?, opts: any?)
	local o = opts or {}
	local function run()
		local result = Center.Call(action, payload)
		if result then
			Center.Toast(result.Ok == true, result.Message)
			if o.OnDone then
				o.OnDone(result)
			end
			if not o.NoRefresh then
				Center.Refresh()
				Center.RefreshDrawer()
			end
		end
	end
	if o.Confirm and deps.ConfirmDialog then
		deps.ConfirmDialog.Show({
			Title = o.Confirm.Title,
			Message = o.Confirm.Message,
			RequiredText = o.Confirm.Required or "CONFIRM",
			ConfirmLabel = o.Confirm.Label or "Confirm",
			OnConfirm = function()
				task.spawn(run)
			end,
		})
	else
		task.spawn(run)
	end
end

local executeRemote = Shared:WaitForChild("ExecuteCommandRemote", 10) :: RemoteEvent?
function Center.Command(text: string)
	if executeRemote then
		executeRemote:FireServer(text, { Source = "anticheat" })
	end
end

-- Records a UI-only action (export, copy, tour) in the audit log.
function Center.Audit(what: string)
	task.spawn(Center.Call, "audit", { What = what })
end

-- ---------------------------------------------------------------------------
-- Status (top bar, sidebar badges, top-bar red dot)
-- ---------------------------------------------------------------------------
local function modeColor(mode: string): Color3
	if mode == "strict" then
		return Theme.Colors.Error
	elseif mode == "balanced" then
		return Theme.Colors.Warning
	end
	return Theme.Colors.Accent
end

local function applyStatus(status: any)
	if type(status) ~= "table" then
		return
	end
	Center.Status = status
	local w = statusWidgets
	if w.Switch then
		w.Switch.Set(status.Enabled == true)
	end
	if w.Mode then
		w.Mode.Text = tostring(status.Mode):upper()
		w.Mode.BackgroundColor3 = modeColor(status.Mode)
	end
	if w.Pill then
		w.Pill.Text = status.Health
		w.Pill.BackgroundColor3 = if status.Health == "Healthy" then Theme.Colors.Success elseif status.Health == "Degraded" then Theme.Colors.Warning else Theme.Colors.Border
	end
	if w.Panic then
		w.Panic.Visible = status.Panic == true
	end
	if w.Warn then
		w.Warn.Visible = #(status.Warnings or {}) > 0 and not status.Panic
		w.Warn.Text = "  " .. table.concat(status.Warnings or {}, "  |  ")
	end
	local function badge(id: string, n: number)
		local b = navButtons[id]
		local label = b and b:FindFirstChild("Badge") :: TextLabel?
		if label then
			label.Visible = n > 0
			label.Text = if n > 99 then "99+" else tostring(n)
		end
	end
	badge("Flags", status.Unreviewed or 0)
	badge("Review", status.OpenReviews or 0)
	if Center.Badge then
		pcall(Center.Badge, (status.UnreviewedHigh or 0) > 0)
	end
end
Center.ApplyStatus = applyStatus

local function refreshBell()
	local b = statusWidgets.BellBadge :: TextLabel?
	if b then
		b.Visible = unreadAlerts > 0
		b.Text = tostring(math.min(unreadAlerts, 99))
	end
end

-- ---------------------------------------------------------------------------
-- Pages
-- ---------------------------------------------------------------------------
function Center.Refresh()
	local page = pages[currentPage]
	if page and page.Api and page.Api.Refresh then
		task.spawn(page.Api.Refresh)
	end
end

local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.delay(1, function()
		refreshQueued = false
		if isOpen then
			local page = pages[currentPage]
			if page and page.Api and page.Api.Live then
				Center.Refresh()
			end
		end
	end)
end

local function buildPage(id: string): any
	local page = pages[id]
	if page.Api then
		return page
	end
	local moduleScript = script.Parent:FindFirstChild(PAGE_MODULES[id])
	if moduleScript then
		local ok, api = pcall(function()
			return require(moduleScript :: ModuleScript).Build(page.Frame, Center)
		end)
		if ok then
			page.Api = api or {}
		else
			warn(("[Sentinel.AntiCheat] page %s failed: %s"):format(id, tostring(api)))
			Widgets.label(page.Frame, "This page failed to load: " .. tostring(api), { Color = Theme.Colors.Error, Wrap = true, AutoY = true })
			page.Api = {}
		end
	end
	return page
end

function Center.ShowPage(id: string, arg: any?)
	if not pages[id] then
		return
	end
	if id ~= currentPage then
		Center.CloseDrawer() -- its content belongs to the page being left
	end
	Widgets.hideTooltip()
	currentPage = id
	for pageId, page in pairs(pages) do
		page.Frame.Visible = pageId == id
		local b = navButtons[pageId]
		if b then
			Widgets.SetActive(b, pageId == id)
			b.TextXAlignment = Enum.TextXAlignment.Left
		end
	end
	for i, p in ipairs(AntiCheatTypes.PAGES) do
		if p.Id == id then
			navCursor = i
		end
	end
	local page = buildPage(id)
	if page.Api.OnShow then
		task.spawn(page.Api.OnShow, arg)
	elseif page.Api.Refresh then
		task.spawn(page.Api.Refresh)
	end
	if sidebar and sidebar:GetAttribute("Mobile") then
		sidebar.Visible = false
	end
end

function Center.CurrentPage(): string
	return currentPage
end

-- ---------------------------------------------------------------------------
-- Drawer
-- ---------------------------------------------------------------------------
local drawerSeq = 0 -- bumps on every open, so a pending close never hides a newer drawer

function Center.CloseDrawer(): boolean
	if drawer and drawer.Visible then
		Theme.tween(drawer, Theme.Motion.Normal, { Position = UDim2.new(1, 0, 0, 0) })
		local seq = drawerSeq
		task.delay(0.2, function()
			if drawer and drawerSeq == seq then
				drawer.Visible = false
			end
		end)
		return true
	end
	return false
end

-- The open drawer's title and builder, so actions can rebuild it with
-- fresh data (RefreshDrawer) instead of leaving stale values on screen.
local drawerTitle: string? = nil
local drawerBuild: ((Frame) -> ())? = nil

function Center.OpenDrawer(title: string, build: (Frame) -> (), keepPosition: boolean?)
	local d = drawer :: Frame
	local body = d:FindFirstChild("Body") :: ScrollingFrame
	for _, c in ipairs(body:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	drawerTitle, drawerBuild = title, build
	if not keepPosition then
		drawerSeq += 1
	end
	(d:FindFirstChild("Title") :: TextLabel).Text = title
	if not (keepPosition and d.Visible) then
		d.Visible = true
		d.Position = UDim2.new(1, 0, 0, 0)
		Theme.tween(d, Theme.Motion.Normal, { Position = UDim2.new(1, -d.AbsoluteSize.X, 0, 0) })
	end
	local ok, err = pcall(build, body)
	if not ok then
		Widgets.label(body, "Could not show this: " .. tostring(err), { Color = Theme.Colors.Error, Wrap = true, AutoY = true })
	end
end

-- Rebuilds the open drawer in place (after an action changed its data).
function Center.RefreshDrawer()
	if drawer and drawer.Visible and drawerTitle and drawerBuild then
		Center.OpenDrawer(drawerTitle, drawerBuild, true)
	end
end

local function kv(parent: Instance, key: string, value: string, order: number)
	local row = Widgets.make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, parent)
	Widgets.label(row, key, { Color = Theme.Colors.TextSecondary, TextSize = 12, Size = UDim2.new(0.32, 0, 0, 18) })
	local v = Widgets.label(row, value, { TextSize = 13, Wrap = true, AutoY = true, Size = UDim2.new(0.68, 0, 0, 18) })
	v.Position = UDim2.fromScale(0.32, 0)
end
Center.KV = kv

local function actionRow(parent: Instance, order: number): Frame
	local row = Widgets.make("Frame", { Name = "Actions", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, parent)
	local layout = Widgets.list(row, Enum.FillDirection.Horizontal, 6)
	layout.Wraps = true
	return row
end
Center.ActionRow = actionRow

local function scoreGraph(parent: Instance, history: { any }, order: number)
	local values = {}
	for i = math.max(1, #history - 39), #history do
		table.insert(values, history[i].S)
	end
	if #values == 0 then
		Widgets.label(parent, "No score history yet.", { Color = Theme.Colors.TextSecondary, LayoutOrder = order })
		return
	end
	Widgets.sparkline(parent, values, { Name = "ScoreGraph", Size = UDim2.new(1, 0, 0, 60), Color = Theme.Colors.Warning, LayoutOrder = order })
end
Center.ScoreGraph = scoreGraph

function Center.FlagActions(parent: Instance, flag: any, order: number)
	local row = actionRow(parent, order)
	Widgets.button(row, "Mark reviewed", { Name = "MarkReviewed", Need = "Review", OnClick = function()
		Center.Act("markReviewed", { Ids = { flag.Id } })
	end })
	Widgets.button(row, "Mark false positive", { Name = "FalsePositive", Need = "Review", OnClick = function()
		Center.Act("falsePositive", { Id = flag.Id }, { Confirm = { Title = "Mark as false positive", Message = ("Lower %s's weight for %s and remove this flag's points?"):format(flag.Module, flag.Name) } })
	end })
	Widgets.button(row, "Create case", { Name = "CreateCase", Need = "Review", OnClick = function()
		Center.Act("createCase", { Id = flag.Id })
	end })
	Widgets.button(row, "Player", { Name = "OpenPlayer", OnClick = function()
		Center.OpenPlayer(flag.UserId, flag.Name)
	end })
end

function Center.OpenFlag(id: string)
	Center.OpenDrawer("Flag " .. id, function(body)
		Widgets.label(body, "Loading...", { Name = "Loading", Color = Theme.Colors.TextSecondary })
		local result = Center.Call("flag", { Id = id })
		local loading = body:FindFirstChild("Loading")
		if loading then
			loading:Destroy()
		end
		if not result or not result.Ok then
			Widgets.label(body, (result and result.Message) or "Not found.", { Color = Theme.Colors.TextSecondary, Wrap = true, AutoY = true })
			return
		end
		local f = result.Flag
		local e = f.Evidence or {}
		Widgets.label(body, ("%s - %s"):format(f.Name, f.Module), { Bold = true, TextSize = 16, LayoutOrder = 1 })
		Widgets.label(body, f.Reason, { Wrap = true, AutoY = true, LayoutOrder = 2 })
		kv(body, "Severity", ("%d / 10"):format(f.Severity), 3)
		kv(body, "Confidence", ("%.0f %%"):format((f.Confidence or 0) * 100), 4)
		kv(body, "Points", ("+%.1f (score after %.1f)"):format(f.Points or 0, f.ScoreAfter or 0), 5)
		kv(body, "When / server", ("%s  (%s)  %s"):format(Widgets.clock(f.Time), Widgets.ago(f.Time), tostring(f.Server)), 6)
		kv(body, "Action", tostring(f.ActionResult or f.Action or "logged"), 7)
		kv(body, "Status", if f.FalsePositive then "False positive" elseif f.Reviewed then ("Reviewed by " .. tostring(f.ReviewedBy)) else "Unreviewed", 8)
		Widgets.label(body, "Evidence", { Bold = true, LayoutOrder = 10 })
		kv(body, "Ping / server FPS", ("%s ms / %s"):format(tostring(e.Ping), tostring(e.ServerFps)), 11)
		kv(body, "Exemptions in effect", if e.Exemptions and #e.Exemptions > 0 then table.concat(e.Exemptions, "; ") else "none", 12)
		local details = {}
		for k, v in pairs(e.Details or {}) do
			if type(v) ~= "table" then
				table.insert(details, ("%s = %s"):format(k, if type(v) == "number" then ("%.2f"):format(v) else tostring(v)))
			elseif #v > 0 then
				table.insert(details, ("%s = %s"):format(k, table.concat((function()
					local out = {}
					for _, x in ipairs(v) do
						table.insert(out, tostring(x))
					end
					return out
				end)(), ", ")))
			end
		end
		table.sort(details)
		kv(body, "Module details", if #details > 0 then table.concat(details, "\n") else "-", 13)
		local samples = {}
		for _, s in ipairs(e.Samples or {}) do
			table.insert(samples, ("%+.1fs  %.0f, %.0f, %.0f"):format(s.T, s.X, s.Y, s.Z))
		end
		kv(body, ("Positions (last %d samples)"):format(#samples), if #samples > 0 then table.concat(samples, "\n") else "-", 14)
		Widgets.label(body, "Score history", { Bold = true, LayoutOrder = 20 })
		scoreGraph(body, result.History or {}, 21)
		Center.FlagActions(body, f, 30)
	end)
end

function Center.OpenPlayer(userId: number, name: string?)
	Center.OpenDrawer(name or ("Player " .. tostring(userId)), function(body)
		local result = Center.Call("player", { UserId = userId })
		if not result or not result.Ok then
			Widgets.label(body, (result and result.Message) or "Not found.", { Color = Theme.Colors.TextSecondary })
			return
		end
		local row = result.Row
		Widgets.label(body, ("%s  (score %.1f)"):format(result.Name, result.Score or 0), { Bold = true, TextSize = 16, LayoutOrder = 1 })
		if row then
			kv(body, "Status / rank / ping", ("%s / %s / %d ms"):format(row.Status, row.Rank, row.Ping), 2)
		else
			kv(body, "Status", "not in this server", 2)
		end
		kv(body, "Testing mode", if result.Testing then "on (checks log only)" else "off", 3)
		kv(body, "Watch", if result.Watch then ("since %s: %s"):format(Widgets.ago(result.Watch.Since), result.Watch.Why) else "not watched", 4)
		kv(body, "Active exemptions", if #(result.Active or {}) > 0 then table.concat(result.Active, "\n") else "none", 5)
		local weights = {}
		for m, w in pairs(result.Weights or {}) do
			table.insert(weights, ("%s x%.2f"):format(m, w))
		end
		kv(body, "False-positive weights", if #weights > 0 then table.concat(weights, ", ") else "none", 6)
		kv(body, "Admin flight", if #(result.Flight or {}) > 0 then table.concat(result.Flight, ", ") .. " (movement checks paused)" else "none", 7)
		Widgets.label(body, "Score", { Bold = true, LayoutOrder = 10 })
		scoreGraph(body, result.History or {}, 11)
		local actions = actionRow(body, 12)
		Center.PlayerButtons(actions, { UserId = userId, Name = result.Name, Online = row ~= nil, Testing = result.Testing, Watched = result.Watch ~= nil })
		Widgets.label(body, ("Flags (%d)"):format(#(result.Flags or {})), { Bold = true, LayoutOrder = 20 })
		for i, f in ipairs(result.Flags or {}) do
			local b = Widgets.button(body, ("%s  %s sev %d  %s"):format(Widgets.clock(f.Time), f.Module, f.Severity, f.Reason), { Name = "Flag_" .. i, Width = 10, LayoutOrder = 20 + i, OnClick = function()
				Center.OpenFlag(f.Id)
			end })
			b.Size = UDim2.new(1, 0, 0, 28)
			b.TextXAlignment = Enum.TextXAlignment.Left
			b.TextTruncate = Enum.TextTruncate.AtEnd
			b.TextColor3 = AntiCheatTypes.SeverityColor(f.Severity)
		end
		Widgets.label(body, "Staff notes", { Bold = true, LayoutOrder = 200 })
		for i, n in ipairs(result.Notes or {}) do
			if i > 10 then
				break
			end
			Widgets.label(body, ("%s (%s): %s"):format(tostring(n.AddedBy), Widgets.ago(n.Timestamp), tostring(n.Text)), { Wrap = true, AutoY = true, TextSize = 12, LayoutOrder = 200 + i })
		end
		Widgets.button(body, "Add note", { Name = "AddNote", Need = "Review", LayoutOrder = 300, OnClick = function()
			Widgets.form("Note on " .. result.Name, { { Key = "Text", Label = "Note", Kind = "multi", Required = true } }, function(v)
				Center.Act("note", { UserId = userId, Text = v.Text })
				return nil
			end)
		end })
	end)
end

-- Exempt form shared by the Players page, drawer and Exemptions page.
function Center.ExemptForm(target: any?)
	local status = Center.Status or {}
	local modules = { "all" }
	for _, name in ipairs(Center.ModuleNames or {}) do
		table.insert(modules, name)
	end
	local fields = {}
	if not target then
		table.insert(fields, { Key = "Player", Label = "Player (name or UserId)", Required = true })
	end
	table.insert(fields, { Key = "Module", Label = "Module", Kind = "choice", Choices = modules, Default = "all" })
	table.insert(fields, { Key = "Duration", Label = "Duration", Kind = "choice", Choices = { "30 minutes", "1 hour", "6 hours", "1 day", "7 days", "30 days", "Permanent" }, Default = "1 hour" })
	table.insert(fields, { Key = "Reason", Label = "Reason", Required = true })
	local _ = status
	Widgets.form(if target then "Exempt " .. target.Name else "Add exemption", fields, function(v)
		local seconds = ({ ["30 minutes"] = 1800, ["1 hour"] = 3600, ["6 hours"] = 21600, ["1 day"] = 86400, ["7 days"] = 604800, ["30 days"] = 2592000 })[v.Duration]
		local payload = { Module = v.Module, Seconds = seconds, Reason = v.Reason }
		if target then
			payload.UserId = target.UserId
		else
			local asId = tonumber(v.Player)
			if asId then
				payload.UserId = asId
			else
				payload.Name = v.Player
			end
		end
		Center.Act("exemptAdd", payload)
		return nil
	end, { SubmitText = "Exempt" })
end

local function reasonForm(title: string, onReason: (string) -> ())
	Widgets.form(title, { { Key = "Reason", Label = "Reason", Required = true } }, function(v)
		onReason(v.Reason)
		return nil
	end, { SubmitText = "Send" })
end

-- The Players page / drawer buttons for one player.
function Center.PlayerButtons(row: Instance, p: any)
	Widgets.button(row, if p.Watched then "Unwatch" else "Watch", { Name = "Watch", Need = "Exempt", OnClick = function()
		if p.Watched then
			Center.Act("watchRemove", { UserId = p.UserId }, { Confirm = { Title = "Remove from watch list", Message = ("Stop watching %s?"):format(p.Name) } })
		else
			Center.Act("watchAdd", { UserId = p.UserId, Why = "watched from the Control Center" })
		end
	end })
	Widgets.button(row, "Exempt", { Name = "Exempt", Need = "Exempt", OnClick = function()
		Center.ExemptForm(p)
	end })
	Widgets.button(row, if p.Testing then "End testing" else "Testing mode", { Name = "Testing", Need = "Exempt", OnClick = function()
		Center.Act("testing", { UserId = p.UserId, On = not p.Testing })
	end })
	Widgets.button(row, "Reset score", { Name = "ResetScore", Need = "Act", OnClick = function()
		Center.Act("resetScore", { UserId = p.UserId }, { Confirm = { Title = "Reset score", Message = ("Set %s's suspicion score to 0? (audit-logged, undo from Logs)"):format(p.Name) } })
	end })
	Widgets.button(row, "Warn", { Name = "Warn", Need = "Act", OnClick = function()
		reasonForm("Warn " .. p.Name, function(reason)
			Center.Act("warn", { UserId = p.UserId, Reason = reason })
		end)
	end })
	Widgets.button(row, "Kick", { Name = "Kick", Kind = "danger", Need = "Act", OnClick = function()
		reasonForm("Kick " .. p.Name, function(reason)
			Center.Act("kick", { UserId = p.UserId, Reason = reason }, { Confirm = { Title = "Kick " .. p.Name, Message = "Reason: " .. reason } })
		end)
	end })
	Widgets.button(row, "Ban", { Name = "Ban", Kind = "danger", Need = "Ban", OnClick = function()
		Center.BanPrompt(p)
	end })
	Widgets.button(row, "Spectate", { Name = "Spectate", Tooltip = "Sentinel ;view (needs player.view)", OnClick = function()
		if p.Online == false then
			Center.Toast(false, p.Name .. " is not in this server.")
			return
		end
		Center.Command("view " .. p.Name)
		Center.Audit("spectate " .. p.Name)
	end })
	Widgets.button(row, "Correct", { Name = "Correct", Need = "Act", Tooltip = "Silent correction: move back to a recent valid position", OnClick = function()
		Center.Act("correct", { UserId = p.UserId })
	end })
end

-- Ban with the evidence attached: Sentinel's ban prompt, sending ;acban
-- (critical risk -> owner approval / ;confirm on the server).
function Center.BanPrompt(p: any)
	local lengths = { "Default (Settings > Bans)", "1 day", "7 days", "15 days", "30 days", "Permanent (if allowed)" }
	Widgets.form("Ban " .. p.Name, {
		{ Key = "Length", Label = "Length", Kind = "choice", Choices = lengths, Default = lengths[1] },
		{ Key = "Reason", Label = "Reason (the anti-cheat flags are attached automatically)", Default = "cheating" },
	}, function(v)
		local length = if v.Length == lengths[1] then ""
			elseif v.Length == lengths[6] then "perm "
			else (v.Length:match("^(%d+)") or "") .. "d "
		Center.Command(("acban %s %s%s"):format(tostring(p.UserId), length, v.Reason))
		Center.Toast(true, "Ban sent - confirm it, or wait for the Owner's approval.")
		return nil
	end, { SubmitText = "Ban", Danger = true, Description = "Bans game-wide (default 15 days; permanent only when Settings > Bans > AllowPermanent is on). A critical command: you confirm it, and while an Owner is online they approve it." })
end

-- Right-click menu for player / flag rows.
function Center.RowMenu(kind: string, row: any, position: Vector2)
	local userId = row.UserId
	local items = {
		{ Text = "Open", OnClick = function()
			if kind == "flag" then
				Center.OpenFlag(row.Id)
			else
				Center.OpenPlayer(userId, row.Name)
			end
		end },
		{ Text = "Watch", Need = "Exempt", OnClick = function()
			Center.Act("watchAdd", { UserId = userId, Why = "watched from the Control Center" })
		end },
		{ Text = "Exempt", Need = "Exempt", OnClick = function()
			Center.ExemptForm({ UserId = userId, Name = row.Name })
		end },
	}
	if kind == "flag" then
		table.insert(items, { Text = "Create case", Need = "Review", OnClick = function()
			Center.Act("createCase", { Id = row.Id })
		end })
	end
	table.insert(items, { Text = "Copy ID", OnClick = function()
		Widgets.copyBox("Copy ID", if kind == "flag" then tostring(row.Id) else tostring(userId))
		Center.Audit("copied id " .. tostring(if kind == "flag" then row.Id else userId))
	end })
	Widgets.menu(position, items)
end

-- ---------------------------------------------------------------------------
-- Bell
-- ---------------------------------------------------------------------------
local function openBell(button: GuiObject)
	local items = {}
	if #alerts == 0 then
		table.insert(items, { Text = "No alerts", OnClick = function() end })
	end
	for i = 1, math.min(#alerts, 12) do
		local a = alerts[i]
		table.insert(items, {
			Text = ("%s%s - %s"):format(if a.Read then "" else "* ", a.Title or "Alert", a.Text or ""),
			OnClick = function()
				a.Read = true
				if a.FlagId then
					Center.OpenFlag(a.FlagId)
				end
			end,
		})
	end
	table.insert(items, { Text = "Mark all read", OnClick = function()
		for _, a in ipairs(alerts) do
			a.Read = true
		end
		unreadAlerts = 0
		refreshBell()
	end })
	local p = Widgets.toScreen(button.AbsolutePosition)
	Widgets.menu(Vector2.new(p.X - 170, p.Y + button.AbsoluteSize.Y + 4), items)
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------
local function isPhone(): boolean
	local size = if screen then (screen :: ScreenGui).AbsoluteSize else Vector2.new(1200, 800)
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
	return touchOnly or size.X < 760 or size.Y < 420
end

local function layout()
	local w = window :: Frame
	local sb = sidebar :: Frame
	local m = main :: Frame
	local phone = isPhone()
	sb:SetAttribute("Mobile", phone)
	local menuButton = statusWidgets.MenuButton :: TextButton?
	if phone then
		local inset = game:GetService("GuiService"):GetGuiInset().Y
		w.AnchorPoint = Vector2.zero
		w.Position = UDim2.fromOffset(0, inset)
		w.Size = UDim2.new(1, 0, 1, -inset)
		sb.Visible = false
		sb.ZIndex = 20
		sb.Position = UDim2.fromOffset(0, 48)
		sb.Size = UDim2.new(0, 200, 1, -48)
		m.Position = UDim2.fromOffset(0, 48)
		m.Size = UDim2.new(1, 0, 1, -48)
		if menuButton then
			menuButton.Visible = true
		end
	else
		-- Fit below the Roblox top bar (the ScreenGui ignores the inset), so
		-- the title bar and close button are never off screen.
		local screen = (w.Parent :: ScreenGui).AbsoluteSize
		local topInset = game:GetService("GuiService"):GetGuiInset().Y
		local maxW = math.max(320, screen.X - 32)
		local maxH = math.max(300, screen.Y - topInset - 16)
		if w:GetAttribute("Placed") ~= true then
			w:SetAttribute("Placed", true)
			w.AnchorPoint = Vector2.new(0.5, 0.5)
			w.Position = UDim2.new(0.5, 0, 0.5, topInset / 2)
			w.Size = UDim2.fromOffset(math.min(1040, maxW), math.min(640, maxH))
		elseif w.AbsoluteSize.X > maxW or w.AbsoluteSize.Y > maxH or w.AbsolutePosition.Y < topInset then
			w.AnchorPoint = Vector2.new(0.5, 0.5)
			w.Position = UDim2.new(0.5, 0, 0.5, topInset / 2)
			w.Size = UDim2.fromOffset(math.min(w.AbsoluteSize.X, maxW), math.min(w.AbsoluteSize.Y, maxH))
		end
		sb.Visible = true
		sb.Position = UDim2.fromOffset(0, 48)
		sb.Size = UDim2.new(0, 176, 1, -48)
		m.Position = UDim2.fromOffset(176, 48)
		m.Size = UDim2.new(1, -176, 1, -48)
		if menuButton then
			menuButton.Visible = false
		end
	end
end

local function buildTopBar(w: Frame)
	local bar = Widgets.make("Frame", { Name = "TopBar", BackgroundColor3 = Theme.Colors.Surface, Size = UDim2.new(1, 0, 0, 48) }, w)
	Theme.corner(bar, Theme.Radius.L)
	Widgets.make("Frame", { Name = "Square", BackgroundColor3 = Theme.Colors.Surface, Position = UDim2.new(0, 0, 1, -12), Size = UDim2.new(1, 0, 0, 12) }, bar)
	local left = Widgets.make("Frame", { Name = "Left", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0.55, 0, 1, 0) }, bar)
	local ll = Widgets.list(left, Enum.FillDirection.Horizontal, 10)
	ll.VerticalAlignment = Enum.VerticalAlignment.Center

	local menuButton = Widgets.button(left, "=", { Name = "MenuButton", Width = 32, LayoutOrder = 0, OnClick = function()
		if sidebar then
			sidebar.Visible = not sidebar.Visible
		end
	end })
	statusWidgets.MenuButton = menuButton
	local shield = Widgets.label(left, "AC", { Name = "Shield", Bold = true, TextSize = 13, Color = Color3.new(1, 1, 1), XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(30, 26), LayoutOrder = 1 })
	shield.BackgroundTransparency = 0
	shield.BackgroundColor3 = Theme.Colors.Error
	Theme.corner(shield, Theme.Radius.S)
	local title = Widgets.label(left, "Anti-Cheat Control Center", { Name = "Title", Bold = true, TextSize = 16, Size = UDim2.fromOffset(220, 26), LayoutOrder = 2 })
	title.AutomaticSize = Enum.AutomaticSize.X
	title.Size = UDim2.fromOffset(0, 26)

	-- Master switch (anticheat.master; asks to confirm).
	local switchHolder = Widgets.make("Frame", { Name = "MasterSwitch", BackgroundTransparency = 1, Size = UDim2.fromOffset(44, 26), LayoutOrder = 3 }, left)
	local ToggleSwitch = deps.ToggleSwitch
	local switch
	if ToggleSwitch then
		switch = ToggleSwitch.Create(switchHolder, {
			Position = UDim2.fromScale(0, 0.5),
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromOffset(40, 18),
			Initial = true,
			OnToggle = function(on: boolean)
				local status = Center.Status or {}
				switch.Set(status.Enabled == true) -- undo the optimistic flip until confirmed
				if not Center.Can("Master") then
					Center.Toast(false, "Turning the system on or off needs anticheat.master.")
					return
				end
				Center.Act("setEnabled", { On = on }, { Confirm = { Title = if on then "Turn anti-cheat on" else "Turn anti-cheat off", Message = if on then "Run every enabled detection again?" else "Stop every detection on every server?" }, OnDone = function(r)
					if r.Ok then
						Center.ApplyStatus(Center.Call("access").Status)
					end
				end })
			end,
		})
		Widgets.tooltip(switchHolder :: any, function()
			return if Center.Can("Master") then "Master switch (all servers)" else "Master switch - needs anticheat.master"
		end)
	end
	statusWidgets.Switch = switch
	local mode = Widgets.label(left, "OBSERVE", { Name = "ModeBadge", Bold = true, TextSize = 12, Color = Color3.new(1, 1, 1), XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(80, 22), LayoutOrder = 4 })
	mode.BackgroundTransparency = 0
	Theme.corner(mode, Theme.Radius.Pill)
	statusWidgets.Mode = mode
	local pill = Widgets.label(left, "Healthy", { Name = "StatusPill", Bold = true, TextSize = 12, Color = Color3.new(1, 1, 1), XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(76, 22), LayoutOrder = 5 })
	pill.BackgroundTransparency = 0
	Theme.corner(pill, Theme.Radius.Pill)
	statusWidgets.Pill = pill
	Widgets.tooltip(pill, function()
		local s = Center.Status
		if s and #(s.Warnings or {}) > 0 then
			return table.concat(s.Warnings, "\n")
		end
		return "All stores and messaging are healthy."
	end)

	local right = Widgets.make("Frame", { Name = "Right", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.new(0.42, 0, 1, 0) }, bar)
	local rl = Widgets.list(right, Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Right)
	rl.VerticalAlignment = Enum.VerticalAlignment.Center
	local search = Widgets.textbox(right, "Search  ( / )", { Name = "Search", Size = UDim2.fromOffset(190, 30), LayoutOrder = 1 })
	searchBox = search
	search.FocusLost:Connect(function(enter)
		if enter then
			Center.Search(search.Text)
		end
	end)
	local bell = Widgets.button(right, "Bell", { Name = "BellButton", Width = 52, LayoutOrder = 2, Tooltip = "Alerts", OnClick = function(b)
		openBell(b)
	end })
	local bellBadge = Widgets.label(bell, "0", { Name = "Badge", Bold = true, TextSize = 11, Color = Color3.new(1, 1, 1), XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(18, 16) })
	bellBadge.BackgroundTransparency = 0
	bellBadge.BackgroundColor3 = Theme.Colors.Error
	bellBadge.Position = UDim2.new(1, -10, 0, -4)
	bellBadge.Visible = false
	Theme.corner(bellBadge, Theme.Radius.Pill)
	statusWidgets.BellBadge = bellBadge
	local close = Widgets.make("TextButton", { Name = "CloseButton", Text = "", BackgroundColor3 = Theme.Colors.SurfaceRaised, Size = UDim2.fromOffset(30, 30), LayoutOrder = 3 }, right)
	Theme.corner(close, Theme.Radius.Pill)
	Theme.crossIcon(close, 12, Theme.Colors.Text, 2)
	close.Activated:Connect(function()
		Center.Close()
	end)
	Widgets.tooltip(close, "Close (Esc)")

	-- Drag on desktop.
	local dragging = false
	local dragStart, startPos
	bar.InputBegan:Connect(function(input)
		if isPhone() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragStart = input.Position
			startPos = w.Position
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
			local delta = input.Position - dragStart
			w.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
end

local function buildResize(w: Frame)
	local grip = Widgets.make("TextButton", { Name = "ResizeGrip", Text = "//", Font = Theme.Font.Bold, TextSize = 11, TextColor3 = Theme.Colors.TextSecondary, BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(18, 18), ZIndex = 30 }, w)
	local resizing = false
	local start, startSize
	grip.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not isPhone() then
			resizing = true
			start = input.Position
			startSize = w.AbsoluteSize
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if resizing and input.UserInputType == Enum.UserInputType.MouseMovement then
			local d = input.Position - start
			-- Anchor 0.5: growing both ways; move by half to keep the top-left put.
			local newX = math.max(720, startSize.X + d.X)
			local newY = math.max(440, startSize.Y + d.Y)
			local grow = Vector2.new(newX - w.AbsoluteSize.X, newY - w.AbsoluteSize.Y)
			w.Size = UDim2.fromOffset(newX, newY)
			w.Position = w.Position + UDim2.fromOffset(grow.X * w.AnchorPoint.X, grow.Y * w.AnchorPoint.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			resizing = false
		end
	end)
	statusWidgets.Grip = grip
end

local function buildSidebar(w: Frame)
	local sb = Widgets.make("Frame", { Name = "Sidebar", BackgroundColor3 = Theme.Colors.Surface, Position = UDim2.fromOffset(0, 48), Size = UDim2.new(0, 176, 1, -48) }, w)
	sidebar = sb
	Theme.padding(sb, 8)
	Widgets.list(sb, nil, 4)
	for i, p in ipairs(AntiCheatTypes.PAGES) do
		local b = Widgets.make("TextButton", {
			Name = "Nav_" .. p.Id,
			Text = ("  %s   %s"):format(PAGE_GLYPHS[p.Id], p.Label),
			Font = Theme.Font.Medium,
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, 0, 0, 34),
			LayoutOrder = i,
			AutoButtonColor = true,
		}, sb)
		Theme.corner(b, Theme.Radius.S)
		Widgets.SetActive(b, false)
		local key = Widgets.label(b, if i == 10 then "0" elseif i > 10 then "" else tostring(i), { Name = "Key", TextSize = 11, Color = Theme.Colors.TextSecondary, XAlign = Enum.TextXAlignment.Right, Size = UDim2.new(1, -10, 1, 0) })
		local _ = key
		local badge = Widgets.label(b, "0", { Name = "Badge", Bold = true, TextSize = 11, Color = Color3.new(1, 1, 1), XAlign = Enum.TextXAlignment.Center, Size = UDim2.fromOffset(28, 18) })
		badge.BackgroundTransparency = 0
		badge.BackgroundColor3 = Theme.Colors.Error
		badge.Position = UDim2.new(1, -52, 0.5, -9)
		badge.Visible = false
		Theme.corner(badge, Theme.Radius.Pill)
		b.Activated:Connect(function()
			Center.ShowPage(p.Id)
		end)
		navButtons[p.Id] = b
	end
end

local function buildDrawer(w: Frame)
	local m = main :: Frame
	local d = Widgets.make("Frame", { Name = "Drawer", BackgroundColor3 = Theme.Colors.Background, Size = UDim2.new(0, 420, 1, 0), Position = UDim2.new(1, 0, 0, 0), Visible = false, ZIndex = 10 }, m)
	local _ = w
	Theme.stroke(d)
	local sizeConstraint = Widgets.make("UISizeConstraint", { MaxSize = Vector2.new(460, math.huge) }, d)
	local __ = sizeConstraint
	d.Size = UDim2.new(0.6, 0, 1, 0)
	Widgets.label(d, "", { Name = "Title", Bold = true, TextSize = 15, Size = UDim2.new(1, -60, 0, 40) }).Position = UDim2.fromOffset(14, 0)
	local close = Widgets.make("TextButton", { Name = "CloseButton", Text = "", BackgroundColor3 = Theme.Colors.SurfaceRaised, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 6), Size = UDim2.fromOffset(28, 28) }, d)
	Theme.corner(close, Theme.Radius.Pill)
	Theme.crossIcon(close, 11, Theme.Colors.Text, 2)
	close.Activated:Connect(Center.CloseDrawer)
	local body = Widgets.make("ScrollingFrame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 40), Size = UDim2.new(1, 0, 1, -40), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 6 }, d)
	Theme.padding(body, 12)
	Widgets.list(body, nil, 6)
	drawer = d
	-- Everything in the drawer draws above the page.
	d.DescendantAdded:Connect(function(x)
		if x:IsA("GuiObject") and x.ZIndex < 11 then
			x.ZIndex = 11
		end
	end)
end

local function build()
	local playerGui = localPlayer:WaitForChild("PlayerGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "SentinelAntiCheat"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Above the panel (50), below notifications (60), the command bar (70)
	-- and confirm dialogs (100), so toasts and prompts stay readable.
	gui.DisplayOrder = 55
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Enabled = false
	gui.Parent = playerGui
	screen = gui
	Widgets.Init(gui, access.Can)

	local w = Widgets.make("Frame", { Name = "Window", BackgroundColor3 = Theme.Colors.Background, Size = UDim2.fromOffset(1040, 640) }, gui)
	window = w
	Theme.corner(w, Theme.Radius.L)
	Theme.stroke(w)
	Widgets.make("UISizeConstraint", { MinSize = Vector2.new(320, 300) }, w)

	local m = Widgets.make("Frame", { Name = "Main", BackgroundTransparency = 1, ClipsDescendants = true }, w)
	main = m
	buildTopBar(w)
	buildSidebar(w)
	buildDrawer(w)
	buildResize(w)

	local panic = Widgets.label(m, "  PANIC: every automatic action is off. Detections keep logging. Turn it off on the Overview page.", { Name = "PanicBanner", Bold = true, Color = Color3.new(1, 1, 1), TextSize = 13, Size = UDim2.new(1, 0, 0, 28) })
	panic.BackgroundTransparency = 0
	panic.BackgroundColor3 = Theme.Colors.Error
	panic.Visible = false
	panic.ZIndex = 5
	statusWidgets.Panic = panic
	local warnBar = Widgets.label(m, "", { Name = "WarningBanner", TextSize = 12, Color = Color3.new(0, 0, 0), Size = UDim2.new(1, 0, 0, 24) })
	warnBar.BackgroundTransparency = 0
	warnBar.BackgroundColor3 = Theme.Colors.Warning
	warnBar.Visible = false
	warnBar.ZIndex = 5
	statusWidgets.Warn = warnBar

	for _, p in ipairs(AntiCheatTypes.PAGES) do
		local frame = Widgets.make("ScrollingFrame", {
			Name = "Page_" .. p.Id,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollBarThickness = 6,
			Visible = false,
		}, m)
		Theme.padding(frame, 14)
		pages[p.Id] = { Frame = frame }
	end

	layout()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layout)
end

-- ---------------------------------------------------------------------------
-- Search: flag id -> flag drawer; otherwise the current page's filter
-- (or the Players page for a name).
-- ---------------------------------------------------------------------------
function Center.Search(text: string)
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" then
		return
	end
	if text:match("^[%w%-]+%-%d+$") then
		Center.OpenFlag(text)
		return
	end
	local page = pages[currentPage]
	if page and page.Api and page.Api.Search then
		page.Api.Search(text)
	else
		Center.ShowPage("Players")
		local players = pages.Players
		if players.Api and players.Api.Search then
			players.Api.Search(text)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Keyboard
-- ---------------------------------------------------------------------------
local DIGITS = {
	[Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6, [Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9, [Enum.KeyCode.Zero] = 10,
}

local function onKey(input: InputObject, processed: boolean)
	if not isOpen or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.Escape then
		if Widgets.closeModal() then
			return
		end
		if Center.CloseDrawer() then
			return
		end
		Center.Close()
		return
	end
	if processed or UserInputService:GetFocusedTextBox() then
		return
	end
	local page = pages[currentPage]
	local tbl = page and page.Api and page.Api.Table
	if DIGITS[key] then
		local p = AntiCheatTypes.PAGES[DIGITS[key]]
		if p then
			Center.ShowPage(p.Id)
		end
	elseif key == Enum.KeyCode.Slash then
		if searchBox then
			task.defer(function()
				(searchBox :: TextBox):CaptureFocus()
				;(searchBox :: TextBox).Text = ""
			end)
		end
	elseif key == Enum.KeyCode.R then
		Center.Refresh()
	elseif key == Enum.KeyCode.Up or key == Enum.KeyCode.Down then
		local delta = if key == Enum.KeyCode.Up then -1 else 1
		if tbl then
			tbl.Move(delta)
		else
			navCursor = math.clamp(navCursor + delta, 1, #AntiCheatTypes.PAGES)
			for i, p in ipairs(AntiCheatTypes.PAGES) do
				local b = navButtons[p.Id]
				if b then
					b.BackgroundColor3 = if i == navCursor and p.Id ~= currentPage then Theme.Colors.Border else b.BackgroundColor3
				end
			end
		end
	elseif key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
		if tbl and tbl.OpenCursor() then
			return
		end
		local p = AntiCheatTypes.PAGES[navCursor]
		if p then
			Center.ShowPage(p.Id)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Live events
-- ---------------------------------------------------------------------------
local function onEvent(kind: any, data: any)
	if not built then
		return
	end
	if kind == "status" then
		applyStatus(data)
	elseif kind == "alert" and type(data) == "table" then
		if data.ForUserId and data.ForUserId ~= localPlayer.UserId then
			return
		end
		table.insert(alerts, 1, data)
		while #alerts > 50 do
			table.remove(alerts)
		end
		unreadAlerts += 1
		refreshBell()
		if deps.NotificationCenter and (data.Severity == "critical" or data.ForUserId) then
			deps.NotificationCenter.Notify({
				Kind = "warning",
				Title = data.Title or "Anti-Cheat alert",
				Message = data.Text or "",
				Action = if data.FlagId then { Text = "Open", Callback = function()
					Center.Open()
					Center.OpenFlag(data.FlagId)
				end } else nil,
			})
		end
	elseif kind == "flag" or kind == "action" or kind == "review" or kind == "log" or kind == "config" then
		local page = pages[currentPage]
		if isOpen and page and page.Api and page.Api.OnEvent then
			page.Api.OnEvent(kind, data)
		end
		queueRefresh()
	end
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------
function Center.IsOpen(): boolean
	return isOpen
end

function Center.IsBuilt(): boolean
	return built
end

local function maybeWizard(): boolean
	local status = Center.Status
	if status and not status.SetupDone and access.Owner and Center.Can("Master") then
		local wizardModule = script.Parent:FindFirstChild("Wizard")
		if wizardModule then
			require(wizardModule :: ModuleScript).Show(Center, false)
			return true
		end
	end
	return false
end

function Center.Open(page: string?)
	if not built or not screen then
		return
	end
	isOpen = true
	;(screen :: ScreenGui).Enabled = true
	task.spawn(function()
		local fresh = Center.Call("access")
		if fresh and fresh.Can then
			access = fresh
			Widgets.SetCan(fresh.Can)
			if not fresh.Can.View then
				Center.Close()
				return
			end
			applyStatus(fresh.Status)
		end
	end)
	if type(page) == "string" and page:sub(1, 5) == "flag:" then
		Center.ShowPage("Flags")
		Center.OpenFlag(page:sub(6))
		return
	end
	local target = "Overview"
	if type(page) == "string" then
		for _, p in ipairs(AntiCheatTypes.PAGES) do
			if p.Id:lower() == page:lower() or p.Label:lower() == page:lower() then
				target = p.Id
			end
		end
		if target == "Overview" and page:match("%-%d+$") then
			Center.ShowPage("Flags")
			Center.OpenFlag(page)
			return
		end
	elseif currentPage then
		target = currentPage
	end
	Center.ShowPage(target)
	if not maybeWizard() and target == "Overview" then
		return
	end
end

function Center.Close()
	isOpen = false
	Widgets.closeMenu()
	if screen then
		(screen :: ScreenGui).Enabled = false
	end
end

function Center.Toggle(page: string?)
	if isOpen then
		Center.Close()
	else
		Center.Open(page)
	end
end

function Center.ReplayTour()
	local wizardModule = script.Parent:FindFirstChild("Wizard")
	if wizardModule then
		require(wizardModule :: ModuleScript).Show(Center, true)
	end
end

-- deps = { NotificationCenter, ConfirmDialog, ToggleSwitch, CommandPalette? }
-- Returns false (and builds nothing) when the player lacks anticheat.view.
function Center.Init(dependencies: any): boolean
	if built then
		return true
	end
	deps = dependencies or {}
	remote = Shared:WaitForChild("AntiCheatRemote", 15) :: RemoteFunction?
	if not remote then
		return false
	end
	local result = Center.Call("access")
	if not result or not result.Can or not result.Can.View then
		return false
	end
	access = result
	build()
	built = true
	applyStatus(result.Status)
	local mods = Center.Call("modules")
	Center.ModuleNames = {}
	for _, m in ipairs((mods and mods.Modules) or {}) do
		table.insert(Center.ModuleNames, m.Name)
	end
	UserInputService.InputBegan:Connect(onKey)
	local eventRemote = Shared:WaitForChild("AntiCheatEvent", 10) :: RemoteEvent?
	if eventRemote then
		eventRemote.OnClientEvent:Connect(onEvent)
	end
	-- Keep the status / badges fresh while closed too (top-bar red dot).
	task.spawn(function()
		while built do
			task.wait(if isOpen then 5 else 20)
			local fresh = Center.Call("access")
			if fresh and fresh.Status then
				applyStatus(fresh.Status)
			end
			if isOpen then
				local page = pages[currentPage]
				if page and page.Api and page.Api.Live then
					Center.Refresh()
				end
			end
		end
	end)
	local _ = GuiService
	return true
end

return Center
