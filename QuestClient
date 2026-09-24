--Discord: @syn1axx;   Roblox: @NebogomDanYo

local TweenService = game:GetService("TweenService") -- Getting TweenService for smooth UI properties changes
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- Getting ReplicatedStorage to access packages

local Packages = ReplicatedStorage.Packages -- Points to the Packages folder holding modules
local Trove = require(Packages.Trove) -- Loads Trove to handle cleanup of connections and tweens automatically
local QuickNet = require(Packages.QuickNet) -- Loads QuickNet to not set up RemoteEvents manually

local Data = QuickNet.Data -- Shortcut to QuickNet data type table
local QuestEvent = QuickNet:register("QuestUpdate", Data.String, Data.Any) -- Creates a remote event called QuestUpdate

local QuestsFrame = script.Parent -- The main UI frame this script controls
local QuestsContainer = QuestsFrame.List -- The list that holds all the individual quest frames
local Template = QuestsContainer.Template -- The hidden template which is being cloned for every new quest

local OriginalPosition = QuestsFrame.Position -- Remembers where the panel sits when its visible
local HiddenPosition = UDim2.new( -- Builds the position for when the panel is hidden off-screen
	1.01, -- Pushes the X scale just past the right edge of the screen
	OriginalPosition.X.Offset, -- Keeps the original X pixel offset
	OriginalPosition.Y.Scale, -- Keeps the original Y scale
	OriginalPosition.Y.Offset -- Keeps the original Y pixel offset
)

local CompletedColor = Color3.fromRGB(123, 255, 130) -- The green color for tinting elements when quest is done

local TweenInfoSet = { -- Stores all our tween settings in one place so they are easy to tweak
	SlideIn = TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), -- Used when sliding the panel into view
	SlideOut = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), -- Used when sliding the panel away
	Icon = TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), -- Used for fading the completion icon
	FadeOut = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), -- Used when fading out quest elements
	Color = TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), -- Used for color transitions
}

local FadePropertyMap = { -- Tells which transparency property each class uses
	ImageLabel = "ImageTransparency", -- ImageLabels fade with ImageTransparency
	TextLabel = "TextTransparency", -- TextLabels fade with TextTransparency
	UIStroke = "Transparency", -- UIStrokes fade with Transparency
	UIShadow = "Transparency", -- UIShadows fade with Transparency
}

local ActiveQuestCount = 0 -- Keeps track of how many quests are showing right now
local IsVisible = false -- Remembers if the panel is currently visible
local CurrentSlideTween = nil -- Stores the active slide tween so we can cancel it if needed
local Destroyed = false -- Turns true once the script starts cleaning up so we stop doing work

local UI = Trove.new() -- Creates a Trove that will manage every connection, tweens, and tasks

QuestsFrame.Position = HiddenPosition -- Prepares panel for sliding in
Template.Visible = false -- Makes sure the template frame is hidden at start

local function PlayTween(Instance, Info, Properties) -- Creates a tween, tracks it, and plays it
	if Destroyed then  -- If cleaned up
		return nil -- Stop here
	end

	local NewTween = TweenService:Create(Instance, Info, Properties) -- Creates the tween on the target instance
	UI:Add(NewTween) -- Hands the tween to Trove so it gets cancelled later
	NewTween:Play() -- Starts the tween playing

	return NewTween -- Returns the tween in case the caller wants to reference it
end

local function SlideTo(TargetPosition, Info) -- Slides the panel to whatever position is passed
	if Destroyed then  -- If cleaned up
		return -- Stop here
	end

	if CurrentSlideTween then -- If a slide is already happening
		CurrentSlideTween:Cancel() -- Cancel it so the new slide doesnt fight the old one
		CurrentSlideTween = nil -- Clear the reference
	end

	CurrentSlideTween = PlayTween(QuestsFrame, Info, { Position = TargetPosition }) -- Starts the new slide and stores it
