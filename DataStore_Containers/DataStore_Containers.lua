--[[	*** DataStore_Containers ***
Written by : Thaoky, EU-Marécages de Zangar
June 21st, 2009

This modules takes care of scanning & storing player bags, bank, & guild banks

Extended services: 
	- guild communication: at logon, sends guild bank tab info (last visit) to guildmates
	- triggers events to manage transfers of guild bank tabs
--]]
if not DataStore then return end

local addonName, addon = ...
local thisCharacter
local thisCharacterBank

local DataStore, tonumber, wipe, type, time, C_Container = DataStore, tonumber, wipe, type, time, C_Container
local GetTime, GetInventoryItemTexture, GetInventoryItemLink, GetItemInfo = GetTime, GetInventoryItemTexture, GetInventoryItemLink, GetItemInfo
local log = math.log
local isRetail = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)

local enum = DataStore.Enum.ContainerIDs
local bit64 = LibStub("LibBit64")

-- Constants usable for all versions
local COMMON_NUM_BAG_SLOTS = isRetail and NUM_BAG_SLOTS + 1 or NUM_BAG_SLOTS
local MIN_BANK_SLOT = isRetail and 6 or 5		-- Bags 6 - 12 are Bank as of 10.0
local MAX_BANK_SLOT = isRetail and 12 or 11
local MIN_WARBANK_TAB = 13


-- *** Utility functions ***
local function GetRemainingCooldown(start)
   local uptime = GetTime()
   
   if start <= uptime + 1 then
      return start - uptime
   end
   
   return -uptime - ((2 ^ 32) / 1000 - start)
end

local function GetContainer(bagID)
	local char = thisCharacter
	local bag = char.Containers[bagID]
	
	-- if the bag does not exist yet, create it
	if not bag then
		char.Containers[bagID] = {}
		bag = char.Containers[bagID]
		
		bag.links = {}
		bag.items = {}
	end
	
	return bag
end

local function GetCooldownIndex(bagID, slotID)
	return (bagID * 1000) + slotID
end

local function Log2(n)
	-- which power of 2 is this number ? ex: 1024 is 2 ^ 10 => return 10
   return log(n) / log(2)
end

-- *** Scanning functions ***
local function ScanContainer(bagID, bagSize)
	local bag = GetContainer(bagID)

	wipe(bag.items)
	wipe(bag.links)

	local link, itemID
	local startTime, duration, isEnabled
	
	for slotID = 1, bagSize do
		link = C_Container.GetContainerItemLink(bagID, slotID)
		
		if link then
			itemID = tonumber(link:match("item:(%d+)"))

			if link:match("|Hkeystone:") then
				-- mythic keystones are actually all using the same item id
				-- https://wowpedia.fandom.com/wiki/KeystoneString
				itemID = 138019

			elseif link:match("|Hbattlepet:") then
				-- special treatment for battle pets, save texture id instead of item id..
				-- texture, itemCount, locked, quality, readable, _, _, isFiltered, noValue, itemID = GetContainerItemInfo(id, itemButton:GetID());
				
				local info = C_Container.GetContainerItemInfo(bagID, slotID)
				itemID = info.iconFileID
			end
			
			bag.links[slotID] = link
		
			-- bits 0-15 : item count (16 bits, up to 65535)
			bag.items[slotID] = C_Container.GetContainerItemInfo(bagID, slotID).stackCount
				+ bit64:LeftShift(itemID, 16)		-- bits 16+ : item ID
		end
		
		startTime, duration, isEnabled = C_Container.GetContainerItemCooldown(bagID, slotID)
		
		if startTime and startTime > 0 then
			if not isRetail then
				startTime = time() + GetRemainingCooldown(startTime)
			end

			thisCharacter.Cooldowns[GetCooldownIndex(bagID, slotID)] = { startTime = startTime, duration = duration }
		else
			thisCharacter.Cooldowns[GetCooldownIndex(bagID, slotID)] = nil
		end
	end
	
	thisCharacter.lastUpdate = time()
	DataStore:Broadcast("DATASTORE_CONTAINER_UPDATED", bagID, containerType)
