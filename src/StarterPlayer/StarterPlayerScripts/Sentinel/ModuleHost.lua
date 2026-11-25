--!strict
--[[
	ModuleHost.lua (W-FINAL.1) - runs the client components of enabled
	Sentinel modules for EVERY player (not only staff).

	ModuleRemote:
		server -> client ("state", { { Id, Client, Enabled, Config } })
		                 ("msg", id, ...) -> that module's OnMessage handlers
		client -> server ("sync"), ("msg", id, ...)

	A client component is a ModuleScript in script.Parent.Modules:
		Start(config, api) -> handle { Stop(), Update(config)? }
		api = { Send(...), OnMessage(fn) }
	A component without Update is restarted on a config change. Errors are
	caught so one module can't break another.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModuleHost = {}

local running: { [string]: { Handle: any, Config: any, Handlers: { (...any) -> () } } } = {}

local function sameConfig(a: any, b: any): boolean
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if b[k] ~= v then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function ModuleHost.Init()
	local shared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel")
	local folder = script.Parent:WaitForChild("Modules", 10)
	task.spawn(function()
		local remote = shared:WaitForChild("ModuleRemote", 30) :: RemoteEvent?
		if not remote or not folder then
			return
		end

		local function stop(id: string)
			local r = running[id]
			if not r then
				return
			end
			running[id] = nil
			local ok, err = pcall(function()
				if r.Handle and r.Handle.Stop then
					r.Handle.Stop()
				end
			end)
			if not ok then
				warn(("[Sentinel.Modules] %s stop failed: %s"):format(id, tostring(err)))
			end
		end

		local function start(id: string, clientName: string, config: any)
			local mod = (folder :: Instance):FindFirstChild(clientName)
			if not mod or not mod:IsA("ModuleScript") then
				warn(("[Sentinel.Modules] no client component '%s' for %s"):format(clientName, id))
				return
			end
			local entry = { Handle = nil :: any, Config = config, Handlers = {} }
			local api = {
				Send = function(...)
					(remote :: RemoteEvent):FireServer("msg", id, ...)
				end,
				OnMessage = function(fn)
					table.insert(entry.Handlers, fn)
				end,
			}
			local ok, handle = pcall(function()
				return (require(mod) :: any).Start(config, api)
			end)
			if not ok then
				warn(("[Sentinel.Modules] %s failed to start: %s"):format(id, tostring(handle)))
				return
			end
			entry.Handle = handle
			running[id] = entry
		end

		remote.OnClientEvent:Connect(function(kind: any, a: any, ...)
			if kind == "state" and type(a) == "table" then
				local seen = {}
				for _, m in ipairs(a) do
					if type(m) == "table" and type(m.Id) == "string" and type(m.Client) == "string" then
						seen[m.Id] = true
						local r = running[m.Id]
						if not m.Enabled then
							stop(m.Id)
						elseif not r then
							start(m.Id, m.Client, m.Config)
						elseif not sameConfig(r.Config, m.Config) then
							if r.Handle and r.Handle.Update then
								r.Config = m.Config
								local ok, err = pcall(r.Handle.Update, m.Config)
								if not ok then
									warn(("[Sentinel.Modules] %s update failed: %s"):format(m.Id, tostring(err)))
								end
							else
								stop(m.Id)
								start(m.Id, m.Client, m.Config)
							end
						end
					end
				end
				for id in pairs(running) do
					if not seen[id] then
						stop(id)
					end
				end
			elseif kind == "msg" and type(a) == "string" and running[a] then
				for _, fn in ipairs(running[a].Handlers) do
					task.spawn(fn, ...)
				end
			end
		end)
		remote:FireServer("sync")
	end)
end

return ModuleHost
