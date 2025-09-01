--[[ 
This file keeps track of a character's bank (only the main slots, bank bags are in the main file)
--]]

local addonName, addon = ...
local thisCharacter
local thisCharacterCooldowns

local DataStore, tonumber, wipe, time, C_Container, C_Bank = DataStore, tonumber, wipe, time, C_Container, C_Bank
local isRetail = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
local interfaceVersion = select(4, GetBuildInfo())
local isConsolidatedBank = (interfaceVersion >= 110200)		-- using the new 11.2 bank ?

local enum = DataStore.Enum.ContainerIDs
local bit64 = LibStub("LibBit64")

local NUM_MAIN_SLOTS = 28
local TAB_SIZE = 98
local BANK_TAG = "Bank"

local function GetBankTab(tabID)
	-- Create the tab
	thisCharacter[tabID] = thisCharacter[tabID] or {}

	return thisCharacter[tabID]
end

local function GetRemainingCooldown(start)
   local uptime = GetTime()
   
   if start <= uptime + 1 then
      return start - uptime
   end
   
   return -uptime - ((2 ^ 32) / 1000 - start)
end

-- *** Scanning functions ***
local function ScanMainSlots()
	local bag = thisCharacter
	
	wipe(bag.items)
	wipe(bag.links)
	
	local link, itemID
	local startTime, duration, isEnabled

	bag.freeslots = C_Container.GetContainerNumFreeSlots(enum.MainBankSlots)
	
	for slotID = 1, NUM_MAIN_SLOTS do
		link = C_Container.GetContainerItemLink(enum.MainBankSlots, slotID)
		
		if link then
			itemID = tonumber(link:match("item:(%d+)"))

			if link:match("|Hkeystone:") then
				-- mythic keystones are actually all using the same item id
				-- https://wowpedia.fandom.com/wiki/KeystoneString
				itemID = 138019

			elseif link:match("|Hbattlepet:") then
				local info = C_Container.GetContainerItemInfo(enum.MainBankSlots, slotID)
				itemID = info.iconFileID
			end
			
			bag.links[slotID] = link
			
			-- bits 0-15 : item count (16 bits, up to 65535)
			bag.items[slotID] = C_Container.GetContainerItemInfo(enum.MainBankSlots, slotID).stackCount
				+ bit64:LeftShift(itemID, 16)		-- bits 16+ : item ID
		end
		

		startTime, duration, isEnabled = C_Container.GetContainerItemCooldown(enum.MainBankSlots, slotID)
		
		if startTime and startTime > 0 then
			if not isRetail then
				startTime = time() + GetRemainingCooldown(startTime)
			end
		
			-- (bagID * 1000) + slotID => (-1 * 1000) + slotID
			thisCharacterCooldowns[-1000 + slotID] = { startTime = startTime, duration = duration }
		else
			thisCharacterCooldowns[-1000 + slotID] = nil
		end
		
	end

	AddonFactory:Broadcast("DATASTORE_CONTAINER_UPDATED", bagID, 2)		-- 2 = container type: Player Bank
end

local function ScanPlayerBankTabSettings(tabID, settings)
	local tab = GetBankTab(tabID)
	if tab and settings then
		tab.name = settings.name
		tab.icon = settings.icon
	end
end

local function ScanTabsInfo()
	-- Only for new bank tabs since 11.2
	local settings = C_Bank.FetchPurchasedBankTabData(Enum.BankType.Character)
	
	for index, tabID in pairs(C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Character)) do
		ScanPlayerBankTabSettings(tabID, settings[index])
	end
	
	thisCharacter.visited = true
end

-- *** Event Handlers ***
local function OnBankFrameClosed()
	addon:StopListeningTo("BANKFRAME_CLOSED", BANK_TAG)
	addon:StopListeningTo("PLAYERBANKSLOTS_CHANGED", BANK_TAG)
end

local function OnPlayerBankSlotsChanged(event, slotID)
	if slotID <= NUM_MAIN_SLOTS then
		ScanMainSlots()
	end
end

