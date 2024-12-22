if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then return end

--[[ 
This file keeps track of a character's reagent bank (Retail + Wrath only)
--]]

local addonName, addon = ...
local thisCharacter
local thisCharacterCooldowns

local DataStore, tonumber, wipe, time, C_Container = DataStore, tonumber, wipe, time, C_Container
local isRetail = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)

local bit64 = LibStub("LibBit64")
local REAGENT_BANK = Enum.BagIndex.Reagentbank

local function GetRemainingCooldown(start)
   local uptime = GetTime()
   
   if start <= uptime + 1 then
      return start - uptime
   end
   
   return -uptime - ((2 ^ 32) / 1000 - start)
end

-- *** Scanning functions ***
local TAB_SIZE = 98

local function ScanReagentBankSlot(storage, slotID)
	local info = C_Container.GetContainerItemInfo(REAGENT_BANK, slotID)
	if not info then return end
	
	storage.items[slotID] = info.stackCount
	-- bits 0-15 : item count (16 bits, up to 65535)
	storage.items[slotID] = info.stackCount
		+ bit64:LeftShift(info.itemID, 16)		-- bits 16+ : item ID	

	-- Set the link (possibly nil)
	storage.links[slotID] = C_Container.GetContainerItemLink(REAGENT_BANK, slotID)
end

local function ScanReagentBankSlotCooldown(slotID)
	local startTime, duration, isEnabled = C_Container.GetContainerItemCooldown(REAGENT_BANK, slotID)
	
	if startTime and startTime > 0 then
		if not isRetail then
			startTime = time() + GetRemainingCooldown(startTime)
		end
		
		-- (bagID * 1000) + slotID => (-3 * 1000) + slotID
		thisCharacterCooldowns[-3000 + slotID] = { startTime = startTime, duration = duration }
	else
		thisCharacterCooldowns[-3000 + slotID] = nil
	end
end

local function ScanReagentBank()
	local bagID = REAGENT_BANK
	if not bagID then return end
	
	local bag = thisCharacter
	wipe(bag.items)
	wipe(bag.links)
	
	local startTime, duration, isEnabled

	bag.freeslots = C_Container.GetContainerNumFreeSlots(bagID)
	
	for slotID = 1, TAB_SIZE do
		ScanReagentBankSlot(bag, slotID)
		ScanReagentBankSlotCooldown(slotID)
	end
	
	DataStore:Broadcast("DATASTORE_CONTAINER_UPDATED", bagID, 1)		-- 1 = container type: Bag
end

-- *** Event Handlers ***
local function OnPlayerReagentBankSlotsChanged(event, slotID)
	-- This event does not work in a consistent way.
	-- When triggered after crafting an item that uses reagents from the reagent bank, it is possible to properly read the container info.
	-- When triggered after validating a quest that uses reagents from the reagent bank, then C_Container.GetContainerItemInfo returns nil

	ScanReagentBankSlot(thisCharacter, slotID)
end


AddonFactory:OnAddonLoaded(addonName, function() 
	DataStore:RegisterTables({
		addon = addon,
		characterTables = {
			["DataStore_Containers_Reagents"] = {
				GetReagentBank = function(character) return character end,
				GetReagentBankItemCount = function(character, searchedID) return DataStore:GetItemCountByID(character, searchedID) end,
			},
		},
	})
	
	thisCharacter = DataStore:GetCharacterDB("DataStore_Containers_Reagents", true)
	thisCharacter.items = thisCharacter.items or {}
	thisCharacter.links = thisCharacter.links or {}

	local db = DataStore:GetCharacterDB("DataStore_Containers_Characters")
	thisCharacterCooldowns = db.Cooldowns
end)

AddonFactory:OnPlayerLogin(function()
	-- Retail + Wrath
	addon:ListenTo("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(event, interactionType)
		if interactionType == Enum.PlayerInteractionType.Banker then 
			ScanReagentBank()
		end
	end)
	
	-- Retail only
	addon:ListenTo("PLAYERREAGENTBANKSLOTS_CHANGED", OnPlayerReagentBankSlotsChanged)
	
end)
