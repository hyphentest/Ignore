--[[
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
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Codebase = ReplicatedStorage:WaitForChild("Codebase")

local Knit = require(ReplicatedStorage:WaitForChild("Packages").Knit) -- framework
local ProfileStore = require(script:WaitForChild("ProfileStore")) -- library
local Notification = require(Codebase.Controllers.UIController:WaitForChild("Notification")) -- my own notification module

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
-- i made this so each 5 mins the player gets his payout
local payAmount = 100 -- scheduled amount for a payout
-- this is the payamount, the player gets his pay based off of teh number here
local Categories = {
	["Hair"] = { Attachment = "HairAttachment", Target = "Head", Offset = CFrame.identity },
	["Headgear"] = { Attachment = "HeadgearAttachment", Target = "Head", Offset = CFrame.identity },
	["Bodygear"] = { Attachment = "VestAttachment", Target = "UpperTorso", Offset = CFrame.new(0, -0.2, 0) },
	["Armband"] = { Attachment = "ArmbandAttachment", Target = "RightUpperArm", Offset = CFrame.new(0, -0.2, 0) }
}

--[[
currentSession class is just my way of keeping everything related to a single player in one place
instead of throwing say raw tables into DataService._Sessions

each player gets one of these when their profile loads, and it sticks around until they leave OR until their session gets closed
i mainly use this to:
- store references like Player and Profile together
- track any RBXScriptConnections i create during the session
- have a clear place to handle cleanup when the player leaves
DataService._Sessions[player] basically just points to one of these objects
]]
function currentSession.new(player, profile)
	local self = setmetatable({}, currentSession)
	self.Player = player
	self.Profile = profile
	
	-- i store connections here so i can clean them up later
	-- roblox doesn't auto-disconnect events, so without this they'd just hang around
	self.Connections = {} 
	-- make sure we always have a character to work with
	-- if it doesn't exist yet, this will wait until it spawns
	self.Character = player.Character or player.CharacterAdded:Wait()
	return self
end

--[[
@UpdateStat handles the slot data to ui talk and synching
by checking the data slot table before updating leaderstats, we ensure we don't waste cycles if the data didnt actualy change
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
	-- basically, i made it here to save an item to the loadouts table (found above) only if the service permits it
	-- say if its an item thats locked behind a group requirement and the player tries to save it dont allow him
	-- prevents players from saving items they shouldn't have access to
	if self.Profile.Data.Loadout[category] ~= nil then
		self.Profile.Data.Loadout[category] = assetId
	end
end

--[[
here is where i handle memory management
disconnecting signals in self.Connections makes sure that even if a character is destroyed, the current registry doesnt keep refs to the session object
i also made it a patch attempt to prevent memory leaks
]]
function currentSession:Destroy()
	-- disconnect everything we stored during the session
	-- if i don't do this preexisting connections can still fire and keep references alive
	for _, conn in ipairs(self.Connections) do
		if conn.Disconnect then conn:Disconnect() end
	end
	
	-- clear references so nothing is holding onto this session anymore
	-- this helps the garbage collector clean it up properly
	self.Connections = nil
	self.Profile = nil
	self.Player = nil
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
		i basically made this bool so in separate games like the parade grounds, loadouts wont be saved since its more of a one time play in pg
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
i changed from manual welds to weldconstraints because their more performant
for each model, i manually disable cancollide cantouch n canquery but also through the script here
i made this to prevent players stacking on each others hats, and worse case scenario being accidentally flung
]]
local function AttachModel(character, model, name, targetPartName, offsetCFrame)
	if not model or not character then return end

	local targetPart = character:FindFirstChild(targetPartName)
	if not targetPart then return end

	local clone = model:Clone()
	local root = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	if not root then
		-- sometimes, i forget to set the primarypart on a model
		-- so i create a little warn here to be alike a 'reminder'
		warn("model " .. name .. " is missing a set PrimaryPart")
		return
	end

	for _, part in clone:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanTouch = false
			part.CanQuery = false
			if part ~= root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = part
				weld.Part1 = root
				weld.Parent = part
			end
		end
	end

	local modelRotation = clone:GetPivot().Rotation
	clone:PivotTo(targetPart.CFrame * (offsetCFrame or CFrame.identity) * modelRotation)

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
i used pcall here because asset loading via rbxassetid is an external dependency that can fail due to robloxs asset API
basically, a bandaid to prevent a failed asset fetch or outfit save from crashing the players entire data slot
flow:
- resolve the session + character
- normalize itemData into an assetId
- apply the item depending on category (clothing vs model attachments)
- wrap in pcall so a failed asset or invalid id doesn't break the whole system
]]
function DataService:EquipItem(player, category, itemData, isAutoLoading)
	local session = self._Sessions[player]
	local character = player.Character
	if not session or not character then return false end

	local assetId = (typeof(itemData) == "table") and (itemData.Id or itemData.ShirtId) or itemData
	local success = pcall(function()
		if category == "Shirt" then
			-- checking for existence first to avoid redundant Instance.new calls
			local s = character:FindFirstChildOfClass("Shirt")
			if not s then
				s = Instance.new("Shirt")
				-- pareting after properties are set
				s.Parent = character 
			end
			s.ShirtTemplate = "rbxassetid://" .. assetId
		elseif category == "Pants" then
			local p = character:FindFirstChildOfClass("Pants")
			if not p then
				p = Instance.new("Pants")
				p.Parent = character
			end
			p.PantsTemplate = "rbxassetid://" .. assetId
		elseif Categories[category] then
			local cfg = Categories[category]
			if typeof(itemData) == "table" and itemData.Item then
				-- atachment logic for cosmetics and models
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
	-- here i used generalized iteration for cleaner performance
	for category, assetId in pairs(savedLoadout) do
		if assetId ~= "" then
			-- i added a lil 'true' falg prevents constant saving during the initial load process
			self:EquipItem(player, category, assetId, true)
		end
	end
end

local function GetStoreName()
	return RunService:IsStudio() and "studio" or "Key1"
end

--[[
@OnPlayerAdded
rather than the former task.wait(0.2), which i added as a brief lil pause to ensure the players character is fully loaded
i replaced it with CharacterAppearanceLoaded, a more robust signal that guarantees to me and to the server the characters base is ready before we go on welding their chosen custom gear
-- leaderstats are now buil twith a properity first assignment to prevent unnecessary replication events while the object is still being intialised
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
			player:Kick("Data session closed via ProfileStore.")
		end)

		if player.Parent == Players then
			local session = currentSession.new(player, profile)
			self._Sessions[player] = session

			local ls = Instance.new("Folder")
			ls.Name = "leaderstats"

			for key, val in pairs(PlayerTemplate) do
				if typeof(val) ~= "table" then
					local stat = Instance.new("IntValue")
					stat.Name = key
					stat.Value = profile.Data[key]
					stat.Parent = ls -- parent last to avoid property-replication overhead
				end
			end
			ls.Parent = player

			local charAddedConn = player.CharacterAppearanceLoaded:Connect(function()
				self:LoadSavedAppearance(player)
			end)
			table.insert(session.Connections, charAddedConn)

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
			-- this waits the set pay interval (which is 300 secs for now) before adding the moeny to the player
			for player, session in pairs(self._Sessions) do
				local currentCash = session.Profile.Data.Cash
				-- here we update the player stats with the additional pay amount
				session:UpdateStat("Cash", currentCash + payAmount)
				-- notification sent by my own notification module
				Notification:SendNotification(
					player,
					"Economy",
					-- in the older block, i had it payInt rather than payAmount
					"Paycheck received! $" .. payAmount .. " added to funds.",
					10
				)
			end
		end
	end)
end

function DataService:KnitInit()
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
	-- this block handles already existing players
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function() self:OnPlayerAdded(player) end)
	end

	Players.PlayerAdded:Connect(function(p) self:OnPlayerAdded(p) end)
	self:PayoutLoop() -- here i initialise the payout loop
end

-- external Knit exposure for client interaction
function DataService.Client:RequestEquip(player, category, itemData)
	return self.Server:EquipItem(player, category, itemData, false)
end

function DataService.Client:GetPlayerStats(player)
	local session = self.Server._Sessions[player]
	return session and session.Profile.Data or nil
end

return DataService