end

local function ScanBagSlotsInfo()
	local char = thisCharacter

	local numSlots = 0
	local freeSlots = 0

	for bagID = 0, COMMON_NUM_BAG_SLOTS, 1 do -- 5 Slots to include Reagent Bag
		local bag = GetContainer(bagID)
		local info = bag.info or 0
		
		numSlots = numSlots + bit64:GetBits(info, 3, 6)		-- bits 3-8 : bag size
		freeSlots = freeSlots + bit64:GetBits(info, 9, 6)		-- bits 9-14 : number of free slots in this bag
	end
	
	char.bagInfo = numSlots								-- bits 0-9 : num bag slots
				+ bit64:LeftShift(freeSlots, 10)		-- bits 10+ : num free slots
end

local function ScanBankSlotsInfo()
	local char = thisCharacter
	
	local numSlots = NUM_BANKGENERIC_SLOTS
	-- local freeSlots = thisCharacterBank.freeslots
	local freeSlots = C_Container.GetContainerNumFreeSlots(-1)

	for bagID = COMMON_NUM_BAG_SLOTS + 1, COMMON_NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do -- 6 to 12
		local bag = GetContainer(bagID)
		
		numSlots = numSlots + bit64:GetBits(bag.info, 3, 6)		-- bits 3-8 : bag size
		freeSlots = freeSlots + bit64:GetBits(bag.info, 9, 6)		-- bits 9-14 : number of free slots in this bag
	end
	
	local numPurchasedSlots, isFull = GetNumBankSlots()
	
	char.bankInfo = numSlots										-- bits 0-9 : num bag slots
				+ bit64:LeftShift(freeSlots, 10)					-- bits 10-19 : num free slots
				+ bit64:LeftShift(numPurchasedSlots, 20)		-- bits 20+ : num purchased
end

local function ScanBag(bagID)
	-- https://wowpedia.fandom.com/wiki/BagID
	local bag = GetContainer(bagID)
	
	local icon = bagID > 0 and GetInventoryItemTexture("player", C_Container.ContainerIDToInventoryID(bagID))
	bag.link = bagID > 0 and GetInventoryItemLink("player", C_Container.ContainerIDToInventoryID(bagID))
	
	local rarity = bag.link and select(3, GetItemInfo(bag.link))
	local size = C_Container.GetContainerNumSlots(bagID)
	
	-- https://wowpedia.fandom.com/wiki/API_GetContainerNumFreeSlots
	local freeSlots, bagType = C_Container.GetContainerNumFreeSlots(bagID)
	
	-- https://wowpedia.fandom.com/wiki/ItemFamily
	-- bag type will be 1024 for a mining bag for instance, it's just bit 11 in the item family (2^bit-1)
	-- we'll just save 10 using the Log2
	
	if bagType and bagType > 0 then
		bagType = Log2(bagType)
	end
	
	bag.info = (rarity or 0)						-- bits 0-2 : rarity
		+ bit64:LeftShift(size, 3)					-- bits 3-8 : bag size
		+ bit64:LeftShift(freeSlots, 9)			-- bits 9-14 : number of free slots in this bag
		+ bit64:LeftShift(bagType or 0, 15)		-- bits 15-19 : 5 bits, 32 values (from 4 to 27 in 10.x) for the bag type
		+ bit64:LeftShift(icon or 0, 20)			-- bits 20+ : icon id
	
	ScanContainer(bagID, size)
	ScanBagSlotsInfo()
end

-- *** Event Handlers ***
local isBankOpen
local MAIN_TAG = "Main"

local function OnBagUpdate(event, bag)
	-- if we get an update for a bank bag but the bank is not open, exit
	if (bag >= MIN_BANK_SLOT) and (bag <= MAX_BANK_SLOT) and not isBankOpen then
		return
	end

	if bag == enum.Keyring or (bag >= 0 and bag < MIN_WARBANK_TAB) then
		ScanBag(bag)
	end
end

