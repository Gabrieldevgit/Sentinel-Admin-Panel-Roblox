--!strict
--[[
	RateLimiter.lua

	Purpose:
		Per-player token-bucket rate limiting for client -> server entry
		points (remotes, chat commands). Each limiter has a burst capacity
		and a refill rate; a request spends one token.

	Public API:
		local limiter = RateLimiter.new(name, capacity, refillPerSecond)
		limiter:Allow(player): (boolean, boolean)
			-- allowed?, and whether this is the FIRST drop of a burst (so
			-- callers notify the player once instead of once per request)
		limiter:Reset(player)
		RateLimiter.SetDropListener(fn(player, limiterName))   -- AntiCheat

		Repeated drops are logged (once per 10 s per player and limiter) as
		a security warning, so spam/exploit attempts show up in the logs.
--]]

local Players = game:GetService("Players")

local Logger = require(script.Parent:WaitForChild("Logger"))

local RateLimiter = {}
RateLimiter.__index = RateLimiter

export type Limiter = typeof(setmetatable(
	{} :: {
		Name: string,
		Capacity: number,
		Refill: number,
		_buckets: { [number]: { Tokens: number, Last: number, Dropped: number, LastReport: number, InBurst: boolean } },
	},
	RateLimiter
))

local all: { Limiter } = {}
-- AntiCheat: told about every dropped request (RemoteSpamCheck input).
local dropListener: ((Player, string) -> ())? = nil

function RateLimiter.SetDropListener(fn: ((Player, string) -> ())?)
	dropListener = fn
end

function RateLimiter.new(name: string, capacity: number, refillPerSecond: number): Limiter
	local self = setmetatable({
		Name = name,
		Capacity = capacity,
		Refill = refillPerSecond,
		_buckets = {},
	}, RateLimiter)
	table.insert(all, self)
	return self
end

function RateLimiter.Allow(self: Limiter, player: Player): (boolean, boolean)
	local now = os.clock()
	local bucket = self._buckets[player.UserId]
	if not bucket then
		bucket = { Tokens = self.Capacity, Last = now, Dropped = 0, LastReport = 0, InBurst = false }
		self._buckets[player.UserId] = bucket
	end
	bucket.Tokens = math.min(self.Capacity, bucket.Tokens + (now - bucket.Last) * self.Refill)
	bucket.Last = now
	if bucket.Tokens >= 1 then
		bucket.Tokens -= 1
		bucket.InBurst = false
		return true, false
	end
	local firstDrop = not bucket.InBurst
	bucket.InBurst = true
	bucket.Dropped += 1
	if dropListener then
		pcall(dropListener :: any, player, self.Name)
	end
	if now - bucket.LastReport >= 10 then
		bucket.LastReport = now
		Logger.Write({
			Executor = tostring(player.UserId),
			ExecutorName = player.Name,
			Command = "security.ratelimit",
			Result = "Denied",
			Severity = "Warning",
			Message = ("Rate limit hit on %s (%d request(s) dropped)."):format(self.Name, bucket.Dropped),
		})
		bucket.Dropped = 0
	end
	return false, firstDrop
end

function RateLimiter.Reset(self: Limiter, player: Player)
	self._buckets[player.UserId] = nil
end

Players.PlayerRemoving:Connect(function(player: Player)
	for _, limiter in ipairs(all) do
		limiter._buckets[player.UserId] = nil
	end
end)

return RateLimiter
