--Discord: @syn1axx;   Roblox: @NebogomDanYo

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packages = ReplicatedStorage.Packages
local Trove = require(Packages.Trove)
local QuickNet = require(Packages.QuickNet)

local Data = QuickNet.Data
local QuestStore = DataStoreService:GetDataStore("QuestsData")

-- 5s debounce prevents hammering datastore with unnecessary checks
-- if we checked every frame or every change, wed waste tons of quota
local SaveDebounceInterval = 5
-- grace period for shutdown saves before server kills the process
-- gives us time to persist player data without hanging indefinitely
local ShutdownDeadline = 10
-- stagger between saves avoids datastore throttling if many players dirty at once
-- spreading saves across the 5s cycle is way better than firing them all instantly
local SaveStagger = 0.1

local QuestEvent = QuickNet:register("QuestUpdate", Data.String, Data.Any)

local QuestService = {}

-- read-only after load. immutable so every player sees the same quest values
-- if we could modify this at runtime, players would see different quest requirements
local QuestDefinitions = {}

-- keyed by Player object so we can detect when they leave (Parent becomes nil)
-- cant use UserId here because wed need to rebuild the whole table structure to clean up
local ActiveQuests = {}

-- separate from Active because quests can be completed and restarted
-- if we only had one "state" field, wed need three states (active, completed, available)
-- this design makes the logic cleaner and state transitions explicit
local CompletedQuests = {}

-- signal queue for autosave loop, not actual data store
-- acts as a dirty flag. when a quest progresses, we dont save immediately because
-- thats slow and wasteful. instead we just mark the player dirty and let the autosave loop
-- pick them up on the next cycle. multiple changes coalesce into one save
local DirtyPlayers = {}

local ServiceTrove = Trove.new()
-- guard against running Init more than once
-- if we connected to player events twice wed save/load players twice
local Initialized = false

local function GetKey(Player)
	-- UserId instead of Name because usernames can change; data would be orphaned under old key
	-- a player changes their name, their old data becomes unreachable under the old key
	-- by using a permanent identifier, we ensure their progress follows them forever
	return "Player_" .. Player.UserId
end

local function IsValidDefinition(Definition)
	-- Catch bad definitions at load time, not during gameplay
	-- if a quest module returns garbage, we find out immediately when the server starts
	-- and skip that quest. way better than discovering a nil field halfway through
	-- if a quest has Required = 0 or negative, thats logically impossible
	-- so we reject it upfront rather than letting it cause weird behavior later
	return typeof(Definition) == "table"
		and typeof(Definition.Id) == "string"
		and typeof(Definition.Description) == "string"
		and typeof(Definition.Required) == "number"
		and Definition.Required > 0
end

local function SanitizeLoaded(Raw)
	-- filter to only expected fields
	-- handles corrupted data (from old code versions, manual edits, bugs, etc)
	-- also means downstream code never has to validate anything
	-- everything that touches this data knows it has exactly Progress and Completed
	local Clean = {}
	if typeof(Raw) ~= "table" then
		-- if somehow the datastore returned a string or number or nil, just start fresh
		-- way better than crashing or trying to iterate over it
		return Clean
	end

	for QuestId, Entry in pairs(Raw) do
		-- each Entry must have Progress (numeric) and Completed (boolean)
		-- if either is missing or the wrong type, we skip this entry
		-- prevents downstream code from hitting nil reference errors or type mismatches
		-- e.g. if Progress were nil, math.clamp(nil, 0, 5) would crash
		local IsValid = typeof(Entry) == "table"
			and typeof(Entry.Progress) == "number"
			and typeof(Entry.Completed) == "boolean"

		if IsValid then
			-- rebuild table instead of copying Entry directly
			-- this strips any legacy fields from old quest systems
			-- also makes explicit exactly what fields we consider valid
			-- if someone tries to add a new field to the structure, it gets dropped
			-- on load, which is intentional
			Clean[QuestId] = {
				Progress = Entry.Progress,
				Completed = Entry.Completed,
			}
		end
	end

	return Clean
end

