--!strict
--[[
	EconomyService.lua

	Purpose:
		Owns every player's currency, XP/level, and premium currency
		values. Uses standard `leaderstats` IntValues so balances show in
		the default Roblox player list for free, backed by a DataStore for
		persistence across sessions.

	Responsibilities:
		- Create leaderstats (Coins, Gems, Level, XP) on join
		- Load persisted values, save on leave and periodically
		- Expose Add/Remove/Set for each stat, clamped at 0 minimum
		- Publish EventBus topics so other systems (analytics, quests,
		  future plugins) can react to economy changes without this
		  service knowing about them

	Dependencies:
		Types.lua, EventBus.lua (Shared)

	Public API:
		EconomyService.AddCoins(player, amount): ()
		EconomyService.SetCoins(player, amount): ()
		EconomyService.AddXP(player, amount): ()
		EconomyService.SetLevel(player, level): ()
		EconomyService.AddGems(player, amount): ()
		EconomyService.GrantBadge(player, badgeId): boolean

	Example usage:
		EconomyService.AddCoins(target, 500)
		EconomyService.SetLevel(target, 10)
--]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local BadgeService = game:GetService("BadgeService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SentinelShared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
local EventBus = require(SentinelShared:WaitForChild("EventBus"))

local EconomyStore = DataStoreService:GetDataStore("Sentinel_Economy_v1")

local EconomyService = {}

type EconomyRecord = {
	Coins: number,
	Gems: number,
	XP: number,
	Level: number,
}

local DEFAULT_RECORD: EconomyRecord = { Coins = 0, Gems = 0, XP = 0, Level = 1 }

local function ensureLeaderstats(player: Player): Folder
	local leaderstats = player:FindFirstChild("leaderstats") :: Folder?
	if leaderstats then
		return leaderstats
	end
	leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	leaderstats.Parent = player

	for _, name in ipairs({ "Coins", "Gems", "Level", "XP" }) do
		local value = Instance.new("IntValue")
		value.Name = name
		value.Parent = leaderstats
	end

	return leaderstats
end

local function loadRecord(player: Player): EconomyRecord
	local ok, stored = pcall(function()
		return EconomyStore:GetAsync(tostring(player.UserId))
	end)
	if ok and stored then
		return stored
	end
	return table.clone(DEFAULT_RECORD)
end

local function saveRecord(player: Player)
	local leaderstats = player:FindFirstChild("leaderstats")
	if not leaderstats then
		return
	end
	local record: EconomyRecord = {
		Coins = (leaderstats:FindFirstChild("Coins") :: IntValue).Value,
		Gems = (leaderstats:FindFirstChild("Gems") :: IntValue).Value,
		XP = (leaderstats:FindFirstChild("XP") :: IntValue).Value,
		Level = (leaderstats:FindFirstChild("Level") :: IntValue).Value,
	}
	local ok, err = pcall(function()
		EconomyStore:SetAsync(tostring(player.UserId), record)
	end)
	if not ok then
		warn(("[Sentinel.EconomyService] failed to save economy for %d: %s"):format(player.UserId, tostring(err)))
	end
end

Players.PlayerAdded:Connect(function(player: Player)
	local leaderstats = ensureLeaderstats(player)
	local record = loadRecord(player)

	local coinsValue = leaderstats:FindFirstChild("Coins") :: IntValue
	local gemsValue = leaderstats:FindFirstChild("Gems") :: IntValue
	local xpValue = leaderstats:FindFirstChild("XP") :: IntValue
	local levelValue = leaderstats:FindFirstChild("Level") :: IntValue

	coinsValue.Value = record.Coins
	gemsValue.Value = record.Gems
	xpValue.Value = record.XP
	levelValue.Value = record.Level
end)

Players.PlayerRemoving:Connect(saveRecord)

-- Periodic autosave so a crash doesn't lose recent economy changes.
task.spawn(function()
	while true do
		task.wait(120)
		for _, player in ipairs(Players:GetPlayers()) do
			saveRecord(player)
		end
	end
end)

local function getStat(player: Player, statName: string): IntValue?
	local leaderstats = player:FindFirstChild("leaderstats")
	return leaderstats and (leaderstats:FindFirstChild(statName) :: IntValue?)
end

local function addToStat(player: Player, statName: string, amount: number)
	local stat = getStat(player, statName)
	if not stat then
		return
	end
	stat.Value = math.max(0, stat.Value + amount)
	EventBus.Publish("Economy.Changed", player, statName, stat.Value)
end

local function setStat(player: Player, statName: string, value: number)
	local stat = getStat(player, statName)
	if not stat then
		return
	end
	stat.Value = math.max(0, value)
	EventBus.Publish("Economy.Changed", player, statName, stat.Value)
end

function EconomyService.AddCoins(player: Player, amount: number)
	addToStat(player, "Coins", amount)
end

function EconomyService.SetCoins(player: Player, amount: number)
	setStat(player, "Coins", amount)
end

function EconomyService.AddGems(player: Player, amount: number)
	addToStat(player, "Gems", amount)
end

function EconomyService.SetGems(player: Player, amount: number)
	setStat(player, "Gems", amount)
end

function EconomyService.AddXP(player: Player, amount: number)
	addToStat(player, "XP", amount)
end

function EconomyService.SetLevel(player: Player, level: number)
	setStat(player, "Level", level)
end

function EconomyService.GetBalance(player: Player, statName: string): number
	local stat = getStat(player, statName)
	return if stat then stat.Value else 0
end

function EconomyService.GrantBadge(player: Player, badgeId: number): boolean
	local ok, alreadyHas = pcall(function()
		return BadgeService:UserHasBadgeAsync(player.UserId, badgeId)
	end)
	if ok and alreadyHas then
		return false
	end
	local awardOk, err = pcall(function()
		BadgeService:AwardBadge(player.UserId, badgeId)
	end)
	if not awardOk then
		warn(("[Sentinel.EconomyService] failed to award badge %d: %s"):format(badgeId, tostring(err)))
		return false
	end
	EventBus.Publish("Economy.BadgeAwarded", player, badgeId)
	return true
end

return EconomyService
