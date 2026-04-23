--[[
this service aka DataService handles player persistence, physical character, and their data slot
i used Knit for streamlined networking, and ProfileStore for session locked data handling
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Codebase = ReplicatedStorage:WaitForChild("Codebase")

local Knit = require(ReplicatedStorage:WaitForChild("Packages").Knit) -- framework
local ProfileStore = require(script:WaitForChild("ProfileStore")) -- library
local Notification = require(Codebase.Controllers.UIController:WaitForChild("Notification")) -- self made notification system

-- default data schema
local PlayerTemplate = {
	Kills = 0, -- player kills
	Deaths = 0, -- player deaths
	Cash = 0, -- players cash
	Loadout = {
		-- all loadout tables
		Shirt = "",
		Pants = "",
		Hair = "",
		Headgear = "",
		Bodygear = "",
		Armband = ""
	}
}

-- individual player data lifecycles
local currentSession = {}
currentSession.__index = currentSession

local payInt = 300 -- scheduled payment each 5 mins
local payAmount = 100 -- scheduled amount for a payout
local Categories = {
	-- TODO: use preset offsets rather than defining them
	["Hair"] = {
		Attachment = "HairAttachment", 
		Target = "Head",
		Offset = CFrame.new(0, 0, 0)
	},
	["Headgear"] = {
		Attachment = "HeadgearAttachment",
		Target = "Head", 
		Offset = CFrame.new(0, 0, 0)
	},
	["Bodygear"] = {
		Attachment = "VestAttachment", 
		Target = "UpperTorso", 
		Offset = CFrame.new(0, -0.2, 0)
	},
	["Armband"] = {
		Attachment = "ArmbandAttachment", 
		Target = "RightUpperArm", 
		Offset = CFrame.new(0, -0.2, 0)
	}
}

-- constructor
function currentSession.new(player, profile)
	local self = setmetatable({}, currentSession)
	self.Player = player
	self.Profile = profile
	self.Connections = {} -- array to store RBXScriptConnections for garbage collection
	self.Character = player.Character or player.CharacterAdded:Wait()
	return self
end

--[[
@UpdateStat
this is a method where we synchronize the data schema with the players leaderstats folder
making sure the ui components stay accurate
]]
function currentSession:UpdateStat(statName, value)
	if self.Profile.Data[statName] ~= nil then
		self.Profile.Data[statName] = value
		
		local leaderstats = self.Player:FindFirstChild("leaderstats")
		if leaderstats then
			local statObj = leaderstats:FindFirstChild(statName)
			if statObj then statObj.Value = value end
		end
	end
end

-- basically where the saving logic is being handled
--[[
@SaveToLoadout
method handling a data change each time an asset is committed
]]
function currentSession:SaveToLoadout(category, assetId)
	-- save an item to the loadouts table only if the service permits it
	if self.Profile.Data.Loadout[category] ~= nil then
		self.Profile.Data.Loadout[category] = assetId
	end
end

--[[
disconnects all active character listeners, workaround for mememory management
]]
function currentSession:Destroy()
	for _, conn in ipairs(self.Connections) do
		if conn.Disconnect then conn:Disconnect() end
	end
	self.Connections = nil
	self.Profile = nil
end

local DataService = Knit.CreateService {
	Name = "DataService",
	Client = {},
	_Sessions = {}, -- internal cache for active currentSession objects
	_Loadout = { -- global and category toggles for loadout persistence
		loadoutsSave = false, 
		--[[
		bool for loadout saves
		if its enabled, on leave the players currentl oadout will be saved to his session
		allowing for his items to be back on him without needing to reequip on rejoin
		]]
		["Hair"] = true,
		["Headgear"] = true,
		["Bodygear"] = true,
		["Armband"] = true,
	}
}

--[[
@AttachModel
function to rig a model to the players character
literally no explanation needed, this is as straightforward as it gets
]]
local function AttachModel(character, model, name, targetPartName, offsetCFrame)
	if not model or not character then 
		return 
	end

	local existing = character:FindFirstChild(name)
	local targetPart = character:FindFirstChild(targetPartName)

	local clone = model:Clone()
	local root = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	if not root then
		-- sometimes we can forget to set a primarypart
		-- so am using this like a reminder
		warn("model has no primarypart set on: " .. name)
		return
	end
	
	-- applying rigid const physics to the model
	for _, part in ipairs(clone:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			if part ~= root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = part
				weld.Part1 = root
				weld.Parent = part
			end
		end
	end

	local modelRotation = clone:GetPivot().Rotation
	clone:PivotTo(targetPart.CFrame * (offsetCFrame or CFrame.new()) * modelRotation)

	local mainWeld = Instance.new("WeldConstraint")
	mainWeld.Part0 = root
	mainWeld.Part1 = targetPart
	mainWeld.Parent = root

	clone.Name = name
	--[[
	basically the name of the attached model is always renamed to the relative category name
	this is so whenever we destroy an attachment, it can simply choose for what the user wishes to destroy
	in the client, whenever the player selects "None" (on the locker ui), the category is sent here to be destroyed
	we receive categroy > check the matching category naem like: is it headgear? then destroy the HeadgearAttachment on the players character
	]]
	clone.Parent = character
end

--[[
@EquipItem
method for handling the primary entry point to the character customization
]]
function DataService:EquipItem(player, category, itemData, isAutoLoading)
	local session = self._Sessions[player]
	local character = player.Character
	if not session or not character then 
		return false
	end

	-- asset normalization for handling raw ids and nested tables
	local assetId = (typeof(itemData) == "table") and (itemData.Id or itemData.ShirtId) or itemData
	local success = pcall(function()
		if category == "Shirt" then
			local s = character:FindFirstChildOfClass("Shirt") or Instance.new("Shirt", character)
			s.ShirtPlayerTemplate = "rbxassetid://" .. assetId
		elseif category == "Pants" then
			local p = character:FindFirstChildOfClass("Pants") or Instance.new("Pants", character)
			p.PantsPlayerTemplate = "rbxassetid://" .. assetId
		elseif Categories[category] then
			local cfg = Categories[category]
			-- attachment logic for models
			if typeof(itemData) == "table" and itemData.Item then
				AttachModel(character, itemData.Item, cfg.Attachment, cfg.Target, cfg.Offset)
			end
		end
	end)
	
	-- check whether loadout profile saving is enabled or not
	if success and not isAutoLoading then
		if self._Loadout.loadoutsSave and self._Loadout[category] then
			-- if enabled save the loadout to the players current session
			session:SaveToLoadout(category, assetId)
		end
	end

	return success
end

function DataService:LoadSavedAppearance(player)
	local session = self._Sessions[player]
	if not session then return end

	local savedLoadout = session.Profile.Data.Loadout
	for category, assetId in pairs(savedLoadout) do
		if assetId ~= "" then
			-- true prevents constant saving during the initial load process
			self:EquipItem(player, category, assetId, true)
		end
	end
end

local function GetStoreName()
	return RunService:IsStudio() and "studio" or "Key1"
end

--[[
@OnPlayerAdded
method for handling data and session initialisation, data reconciliation and the stats setup
small safeguard to kick the player incase their data loading fails
]]
local PlayerStore = ProfileStore.New(GetStoreName(), PlayerTemplate)
function DataService:OnPlayerAdded(player)
	local profile = PlayerStore:StartSessionAsync("User_"..player.UserId, {
		Cancel = function() return player.Parent ~= Players end,
	})

	if profile then
		profile:AddUserId(player.UserId)
		profile:Reconcile()
		profile.OnSessionEnd:Connect(function()
			self._Sessions[player] = nil
			player:Kick("Data session closed")
		end)

		if player.Parent == Players then
			local session = currentSession.new(player, profile)
			self._Sessions[player] = session
			-- dynamically buildl eaderstats from the data schema
			local ls = Instance.new("Folder", player)
			ls.Name = "leaderstats"

			for key, val in pairs(PlayerTemplate) do
				if typeof(val) ~= "table" then
					local stat = Instance.new("IntValue", ls)
					stat.Name = key
					stat.Value = profile.Data[key]
				end
			end

			local characterAddedConn = player.CharacterAdded:Connect(function()
				task.wait(0.2) -- small waittime for the character to fully load
				self:LoadSavedAppearance(player)
			end)
			table.insert(session.Connections, characterAddedConn)

			-- if the character exists before the event is connected
			if player.Character then 
				task.spawn(function() self:LoadSavedAppearance(player) end) 
			end
		else
			profile:EndSession()
		end
	else
		-- if a data error occurs, kick the player to force rejoin
		player:Kick("Woopsies! A data related error occured on your client! If the issue persists past numerous rejoins, open a support ticket in our communications server.")
	end
end

--[[
@PayoutLoop
economy threadh andling passive income
straightforward
]]
function DataService:PayoutLoop()
	task.spawn(function()
		while true do
			task.wait(payInt)
			for player, session in pairs(self._Sessions) do
				local currentCash = session.Profile.Data.Cash
				session:UpdateStat("Cash", currentCash + payAmount)
				-- using my own notification system here
				Notification:SendNotification(
					player,
					"Royal Guard",
					"Paycheck received!" .. payAmount .. " have been allocated to your funds account.",
					10
				)
			end
		end
	end)
end


function DataService:KnitInit()
	-- cleanup on player leave
	Players.PlayerRemoving:Connect(function(player)
		local session = self._Sessions[player]
		if session then
			session.Profile:EndSession()
			session:Destroy() -- call to our OOP cleanup method
			self._Sessions[player] = nil
		end
	end)
end

function DataService:KnitStart()
	-- handles existing players
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function() self:OnPlayerAdded(player) end)
	end

	Players.PlayerAdded:Connect(function(p) self:OnPlayerAdded(p) end)
	-- initiates the payout loop
	self:PayoutLoop()
end

-- client methods
-- bridged
function DataService.Client:RequestEquip(player, category, itemData)
	-- pass through to server method with loading flag
	return self.Server:EquipItem(player, category, itemData, false)
end

function DataService.Client:GetPlayerStats(player)
	local session = self.Server._Sessions[player]
	return session and session.Profile.Data or nil
end

return DataService