local function OnBankFrameClosed()
	isBankOpen = nil
	addon:StopListeningTo("BANKFRAME_CLOSED", MAIN_TAG)
	addon:StopListeningTo("PLAYERBANKSLOTS_CHANGED", MAIN_TAG)
end

local function OnPlayerBankSlotsChanged(event, slotID)
	-- from top left to bottom right, slotID = 1 to 28 for main slots, and 29 to 35 for the additional bags
	if (slotID >= 29) and (slotID <= 35) then
		ScanBag(slotID - (35 - MAX_BANK_SLOT))		-- correction will be -23 in retail or -24 in LK
	else
		ScanBankSlotsInfo()
	end
end

local function OnBankFrameOpened()
	isBankOpen = true
	for bagID = COMMON_NUM_BAG_SLOTS + 1, COMMON_NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do -- 5 to 11 or 6 to 12 in retail
		ScanBag(bagID)
	end
	
	ScanBankSlotsInfo()
	addon:ListenTo("BANKFRAME_CLOSED", OnBankFrameClosed, MAIN_TAG)
	addon:ListenTo("PLAYERBANKSLOTS_CHANGED", OnPlayerBankSlotsChanged, MAIN_TAG)
end

local function OnAuctionMultiSellStart()
	-- if a multi sell starts, unregister bag updates.
	addon:StopListeningTo("BAG_UPDATE")
end

local function OnAuctionMultiSellUpdate(event, current, total)
	if current == total then	-- ex: multisell = 8 items, if we're on the 8th, resume bag updates.
		addon:ListenTo("BAG_UPDATE", OnBagUpdate)
	end
end

local function OnAuctionHouseClosed()
	addon:StopListeningTo("AUCTION_MULTISELL_START")
	addon:StopListeningTo("AUCTION_MULTISELL_UPDATE")
	addon:StopListeningTo("AUCTION_HOUSE_CLOSED")
	
	addon:ListenTo("BAG_UPDATE", OnBagUpdate)	-- just in case things went wrong
end

local function OnAuctionHouseShow()
	-- when going to the AH, listen to multi-sell
	addon:ListenTo("AUCTION_MULTISELL_START", OnAuctionMultiSellStart)
	addon:ListenTo("AUCTION_MULTISELL_UPDATE", OnAuctionMultiSellUpdate)
	addon:ListenTo("AUCTION_HOUSE_CLOSED", OnAuctionHouseClosed)
end


-- ** Mixins **
local function _GetContainer(character, containerID)
	return character.Containers[containerID]
end

local function _GetContainers(character)
	return character.Containers
end

local function _GetNumBagSlots(character)
	return character.bagInfo
		and bit64:GetBits(character.bagInfo, 0, 10)		-- bits 0-9 : num bag slots
		or 0
end

local function _GetNumFreeBagSlots(character)
	return character.bagInfo
		and bit64:RightShift(character.bagInfo, 10)		-- bits 10+ : num free slots
		or 0
end

local function _GetNumBankSlots(character)
	return character.bankInfo
		and bit64:GetBits(character.bankInfo, 0, 10)		-- bits 0-9 : num bag slots
		or 0
end

local function _GetNumFreeBankSlots(character)
	return character.bankInfo
		and bit64:GetBits(character.bankInfo, 10, 10)	-- bits 10-19 : num free slots
		or 0
end

local function _GetNumPurchasedBankSlots(character)
	return character.bankInfo
		and bit64:RightShift(character.bankInfo, 20)		-- bits 20+ : num purchased
		or 0
end

local bagTypeStrings

local bagIcons = {
	[0] = "Interface\\Buttons\\Button-Backpack-Up",
	[enum.Keyring] = "ICONS\\INV_Misc_Key_04.blp",
	[enum.VoidStorageTab1] = "Interface\\Icons\\spell_nature_astralrecalgroup",
	[enum.VoidStorageTab2] = "Interface\\Icons\\spell_nature_astralrecalgroup",
	[enum.MainBankSlots] = "Interface\\Icons\\inv_misc_enggizmos_17",
	[enum.ReagentBank] = "Interface\\Icons\\inv_misc_bag_satchelofcenarius",
}