local function LoadPlayerData(Player)
	-- wrap in pcall because datastore operations are network I/O
	-- network can timeout, datastore can throttle (too many requests at once),
	-- servers can have temporary outages. any of these make GetAsync fail
	-- without pcall, the whole server crashes and kicks everyone
	-- with pcall, one player loads empty data and keeps playing
	local Success, Result = pcall(function()
		return QuestStore:GetAsync(GetKey(Player))
	end)

	if not Success then
		-- player starts with blank state instead of error state
		-- they can still play and progress quests normally
		-- on their next save (5s from now in the autosave loop),
		-- that progress gets persisted to datastore
		return {}
	end

	-- always sanitize loaded data even on success
	-- datastore might contain garbage from previous bugs or manual edits
	-- centralized validation means every code path gets the same guarantees
	return SanitizeLoaded(Result)
end

local function SavePlayerData(Player)
	-- grab both active and completed quests
	local Active = ActiveQuests[Player]
	local Completed = CompletedQuests[Player]
	if not Active and not Completed then
		-- if player hasnt started any quests, theres nothing to save
		-- dont waste a datastore operation on empty data
		return false
	end

	local Payload = {}

	-- iterate active quests first and mark them as not completed
	-- this establishes the baseline state for the save
	for QuestId, Quest in pairs(Active or {}) do
		Payload[QuestId] = { Progress = Quest.Progress, Completed = false }
	end

	-- iterate completed quests
	-- only add them if they werent already added as active above
	-- why? because a quest might be in both tables momentarily (completed this frame)
	-- if we overwrote Active data with Completed data, we lose progress
	-- Active is the source of truth so Active wins if theres a conflict
	for QuestId in pairs(Completed or {}) do
		if not Payload[QuestId] then
			-- completed quests get Progress = 0 as a placeholder
			-- the Completed flag is whats important; progress doesnt matter when youre done
			Payload[QuestId] = { Progress = 0, Completed = true }
		end
	end

	local PayloadCount = 0
	for _ in pairs(Payload) do PayloadCount += 1 end

	if PayloadCount == 0 then
		-- no data to save; treat as success so we dont retry
		return true
	end

	-- UpdateAsync instead of SetAsync because UpdateAsync is atomic and merge-friendly
	-- heres why: if another server (or even another coroutine) updates the datastore
	-- between our read and write, UpdateAsync ensures we dont lose their changes
	-- SetAsync would blindly overwrite, causing data loss in multi-server setups
	-- UpdateAsync passes us the current data in the callback, so we can merge intelligently
	local Success, Error = pcall(function()
		QuestStore:UpdateAsync(GetKey(Player), function(Current)
			-- Current is whatever is already in the datastore (might have been updated by another server)
			-- we sanitize it and then merge our Payload into it
			local Merged = SanitizeLoaded(Current)

			-- merge our new data into whatever already exists
			-- this is additive: we update keys in Payload, but we dont delete other keys
			-- if a quest was in the datastore but not in our Payload, it stays
			-- this is intentional for data preservation
			for QuestId, Entry in pairs(Payload) do
				Merged[QuestId] = Entry
			end

			-- return Merged tells UpdateAsync to save this new state atomically
			return Merged
		end)
	end)

	if not Success then
		-- if the save failed (throttle, timeout, etc), return false
		-- the autosave loop sees false and re-marks the player dirty
		-- they get retried on the next cycle (5s later)
		-- automatic retry is simpler and more resilient than forcing immediate retry
		return false
	end

	return true
end

local function MarkDirty(Player)
	-- only mark if player still in game
	-- Player.Parent is nil after they disconnect
	-- if we mark a disconnected player dirty, the autosave loop will waste time trying to save them
	if Player and Player.Parent then
		-- adding to DirtyPlayers signals the autosave loop to save them
		-- multiple changes (progress 5 times, complete a quest) all get batched into one save
		-- this is way more efficient than saving after every single change
		DirtyPlayers[Player] = true
	end
end