end

local function SetVisible(Visible) -- Shows or hides the whole panel
	if Destroyed then  -- If cleaned up
		return -- Stop here
	end
	
	IsVisible = Visible -- Updates our cached visibility state

	if Visible then -- If we want it visible
		SlideTo(OriginalPosition, TweenInfoSet.SlideIn) -- Slide it into view
	else -- Otherwise
		SlideTo(HiddenPosition, TweenInfoSet.SlideOut) -- Slide it off screen
	end
end

local function GetIcon(QuestFrame) -- Finds the checkmark icon inside a quest frame
	local Box = QuestFrame:FindFirstChild("Box") -- Looks for the Box child first
	if not Box then -- If there is no Box
		return nil -- Give up and return nothing
	end

	return Box:FindFirstChild("Icon") -- Returns the checkmark or nil if its missing
end

local function SetIconCompleted(QuestFrame, Completed) -- Shows or hides the checkmark icon
	if Destroyed then  -- If cleaned up
		return -- Stop here
	end

	local Icon = GetIcon(QuestFrame) -- Grabs the icon reference
	if not Icon then -- If there is no icon
		return -- Nothing to do
	end

	PlayTween(Icon, TweenInfoSet.Icon, { -- Fades the icon
		ImageTransparency = Completed and 0 or 1, -- Makes it visible when done, hidden otherwise
	})
end

local function SetCompletedColors(QuestFrame) -- Turns a quest ui elements green when its finished
	if Destroyed then  -- If cleaned up
		return -- Stop here
	end

	local Stroke = QuestFrame.Box.UIStroke -- Grabs the stroke around the box
	if Stroke then -- If the stroke exists
		PlayTween(Stroke, TweenInfoSet.Color, { Color = CompletedColor }) -- Tints it green
	end

	local Icon = GetIcon(QuestFrame) -- Grabs the icon
	if Icon then -- If the icon exists
		PlayTween(Icon, TweenInfoSet.Color, { ImageColor3 = CompletedColor }) -- Tints it green
	end

	local Label = QuestFrame.QuestLabel -- Grabs the quest label
	if Label then -- If the label exists
		PlayTween(Label, TweenInfoSet.Color, { TextColor3 = CompletedColor }) -- Tints it green
	end
end

local function FadeOutAll(Root) -- Recursively fades out everything under a root
	if Destroyed then  -- If cleaned up
		return -- Stop here
	end

	local function Fade(Instance) -- Inner function that handles one instance at a time
		local IsFadeable = Instance:IsA("GuiObject") -- Checks if its a GuiObject
			or Instance:IsA("UIStroke") -- Or a UIStroke
			or Instance:IsA("UIShadow") -- Or a UIShadow

		if IsFadeable then -- If this thing can be faded
			local Property = FadePropertyMap[Instance.ClassName] -- Looks up its transparency property
			if Property then -- If we found one
				PlayTween(Instance, TweenInfoSet.FadeOut, { [Property] = 1 }) -- Fades it to fully transparent
			end
		end

		for _, Child in ipairs(Instance:GetChildren()) do -- Goes through each child
			Fade(Child) -- And fades it too
		end
	end

	Fade(Root) -- Kicks off the recursion from the root
end

local function FadeOutQuest(QuestFrame) -- Fades a quest out and then removes it
	FadeOutAll(QuestFrame) -- Starts fading everything inside the frame

	UI:Add(task.delay(TweenInfoSet.FadeOut.Time, function() -- Waits for the fade to finish using a tracked delay
		if QuestFrame.Parent then -- If the frame is still around
			QuestFrame:Destroy() -- Removes it completely
		end
	end))
end

local function UpdateQuestLabel(QuestFrame, Data) -- Refreshes the quest text label
	if Destroyed then  -- If cleaned up
		return -- Stop here
	end

	QuestFrame.QuestLabel.Text = string.format( -- Formats the label text
		"%s (%d/%d)",
		Data.Description, -- The quest description
		Data.Progress or 0, -- Current progress, defaults to 0
		Data.Required -- How much is needed
	)
