if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then return end

--[[ 
This file keeps track of an account's warband bank (Retail only).
--]]

local addonName, addon = ...
local thisCharacter
local warbank

local DataStore, tonumber, wipe, time, C_Container, C_Bank = DataStore, tonumber, wipe, time, C_Container, C_Bank

local bit64 = LibStub("LibBit64")

local function GetBankTab(tabID)
	-- Create the tab
	warbank[tabID] = warbank[tabID] or {}
	local tab = warbank[tabID]
	tab.items = tab.items or {}
	tab.links = tab.links or {}

	return warbank[tabID]
end

-- *** Scanning functions ***
local TAB_SIZE = 98

local function ScanAccountBankTab(tabID)
	local tab = GetBankTab(tabID)
	if not tab then return end

	local link, itemID
	local isWipeDone = false

	for slotID = 1, TAB_SIZE do
		link = C_Container.GetContainerItemLink(tabID, slotID)
		
		if link then
			
			-- Wiping the tab has to be delayed until we get actual data, because the BAG_UPDATE event will be triggered
			-- when using portals, etc.. and nil data will be returned, so we have to guard against it.
			if not isWipeDone then
				wipe(tab.items)				-- clean existing tab data
				wipe(tab.links)
				isWipeDone = true
			end
		
			itemID = tonumber(link:match("item:(%d+)"))

			if link:match("|Hkeystone:") then
				-- mythic keystones are actually all using the same item id
				-- https://wowpedia.fandom.com/wiki/KeystoneString
				itemID = 138019

			elseif link:match("|Hbattlepet:") then
				-- special treatment for battle pets, save texture id instead of item id..
				local info = C_Container.GetContainerItemInfo(tabID, slotID)
				itemID = info.iconFileID
			end
			
			tab.links[slotID] = link
			
			-- bits 0-15 : item count (16 bits, up to 65535)
			tab.items[slotID] = C_Container.GetContainerItemInfo(tabID, slotID).stackCount
				+ bit64:LeftShift(itemID, 16)		-- bits 16+ : item ID
		end
	end

	AddonFactory:Broadcast("DATASTORE_CONTAINER_UPDATED", bagID, 1)		-- 1 = container type: Bag
end

local function ScanAccountBankTabSettings(tabID, settings)
	local tab = GetBankTab(tabID)
	if tab then
		tab.name = settings.name
		tab.icon = settings.icon
	end
end

local function ScanAccountBank()
	local settings = C_Bank.FetchPurchasedBankTabData(Enum.BankType.Account)

	for index, tabID in pairs(C_Bank.FetchPurchasedBankTabIDs(Enum.BankType.Account)) do
		ScanAccountBankTab(tabID)
		ScanAccountBankTabSettings(tabID, settings[index])
	end
end


-- *** Event Handlers ***
local function OnBagUpdate(event, bag)
	if bag >= Enum.BagIndex.AccountBankTab_1 and bag <= Enum.BagIndex.AccountBankTab_5 then
		ScanAccountBankTab(bag)
	end
end

local function OnAccountBankTabsChanged(event, tabID)
	-- tabID = 1 to 5 (from top to bottom in the UI)

end

local function OnBankTabSettingsUpdated(event, tabID)
	ScanAccountBank()
end

-- ** Mixins **
local function _GetAccountBankTabName(tabID)
	return warbank[tabID] and warbank[tabID].name or ""
end

local function _GetAccountBankTabItemCount(tabID, searchedID)
	local count = 0
	local container = warbank[tabID]
	
	if container then
	   for slotID, slot in pairs(container.items) do
			local pos = DataStore:GetItemCountPosition(slot)
			
			-- is it the item we are searching for ?
			if searchedID == bit64:RightShift(slot, pos) then	-- bits 10+ : item ID
				count = count + bit64:GetBits(slot, 0, pos)		-- bits 0-9 : item count (10 bits, up to 1024)
			end
	   end
	end
	
	return count
end


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

local function _IterateWarbandBank(callback)
	for tabID, tab in pairs(warbank) do
		for slotID = 1, TAB_SIZE do
			local itemID, itemLink, itemCount, isBattlePet = _GetSlotInfo(tab, slotID)
			
			-- Callback only if there is an item in that slot
			if itemID then
				callback(itemID, itemLink, itemCount, isBattlePet)
			end
		end
	end
end


AddonFactory:OnAddonLoaded(addonName, function() 
	DataStore:RegisterTables({
		addon = addon,
		rawTables = {
			"DataStore_Containers_Warbank"
		},
	})
	
	warbank = DataStore_Containers_Warbank
	
	DataStore:RegisterMethod(addon, "GetAccountBankTabName", _GetAccountBankTabName)
	DataStore:RegisterMethod(addon, "GetAccountBankTabItemCount", _GetAccountBankTabItemCount)
	DataStore:RegisterMethod(addon, "IterateWarbandBank", _IterateWarbandBank)
	
end)

AddonFactory:OnPlayerLogin(function()
	C_Timer.After(3, function()
		-- To avoid the long list of BAG_UPDATE at startup, only register the event 3 seconds later ..
		addon:ListenTo("BAG_UPDATE", OnBagUpdate)
	end)
	
	addon:ListenTo("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(event, interactionType)
		-- .Banker when interacting with a banker in a capital
		-- .AccountBanker when interacting with the remote portal
		
		if interactionType == Enum.PlayerInteractionType.Banker or interactionType == Enum.PlayerInteractionType.AccountBanker then 
			ScanAccountBank()
		end
	end)
	
	-- The event is triggered when purchasing a new tab, not sure yet if we need it.
	addon:ListenTo("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", OnAccountBankTabsChanged)
	addon:ListenTo("BANK_TAB_SETTINGS_UPDATED", OnBankTabSettingsUpdated)
	
end)