local function LoadQuestDefinitions()
	local Shared = ReplicatedStorage:WaitForChild("Shared")
	local QuestsFolder = Shared:WaitForChild("Quests")

	-- dynamically load quests from the folder
	-- means new quests can be added without touching this code
	-- just drop a new ModuleScript into Quests/ and itll load automatically
	for _, Module in ipairs(QuestsFolder:GetChildren()) do
		if not Module:IsA("ModuleScript") then
			-- skip non-script objects (folders, etc)
			continue
		end

		-- wrap require in pcall because a ModuleScript might have a syntax error
		-- or throw an exception during require
		-- if we didnt catch errors, one broken quest module would prevent the server from starting
		-- with pcall, we skip the broken one and continue loading others
		-- server boots with whatever quests loaded successfully
		local Ok, Definition = pcall(require, Module)
		if not Ok then
			continue
		end

		-- validate the returned definition before storing it
		-- a developer might accidentally return invalid data from their quest module
		-- validating here means no bad definitions make it into the system
		-- another fail-gracefully checkpoint
		if IsValidDefinition(Definition) then
			QuestDefinitions[Definition.Id] = Definition
		end
	end
end

local function SendQuestUpdate(Player, Action, Quest)
	-- send quest state to client whenever it changes
	-- client needs this to update UI (progress, quest list, etc)
	-- we construct a new table with only the fields we want to send
	-- dont send the entire Quest object; that leaks implementation details
	-- only expose the fields the client needs to render UI
	QuestEvent:FireClient(Player, Action, {
		Id = Quest.Id,
		Description = Quest.Description,
		Required = Quest.Required,
		Progress = Quest.Progress,
	})
end

local function CompleteQuest(Player, Quest)
	-- notify client immediately when a quest completes
	-- they need to show the completion effect/animation/popup right away
	QuestEvent:FireClient(Player, "Completed", { Id = Quest.Id })

	CompletedQuests[Player] = CompletedQuests[Player] or {}
	CompletedQuests[Player][Quest.Id] = true
	-- remove from active so it doesnt show up in GetActiveQuest results
	-- semantically, active means "in progress"; completed quests are not active
	ActiveQuests[Player][Quest.Id] = nil
end

local function HydrateAndSend(Player, Saved)
	-- reconstruct runtime state from datastore data
	-- happens when a player joins; we load their saved state and rebuild it in memory
	-- then send all their quests to the client so their UI is in sync
	ActiveQuests[Player] = ActiveQuests[Player] or {}
	CompletedQuests[Player] = CompletedQuests[Player] or {}

	for QuestId, SavedEntry in pairs(Saved) do
		-- look up the quest definition for this QuestId
		-- datastore only stores Progress and Completed; it doesnt store the full definition
		local Definition = QuestDefinitions[QuestId]
		if not Definition then
			-- quest definition was removed from the game
			-- if we tried to use it, wed hit nil reference errors
			-- safer to skip it and let the player lose that quest
			-- they can still play other quests
			continue
		end

		if SavedEntry.Completed then
			-- already completed, just mark it and move on
			-- dont need to rebuild the full quest object
			-- completed quests dont need progress displayed
			CompletedQuests[Player][QuestId] = true
			continue
		end

		-- rebuild the active quest by copying fields from Definition
		-- Progress comes from SavedEntry (what they had saved before)
		-- but we clamp it between 0 and Required
		-- why clamp? because if data got corrupted or definition changed,
		-- we prevent nonsensical states (negative progress or 999% complete)
		local Quest = {
			Id = Definition.Id,
			Description = Definition.Description,
			Required = Definition.Required,
			Progress = math.clamp(SavedEntry.Progress, 0, Definition.Required),
		}

		ActiveQuests[Player][QuestId] = Quest
		-- send a Started event to the client so they reconstruct their UI
		-- this is necessary because the client might have restarted or they might be rejoining
		-- server is the source of truth; we replicate that truth to client UI
		SendQuestUpdate(Player, "Started", Quest)
	end
end

local function OnPlayerAdded(Player)
	-- when a player joins, load their saved data and rebuild their state
	local Saved = LoadPlayerData(Player)
	HydrateAndSend(Player, Saved)
