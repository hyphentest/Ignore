--[[
Connected Discord-GitHub
bbellick
@phoontg

DataService basically handles all player data lifecycle management
i used ProfileStore for session-locking, to prevent race conditions for the players concurrent data slot and prevent accidental overwrites
for my networking and overall architechture, i used Knit since im familiar with it, gives me a clean n promise ready bridge
i also implemented a 'currentSession' class to encapsulate player state, letting me track RBXScriptConnections n clean them up upon disconnection
also preventing memory leaks and overall solving the performance side
basic flow of this service:
player joins
> ProfileStore starts a session for their data
> currentSession is created and stored in _Sessions
> leaderstats are built from the profile data

when the character loads
> LoadSavedAppearance runs and reapplies anything saved in Loadout

during play time
> stats and loadout changes update the ProfileStore data through the session

player leaves or session ends OR just serv gets shutodnw
> ProfileStore session closes
> currentSession:Destroy() runs to disconnect events and clear references

in this version, ive refractored specific codeblocks, added more roblox api usage and bettered my comments
also made the style easier on the eyes with nice spacing between each declaration
]]

local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local TweenService    = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Codebase        = ReplicatedStorage:WaitForChild("Codebase")

local Knit         	  = require(ReplicatedStorage:WaitForChild("Packages").Knit) -- framework
local ProfileStore    = require(script:WaitForChild("ProfileStore")) -- library
local Notification    = require(Codebase.Controllers.UIController:WaitForChild("Notification"))

-- default data schema, ProfileStore uses this as the base template on first join
-- Reconcile() fills in any keys that are missing from older profiles
local PlayerTemplate = {
	Kills  = 0,
	Deaths = 0,
	Cash   = 0,
	Loadout = {
		Shirt    = "",
		Pants    = "",
		Hair     = "",
		Headgear = "",
		Bodygear = "",
		Armband  = "",
	},
}

-- payout config
local PAY_INTERVAL_SECONDS = 300 -- passive income fires every 5 minutes
local PAY_AMOUNT = 100 -- flat cash granted per payout tick

--[[
category config maps loadout slot names to their attachment points on the R15 rig
Offset is a CFrame applied on top of the target part's CFrame before welding, letting me nudge accessories into position without touching the model itself
]]
local Categories = {
	Hair     = { Attachment = "HairAttachment",     Target = "Head",         Offset = CFrame.identity           },
	Headgear = { Attachment = "HeadgearAttachment", Target = "Head",         Offset = CFrame.identity          },
	Bodygear = { Attachment = "VestAttachment",     Target = "UpperTorso",   Offset = CFrame.new(0, -0.2, 0)   },
	Armband  = { Attachment = "ArmbandAttachment",  Target = "RightUpperArm",Offset = CFrame.new(0, -0.2, 0)   },
}

-- cash milestone thresholds, checked whenever a players cash value changes
local CASH_MILESTONES = { 25000, 35000, 50000 }
--[[
	@currentSession class
	wraps a single players Profile and their event connections into one object so cleanup is contained
]]

local currentSession = {}
currentSession.__index = currentSession

function currentSession.new(player, profile)
	local self    = setmetatable({}, currentSession)
	self.Player      = player
	self.Profile     = profile
	self.Connections = {} -- all RBXScriptConnections created during this session live here
	self.TriggeredMilestones = {}
	return self
end

--[[
	@UpdateStat 
	writes a new value to both the persistent profile slot
	and the matching IntValue under leaderstats so the leaderboard stays in sync
	the nil check on profile data prevents us from accidentally creating keys
]]
function currentSession:UpdateStat(statName, value)
	if self.Profile.Data[statName] == nil then 
		return 
	end

	self.Profile.Data[statName] = value
	local leaderstats = self.Player:FindFirstChild("leaderstats")
	if not leaderstats then 
		return
	end

	local statObj = leaderstats:FindFirstChild(statName)
	if statObj then
		statObj.Value = value
	end
end

--[[
	@SaveToLoadout
	persists a loadout change to the profile slot
	we only write if the category key already exists in the saved Loadout table, made this purposefully so unsupported categories get rejected
]]
function currentSession:SaveToLoadout(category, assetId)
	if self.Profile.Data.Loadout[category] ~= nil then
		self.Profile.Data.Loadout[category] = assetId
	end
end

--[[
	OnStatChanged 
	subscribes a callback to a leaderstats Changed signal storing the connection in self.Connections means itll always be cleaned up in Destroy()
]]
function currentSession:OnStatChanged(statName, callback)
	local leaderstats = self.Player:FindFirstChild("leaderstats")
	if not leaderstats then return end

	local stat = leaderstats:FindFirstChild(statName)
	if not stat then return end

	local conn = stat.Changed:Connect(callback)
	table.insert(self.Connections, conn)
	return conn
