--Discord: @syn1axx;   Roblox: @NebogomDanYo

local DataStoreService = game:GetService("DataStoreService") -- Getting DataStoreService to save and load player quest data
local Players = game:GetService("Players") -- Getting Players service to handle player join and leave events
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Getting ReplicatedStorage to access shared packages

local Packages = ReplicatedStorage.Packages -- Points to the Packages folder holding modules
local Trove = require(Packages.Trove) -- Loads Trove to handle cleanup of connections and tasks automatically
local QuickNet = require(Packages.QuickNet) -- Loads QuickNet to not set up RemoteEvents manually

local Data = QuickNet.Data -- Shortcut to QuickNet data type table
local QuestStore = DataStoreService:GetDataStore("QuestsData") -- Creates or gets the datastore that holds quest data

local SaveDebounceInterval = 5 -- How often autosave loop checks for dirty players
local ShutdownDeadline = 10 -- How long to wait for saves during server shutdown
local SaveStagger = 0.1 -- Delay between saving each player to avoid datastore throttling

local QuestEvent = QuickNet:register("QuestUpdate", Data.String, Data.Any) -- Creates a remote event called QuestUpdate

local QuestService = {} -- The main service table that gets returned at the end

local QuestDefinitions = {} -- Stores all loaded quest definitions by their Id
local ActiveQuests = {} -- Tracks active quests per player (keyed by Player, then by QuestId)
local CompletedQuests = {} -- Tracks completed quests per player (keyed by Player, then by QuestId)
local DirtyPlayers = {} -- Tracks players who have unsaved changes that need to be persisted

local ServiceTrove = Trove.new() -- Creates a Trove that will manage every connection, tweens, and tasks
local Initialized = false -- Guards against running Init more than once

local function GetKey(Player) -- Builds the datastore key for a player
	return "Player_" .. Player.UserId -- Uses the UserId so it stays unique and stable
end

local function IsValidDefinition(Definition) -- Checks if a quest definition table has all required fields
	return typeof(Definition) == "table" -- Must be a table
		and typeof(Definition.Id) == "string" -- Must have a string Id
		and typeof(Definition.Description) == "string" -- Must have a string Description
		and typeof(Definition.Required) == "number" -- Must have a numeric Required amount
		and Definition.Required > 0 -- Required must be greater than zero
end

local function SanitizeLoaded(Raw) -- Cleans up raw data loaded from the datastore
	local Clean = {} -- The sanitized table which will return
	if typeof(Raw) ~= "table" then -- If the loaded data is not a table
		return Clean -- Return an empty table instead
	end

	for QuestId, Entry in pairs(Raw) do -- Goes through each quest entry
		local IsValid = typeof(Entry) == "table" -- Each entry must be a table
			and typeof(Entry.Progress) == "number" -- Must have a numeric Progress
			and typeof(Entry.Completed) == "boolean" -- Must have a boolean Completed

		if IsValid then -- If the entry passes validation
			Clean[QuestId] = { -- Store only the important fields
				Progress = Entry.Progress, -- The saved progress amount
				Completed = Entry.Completed, -- Whether the quest was completed
			}
		end
	end

	return Clean -- Returns the cleaned data
end

local function LoadPlayerData(Player) -- Loads player quest data from the datastore
	local Success, Result = pcall(function() -- Wraps the call in pcall to catch errors
		return QuestStore:GetAsync(GetKey(Player)) -- Fetches the saved data using the player key
	end)

	if not Success then -- If the fetch failed
		return {} -- Return empty data so the player starts fresh
	end

	return SanitizeLoaded(Result) -- Returns the sanitized loaded data
end

local function SavePlayerData(Player) -- Saves player quest data to the datastore
	local Active = ActiveQuests[Player] -- Grabs player active quests
	local Completed = CompletedQuests[Player] -- Grabs player completed quests
	if not Active and not Completed then -- If the player has no data at all
		return false -- Nothing to save
	end

	local Payload = {} -- The table which going to merge into the datastore

	for QuestId, Quest in pairs(Active or {}) do -- Goes through each active quest
		Payload[QuestId] = { Progress = Quest.Progress, Completed = false } -- Marks it as not completed with its progress
	end

	for QuestId in pairs(Completed or {}) do -- Goes through each completed quest
		if not Payload[QuestId] then -- If it wasnt already added as active
			Payload[QuestId] = { Progress = 0, Completed = true } -- Marks it as completed with zero progress
		end
	end

	local PayloadCount = 0 -- Counter for how many entries are in the payload
	for _ in pairs(Payload) do PayloadCount += 1 end -- Counts each entry

	if PayloadCount == 0 then -- If there is nothing to save
		return true -- Treat it as a successful no-op
	end

	local Success, Error = pcall(function() -- Wraps the update in pcall to catch errors
		QuestStore:UpdateAsync(GetKey(Player), function(Current) -- Uses UpdateAsync to safely merge with existing data
			local Merged = SanitizeLoaded(Current) -- Cleans whatever is already in the datastore

			for QuestId, Entry in pairs(Payload) do -- Goes through our new payload
				Merged[QuestId] = Entry -- Overwrites or adds each entry
			end

			return Merged -- Returns the merged result to be saved
		end)
	end)

	if not Success then -- If the save failed
		return false -- Return failure so the player stays dirty
	end

	return true -- Return success
