--!strict
--[[
	ChatLogService.lua (M-panel gaps: server chat log page)

	Purpose:
		A server-wide buffer of the recent chat (every player, newest last
		in memory, newest first when read). Text is filtered ForBroadcast
		when captured (staff are other users); on a filter failure the line
		shows "(could not be filtered)", never the original. Lines that are
		Sentinel commands are flagged Command = true.

		Memory only (this server), at most MAX_LINES. ReportService keeps its
		own per-player evidence copy; this one is for the Chat Log page.

	Public API:
		ChatLogService.Note(player, message)
		ChatLogService.Search(filter?, limit?) -> { line }  newest first
			filter = { Text = string?, Player = string? (name / display /
			UserId prefix), Since = number? }
		ChatLogService.ParseQuery(text) -> filter   ("player:name words")
		ChatLogService.Clear() -> number            lines removed
		ChatLogService.Count() -> number
		ChatLogService.MAX_LINES

	Line = { Id, UserId, Name, DisplayName, Text, Time, Command }
--]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local TextFilterService = require(script.Parent:WaitForChild("TextFilterService"))

local ChatLogService = {}

ChatLogService.MAX_LINES = 300
local LIVE = RunService:IsRunning() and RunService:IsServer()

local lines: { any } = {}
local nextId = 0

function ChatLogService.Note(player: any, message: string)
	if type(message) ~= "string" or message:match("^%s*$") then
		return
	end
	nextId += 1
	local line = {
		Id = nextId,
		UserId = tonumber(player.UserId) or 0,
		Name = tostring(player.Name),
		DisplayName = tostring(player.DisplayName or player.Name),
		Text = "",
		Time = os.time(),
		Command = message:match("^[;:!%./%-?>]%a") ~= nil,
	}
	table.insert(lines, line)
	while #lines > ChatLogService.MAX_LINES do
		table.remove(lines, 1)
	end
	local raw = message:sub(1, 200)
	if LIVE then
		task.spawn(function()
			line.Text = TextFilterService.ForBroadcast(line.UserId, raw) or "(could not be filtered)"
		end)
	else
		line.Text = raw
	end
end

function ChatLogService.ParseQuery(text: string?): { [string]: any }
	local filter: { [string]: any } = {}
	local words = {}
	for word in tostring(text or ""):gmatch("%S+") do
		local key, value = word:match("^(%a+):(.+)$")
		if key and (key:lower() == "player" or key:lower() == "from") then
			filter.Player = value
		else
			table.insert(words, word)
		end
	end
	if #words > 0 then
		filter.Text = table.concat(words, " ")
	end
	return filter
end

local function matches(line: any, filter: { [string]: any }): boolean
	if line.Text == "" then
		return false -- still being filtered
	end
	if filter.Since and line.Time < filter.Since then
		return false
	end
	if filter.Player then
		local needle = tostring(filter.Player):lower()
		if
			line.Name:lower():sub(1, #needle) ~= needle
			and line.DisplayName:lower():sub(1, #needle) ~= needle
			and tostring(line.UserId) ~= needle
		then
			return false
		end
	end
	if filter.Text then
		local needle = tostring(filter.Text):lower()
		if not line.Text:lower():find(needle, 1, true) and not line.Name:lower():find(needle, 1, true) then
			return false
		end
	end
	if filter.Commands == false and line.Command then
		return false
	end
	return true
end

function ChatLogService.Search(filter: { [string]: any }?, limit: number?): { any }
	local f = filter or {}
	local max = math.clamp(math.floor(tonumber(limit) or 100), 1, ChatLogService.MAX_LINES)
	local out = {}
	for i = #lines, 1, -1 do
		local line = lines[i]
		if matches(line, f) then
			table.insert(out, table.clone(line))
			if #out >= max then
				break
			end
		end
	end
	return out
end

function ChatLogService.Count(): number
	return #lines
end

function ChatLogService.Clear(): number
	local n = #lines
	table.clear(lines)
	return n
end

if LIVE then
	local function watch(player: Player)
		player.Chatted:Connect(function(message)
			ChatLogService.Note(player, message)
		end)
	end
	for _, p in ipairs(Players:GetPlayers()) do
		watch(p)
	end
	Players.PlayerAdded:Connect(watch)
end

return ChatLogService
