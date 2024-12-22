if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then return end

--[[ 
This file keeps track of a character's keystones
--]]

local addonName, addon = ...
local thisCharacter

local DataStore = DataStore
local C_MythicPlus, C_ChallengeMode = C_MythicPlus, C_ChallengeMode

local EVENT_TAG = "Keys"

-- *** Scanning functions ***
local function ScanKeystoneInfo()
	local char = thisCharacter
	wipe(char)
	
   local mapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
	if not mapID then return end
	
	local keyName, _, _, texture = C_ChallengeMode.GetMapUIInfo(mapID)
	char.name = keyName
	char.texture = texture
	
	char.level = C_MythicPlus.GetOwnedKeystoneLevel()
	char.lastUpdate = time()
end

-- *** Event Handlers ***
local function OnBagUpdate(event, bag)
	-- bag id >= 13 are the warband bank, don't react on those.
	if bag < 13 then
		ScanKeystoneInfo()
	end
end

local function OnAuctionHouseClosed()
	addon:StopListeningTo("AUCTION_HOUSE_CLOSED")
	addon:ListenTo("BAG_UPDATE", OnBagUpdate, EVENT_TAG)		-- resume listening
end

local function OnAuctionHouseShow()
	addon:StopListeningTo("BAG_UPDATE", EVENT_TAG)						-- do not listen to bag updates at the AH
	addon:ListenTo("AUCTION_HOUSE_CLOSED", OnAuctionHouseClosed)
end


AddonFactory:OnAddonLoaded(addonName, function() 
	DataStore:RegisterTables({
		addon = addon,
		characterTables = {
			["DataStore_Containers_Keystones"] = {
				GetKeystoneName = function(character) return character.name or "" end,
				GetKeystoneLevel = function(character) return character.level or 0 end,
			},
		}
	})
	
	thisCharacter = DataStore:GetCharacterDB("DataStore_Containers_Keystones", true)
end)

AddonFactory:OnPlayerLogin(function()
	addon:ListenTo("PLAYER_ALIVE", ScanKeystoneInfo)
	addon:ListenTo("WEEKLY_REWARDS_UPDATE", ScanKeystoneInfo)
	addon:ListenTo("BAG_UPDATE", OnBagUpdate, EVENT_TAG)	-- Give a tag to ensure uniqueness when removing
	
	-- disable bag updates during multi sell at the AH
	addon:ListenTo("AUCTION_HOUSE_SHOW", OnAuctionHouseShow)
end)
