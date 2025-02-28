if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then return end

--[[ 
This file keeps track of a character's Void Storage (Retail + Wrath only)
--]]

local addonName, addon = ...
local thisCharacter

local DataStore = DataStore
local GetVoidItemInfo = GetVoidItemInfo
local bit64 = LibStub("LibBit64")

local TAB_SIZE = 80

-- *** Scanning functions ***
local function ScanTab(tabID)
	-- Get the database
	thisCharacter[tabID] = thisCharacter[tabID] or {}
	thisCharacter[tabID].items = thisCharacter[tabID].items or {}
	local tab = thisCharacter[tabID]
	
	-- Get the content
	for slotID = 1, TAB_SIZE do
		local itemID = GetVoidItemInfo(tabID, slotID)
		
		if itemID then
			tab.items[slotID] = 1 + bit64:LeftShift(itemID, 10)		-- bits 10+ : item ID
		else
			tab.items[slotID] = nil
		end
	end	
end

local function ScanVoidStorage()
	ScanTab(1)
	ScanTab(2)
	AddonFactory:Broadcast("DATASTORE_VOIDSTORAGE_UPDATED")
end

-- *** Event Handlers ***
local function OnVoidStorageTransferDone()
	ScanVoidStorage()
end

-- ** Mixins **
local function _GetVoidStorageItemCount(character, searchedID)
	local count = 0
	
	for tabID = 1, 2 do
		local tab = character[tabID]
		
		if tab and tab.items then
			for slotID, slot in pairs(tab.items) do
				-- is it the item we are searching for ?
				if searchedID == bit64:RightShift(slot, 10) then	-- bits 10+ : item ID
					count = count + bit64:GetBits(slot, 0, 10)		-- bits 0-9 : item count (10 bits, up to 1024)
				end
			end
		end
	end

	return count
end

local function _IterateVoidStorage(character, callback)
	local itemID
	
	for tabID = 1, 2 do
		local tab = character[tabID]
		
		if tab then
			for slotID = 1, TAB_SIZE do
				itemID = character[tabID][slotID]
				
				-- Callback only if there is an item in that slot
				if itemID then
					callback(itemID)
				end
			end
		end
	end
end

AddonFactory:OnAddonLoaded(addonName, function() 
	DataStore:RegisterTables({
		addon = addon,
		characterTables = {
			["DataStore_Containers_VoidStorage"] = {
				GetVoidStorageTab = function(character, tabID) return character[tabID] end,
				GetVoidStorageItemCount = _GetVoidStorageItemCount,
				IterateVoidStorage = _IterateVoidStorage,
			},
		}
	})
	
	thisCharacter = DataStore:GetCharacterDB("DataStore_Containers_VoidStorage", true)
end)

AddonFactory:OnPlayerLogin(function()
	addon:ListenTo("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(event, interactionType)
		-- only process void storage events
		if interactionType ~= Enum.PlayerInteractionType.VoidStorageBanker then return end
		
		ScanVoidStorage()
		addon:ListenTo("VOID_STORAGE_UPDATE", ScanVoidStorage)
		addon:ListenTo("VOID_STORAGE_CONTENTS_UPDATE", ScanVoidStorage)
		addon:ListenTo("VOID_TRANSFER_DONE", OnVoidStorageTransferDone)
	end)
	
	addon:ListenTo("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(event, interactionType)
		-- only process void storage events
		if interactionType ~= Enum.PlayerInteractionType.VoidStorageBanker then return end

		addon:StopListeningTo("VOID_STORAGE_UPDATE")
		addon:StopListeningTo("VOID_STORAGE_CONTENTS_UPDATE")
		addon:StopListeningTo("VOID_TRANSFER_DONE")
	end)
end)