local bagSizes = {
	[enum.VoidStorageTab1] = 80,
	[enum.VoidStorageTab2] = 80,
	[enum.MainBankSlots] = 28,
	[enum.ReagentBank] = 98,
}

if isRetail then
	bagTypeStrings = {
		-- [1] = "Quiver",
		-- [2] = "Ammo Pouch",
		[4] = C_Item.GetItemSubClassInfo(Enum.ItemClass.Container, 1), -- "Soul Bag",
		[8] = C_Item.GetItemSubClassInfo(Enum.ItemClass.Container, 7), -- "Leatherworking Bag",
		[16] = C_Item.GetItemSubClassInfo(Enum.ItemClass.Container, 8), -- "Inscription Bag",
		[32] = C_Item.GetItemSubClassInfo(Enum.ItemClass.Container, 2), -- "Herb Bag"
		[64] = C_Item.GetItemSubClassInfo(Enum.ItemClass.Container, 3), -- "Enchanting Bag",
		[128] = C_Item.GetItemSubClassInfo(Enum.ItemClass.Container, 4), -- "Engineering Bag",
		[512] = C_Item.GetItemSubClassInfo(Enum.ItemClass.Container, 5), -- "Gem Bag",
		[1024] = C_Item.GetItemSubClassInfo(Enum.ItemClass.Container, 6), -- "Mining Bag",
	}
	
	bagIcons[REAGENTBANK_CONTAINER] = "Interface\\Icons\\inv_misc_bag_satchelofcenarius"
	bagSizes[REAGENTBANK_CONTAINER] = 98
else
	bagTypeStrings = {
		[1] = "Quiver",
		[2] = "Ammo Pouch",
		[4] = C_Item.GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 1), -- "Soul Bag",
		[8] = C_Item.GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 7), -- "Leatherworking Bag",
		[16] = C_Item.GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 8), -- "Inscription Bag",
		[32] = C_Item.GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 2), -- "Herb Bag"
		[64] = C_Item.GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 3), -- "Enchanting Bag",
		[128] = C_Item.GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 4), -- "Engineering Bag",
		[512] = C_Item.GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 5), -- "Gem Bag",
		[1024] = C_Item.GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 6), -- "Mining Bag",
	}
end

local function _GetContainerInfo(character, containerID)
	local bag = _GetContainer(character, containerID)

	local link, size, free, bagType

	if bag and bag.info then
		size = bit64:GetBits(bag.info, 3, 6)		-- bits 3-8 : bag size
		free = bit64:GetBits(bag.info, 9, 6)		-- bits 9-14 : number of free slots in this bag
		bagType = bit64:GetBits(bag.info, 15, 5)	-- bits 15-19 : 5 bits, 32 values (from 4 to 27 in 10.x) for the bag type
		link = bag.link
	end
	
	return link, size, free, bagTypeStrings[bagType]
end

local function _GetContainerLink(character, containerID)
	local bag = _GetContainer(character, containerID)
	
	return bag.link
end

local function _GetContainerIcon(character, containerID)
	-- if it is a known static icon, return it
	if bagIcons[containerID] then return bagIcons[containerID] end
	
	local bag = _GetContainer(character, containerID)
	return bit64:RightShift(bag.info, 20)		-- bits 20+ : icon id
end

local function _GetContainerSize(character, containerID)
	-- if it is a known static size, return it
	if bagSizes[containerID] then return bagSizes[containerID] end

	local bag = _GetContainer(character, containerID)
	
	return (bag and bag.info)
		and bit64:GetBits(bag.info, 3, 6)		-- bits 3-8 : bag size
		or 0
end

local rarityColors = {
	[0] = "|cFFFFFFFF",
	[2] = "|cFF1EFF00",
	[3] = "|cFF0070DD",
	[4] = "|cFFA335EE"
}

local function _GetContainerRarity(character, containerID)
	local bag = _GetContainer(character, containerID)
	
	return (bag and bag.info)
		and bit64:GetBits(bag.info, 0, 3)		-- bits 0-2 : rarity
		or 0
end

