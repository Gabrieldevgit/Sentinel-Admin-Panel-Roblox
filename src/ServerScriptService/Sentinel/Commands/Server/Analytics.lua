--!strict
--[[
	Analytics.lua (W16)

		;analytics [range] [server] [compare]   (metrics, insights)
			range = 24h (default) | today | 7d | 30d | <n>h | <n>d |
			        YYYY-MM-DD [YYYY-MM-DD]
			server  = only this server (memory) instead of every server
			compare = add the previous period of the same length

	Node analytics.view (default Moderator rank). The panel page is
	Insights > Analytics (GetAnalyticsRemote). See Systems/AnalyticsService.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local AnalyticsService = require(Sentinel:WaitForChild("Systems"):WaitForChild("AnalyticsService"))

type CommandContext = Types.CommandContext
type CommandResult = Types.CommandResult

local function delta(before: number?, after: number?): string
	local pct = AnalyticsService.PctChange(before, after)
	if not pct then
		return ""
	end
	return (" (%s%s%%)"):format(if pct >= 0 then "+" else "", tostring(pct))
end

CommandRegistry.Register({
	Name = "analytics",
	Aliases = { "metrics", "insights" },
	Description = "Summarises persisted analytics: players, performance, commands, moderation, staff and economy.",
	Usage = "/analytics [range] [scope] [compare]",
	ArgHints = {
		range = { Type = "string", Description = "24h, today, 7d, 30d or YYYY-MM-DD", Suggestions = { "24h", "today", "7d", "30d" } },
		scope = { Type = "string", Description = "server = only this server", Suggestions = { "server", "all" } },
		compare = { Type = "string", Description = "compare with the previous period", Suggestions = { "compare" } },
	},
	Examples = { "analytics", "analytics 7d compare", "analytics 2026-11-01 2026-11-20", "analytics 24h server" },
	Permission = "analytics.view",
	Category = "Server",
	Subcategory = "Analytics",
	Cooldown = 2,
	Log = false,
	RequiresTarget = false,
	Execute = function(ctx: CommandContext): CommandResult
		local options: any = { Range = "24h" }
		local dates = {}
		for _, raw in ipairs(ctx.Arguments) do
			local a = raw:lower()
			if a == "server" or a == "this" then
				options.Scope = "server"
			elseif a == "all" or a == "global" then
				options.Scope = "all"
			elseif a == "compare" or a == "vs" then
				options.Compare = true
			elseif a:match("^%d%d%d%d%-%d%d?%-%d%d?$") then
				table.insert(dates, a)
			else
				options.Range = a
			end
		end
		if #dates > 0 then
			options.Range, options.From, options.To = "custom", dates[1], dates[2] or dates[1]
		end
		local report, err = AnalyticsService.Query(options)
		if not report then
			return { Success = false, Message = err or "Could not build the report." }
		end
		local t = report.Totals
		local p = report.Previous and report.Previous.Totals
		local lines = {
			("Analytics - %s, %s%s"):format(report.Range.Label, if report.Scope == "server" then "this server" else ("all servers (%d seen)"):format(report.Servers), if report.Persistent then "" else " [not persisted in this session]"),
			("Players: peak %d per server, %d across servers, avg %s%s"):format(t.Peak, t.GlobalPeak, tostring(t.PlayersAvg), if p then delta(p.Peak, t.Peak) else ""),
			("Performance: %s FPS, %d ms ping, %d MB memory"):format(tostring(t.Fps), t.Ping, t.Memory),
			("Commands: %d (%d ok, %d failed, %d denied) - %s%% success%s"):format(t.Commands, t.Success, t.Failed, t.Denied, tostring(t.SuccessRate), if p then delta(p.Commands, t.Commands) else ""),
			("Moderation actions: %d%s   Staff commands: %d   Staff peak: %d"):format(t.Moderation, if p then delta(p.Moderation, t.Moderation) else "", t.StaffCmd, t.StaffPeak),
			("Economy: %d transactions, %d moved%s"):format(t.Economy, t.EconomyVolume, if p then delta(p.Economy, t.Economy) else ""),
		}
		local top = {}
		for i, c in ipairs(report.TopCommands) do
			if i > 5 then
				break
			end
			table.insert(top, ("%s %d"):format(c.Command, c.Count))
		end
		if #top > 0 then
			table.insert(lines, "Most used: " .. table.concat(top, ", "))
		end
		local mods = {}
		for i, m in ipairs(report.TopModerators) do
			if i > 5 then
				break
			end
			table.insert(mods, ("%s %d"):format(m.Name, m.Count))
		end
		if #mods > 0 then
			table.insert(lines, "Most active moderators: " .. table.concat(mods, ", "))
		end
		return { Success = true, Message = table.concat(lines, "\n") }
	end,
} :: any)

return {}
