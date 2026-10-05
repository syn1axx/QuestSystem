--Discord: @syn1axx;   Roblox: @NebogomDanYo

local DataStoreService = game:GetService("DataStoreService") -- GetService, not game.X, survives renames and looks cleaner
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.Packages -- in RS so client can require the same stuff
local Trove = require(Packages.Trove) -- cleanup bag for connections/threads
local QuickNet = require(Packages.QuickNet) -- buffer based net lib, same api as RemoteEvents but way less traffic/cpu

local Data = QuickNet.Data -- schema types (String, Any, NumberU8..), register uses them to encode + validate args

local QuestStore = DataStoreService:GetDataStore("QuestsData") -- dont rename, new name = empty store, everyones quests will reset

-- how often the autosave loop runs. datastore has a per minute budget so
-- saving on every progress change would burn it
local SaveDebounceInterval = 5
-- bindtoclose gets ~30s total, 10 leaves some room if a request hangs
local ShutdownDeadline = 10
-- gap between each player in the loop, avoids a burst of requests when lots are dirty
local SaveStagger = 0.1

-- client registers the same name + types too, or it cant decode
-- Any = slow and unvalidated, but Started/Progress/Completed send different fields
local QuestEvent = QuickNet:register("QuestUpdate", Data.String, Data.Any)

local QuestService = {}

-- quest id -> definition. only written in LoadQuestDefinitions, after that its read only
local QuestDefinitions = {}

-- Player -> {QuestId -> Quest}. Player instance as key since every event gives me that,
-- and clearing on leave is just = nil
local ActiveQuests = {}

-- Player -> {QuestId -> true}
-- kept apart from Active so state is simple: in Active = running, in here = done, neither = not started
local CompletedQuests = {}

-- its a set not a queue. progress changes just set Player = true and the loop saves them later
-- so 10 progress ticks in 5s is still one write
local DirtyPlayers = {}

local ServiceTrove = Trove.new() -- gets the connections + autosave thread from Init
local Initialized = false -- Init twice = double connections + two loops

local function GetKey(Player)
	return "Player_" .. Player.UserId -- id not name, names can change
end

local function IsValidDefinition(Definition)
	-- check all of it here so nothing later needs to check again
	-- Required > 0 because 0 would finish instantly
	return typeof(Definition) == "table"
		and typeof(Definition.Id) == "string"
		and typeof(Definition.Description) == "string"
		and typeof(Definition.Required) == "number"
		and Definition.Required > 0
end

local function SanitizeLoaded(Raw)
	local Clean = {}
	if typeof(Raw) ~= "table" then
		return Clean -- nil for new players, so this hits all the time
	end

	for QuestId, Entry in pairs(Raw) do -- pairs since keys are strings
		-- Progress gets used in math and Completed in ifs so both have to be right types
		local IsValid = typeof(Entry) == "table"
			and typeof(Entry.Progress) == "number"
			and typeof(Entry.Completed) == "boolean"

		if IsValid then
			-- rebuilt on purpose, any extra keys on Entry just get dropped
			Clean[QuestId] = {
				Progress = Entry.Progress,
				Completed = Entry.Completed,
			}
		end
	end

	return Clean
end

local function LoadPlayerData(Player)
	-- GetAsync can throw (throttle, outage, no api access in studio)
	-- pcall so it doesnt kill the PlayerAdded thread
	local Success, Result = pcall(function()
		return QuestStore:GetAsync(GetKey(Player))
	end)

	if not Success then
		return {} -- starts empty. saves merge so the real data isnt overwritten later
	end

	return SanitizeLoaded(Result) -- request working doesnt mean the data is good
end

local function SavePlayerData(Player)
	local Active = ActiveQuests[Player]
	local Completed = CompletedQuests[Player]
	if not Active and not Completed then
		return false -- no quests ever, nothing to write (nobody queues these anyway)
	end

	local Payload = {}

	for QuestId, Quest in pairs(Active or {}) do -- "or {}" because pairs(nil) errors
		Payload[QuestId] = { Progress = Quest.Progress, Completed = false }
	end

	for QuestId in pairs(Completed or {}) do -- only key needed, its a set
		if not Payload[QuestId] then -- Active wins if a quest is somehow in both
			Payload[QuestId] = { Progress = 0, Completed = true } -- 0 is filler, Sanitize needs a number
		end
	end

	local PayloadCount = 0
	for _ in pairs(Payload) do PayloadCount += 1 end -- # doesnt work on dictionaries

	if PayloadCount == 0 then
		return true -- true so the loop doesnt think it failed and retry
	end

	-- UpdateAsync instead of SetAsync. the callback gets whats stored right now so i can
	-- merge into it, SetAsync would overwrite everything blindly
	local Success, Error = pcall(function()
		QuestStore:UpdateAsync(GetKey(Player), function(Current)
			local Merged = SanitizeLoaded(Current) -- stored data again, clean it again

			-- only touches ids im saving. other ids stay, incl quests that are removed
			-- from the game (they come back if the quest does)
			for QuestId, Entry in pairs(Payload) do
				Merged[QuestId] = Entry
			end

			return Merged -- this is what gets written, nil would cancel it
		end)
	end)

	if not Success then
		-- Error isnt used anywhere, print it here if you need to debug a failing save
		return false
	end

	return true
