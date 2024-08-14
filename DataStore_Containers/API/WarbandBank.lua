if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then return end

--[[ 
This file keeps track of an account's warband bank (Retail only).
--]]

local addonName, addon = ...
local thisCharacter
local warbank

local DataStore, tonumber, wipe, time, C_Container = DataStore, tonumber, wipe, time, C_Container

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

	wipe(tab.items)				-- clean existing tab data
	wipe(tab.links)
	
	local link, itemID

	for slotID = 1, TAB_SIZE do
		link = C_Container.GetContainerItemLink(tabID, slotID)
		
		if link then
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

	DataStore:Broadcast("DATASTORE_CONTAINER_UPDATED", bagID, 1)		-- 1 = container type: Bag
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


DataStore:OnAddonLoaded(addonName, function() 
	DataStore:RegisterTables({
		addon = addon,
		rawTables = {
			"DataStore_Containers_Warbank"
		},
	})
	
	warbank = DataStore_Containers_Warbank
	
	DataStore:RegisterMethod(addon, "GetAccountBankTabName", _GetAccountBankTabName)
	DataStore:RegisterMethod(addon, "GetAccountBankTabItemCount", _GetAccountBankTabItemCount)
	
end)

DataStore:OnPlayerLogin(function()
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