end

--[[
	Destroy 
	cleanups called whenever a players session ends
	disconnecting every stored connection basically ensures that tehres no leftover callbacks
	basically overall easing garbage collection to make sure no references are being held
]]
function currentSession:Destroy()
	for _, conn in ipairs(self.Connections) do
		if conn and conn.Disconnect then
			conn:Disconnect()
		end
	end

	self.Connections 		 = nil
	self.Profile     		 = nil
	self.Player      		 = nil
	self.TriggeredMilestones = nil
end


-- DataService
local DataService = Knit.CreateService {
	Name    = "DataService",
	Client  = {},
	_Sessions = {},

	-- _Loadout controls whether loadout state persists across sessions
	_Loadout = {
		loadoutsSave = false, -- loadoutsSave bool controls whether should the clients loadout save or not
		-- in simple terms, if this is true then whenever the player leaves their loadout/appearance will be saved
		Hair     = true,
		Headgear = true,
		Bodygear = true,
		Armband  = true,
	},
}

-- attachment helpers
--[[
	@ConfigurePartPhysics 
	disables all physics interaction on a cosmetic part in the case that we've manually forgot to do so, also eases the process of adding new models
	CanCollide / CanTouch / CanQuery being off prevents accessories from interfering with gameplay (no getting flung by stacked hats n no hard hitbox pollution)
	non root parts also get a WeldConstraint to the root so the model stays rigid without relying on Motor6D or manual CFrame updates
]]
local function ConfigurePartPhysics(part, rootPart)
	part.Anchored   = false
	part.CanCollide = false
	part.CanTouch   = false
	part.CanQuery   = false
	if part ~= rootPart then
		local weld   = Instance.new("WeldConstraint")
		weld.Part0   = part
		weld.Part1   = rootPart
		weld.Parent  = part
	end
end

--[[
	@AttachModel
	clones a model and welds it onto the character
	positioning uses CFrame multiplication: targetPart.CFrame offsetCFrame n modelRotation
	this means accessories stay correctly oriented even if the character rotates
]]
local function AttachModel(character, model, name, targetPartName, offsetCFrame)
	if not model or not character then return end

	local targetPart = character:FindFirstChild(targetPartName)
	if not targetPart then return end

	local clone = model:Clone()
	local root  = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	if not root then
		warn("model '" .. name .. "' has no PrimaryPart set. skipping")
		-- in the case that ive forgotten to set the primarypart, remind mne here
		return
	end

	for _, part in ipairs(clone:GetDescendants()) do
		if part:IsA("BasePart") then
			ConfigurePartPhysics(part, root)
		end
	end

	-- CFrame places the model at the target parts position and applies the offset
	local modelRotation = clone:GetPivot().Rotation
	clone:PivotTo(targetPart.CFrame * (offsetCFrame or CFrame.identity) * modelRotation)
	local mainWeld  = Instance.new("WeldConstraint")
	mainWeld.Part0  = root
	mainWeld.Part1  = targetPart
	mainWeld.Parent = root

	-- naming the clone after the category attachment key for later removal via the wardrobe (manual) or automatic
	clone.Name   = name
	clone.Parent = character
end

--[[
	GetOrCreateClothing
	reuses an existing Shirt/Pants instance if one is already parented to the character otherwise creates a fresh one
	avoids stacking duplicate clothing objects whjich would look horrendous
]]
local function GetOrCreateClothing(character, clothingClass)
	local existing = character:FindFirstChildOfClass(clothingClass)
	if existing then return existing end

	local obj   = Instance.new(clothingClass)
	obj.Parent  = character
	return obj
end

-- equip dispatch
-- split into two focused functions so EquipItem doesn't need a long if/elseif chain each helper handles one concern
local function ApplyClothing(character, category, assetId)
	if category == "Shirt" then
		local shirt = GetOrCreateClothing(character, "Shirt")
		shirt.ShirtTemplate = "rbxassetid://" .. assetId
		return true
	elseif category == "Pants" then
		local pants = GetOrCreateClothing(character, "Pants")
		pants.PantsTemplate = "rbxassetid://" .. assetId
		return true
	end
	return false
end

local function ApplyAccessory(character, category, itemData)
	local cfg = Categories[category]
	if not cfg then return false end

	if typeof(itemData) == "table" and itemData.Item then
		AttachModel(character, itemData.Item, cfg.Attachment, cfg.Target, cfg.Offset)
		return true
	end
	return false