end

local function MarkDirty(Player)
	-- skip if theyre gone (Parent is nil after leaving)
	-- else they get re-added after OnPlayerRemoving cleaned up and never get removed again
	if Player and Player.Parent then
		DirtyPlayers[Player] = true
	end
end

local function LoadQuestDefinitions()
	local Shared = ReplicatedStorage:WaitForChild("Shared") -- WaitForChild, may not be loaded yet
	local QuestsFolder = Shared:WaitForChild("Quests")

	-- 1 ModuleScript per quest, adding a quest doesnt touch this file
	for _, Module in ipairs(QuestsFolder:GetChildren()) do
		if not Module:IsA("ModuleScript") then
			continue -- IsA also counts subclasses
		end

		-- pcall(require, Module) is pcall(fn, arg), no closure needed
		-- one broken module only loses that quest, not the server
		local Ok, Definition = pcall(require, Module)
		if not Ok then
			continue
		end

		if IsValidDefinition(Definition) then
			QuestDefinitions[Definition.Id] = Definition -- by Id so StartQuest can index it directly
		end
	end
end

local function SendQuestUpdate(Player, Action, Quest)
	-- FireClient = just this player. new table so only these 4 fields get sent,
	-- not the whole server quest
	QuestEvent:FireClient(Player, Action, {
		Id = Quest.Id,
		Description = Quest.Description,
		Required = Quest.Required,
		Progress = Quest.Progress,
	})
end

local function CompleteQuest(Player, Quest)
	QuestEvent:FireClient(Player, "Completed", { Id = Quest.Id }) -- id only, client has the rest

	CompletedQuests[Player] = CompletedQuests[Player] or {}
	CompletedQuests[Player][Quest.Id] = true
	-- AddProgress can be looping over Active when this runs. lua is fine with
	-- setting the current key to nil mid pairs
	ActiveQuests[Player][Quest.Id] = nil
end

local function HydrateAndSend(Player, Saved)
	ActiveQuests[Player] = ActiveQuests[Player] or {} -- both need to exist even if Saved is {}
	CompletedQuests[Player] = CompletedQuests[Player] or {}

	for QuestId, SavedEntry in pairs(Saved) do
		-- the save only has progress/completed. text + Required come from the definition,
		-- so if i edit a description later old saves get it too
		local Definition = QuestDefinitions[QuestId]
		if not Definition then
			continue -- quest was deleted. its still in the datastore, just ignored
		end

		if SavedEntry.Completed then
			CompletedQuests[Player][QuestId] = true -- flag only, no Quest table, nothing to send
			continue
		end

		-- clamp in case Required got lowered after they saved
		-- (or bad data), otherwise bar goes past 100%
		local Quest = {
			Id = Definition.Id,
			Description = Definition.Description,
			Required = Definition.Required,
			Progress = math.clamp(SavedEntry.Progress, 0, Definition.Required),
		}

		ActiveQuests[Player][QuestId] = Quest
		SendQuestUpdate(Player, "Started", Quest) -- same "Started" as a new quest so client has 1 path
	end
end

local function OnPlayerAdded(Player)
	local Saved = LoadPlayerData(Player) -- yields (network)
	HydrateAndSend(Player, Saved)
end

local function OnPlayerRemoving(Player)
	pcall(SavePlayerData, Player) -- pcall so a failed save cant stop the cleanup under it

	-- Player instances as keys dont get collected by themselves, table still holds them
	DirtyPlayers[Player] = nil
	ActiveQuests[Player] = nil
	CompletedQuests[Player] = nil
end

function QuestService:StartQuest(Player, QuestOrId)
	-- accepts a table or a string. "a and b or c" = lua ternary
	local QuestId = typeof(QuestOrId) == "table" and QuestOrId.Id or QuestOrId
	local Definition = typeof(QuestOrId) == "table" and QuestOrId or QuestDefinitions[QuestId]

	if not Definition then
		return -- unknown id, no error. a stale button shouldnt throw
	end

	ActiveQuests[Player] = ActiveQuests[Player] or {}
	CompletedQuests[Player] = CompletedQuests[Player] or {}

	-- already running -> ignore, otherwise a double trigger sets progress back to 0
	if ActiveQuests[Player][Definition.Id] then
		return
	end

	CompletedQuests[Player][Definition.Id] = nil -- this is what allows repeating a quest

	-- new table per player, putting Definition itself in Active would share progress between everyone
	local Quest = {
		Id = Definition.Id,
		Description = Definition.Description,
		Required = Definition.Required,
		Progress = 0,
	}

	ActiveQuests[Player][Definition.Id] = Quest
	SendQuestUpdate(Player, "Started", Quest)
	MarkDirty(Player)
