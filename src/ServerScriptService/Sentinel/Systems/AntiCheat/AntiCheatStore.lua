--!strict
--[[
	AntiCheatStore.lua (Sentinel AntiCheat)

	Purpose:
		Small DataStore wrapper shared by EvidenceService (flags) and
		ExemptionService (exemptions + watch list): one key per player,
		batched writes, throttled to the request budget, retries with
		backoff, and a health record the Control Center shows. When the
		DataStore fails, data stays in memory and the game keeps running.

		Outside a running game (unit tests) it never touches DataStores:
		Read returns nil and Queue only records the pending write.

	Public API:
		local store = AntiCheatStore.new(name)       -- "Sentinel_AC_Flags_v1"
		store:Read(key) -> (value?, ok)              -- yields; pcall'd
		store:Queue(key, transform)                  -- transform(old) -> new; merged at flush
		store:Flush(maxWrites?) -> number written
		store:Health() -> { Name, Ok, LastError, LastErrorAt, Pending, Failures, Writes }
		AntiCheatStore.All() -> { store }
		AntiCheatStore.SetFailing(bool)              -- tests / drills: pretend every call fails
--]]

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local AntiCheatStore = {}
AntiCheatStore.__index = AntiCheatStore

local LIVE = RunService:IsRunning() and RunService:IsServer()
local all: { any } = {}
local forceFail = false

function AntiCheatStore.new(name: string): any
	local self = setmetatable({
		Name = name,
		_store = nil :: any,
		_pending = {} :: { [string]: { (any) -> any } },
		_attempts = {} :: { [string]: number },
		_retryAt = {} :: { [string]: number },
		_health = { Ok = true, LastError = nil :: string?, LastErrorAt = nil :: number?, Failures = 0, Writes = 0 },
	}, AntiCheatStore)
	if LIVE then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore(name)
		end)
		if ok then
			self._store = store
		else
			self._health.Ok = false
			self._health.LastError = tostring(store)
		end
	end
	table.insert(all, self)
	return self
end

function AntiCheatStore.All(): { any }
	return all
end

function AntiCheatStore.SetFailing(on: boolean)
	forceFail = on == true
end

local function fail(self: any, err: any)
	self._health.Ok = false
	self._health.LastError = tostring(err):sub(1, 200)
	self._health.LastErrorAt = os.time()
	self._health.Failures += 1
end

function AntiCheatStore.Read(self: any, key: string): (any, boolean)
	if not self._store then
		return nil, not LIVE
	end
	local ok, value = pcall(function()
		if forceFail then
			error("simulated DataStore failure")
		end
		return self._store:GetAsync(key)
	end)
	if not ok then
		fail(self, value)
		return nil, false
	end
	return value, true
end

-- Writes are merged per key: every transform runs in order inside one
-- UpdateAsync at flush time.
function AntiCheatStore.Queue(self: any, key: string, transform: (any) -> any)
	local list = self._pending[key]
	if not list then
		list = {}
		self._pending[key] = list
	end
	table.insert(list, transform)
	-- A single key never piles up unbounded work.
	while #list > 50 do
		table.remove(list, 1)
	end
end

function AntiCheatStore.PendingCount(self: any): number
	local n = 0
	for _ in pairs(self._pending) do
		n += 1
	end
	return n
end

local function budget(): number
	local ok, n = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end)
	return if ok and type(n) == "number" then n else 10
end

function AntiCheatStore.Flush(self: any, maxWrites: number?): number
	if not self._store then
		return 0
	end
	-- Leave headroom for the rest of the game's DataStore use.
	local allowed = math.min(maxWrites or 20, math.max(0, budget() - 5))
	local written = 0
	local now = os.clock()
	local keys = {}
	for key in pairs(self._pending) do
		table.insert(keys, key)
	end
	for _, key in ipairs(keys) do
		if written >= allowed then
			break
		end
		local transforms = self._pending[key]
		if transforms and (self._retryAt[key] or 0) <= now then
			self._pending[key] = nil
			written += 1
			local ok, err = pcall(function()
				if forceFail then
					error("simulated DataStore failure")
				end
				self._store:UpdateAsync(key, function(old: any)
					local value = old
					for _, transform in ipairs(transforms) do
						value = transform(value)
					end
					return value
				end)
			end)
			if ok then
				self._attempts[key] = nil
				self._retryAt[key] = nil
				self._health.Writes += 1
				self._health.Ok = true
			else
				fail(self, err)
				-- Retry with exponential backoff (2, 4, 8 ... 120 s), keep the data.
				local attempts = (self._attempts[key] or 0) + 1
				self._attempts[key] = attempts
				self._retryAt[key] = os.clock() + math.min(120, 2 ^ attempts)
				local merged = self._pending[key] or {}
				for i = #transforms, 1, -1 do
					table.insert(merged, 1, transforms[i])
				end
				self._pending[key] = merged
			end
		end
	end
	return written
end

function AntiCheatStore.Health(self: any): any
	return {
		Name = self.Name,
		Ok = self._health.Ok and not forceFail,
		Live = self._store ~= nil,
		LastError = self._health.LastError,
		LastErrorAt = self._health.LastErrorAt,
		Pending = self:PendingCount(),
		Failures = self._health.Failures,
		Writes = self._health.Writes,
	}
end

return AntiCheatStore
