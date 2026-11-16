-- Tests for Shared/UsageSpec + Shared/ArgumentTypes (W05 palette autocomplete).
return function(t)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	-- A fresh clone, so Edit-mode runs never get a cached old module.
	local Shared = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Sentinel"):Clone()
	local UsageSpec = require(Shared:WaitForChild("UsageSpec"))
	local ArgumentTypes = require(Shared:WaitForChild("ArgumentTypes"))

	-- Fake players: plain tables are enough for name matching.
	local function fakePlayer(name, display, userId)
		return { Name = name, DisplayName = display or name, UserId = userId or 1, Team = nil }
	end
	local env = {
		Players = { fakePlayer("Builderman", "Bob", 1), fakePlayer("Player1", "Player1", 2), fakePlayer("Player2", "Pip", 3) },
		Teams = {},
		Ranks = { { Name = "Owner", Priority = 100 }, { Name = "Moderator", Priority = 40 } },
	}

	t.test("usage: target with required modifier and optional rest", function()
		local args = UsageSpec.Parse("/ban target:duration [reason]")
		t.eq(#args, 2)
		t.eq(args[1].Type, "players")
		t.eq(args[1].Modifier.Type, "duration")
		t.eq(args[1].Modifier.Optional, nil)
		t.eq(args[2].Name, "reason")
		t.eq(args[2].Optional, true)
		t.eq(args[2].Rest, true)
	end)

	t.test("usage: optional modifier, choices, on|off, rest", function()
		local mute = UsageSpec.Parse("/mute target[:duration]")
		t.eq(mute[1].Modifier.Optional, true)
		local tf = UsageSpec.Parse("/timefreeze on|off")
		t.eq(tf[1].Type, "boolean")
		local edit = UsageSpec.Parse("/editrank Rank priority|color|icon|description|inherits value")
		t.eq(edit[1].Type, "rank")
		t.eq(edit[2].Type, "choice")
		t.eq(#edit[2].Choices, 5)
		local msg = UsageSpec.Parse("/message text...")
		t.eq(msg[1].Rest, true)
		t.eq(msg[1].Type, "text")
	end)

	t.test("usage: bracket groups, slash alternatives, example text", function()
		local tp = UsageSpec.Parse("/teleport target [destination / x,y,z]")
		t.eq(#tp, 2)
		t.eq(tp[2].Name, "destination")
		local rp = UsageSpec.Parse("/rankpreset [Rank Preset]")
		t.eq(#rp, 2)
		t.eq(rp[1].Optional, true)
		t.eq(rp[2].Optional, true)
		local ur = UsageSpec.Parse('/updaterank Rank field value [field value ...]  e.g. priority 25 description "x"')
		t.eq(#ur, 4)
		t.eq(ur[4].Rest, true)
		t.eq(#UsageSpec.Parse("/ranks"), 0)
	end)

	t.test("build: ArgHints refine parsed args", function()
		local args = UsageSpec.Build({
			Usage = "/weather name",
			ArgHints = { name = { Type = "choice", Choices = { "clear", "foggy" } } },
		})
		t.eq(args[1].Type, "choice")
		t.eq(args[1].Choices[2], "foggy")
	end)

	local commands = {
		ban = { Name = "ban", RequiresTarget = true, Args = UsageSpec.Parse("/ban target:duration [reason]") },
		kick = { Name = "kick", RequiresTarget = true, Args = UsageSpec.Parse("/kick target [reason]") },
		speed = { Name = "speed", RequiresTarget = true, Args = UsageSpec.Parse("/speed target [amount]") },
	}
	local function resolve(name)
		return commands[name]
	end

	t.test("analyze: command word, then target, then modifier", function()
		local a = UsageSpec.Analyze("ba", resolve, env)
		t.eq(a.Part, "command")
		t.eq(a.Partial, "ba")
		a = UsageSpec.Analyze("ban Pla", resolve, env)
		t.eq(a.Part, "arg")
		t.eq(a.ArgIndex, 1)
		t.eq(a.Partial, "Pla")
		t.eq(a.Trailer, ":") -- required modifier comes next
		t.eq(a.Missing[1].Name, "duration")
		a = UsageSpec.Analyze("ban Player1:3", resolve, env)
		t.eq(a.Part, "modifier")
		t.eq(a.Partial, "3")
		t.eq(a.ReplaceStart, #"ban Player1:" + 1)
	end)

	t.test("analyze: inline errors and missing arguments", function()
		local a = UsageSpec.Analyze("ban Nobody:30m ", resolve, env)
		t.ok(#a.Errors >= 1, "unknown player reported")
		a = UsageSpec.Analyze("ban Player1:30x ", resolve, env)
		t.ok(#a.Errors >= 1, "bad duration reported")
		a = UsageSpec.Analyze("ban Player1 ", resolve, env)
		t.ok(#a.Errors >= 1, "missing modifier reported")
		a = UsageSpec.Analyze("speed Player1 abc", resolve, env)
		t.eq(#a.Errors, 0, "current token is not validated while typing")
		a = UsageSpec.Analyze("speed Player1 abc ", resolve, env)
		t.ok(#a.Errors >= 1, "non-number amount reported")
		a = UsageSpec.Analyze("kick ", resolve, env)
		t.eq(#a.Missing, 1)
		a = UsageSpec.Analyze("nope x", resolve, env)
		t.eq(a.Part, "unknown")
	end)

	t.test("analyze: chains, prefixes and @team values", function()
		local a = UsageSpec.Analyze("kick Player1 && ;speed Pl", resolve, env)
		t.eq(a.Part, "arg")
		t.eq(a.Partial, "Pl")
		a = UsageSpec.Analyze("kick @team ", resolve, env)
		t.eq(a.Part, "selectorValue")
		t.eq(a.Arg.Type, "team")
		a = UsageSpec.Analyze('kick Player1 "spamming the chat', resolve, env)
		t.eq(a.ArgIndex, 2)
	end)

	t.test("types: player lookup matches display names and prefixes", function()
		t.eq(ArgumentTypes.FindPlayer("bob", env.Players).Name, "Builderman")
		t.eq(ArgumentTypes.FindPlayer("build", env.Players).Name, "Builderman")
		t.eq(ArgumentTypes.FindPlayer("Player", env.Players), nil) -- ambiguous
		t.eq(ArgumentTypes.FindPlayer("player2", env.Players).Name, "Player2")
	end)

	t.test("types: suggestions for players, durations, ranks", function()
		local s = ArgumentTypes.Suggest({ Name = "target", Type = "players" }, "Player1,Pi", env)
		t.eq(s[1].Text, "Player1,Player2")
		s = ArgumentTypes.Suggest({ Name = "d", Type = "duration" }, "5", env)
		t.eq(s[1].Text, "5s")
		t.ok(#s >= 5)
		s = ArgumentTypes.Suggest({ Name = "r", Type = "rank" }, "mo", env)
		t.eq(s[1].Text, "Moderator")
		local ok = ArgumentTypes.Validate({ Name = "r", Type = "rank" }, "Admin", env)
		t.eq(ok, false)
	end)

	-- W06 -------------------------------------------------------------------
	local function kinds(text)
		local spans, segments = UsageSpec.Walk(text, resolve, env)
		local out = {}
		for _, sp in ipairs(spans) do
			table.insert(out, text:sub(sp.Start, sp.Stop) .. "=" .. sp.Kind)
		end
		return table.concat(out, " "), segments
	end

	t.test("walk: highlight kinds for a full ban line", function()
		local k = kinds(';ban Player1:3d "fly hacking"')
		t.eq(k, ';=prefix ban=command Player1=target :=punct 3d=modifier "fly hacking"=text')
	end)

	t.test("walk: selectors, chains, errors and the typed token", function()
		t.eq((kinds("kick all && speed me 4")), "kick=command all=selector &&=chain speed=command me=selector 4=number")
		t.eq((kinds("speed Nobody 50 ")), "speed=command Nobody=error 50=number")
		t.eq((kinds("speed Nob")), "speed=command Nob=target") -- still typing: no error
		local k, segs = kinds("zzz me")
		t.eq(k, "zzz=error")
		t.eq(#segs[1].Errors, 1)
	end)

	t.test("breakdown: live parse with pretty durations", function()
		local _, segs = UsageSpec.Walk("ban Player1:3d Spamming chat", resolve, env)
		t.eq(UsageSpec.Breakdown(segs[1]), 'target = Player1 · duration = 3d (3 days) · reason = "Spamming chat"')
		t.eq(UsageSpec.PrettyDuration("perm"), "permanent")
		t.eq(UsageSpec.PrettyDuration("90m"), "1.5 hours")
	end)

	t.test("examples: explicit first, then generated minimal and full", function()
		local ex = UsageSpec.Examples({ Name = "ban", Args = commands.ban.Args, Examples = { "ban Player1:7d Exploiting" } }, env)
		t.eq(ex[1], "ban Player1:7d Exploiting")
		t.eq(ex[2], "ban me:30m")
		t.eq(ex[3], 'ban me:30m "Breaking the rules"')
		t.eq(UsageSpec.Examples({ Name = "ranks", Args = {} }, env)[1], "ranks")
	end)

	t.test("types: custom type registration", function()
		ArgumentTypes.Register("testcolor", {
			Description = "test",
			Validate = function(v)
				return v == "red", "only red"
			end,
			Suggest = function()
				return { { Text = "red" } }
			end,
		})
		local arg = { Name = "c", Type = "testcolor" }
		t.eq((ArgumentTypes.Validate(arg, "red", env)), true)
		t.eq((ArgumentTypes.Validate(arg, "blue", env)), false)
		t.eq(ArgumentTypes.Suggest(arg, "", env)[1].Text, "red")
	end)
end