end

-- highlight effect
-- plays a brief BillboardGui pulse above the character's head
-- whenever they hit a cash milestone, uses TweenService to fade it out
local function PlayMilestoneEffect(character, milestoneAmount)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	-- build a temporary billboard that floats above the character
	local billboard      = Instance.new("BillboardGui")
	billboard.Size       = UDim2.new(0, 200, 0, 50)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = false
	billboard.Parent     = hrp

	local label          = Instance.new("TextLabel")
	label.Size           = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text           = "💰 $" .. milestoneAmount .. " milestone!"
	label.TextColor3     = Color3.fromRGB(255, 215, 0)
	label.TextStrokeColor3 		 = Color3.fromRGB(239, 225, 28)
	label.TextStrokeTransparency = 0
	label.TextScaled     = true
	label.Font           = Enum.Font.GothamBold
	label.Parent         = billboard
	
	-- tween the label's transparency from 0 to 1 over 2.5 seconds, then destroy the billboard
	local tweenInfo = TweenInfo.new(2.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween     = TweenService:Create(label, tweenInfo, { TextTransparency = 1 })
	tween:Play()
	tween.Completed:Connect(function()
		billboard:Destroy()
	end)
end

-- leaderstats / appearance helpers

-- builds the leaderstats folder from the clients saved profile data
-- properties are set before parenting to avoid sending partial replication events
local function InitLeaderstats(player, profile)
	local leaderstats  = Instance.new("Folder")
	leaderstats.Name   = "leaderstats"
	for key, val in pairs(PlayerTemplate) do
		if typeof(val) ~= "table" then
			local stat       = Instance.new("IntValue")
			stat.Name        = key
			stat.Value       = profile.Data[key]
			stat.Parent      = leaderstats
		end
	end

	leaderstats.Parent = player
end

--[[
	@SetupCharacterAppearance 
	connects appearance loading to the character lifecycle.
	the check order matters here:
	1. connect CharacterAppearanceLoaded first
	2. then check if a character already exists
	if we did it the other way around there'd be a window between the check and the connect
	where the character could finish loading and fire the event before we're listening,
	meaning the first spawn would never get their loadout applied (fixed TOCTOU race condition)
]]
local function SetupCharacterAppearance(service, player, session)
	-- connect first so we never miss a future character spawn
	local conn = player.CharacterAppearanceLoaded:Connect(function()
		service:LoadSavedAppearance(player)
	end)
	table.insert(session.Connections, conn)

	-- if a character already exists and is fully initialised, load immediately
	local character = player.Character
	if character and character:FindFirstChildOfClass("Humanoid") then
		service:LoadSavedAppearance(player)
	end
end

-- stat change listeners
-- set up after the session is created so callbacks have a valid session reference
local function SetupStatListeners(service, player, session)
	-- cash listener which validates the value is non-negative, checks milestones, and fires a visual effect for each one hit
	session:OnStatChanged("Cash", function(newValue)
		-- reject negative cash could be an exploiter manually writing to the IntValue
		if newValue < 0 then
			session:UpdateStat("Cash", 0)
			Notification:SendNotification(player, "Royal Guard", "Invalid cash value detected; reset to $0.", 8)
			return
		end
		
		for _, milestone in ipairs(CASH_MILESTONES) do
			if newValue >= milestone and not session.TriggeredMilestones[milestone] then
				session.TriggeredMilestones[milestone] = true
				Notification:SendNotification(player, "Economy", "Milestone reached: $" .. milestone .. "!", 15)
				local character = player.Character
				if character then
					PlayMilestoneEffect(character, milestone)
				end
			end
		end
	end)

	-- kills listener which validates integrity and stamps the value onto the Humanoid as an Attribute so other scripts can read it without touching leaderstats
	session:OnStatChanged("Kills", function(newValue)
		-- kills must be a non-negative integer
		if newValue < 0 or newValue ~= math.floor(newValue) then
			session:UpdateStat("Kills", session.Profile.Data.Kills)
			Notification:SendNotification(player, "Royal Guard", "Invalid kill count detected; reverted.", 8)
			return
		end

		local character = player.Character
		if not character then return end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			-- storing on the Humanoid as an Attribute lets LocalScripts read the kill count directly without a remote call
			humanoid:SetAttribute("PlayerKills", newValue)
		end
	end)
end

-- ProfileStore setup
local function GetStoreName()
	-- use a separate store key in Studio so tests don't touch live data
	return RunService:IsStudio() and "studio" or "Key1"
end

local PlayerStore = ProfileStore.New(GetStoreName(), PlayerTemplate)
-- core service methods

--[[
	@EquipItem 
	applies a clothing or accessory item to the player's character
	wrapped in pcall because rbxassetid loading is an external dependency
	(InsertService / asset fetch) that can fail independently of our code
	sop we just catch it here and simply return false
]]
function DataService:EquipItem(player, category, itemData, isAutoLoading)
	local session   = self._Sessions[player]
	local character = player.Character
	if not session or not character then return false end

	local assetId = (typeof(itemData) == "table") and (itemData.Id or itemData.ShirtId) or itemData

	local success = pcall(function()
		local applied = ApplyClothing(character, category, assetId)
		if not applied then
			ApplyAccessory(character, category, itemData)
		end
	end)

	-- only persist the loadout change if equip succeeded and we're not mid-autoload
	if success and not isAutoLoading then
		if self._Loadout.loadoutsSave and self._Loadout[category] then
			session:SaveToLoadout(category, assetId)
		end
	end

	return success
end

-- re-applies every non-empty loadout slot from the player's saved profile
function DataService:LoadSavedAppearance(player)
	local session = self._Sessions[player]
	if not session then return end

	for category, assetId in pairs(session.Profile.Data.Loadout) do
		if assetId ~= "" then
			-- isAutoLoading = true prevents re-saving items were loading FROM the save
			self:EquipItem(player, category, assetId, true)
		end
	end
end

--[[
	@OnPlayerAdded
	full session setup for a joining player
	ProfileStore:StartSessionAsync will yield until it either claims the session lock or determines the player left before it could (via the Cancel callback)
	if profile is nil something went wrong on ProfileStores end kick to force a clean rejoin
]]
function DataService:OnPlayerAdded(player)
	local profile = PlayerStore:StartSessionAsync("User_" .. player.UserId, {
		Cancel = function() return player.Parent ~= Players end,
	})

	if not profile then
		player:Kick("A data error occurred. Please rejoin; if this keeps happening open a support ticket.")
		return
	end

	profile:AddUserId(player.UserId)
	profile:Reconcile()

	--[[
	OnSessionEnd fires if ProfileStore closes the session externally (e.g. another server steals the lock)
	we kick the player so they rejoin cleanly rather than playing with a dead session
	]]
	profile.OnSessionEnd:Connect(function()
		self._Sessions[player] = nil
		player:Kick("Your data session was closed. Please rejoin.")
	end)

	-- player could have left while StartSessionAsync was yielding
	if player.Parent ~= Players then
		profile:EndSession()
		return
	end

	local session = currentSession.new(player, profile)
	self._Sessions[player] = session

	InitLeaderstats(player, profile)
	SetupCharacterAppearance(self, player, session)
	SetupStatListeners(self, player, session)
end

--[[
	@PayoutLoop
	passive income thread which runs in its own task.spawn so it doesnt block out KnitStart
	every PAY_INTERVAL_SECONDS or 300 seconds every active session gets PAY_AMOUNT added to their cash
]]
function DataService:PayoutLoop()
	task.spawn(function()
		while true do
			task.wait(PAY_INTERVAL_SECONDS)
			for _, session in pairs(self._Sessions) do
				local newCash = session.Profile.Data.Cash + PAY_AMOUNT
				session:UpdateStat("Cash", newCash)
				Notification:SendNotification(
					session.Player,
					"Economy",
					"Paycheck received — $" .. PAY_AMOUNT .. " added to your funds.",
					10
				)
			end
		end
	end)
end

function DataService:KnitInit()
	--PlayerRemoving fires before the player actually leaves which gives me a window to cleanly end their ProfileStore session and run Destroy() before references drop
	Players.PlayerRemoving:Connect(function(player)
		local session = self._Sessions[player]
		if not session then return end

		session.Profile:EndSession()
		session:Destroy()
		self._Sessions[player] = nil
	end)
end

function DataService:KnitStart()
	-- handle players who joined before this service finished initialising
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function() self:OnPlayerAdded(player) end)
	end

	Players.PlayerAdded:Connect(function(player)
		self:OnPlayerAdded(player)
	end)

	self:PayoutLoop()
end

-- client bridges

-- RequestEquip is called by the client when a player selects an item from the locker UI
function DataService.Client:RequestEquip(player, category, itemData)
	return self.Server:EquipItem(player, category, itemData, false)
end

-- GetPlayerStats lets the client read the full profile data table for UI display
function DataService.Client:GetPlayerStats(player)
	local session = self.Server._Sessions[player]
	return session and session.Profile.Data or nil
end

return DataService