end

local function MarkDirty(Player) -- Flags a player as having unsaved changes
	if Player and Player.Parent then -- Only mark if the player still exists
		DirtyPlayers[Player] = true -- Adds them to the dirty set
	end
end

local function LoadQuestDefinitions() -- Loads all quest definition modules from ReplicatedStorage
	local Shared = ReplicatedStorage:WaitForChild("Shared") -- Waits for the Shared folder
	local QuestsFolder = Shared:WaitForChild("Quests") -- Waits for the Quests folder inside it

	for _, Module in ipairs(QuestsFolder:GetChildren()) do -- Goes through every child of the Quests folder
		if not Module:IsA("ModuleScript") then -- If its not a ModuleScript
			continue -- Skip it
		end

		local Ok, Definition = pcall(require, Module) -- Tries to require the module safely
		if not Ok then -- If requiring failed
			continue -- Skip this module
		end

		if IsValidDefinition(Definition) then -- If the definition is valid
			QuestDefinitions[Definition.Id] = Definition -- Stores it by its Id
		end
	end
end

local function SendQuestUpdate(Player, Action, Quest) -- Sends a quest update to a specific player
	QuestEvent:FireClient(Player, Action, { -- Fires the remote with the action and quest data
		Id = Quest.Id, -- The quest Id
		Description = Quest.Description, -- The quest description
		Required = Quest.Required, -- How much is needed
		Progress = Quest.Progress, -- Current progress
	})
end

local function CompleteQuest(Player, Quest) -- Marks a quest as completed for a player
	QuestEvent:FireClient(Player, "Completed", { Id = Quest.Id }) -- Tells the client the quest is done

	CompletedQuests[Player] = CompletedQuests[Player] or {} -- Ensures the completed table exists
	CompletedQuests[Player][Quest.Id] = true -- Marks the quest as completed
	ActiveQuests[Player][Quest.Id] = nil -- Removes it from active quests
end

local function HydrateAndSend(Player, Saved) -- Rebuilds player quest state from saved data and sends it to the client
	ActiveQuests[Player] = ActiveQuests[Player] or {} -- Ensures the active table exists
	CompletedQuests[Player] = CompletedQuests[Player] or {} -- Ensures the completed table exists

	for QuestId, SavedEntry in pairs(Saved) do -- Goes through each saved entry
		local Definition = QuestDefinitions[QuestId] -- Looks up the quest definition
		if not Definition then -- If there is no definition for this quest
			continue -- Skip it
		end

		if SavedEntry.Completed then -- If the quest was completed
			CompletedQuests[Player][QuestId] = true -- Just mark it as completed
			continue -- Move to the next one
		end

		local Quest = { -- Builds the active quest object
			Id = Definition.Id, -- The quest Id
			Description = Definition.Description, -- The quest description
			Required = Definition.Required, -- How much is needed
			Progress = math.clamp(SavedEntry.Progress, 0, Definition.Required), -- Clamps progress between 0 and required
		}

		ActiveQuests[Player][QuestId] = Quest -- Stores the active quest
		SendQuestUpdate(Player, "Started", Quest) -- Tells the client the quest has started
	end
end

local function OnPlayerAdded(Player) -- Handles a player joining the game
	local Saved = LoadPlayerData(Player) -- Loads their saved quest data
	HydrateAndSend(Player, Saved) -- Rebuilds their state and sends it to the client
end

local function OnPlayerRemoving(Player) -- Handles a player leaving the game
	pcall(SavePlayerData, Player) -- Tries to save their data one last time

	DirtyPlayers[Player] = nil -- Removes them from the dirty set
	ActiveQuests[Player] = nil -- Clears their active quests
	CompletedQuests[Player] = nil -- Clears their completed quests
end

function QuestService:RegisterQuest(Definition) -- Public function to register a quest definition at runtime
	assert(IsValidDefinition(Definition), "Invalid quest definition") -- Makes sure the definition is valid
	QuestDefinitions[Definition.Id] = Definition -- Stores it by its Id
end

function QuestService:StartQuest(Player, QuestOrId) -- Public function to start a quest for a player
	local QuestId = typeof(QuestOrId) == "table" and QuestOrId.Id or QuestOrId -- Supports passing either a table or an Id string
	local Definition = typeof(QuestOrId) == "table" and QuestOrId or QuestDefinitions[QuestId] -- Resolves the definition

	if not Definition then -- If there is no definition
		return -- Nothing to start
	end

	ActiveQuests[Player] = ActiveQuests[Player] or {} -- Ensures the active table exists
	CompletedQuests[Player] = CompletedQuests[Player] or {} -- Ensures the completed table exists

	if ActiveQuests[Player][Definition.Id] then -- If the quest is already active
		return -- Dont start it again
	end

	CompletedQuests[Player][Definition.Id] = nil -- Removes it from completed so it can be redone

	local Quest = { -- Builds the active quest object
		Id = Definition.Id, -- The quest Id
		Description = Definition.Description, -- The quest description
		Required = Definition.Required, -- How much is needed
		Progress = 0, -- Starts at zero progress
	}

	ActiveQuests[Player][Definition.Id] = Quest -- Stores the active quest
	SendQuestUpdate(Player, "Started", Quest) -- Tells the client the quest has started
	MarkDirty(Player) -- Flags the player as needing a save