local function _GetColoredContainerSize(character, containerID)
	local bag = _GetContainer(character, containerID)
	local size = _GetContainerSize(character, containerID)
	local rarity = _GetContainerRarity(character, containerID)

	-- attempt to recover from a bad scan..
	if rarity == 0 and bag then
		rarity = bag.link and select(3, GetItemInfo(bag.link))
	end

	local color = rarity and rarityColors[rarity] or "|cFFFFFFFF"
	
	return format("%s%s", color, size)
end

local function _GetItemCountPosition(slot)
	--[[ The item count used to be saved (in the rewrite of 10.2.013) in 10 bits, up to 1024.
			It turns out stacks could be higher than that (2000). 
			To prevent users from having to logon with all their alts again, the fix will work as follows:
			
			We will use 16 bits for the count, more than enough but we never know.
			The database will contain both old & new formats (10 & 16 bits), so we will test the value between bits 11 & 15 (only 10 should be used)
			and if that value is higher than 0, we have the old format. If it is 0, we have the new format.
			
			After a few updates, we can get rid of the temporary fix, and use only the new format.
	--]]

	local version = bit64:GetBits(slot, 13, 3)
	return version == 0 and 16 or 10
end

local function _GetSlotInfo(bag, slotID)
	-- assert(type(bag) == "table")		-- this is the pointer to a bag table, obtained through addon:GetContainer()
	-- assert(type(slotID) == "number")
	if not bag then return end

	local link = bag.links and bag.links[slotID]
	local isBattlePet
	
	if link then
		isBattlePet = link:match("|Hbattlepet:")
	end
	
	local slot = bag.items and bag.items[slotID]
	local itemID, count
	
	if slot then
		local pos = _GetItemCountPosition(slot)
		
		count = bit64:GetBits(slot, 0, pos)			-- bits 0-9 : item count (10 bits, up to 1024)
		itemID = bit64:RightShift(slot, pos)		-- bits 10+ : item ID
	end

	return itemID, link, count, isBattlePet
end

local function _GetContainerCooldownInfo(bagID, slotID)
	local index = GetCooldownIndex(bagID, slotID)

	local cd = thisCharacter.Cooldowns[index]
	if cd then
		local startTime = cd.startTime
		local duration = cd.duration
		
		-- local startTime, duration, isEnabled = strsplit("|", bag.cooldowns[slotID])
		local remaining = duration - (GetTime() - startTime)
		
		if remaining > 0 then		-- valid cd ? return it
			return startTime, duration, 1		-- 1 = isEnabled
		end
		
		-- cooldown expired ? clean it from the db
		table.remove(thisCharacter.Cooldowns, index)
	end
end

local function _GetItemCountByID(container, searchedID)
	local count = 0
	
	for slotID, slot in pairs(container.items) do
		local pos = _GetItemCountPosition(slot)
		
		-- is it the item we are searching for ?
		if searchedID == bit64:RightShift(slot, pos) then	-- bits 10+ : item ID
			count = count + bit64:GetBits(slot, 0, pos)		-- bits 0-9 : item count (10 bits, up to 1024)
		end
	end

	return count
end

local function _GetContainerItemCount(character, searchedID)
	local bagCount = 0
	local bankCount = 0
	local reagentBagCount = 0
	local count
		
	for containerID, container in pairs(character.Containers) do
		-- get the container count
		count = _GetItemCountByID(_GetContainer(character, containerID), searchedID)
		
		if containerID <= 4 then
			bagCount = bagCount + count
		elseif containerID == 5 and isRetail then
			reagentBagCount = reagentBagCount + count
		else
			bankCount = bankCount + count
		end
	end

	return bagCount, bankCount, reagentBagCount
end

local function _GetReagentBagItemCount(character, searchedID)
	-- Reagent bag = bag 5 in retail only
	return _GetItemCountByID(_GetContainer(character, enum.ReagentBag), searchedID)
end

