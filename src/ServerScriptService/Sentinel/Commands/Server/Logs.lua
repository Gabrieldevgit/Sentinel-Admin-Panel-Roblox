--!strict
--[[
	Logs.lua (W10)

	;logs [filters...]   search the persistent audit log (newest first)
	;logs status         where the audit store stands (pages, pending, retention)
	;logs flush          write pending entries now (node config.edit)
	;logs prune          drop pages older than the retention now (config.edit;
	                     also runs every 30 minutes)

	Filters are key:value words; any other words search the text:
		mod:<name|id>  player:<name|id>  cmd:<command>  action:<category[.cmd]>
		sev:<info|warning|error|critical>[+]  result:<success|failed|denied|...>
		server:<id prefix>  since:<2h|3d|2026-11-17>  until:<...>  has:changes
	e.g.  ;logs mod:Alice cmd:ban since:7d
	      ;logs result:failed
	      ;logs player:Bob coins
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):WaitForChild("Types"))

local Sentinel = script.Parent.Parent.Parent
local CommandRegistry = require(Sentinel:WaitForChild("Core"):WaitForChild("CommandRegistry"))
local PermissionSystem = require(Sentinel:WaitForChild("Core"):WaitForChild("PermissionSystem"))
local AuditService = require(Sentinel:WaitForChild("Systems"):WaitForChild("AuditService"))

type Ctx = Types.CommandContext
type Result = Types.CommandResult

local SHOWN = 10

CommandRegistry.Register({
	Name = "logs",
	Aliases = { "audit", "auditlog" },
	Description = "Searches the persistent audit log of every server. Filter with mod: player: cmd: action: sev: result: server: since: until: and free text.",
	Usage = "/logs [query...]",
	ArgHints = {
		query = {
			Type = "text",
			Description = "status, flush, prune, or filters like mod:Alice cmd:ban since:7d result:failed",
			Suggestions = { "status", "result:failed", "sev:warning+", "since:1d", "action:moderation" },
		},
	},
	Examples = { "logs", "logs cmd:ban since:7d", "logs result:failed", "logs status" },
	Permission = "panel.open",
	Category = "Server",
	Subcategory = "Logs",
	Cooldown = 2,
	Log = false,
	NoHistory = false,
	Undoable = false,
	Audit = false,
	Execute = function(ctx: Ctx): Result
		local text = table.concat(ctx.Arguments, " ")
		local first = (ctx.Arguments[1] or ""):lower()

		if first == "status" then
			local s = AuditService.GetStatus()
			return {
				Success = true,
				Message = ("Audit store: %s | server %s | %d pending | %d page(s) / %d entries written | %d page(s) pruned | retention %s day(s)%s"):format(
					if s.Persistent then "persistent (DataStore)" else "memory only",
					tostring(s.ServerId),
					s.Pending,
					s.PagesWritten,
					s.EntriesWritten,
					s.PagesPruned,
					tostring(s.RetentionDays or "-"),
					if s.LastError then " | last error: " .. s.LastError else ""
				),
			}
		elseif first == "prune" then
			if not PermissionSystem.Has(ctx.Executor, "config.edit") then
				return { Success = false, Message = "Pruning the audit store needs config.edit." }
			end
			local removed = AuditService.Prune()
			return {
				Success = true,
				Message = ("Removed %d page(s) older than %s day(s)."):format(removed, tostring(AuditService.GetStatus().RetentionDays or "-")),
			}
		elseif first == "flush" then
			if not PermissionSystem.Has(ctx.Executor, "config.edit") then
				return { Success = false, Message = "Flushing the audit store needs config.edit." }
			end
			local ok = AuditService.Flush()
			local s = AuditService.GetStatus()
			return {
				Success = ok,
				Message = if ok
					then ("Audit log written (%d page(s) so far)."):format(s.PagesWritten)
					else "Could not write the audit log now: " .. tostring(s.LastError or "store unavailable"),
			}
		end

		local filter, err = AuditService.ParseQuery(text)
		if not filter then
			return { Success = false, Message = err }
		end
		local found = AuditService.Search(filter, nil, SHOWN)
		local entries = found.Entries
		if #entries == 0 then
			return { Success = true, Message = found.Error or "No log entries match." }
		end
		local lines = {}
		for i = 1, math.min(SHOWN, #entries) do
			table.insert(lines, AuditService.FormatEntry(entries[i]))
		end
		local more = if #entries > SHOWN or found.Cursor then " (more in the Logs page)" else ""
		return {
			Success = true,
			Message = ("%s\n%d shown%s."):format(table.concat(lines, "\n"), math.min(SHOWN, #entries), more),
		}
	end,
} :: any)

return true