local function OnBankFrameOpened()
	if isConsolidatedBank then
		ScanTabsInfo()
	else
		ScanMainSlots()
		
		addon:ListenTo("PLAYERBANKSLOTS_CHANGED", OnPlayerBankSlotsChanged, BANK_TAG)
	end

	addon:ListenTo("BANKFRAME_CLOSED", OnBankFrameClosed, BANK_TAG)
end

-- ** Mixins **

local function _GetSlotInfo(bag, slotID)
	-- This function is repeated in the main file, here, and in Guild bank.. find some time to clean this.
	if not bag then return end

	-- local link = bag.links[slotID]
	local link = bag.links and bag.links[slotID]
	local isBattlePet
	
	if link then
		isBattlePet = link:match("|Hbattlepet:")
	end
	
	-- local slot = bag.items[slotID]
	local slot = bag.items and bag.items[slotID]
	local itemID, count
	
	if slot then
		local pos = DataStore:GetItemCountPosition(slot)
	
		count = bit64:GetBits(slot, 0, pos)		-- bits 0-9 : item count (10 bits, up to 1024)
		itemID = bit64:RightShift(slot, pos)		-- bits 10+ : item ID
	end

	return itemID, link, count, isBattlePet
end

local function _IteratePlayerBankSlots(character, callback)
	for slotID = 1, NUM_MAIN_SLOTS do
		local itemID, itemLink, itemCount, isBattlePet = _GetSlotInfo(character, slotID)
		
		-- Callback only if there is an item in that slot
		if itemID then
			callback(itemID, itemLink, itemCount, isBattlePet)
		end
	end
end

local function _HasPlayerVisitedBank_Retail(character)
	return character.visited
end

local function _HasPlayerVisitedBank_NonRetail(character)
	return (type(character.freeslots) ~= "nil")
end

local function _GetPlayerBankTabName(character, tabID)
	local tab = character[tabID]

	return tab and tab.name or ""
end

local function _GetPlayerBankTabIcon(character, tabID)
	local tab = character[tabID]
	
	return tab and tab.icon
end

local function _GetPlayerBankItemCount_Retail(character, searchedID)
	return DataStore:GetItemCountByID(DataStore:GetPlayerBank(character), searchedID)
end

local function _GetPlayerBankItemCount_NonRetail(character, searchedID)
	return DataStore:GetItemCountByID(character, searchedID)
end


AddonFactory:OnAddonLoaded(addonName, function() 
	DataStore:RegisterTables({
		addon = addon,
		characterTables = {
			["DataStore_Containers_Banks"] = {
				GetPlayerBank = function(character) return character end,
				GetPlayerBankItemCount = isRetail and _GetPlayerBankItemCount_Retail or _GetPlayerBankItemCount_NonRetail,
				
				GetPlayerBankInfo = function(character) return NUM_MAIN_SLOTS, character.freeslots end,
				GetPlayerBankTabName = isConsolidatedBank and _GetPlayerBankTabName,
				GetPlayerBankTabIcon = isConsolidatedBank and _GetPlayerBankTabIcon,
				HasPlayerVisitedBank = isConsolidatedBank and _HasPlayerVisitedBank_Retail or _HasPlayerVisitedBank_NonRetail,
				IteratePlayerBankSlots = _IteratePlayerBankSlots,
			},
		},
	})
	
	thisCharacter = DataStore:GetCharacterDB("DataStore_Containers_Banks", true)
	
	-- 11.2 : Clear the reagent bank table for everyone
	if isConsolidatedBank then
		-- Remove the old main bank slots info
		thisCharacter.items = nil
		thisCharacter.links = nil
		thisCharacter.freeslots = nil
	else
		thisCharacter.items = thisCharacter.items or {}
		thisCharacter.links = thisCharacter.links or {}
	end

	local db = DataStore:GetCharacterDB("DataStore_Containers_Characters")
	thisCharacterCooldowns = db.Cooldowns
end)

AddonFactory:OnPlayerLogin(function()
	addon:ListenTo("BANKFRAME_OPENED", OnBankFrameOpened, BANK_TAG)
end)