local function _IterateContainerSlots(character, callback)
	for containerID, container in pairs(character.Containers) do
		for slotID = 1, _GetContainerSize(character, containerID) do
			local itemID, itemLink, itemCount, isBattlePet = _GetSlotInfo(container, slotID)
			
			-- Callback only if there is an item in that slot
			if itemID then
				callback(containerID, itemID, itemLink, itemCount, isBattlePet)
			end
		end
	end
end

local function _IterateBags(character, callback)
	if not character.Containers then return end
	
	local stop
	for containerID, container in pairs(character.Containers) do
		for slotID = 1, _GetContainerSize(character, containerID) do
			local itemID = _GetSlotInfo(container, slotID)
			
			-- Callback only if there is an item in that slot
			if itemID then
				stop = callback(containerID, container, slotID, itemID)
				if stop then return end		-- exit if the callback returns true
			end
		end
	end
end

local function _SearchBagsForItem(character, searchedItemID, onItemFound)
	-- Iterate bag contents, call the callback if the item is found
	_IterateBags(character, function(containerID, bag, slotID, itemID) 
		if itemID == searchedItemID then
			onItemFound(containerID, bag, slotID)
		end
	end)
end


DataStore:OnAddonLoaded(addonName, function()
	DataStore:RegisterModule({
		addon = addon,
		addonName = addonName,
		characterTables = {
			["DataStore_Containers_Characters"] = {
				GetContainer = _GetContainer,
				GetContainers = _GetContainers,
				GetContainerInfo = _GetContainerInfo,
				GetContainerLink = _GetContainerLink,
				GetContainerIcon = _GetContainerIcon,
				GetContainerSize = _GetContainerSize,
				GetContainerRarity = _GetContainerRarity,
				GetColoredContainerSize = _GetColoredContainerSize,
				
				GetContainerItemCount = _GetContainerItemCount,
				GetNumBagSlots = _GetNumBagSlots,
				GetNumFreeBagSlots = _GetNumFreeBagSlots,
				GetNumBankSlots = _GetNumBankSlots,
				GetNumFreeBankSlots = _GetNumFreeBankSlots,
				
				-- retail
				GetReagentBagItemCount = isRetail and _GetReagentBagItemCount,
				GetNumPurchasedBankSlots = isRetail and _GetNumPurchasedBankSlots,
				IterateContainerSlots = _IterateContainerSlots,
				
				-- non-retail
				IterateBags = not isRetail and _IterateBags,
				SearchBagsForItem = not isRetail and _SearchBagsForItem,
			},
			["DataStore_Containers_Banks"] = {
			}
		},
	})

	thisCharacter = DataStore:GetCharacterDB("DataStore_Containers_Characters", true)
	thisCharacter.Containers = thisCharacter.Containers or {}
	thisCharacter.Cooldowns = thisCharacter.Cooldowns or {}
	
	thisCharacterBank = DataStore:GetCharacterDB("DataStore_Containers_Banks")

	DataStore:RegisterMethod(addon, "GetSlotInfo", _GetSlotInfo)
	DataStore:RegisterMethod(addon, "GetItemCountByID", _GetItemCountByID)
	DataStore:RegisterMethod(addon, "GetItemCountPosition", _GetItemCountPosition)
	DataStore:RegisterMethod(addon, "GetContainerCooldownInfo", _GetContainerCooldownInfo)
end)

DataStore:OnPlayerLogin(function()
	C_Timer.After(3, function()
		-- To avoid the long list of BAG_UPDATE at startup, make the initial scan 3 seconds later ..
		for bagID = 0, COMMON_NUM_BAG_SLOTS do
			ScanBag(bagID)
		end

		-- .. then register the event
		addon:ListenTo("BAG_UPDATE", OnBagUpdate)
	end)

	-- Only for Classic & BC, scan the keyring
	-- 2024/06/20 : not for Cata either, see later what we do for Classic
	-- if not isRetail and HasKey() then
		-- ScanBag(enum.Keyring)
	-- end
	
	addon:ListenTo("BANKFRAME_OPENED", OnBankFrameOpened, MAIN_TAG)
	
	-- disable bag updates during multi sell at the AH
	addon:ListenTo("AUCTION_HOUSE_SHOW", OnAuctionHouseShow)
end)