end

local function OnPlayerRemoving(Player)
	-- player is leaving; try to save their data one last time
	-- pcall prevents exceptions here from crashing other disconnect handlers
	pcall(SavePlayerData, Player)

	-- clean up all memory associated with this player
	-- if we didnt remove entries from these tables, they would grow forever
	-- after a few thousand join/leave cycles, wed run out of RAM
	DirtyPlayers[Player] = nil
	ActiveQuests[Player] = nil
	CompletedQuests[Player] = nil
end

function QuestService:StartQuest(Player, QuestOrId)
	-- public API accepts either a quest table or just a quest ID string
	-- this flexibility lets callers pass what they have
	-- either they already have the Definition and can pass it directly,
	-- or they just know the ID and we look it up
	local QuestId = typeof(QuestOrId) == "table" and QuestOrId.Id or QuestOrId
	local Definition = typeof(QuestOrId) == "table" and QuestOrId or QuestDefinitions[QuestId]

	if not Definition then
		-- quest doesnt exist; silently do nothing instead of erroring
		-- if a quest was removed while theyre in the menu, we dont want to crash
		-- just return silently
		return
	end

	ActiveQuests[Player] = ActiveQuests[Player] or {}
	CompletedQuests[Player] = CompletedQuests[Player] or {}

	-- check if the quest is already active
	-- if a player calls StartQuest twice for the same quest, ignore the second call
	-- this prevents duplicate quests or accidentally resetting progress to 0
	-- the function is idempotent: calling it 5 times has the same effect as calling it once
	if ActiveQuests[Player][Definition.Id] then
		return
	end

	-- remove from completed so it can be restarted
	-- this is the key to supporting repeatable quests
	-- admin gives player permission to retry? remove from Completed, call StartQuest again
	CompletedQuests[Player][Definition.Id] = nil

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
	-- validate amount upfront
	-- negative progress doesnt make sense (cant un-progress)
	-- zero progress is a no-op
	-- so we reject anything <= 0 to prevent silent bugs
	if typeof(Amount) ~= "number" or Amount <= 0 then
		return
	end

	local Active = ActiveQuests[Player]
	if not Active then
		-- no active quests; nothing to update
		return
	end

	local function Bump(Quest)
		-- add progress but cap it at Required
		-- why cap? because a quest is complete when Progress >= Required
		-- if we let Progress go over (say 150 out of 100), it wouldnt change completion state
		-- but it would confuse UI rendering (progress bar at 150%?)
		-- capping at Required is cleaner and matches how quest systems normally work
		Quest.Progress = math.min(Quest.Progress + Amount, Quest.Required)

		-- notify client immediately so their progress bar updates in real-time
		-- better UX than waiting for the next save cycle
		SendQuestUpdate(Player, "Progress", Quest)

		-- check if quest is now complete
		-- threshold is >= not == because if Amount overshoots (e.g. gain 50 when Required is 30),
		-- we want to complete immediately, not require another call
		if Quest.Progress >= Quest.Required then
			CompleteQuest(Player, Quest)
		end
	end

	if QuestId then
		-- specific quest ID provided
		-- update only that quest (useful for "kill this specific enemy" mechanics)
		local Quest = Active[QuestId]
		if Quest then
			Bump(Quest)
		end
	else
		-- no QuestId provided means apply to all active quests
		-- useful for "gain 10 experience" mechanics that progress everything at once
		for _, Quest in pairs(Active) do
			Bump(Quest)
		end
	end

	MarkDirty(Player)
end

function QuestService:GetActiveQuest(Player, QuestId)
	-- read-only query function
	-- doesnt modify state, just retrieves it
	-- good API design: separate queries from mutations
	local Active = ActiveQuests[Player]
	if not Active then
		return nil
	end

	if QuestId then
		-- specific quest requested
		return Active[QuestId]
	end

	-- no ID specified means return all active quests
	return Active
end

