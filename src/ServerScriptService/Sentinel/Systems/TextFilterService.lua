--!strict
--[[
	TextFilterService.lua

	Purpose:
		Roblox requires text written by one user and shown to others to go
		through its text filter. Every Sentinel feature that displays staff-
		typed text to other players (announcements, hints, messages, PMs,
		countdown labels, kick/ban/warn reasons) filters it here first.

	Rules:
		- On any filter error, return nil: the caller must NOT show the
		  original text. Never fall back to unfiltered text.
		- Broadcast text (seen by everyone) uses the broadcast variant;
		  text for one recipient uses the per-user variant.

	Public API:
		TextFilterService.ForBroadcast(fromUserId, text): string?
		TextFilterService.ForUser(fromUserId, text, toUserId): string?
		TextFilterService.FAILED_MESSAGE
--]]

local TextService = game:GetService("TextService")

local TextFilterService = {}

TextFilterService.FAILED_MESSAGE = "Text could not be filtered right now, so it wasn't shown. Try again."

local MAX_LENGTH = 500

local function filterObject(fromUserId: number, text: string): TextFilterResult?
	if type(text) ~= "string" or #text == 0 then
		return nil
	end
	text = text:sub(1, MAX_LENGTH)
	local ok, result = pcall(TextService.FilterStringAsync, TextService, text, fromUserId, Enum.TextFilterContext.PublicChat)
	if not ok then
		warn("[Sentinel.TextFilter] filter failed: " .. tostring(result))
		return nil
	end
	return result
end

function TextFilterService.ForBroadcast(fromUserId: number, text: string): string?
	local result = filterObject(fromUserId, text)
	if not result then
		return nil
	end
	local ok, filtered = pcall(result.GetNonChatStringForBroadcastAsync, result)
	return if ok then filtered else nil
end

function TextFilterService.ForUser(fromUserId: number, text: string, toUserId: number): string?
	local result = filterObject(fromUserId, text)
	if not result then
		return nil
	end
	local ok, filtered = pcall(result.GetNonChatStringForUserAsync, result, toUserId)
	return if ok then filtered else nil
end

return TextFilterService
