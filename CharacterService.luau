local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Knit = require(ReplicatedStorage.Packages.Knit)

local CharacterService = Knit.CreateService {
	Name = "CharacterService",
	Client = {},
	_PlayerState = {},
}

local ATTACHMENT_MAP = {
	["Hair"] = "HairAttachment",
	["Headgear"] = "HeadgearAttachment",
	["Bodygear"] = "VestAttachment",
	["Armband"] = "ArmbandAttachment"
}

local function AttachModel(character, model, name, targetName, offsetCFrame)
	if not model or not character then return end
	local existing = character:FindFirstChild(name)
	if existing then existing:Destroy() end

	local targetPart = character:FindFirstChild(targetName)
	if not targetPart then return end

	local clone = model:Clone()
	local root = clone.PrimaryPart or clone:FindFirstChildWhichIsA("BasePart")
	if not root then return end

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

	local modelRotationOnly = clone:GetPivot().Rotation
	clone:PivotTo(targetPart.CFrame * (offsetCFrame or CFrame.new()) * modelRotationOnly)

	local mainWeld = Instance.new("WeldConstraint")
	mainWeld.Part0 = root
	mainWeld.Part1 = targetPart
	mainWeld.Parent = root

	clone.Name = name
	clone.Parent = character
end

local function ClearDefaultAccessories(character)
	for _, child in ipairs(character:GetChildren()) do
		if child:IsA("Accessory") then
			child:Destroy()
		end
	end
end

function CharacterService:ForceBlocky(character)
	local humanoid = character:WaitForChild("Humanoid")
	if not character:IsDescendantOf(game) then
		character.AncestryChanged:Wait()
	end

	pcall(function()
		local description = humanoid:GetAppliedDescription()
		description.Head = 0
		description.LeftArm = 0
		description.RightArm = 0
		description.LeftLeg = 0
		description.RightLeg = 0
		description.Torso = 0
		humanoid:ApplyDescription(description)
	end)
end

function CharacterService:KnitInit()
	self.Index = require(ReplicatedStorage.Shared:WaitForChild("Index"))
	Players.PlayerRemoving:Connect(function(player)
		self._PlayerState[player.UserId] = nil
	end)
end

function CharacterService:KnitStart()
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAppearanceLoaded:Connect(function(character)
			self:ForceBlocky(character)
		end)
	end)
end

function CharacterService:EquipItem(player, category, itemData, retryCount)
	retryCount = retryCount or 0
	local character = player.Character
	if not character or not character:FindFirstChild("Humanoid") then return false end

	local requiredRank = itemData ~= "REMOVE" and (itemData.RankId or 0) or 0
	if player:GetRankInGroup(self.Index.BA) < requiredRank then return false end

	local success = pcall(function()
		if itemData == "REMOVE" then
			if category == "Shirt" then
				local s = character:FindFirstChildOfClass("Shirt")
				if s then s.ShirtTemplate = "" end
			elseif category == "Pants" then
				local p = character:FindFirstChildOfClass("Pants")
				if p then p.PantsTemplate = "" end
			else
				local folderName = ATTACHMENT_MAP[category]
				if folderName then
					local existing = character:FindFirstChild(folderName)
					if existing then 
						existing:Destroy() 
					end
				end
			end
		else
			if category == "Hair" or category == "Headgear" then
				ClearDefaultAccessories(character)
			end

			if category == "Shirt" then
				local shirt = character:FindFirstChildWhichIsA("Shirt") or Instance.new("Shirt", character)
				shirt.ShirtTemplate = "rbxassetid://" .. (itemData.ShirtId or itemData.Id)
			elseif category == "Pants" then
				local pants = character:FindFirstChildWhichIsA("Pants") or Instance.new("Pants", character)
				pants.PantsTemplate = "rbxassetid://" .. (itemData.PantsId or itemData.Id)
			elseif ATTACHMENT_MAP[category] then
				local targetPartName = (category == "Bodygear" and "UpperTorso") or (category == "Armband" and "RightUpperArm") or "Head"
				local offset = (category == "Bodygear" or category == "Armband") and CFrame.new(0, -0.2, 0) or CFrame.new(0, 0, 0)
				AttachModel(character, itemData.Item, ATTACHMENT_MAP[category], targetPartName, offset)
			end
		end
	end)

	if not success then
		if retryCount < 3 then
			task.wait(1)
			return self:EquipItem(player, category, itemData, retryCount + 1)
		end
		return false
	end

	if not self._PlayerState[player.UserId] then self._PlayerState[player.UserId] = {} end
	self._PlayerState[player.UserId][category] = itemData

	return true
end

function CharacterService.Client:RequestEquip(player, category, itemData)
	return self.Server:EquipItem(player, category, itemData)
end

return CharacterService