--!strict
--[[
	Init.client.lua

	Purpose:
		Placeholder client entry point. Phase 7 (UI/UX) will build the
		dockable command palette here and call the server's
		CommandProcessor through a RemoteFunction/RemoteEvent pair defined
		in ReplicatedStorage.Shared.Sentinel — nothing to wire up yet in
		Phase 1, this file exists so the folder structure matches the
		architecture doc from day one.

	Responsibilities (future):
		- Render dockable command palette
		- Client-side autocomplete against a replicated command index
		- Live notifications (bans, warnings, announcements)
--]]

print("[Sentinel] Client shell loaded (UI arrives in Phase 7).")