end

function QuestService:AddProgress(Player, Amount, QuestId) -- Public function to add progress to a quest
	if typeof(Amount) ~= "number" or Amount <= 0 then -- If the amount is invalid
		return -- Nothing to do
	end

	local Active = ActiveQuests[Player] -- Grabs player active quests
	if not Active then -- If they have none
		return -- Nothing to do
	end

	local function Bump(Quest) -- Inner helper that adds progress to one quest
		Quest.Progress = math.min(Quest.Progress + Amount, Quest.Required) -- Adds progress but caps at required

		SendQuestUpdate(Player, "Progress", Quest) -- Tells the client about the progress

		if Quest.Progress >= Quest.Required then -- If the quest is now complete
			CompleteQuest(Player, Quest) -- Marks it as completed
		end
	end

	if QuestId then -- If a specific quest Id was given
		local Quest = Active[QuestId] -- Grabs that quest
		if Quest then -- If it exists
			Bump(Quest) -- Adds progress to it
		end
	else -- Otherwise
		for _, Quest in pairs(Active) do -- Goes through every active quest
			Bump(Quest) -- Adds progress to each one
		end
	end

	MarkDirty(Player) -- Flags the player as needing a save
end

function QuestService:GetActiveQuest(Player, QuestId) -- Public function to get player active quests
	local Active = ActiveQuests[Player] -- Grabs player active quests
	if not Active then -- If they have none
		return nil -- Return nothing
	end

	if QuestId then -- If a specific quest Id was given
		return Active[QuestId] -- Return just that one
	end

	return Active -- Otherwise return the whole table
end

function QuestService:IsCompleted(Player, QuestId) -- Public function to check if a quest is completed
	local Completed = CompletedQuests[Player] -- Grabs player completed quests
	return Completed ~= nil and Completed[QuestId] == true -- Returns true only if it exists and is marked done
end

function QuestService:Save(Player) -- Public function to force a save for a player
	local Ok = SavePlayerData(Player) -- Tries to save
	if Ok then -- If it succeeded
		DirtyPlayers[Player] = nil -- Clear the dirty flag
	end
	return Ok -- Return the result
end

function QuestService:Init() -- Initializes the service, wires up events, and starts the auto-save loop
	if Initialized then -- If already initialized
		return -- Dont do it again
	end

	Initialized = true -- Marks us as initialized

	LoadQuestDefinitions() -- Loads all quest definitions from ReplicatedStorage

	ServiceTrove:Add(Players.PlayerAdded:Connect(OnPlayerAdded)) -- Hooks up the player joined event
	ServiceTrove:Add(Players.PlayerRemoving:Connect(OnPlayerRemoving)) -- Hooks up the player leaving event

	for _, Player in ipairs(Players:GetPlayers()) do -- Goes through any players already in the game
		task.spawn(OnPlayerAdded, Player) -- Handles them as if they just joined
	end

	ServiceTrove:Add(task.spawn(function() -- Starts the auto-save loop as a tracked task
		while true do -- Runs forever until the trove is destroyed
			task.wait(SaveDebounceInterval) -- Waits the debounce interval

			local ToSave = {} -- Collects the players that need to save

			for Player in pairs(DirtyPlayers) do -- Goes through every dirty player
				table.insert(ToSave, Player) -- Adds them to the list
			end

			for _, Player in ipairs(ToSave) do -- Goes through each player to save
				DirtyPlayers[Player] = nil -- Clears the dirty flag optimistically

				if Player.Parent then -- If the player is still in the game
					local Ok = SavePlayerData(Player) -- Tries to save

					if not Ok then -- If the save failed
						DirtyPlayers[Player] = true -- Mark them dirty again to retry next cycle
					end
				end

				task.wait(SaveStagger) -- Waits a bit before the next player to avoid throttling
			end
		end
	end))

	game:BindToClose(function() -- Hooks up the server shutdown handler
		local Threads = {} -- Collects the save threads

		for _, Player in ipairs(Players:GetPlayers()) do -- Goes through every player still in the game
			table.insert(Threads, task.spawn(function() -- Starts a save thread for each
				SavePlayerData(Player) -- Tries to save their data
			end))
		end

		local Deadline = os.clock() + ShutdownDeadline -- Calculates the absolute deadline
		for _, Thread in ipairs(Threads) do -- Goes through each save thread
			while coroutine.status(Thread) ~= "dead" and os.clock() < Deadline do -- Waits until it finishes or the deadline run out of time
				task.wait(0.1) -- Small wait to avoid busy looping
			end
		end
	end)
end

return QuestService -- Returns the service so other scripts can require and use it