end

function QuestService:AddProgress(Player, Amount, QuestId)
	-- other scripts call this so check the type. <= 0 rejected, progress only goes up
	if typeof(Amount) ~= "number" or Amount <= 0 then
		return
	end

	local Active = ActiveQuests[Player]
	if not Active then
		return
	end

	local function Bump(Quest) -- inside so it sees Player and Amount
		Quest.Progress = math.min(Quest.Progress + Amount, Quest.Required) -- capped

		-- sent before the complete check so the client sees the full bar first
		SendQuestUpdate(Player, "Progress", Quest)

		if Quest.Progress >= Quest.Required then -- >= just to be safe
			CompleteQuest(Player, Quest)
		end
	end

	if QuestId then
		local Quest = Active[QuestId] -- nil if its not active, then nothing happens
		if Quest then
			Bump(Quest)
		end
	else
		for _, Quest in pairs(Active) do -- no id = all active quests
			Bump(Quest)
		end
	end

	MarkDirty(Player) -- once here, not per quest
end

function QuestService:GetActiveQuest(Player, QuestId)
	local Active = ActiveQuests[Player]
	if not Active then
		return nil
	end

	if QuestId then
		return Active[QuestId]
	end

	return Active -- the real table not a copy, dont edit it from outside
end

function QuestService:IsCompleted(Player, QuestId)
	-- ~= nil stops indexing a nil table, == true so it never returns nil
	local Completed = CompletedQuests[Player]
	return Completed ~= nil and Completed[QuestId] == true
end

function QuestService:Save(Player)
	-- for important moments (reward, purchase) so it doesnt wait for the loop
	local Ok = SavePlayerData(Player)
	if Ok then
		DirtyPlayers[Player] = nil -- only on success, on fail the loop retries
	end
	return Ok
end

function QuestService:Init()
	if Initialized then
		return
	end

	Initialized = true

	LoadQuestDefinitions() -- before any player loads, HydrateAndSend needs them

	ServiceTrove:Add(Players.PlayerAdded:Connect(OnPlayerAdded)) -- Trove keeps it so Destroy() disconnects
	ServiceTrove:Add(Players.PlayerRemoving:Connect(OnPlayerRemoving))

	-- PlayerAdded doesnt fire for players already here (studio, late require)
	-- task.spawn each so they dont load one by one
	for _, Player in ipairs(Players:GetPlayers()) do
		task.spawn(OnPlayerAdded, Player)
	end

	-- autosave loop. task.spawn returns the thread and Trove can cancel it
	-- (task.* not spawn/wait, those are deprecated)
	ServiceTrove:Add(task.spawn(function()
		while true do
			task.wait(SaveDebounceInterval)

			local ToSave = {}

			-- copy to an array first, DirtyPlayers changes during the waits below
			-- and editing a table while pairs is on it is unreliable
			for Player in pairs(DirtyPlayers) do
				table.insert(ToSave, Player)
			end

			for _, Player in ipairs(ToSave) do
				-- cleared BEFORE the save, if progress changes during it the flag is set again, nothing lost
				DirtyPlayers[Player] = nil

				if Player.Parent then -- may have left, OnPlayerRemoving saved them already
					local Ok = SavePlayerData(Player)

					if not Ok then
						DirtyPlayers[Player] = true -- retry next pass
					end
				end

				task.wait(SaveStagger)
			end
		end
	end))

	-- runs on shutdown, server stays up until it returns (or ~30s)
	-- only thing that catches progress made in the last 5s
	game:BindToClose(function()
		local Threads = {}

		-- one thread per player so a slow one doesnt hold the others
		for _, Player in ipairs(Players:GetPlayers()) do
			table.insert(Threads, task.spawn(function()
				SavePlayerData(Player)
			end))
		end

		local Deadline = os.clock() + ShutdownDeadline -- os.time is only whole seconds

		-- task.spawn returns a coroutine so coroutine.status works, "dead" = done
		-- past the deadline we stop waiting and let it close
		for _, Thread in ipairs(Threads) do
			while coroutine.status(Thread) ~= "dead" and os.clock() < Deadline do
				task.wait(0.1) -- short waits so the deadline gets checked often
			end
		end
	end)
end

return QuestService