end

local function CreateQuest(Data) -- Builds new quest frame
	if Destroyed then  -- If cleaned up
		return nil  -- Stop here
	end

	local QuestFrame = Template:Clone() -- Clones the hidden template
	QuestFrame.Name = Data.Id -- Names it after the quest ID so it can be found later
	QuestFrame.Visible = true -- Makes it visible
	QuestFrame.Parent = QuestsContainer -- Drops it into the list

	UpdateQuestLabel(QuestFrame, Data) -- Sets the initial text
	SetIconCompleted(QuestFrame, false) -- Hides the completion icon for now

	ActiveQuestCount += 1 -- Bumps up our active counter
	SetVisible(true) -- Makes sure the panel is showing

	return QuestFrame -- Returns new frame
end

local function HideIfEmpty() -- Hides the panel when there are no quests left
	if Destroyed then  -- If cleaned up
		return -- Stop here
	end

	if ActiveQuestCount == 0 then -- If nothing is active
		SetVisible(false) -- Slide the panel away
	end
end

local function HandleEvent(Action, Data) -- Routes every quest event to the right handler
	if Destroyed then  -- If cleaned up
		return -- Stop here
	end

	if Action == "Started" then -- When a quest starts
		if not QuestsContainer:FindFirstChild(Data.Id) then -- Only make a frame if there is no already one
			CreateQuest(Data) -- Builds the new quest frame
		end
	elseif Action == "Progress" then -- When a quest progresses
		local QuestFrame = QuestsContainer:FindFirstChild(Data.Id) -- Finds the required frame
		if QuestFrame then -- If it exists
			UpdateQuestLabel(QuestFrame, Data) -- Refreshes the text
		end
	elseif Action == "Completed" then -- When a quest finishes
		local QuestFrame = QuestsContainer:FindFirstChild(Data.Id) -- Finds the required frame
		if not QuestFrame then -- If it doesnt exist
			return -- Nothing to do
		end

		if QuestFrame:GetAttribute("CountedCompleted") then -- If already counted this one
			return -- Skip it to not double-count
		end

		QuestFrame:SetAttribute("CountedCompleted", true) -- Marks it as counted
		SetIconCompleted(QuestFrame, true) -- Shows the checkmark
		SetCompletedColors(QuestFrame) -- Turns stroke, text, and icon green
		ActiveQuestCount = math.max(0, ActiveQuestCount - 1) -- Lowers the counter but never below zero

		UI:Add(task.delay(TweenInfoSet.Icon.Time + 0.5, function() -- Waits a moment so the player sees the checkmark
			if Destroyed then  -- If cleaned up
				return -- Stop here
			end

			if QuestFrame.Parent then -- If the frame still exists
				FadeOutQuest(QuestFrame) -- Fades it out and removes it
			end

			HideIfEmpty() -- Hides the panel if nothing is left
		end))
	end
end

local function Cleanup() -- Cleans up everything when the script or ui goes away
	if Destroyed then  -- If cleaned up
		return -- Stop here
	end

	Destroyed = true -- Marks us as destroyed so nothing else runs

	if CurrentSlideTween then -- If a slide is still going
		CurrentSlideTween:Cancel() -- Cancel it
		CurrentSlideTween = nil -- Clear the reference
	end

	UI:Destroy() -- Destroys the Trove which handles all the rest
end

UI:Add(QuestEvent.OnClientEvent:Connect(HandleEvent)) -- Hooks up the remote event to our handler
UI:Add(QuestsFrame.Destroying:Connect(Cleanup)) -- Runs cleanup if the ui frame is destroyed
UI:Add(script.Destroying:Connect(Cleanup)) -- Runs cleanup if the script itself is destroyed