function QuestService:IsCompleted(Player, QuestId)
	-- check both that the completed table exists AND that quest is marked done
	-- prevents nil errors if player never completed anything
	-- ensures accurate completion state
	local Completed = CompletedQuests[Player]
	return Completed ~= nil and Completed[QuestId] == true
end

function QuestService:Save(Player)
	-- force immediate save outside the autosave cycle
	-- normally saves happen on the 5s cycle but this lets you trigger now
	local Ok = SavePlayerData(Player)
	if Ok then
		-- clear dirty flag if save succeeded
		-- prevents this player from being re-saved unnecessarily in the next cycle
		DirtyPlayers[Player] = nil
	end
	return Ok
end

function QuestService:Init()
	-- initialize the entire quest system
	-- sets up event connections, the autosave loop, shutdown handler
	-- called once at server startup
	if Initialized then
		return
	end

	Initialized = true

	LoadQuestDefinitions()

	-- connect to player join/leave events
	-- track connections in ServiceTrove so they get cleaned up later
	ServiceTrove:Add(Players.PlayerAdded:Connect(OnPlayerAdded))
	ServiceTrove:Add(Players.PlayerRemoving:Connect(OnPlayerRemoving))

	-- handle players who were already in the game before this script ran
	-- e.g. if youre testing in studio with an existing player
	-- spawn them as tasks so they run concurrently instead of sequentially
	for _, Player in ipairs(Players:GetPlayers()) do
		task.spawn(OnPlayerAdded, Player)
	end

	-- the main autosave loop
	-- this is the heartbeat of the quest persistence system
	ServiceTrove:Add(task.spawn(function()
		while true do
			-- wait for the debounce interval before checking for dirty players
			task.wait(SaveDebounceInterval)

			local ToSave = {}

			-- collect all dirty players into a list first
			-- dont save while iterating over DirtyPlayers because modifying it during iteration
			-- can cause us to miss players or save duplicates
			for Player in pairs(DirtyPlayers) do
				table.insert(ToSave, Player)
			end

			-- iterate over ToSave and save each player
			-- clear the dirty flag optimistically (before saving)
			-- if the save succeeds, great, we saved time
			-- if it fails, we immediately re-mark them dirty to retry next cycle
			for _, Player in ipairs(ToSave) do
				DirtyPlayers[Player] = nil

				-- check if the player is still in the game
				-- they might have left between when we collected ToSave and now
				-- if theyre gone, dont waste time trying to save
				if Player.Parent then
					local Ok = SavePlayerData(Player)

					-- if the save failed, mark them dirty again
					-- theyll be retried on the next autosave cycle
					if not Ok then
						DirtyPlayers[Player] = true
					end
				end

				-- wait between saves to avoid datastore throttling
				-- throttling happens when you fire too many requests at once
				-- spreading them across the 5s cycle (one every 0.1s) prevents that
				task.wait(SaveStagger)
			end
		end
	end))

	-- handle server shutdown gracefully
	-- when roblox shuts down the server, this callback runs first
	-- we have time to save all player data before the process terminates
	game:BindToClose(function()
		local Threads = {}

		-- spawn a save thread for each player still connected
		-- spawn lets them all run in parallel instead of one after another
		-- much faster than sequential saves
		for _, Player in ipairs(Players:GetPlayers()) do
			table.insert(Threads, task.spawn(function()
				SavePlayerData(Player)
			end))
		end

		-- calculate the absolute deadline for shutdown
		-- we wait up to ShutdownDeadline seconds but no more
		local Deadline = os.clock() + ShutdownDeadline

		-- wait for each save thread to finish, but with a hard deadline
		-- if a save thread is still running when we hit the deadline,
		-- we stop waiting and let the server shut down anyway
		-- better to miss one save than hang the server forever and fail to restart
		for _, Thread in ipairs(Threads) do
			while coroutine.status(Thread) ~= "dead" and os.clock() < Deadline do
				-- loop with small waits instead of a single long wait
				-- this lets us check if the deadline has been exceeded frequently
				-- so we exit as soon as possible after the deadline
				task.wait(0.1)
			end
		end
	end)
end

return QuestService
