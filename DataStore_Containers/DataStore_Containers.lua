--[[	*** DataStore_Containers ***
Written by : Thaoky, EU-Marécages de Zangar
June 21st, 2009

This modules takes care of scanning & storing player bags, bank, & guild banks

Extended services: 
	- guild communication: at logon, sends guild bank tab info (last visit) to guildmates
	- triggers events to manage transfers of guild bank tabs
--]]
if not DataStore then return end

local addonName = "DataStore_Containers"

_G[addonName] = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceConsole-3.0", "AceEvent-3.0", "AceComm-3.0", "AceSerializer-3.0")

local addon = _G[addonName]

local commPrefix = "DS_Cont"		-- let's keep it a bit shorter than the addon name, this goes on a comm channel, a byte is a byte ffs :p
local MAIN_BANK_SLOTS = 100		-- bag id of the 28 main bank slots

-- Constants usable for all versions
local COMMON_NUM_BAG_SLOTS = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE) and NUM_BAG_SLOTS + 1 or NUM_BAG_SLOTS
local MIN_BANK_SLOT = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE) and 6 or 5		-- Bags 6 - 12 are Bank as of 10.0
local MAX_BANK_SLOT = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE) and 12 or 11

local guildMembers = {} 	-- hash table containing guild member info (tab timestamps)

-- Message types
local MSG_SEND_BANK_TIMESTAMPS				= 1	-- broacast at login
local MSG_BANK_TIMESTAMPS_REPLY				= 2	-- reply to someone else's login
local MSG_BANKTAB_REQUEST						= 3	-- request bank tab data ..
local MSG_BANKTAB_REQUEST_ACK					= 4	-- .. ack the request, tell the requester to wait
local MSG_BANKTAB_REQUEST_REJECTED			= 5	-- .. refuse the request
local MSG_BANKTAB_TRANSFER						= 6	-- .. or send the data

local VOID_STORAGE_TAB = "VoidStorage.Tab"

local AddonDB_Defaults = {
	global = {
		Guilds = {
			['*'] = {			-- ["Account.Realm.Name"] 
				money = nil,
				faction = nil,
				Tabs = {
					['*'] = {		-- tabID = table index [1] to [6]
						name = nil,
						icon = nil,
						visitedBy = "",
						ClientTime = 0,				-- since epoch
						ClientDate = nil,
						ClientHour = nil,
						ClientMinute = nil,
						ServerHour = nil,
						ServerMinute = nil,
						ids = {},
						links = {},
						counts = {}
					}
				},
			}
		},
		Characters = {
			['*'] = {					-- ["Account.Realm.Name"] 
				lastUpdate = nil,
				numBagSlots = 0,
				numFreeBagSlots = 0,
				numBankSlots = 0,
				numPurchasedBankSlots = nil,		-- nil = never visited, keep this to distinguish from 0 actually purchased
				numFreeBankSlots = 0,
				bankType = 0,					-- alt is a bank type (flags)
				Containers = {
					['*'] = {					-- Containers["Bag0"]
						icon = nil,				-- Containers's texture
						link = nil,				-- Containers's itemlink
						size = 0,
						freeslots = 0,
						bagtype = 0,
						ids = {},
						links = {},
						counts = {},
						cooldowns = {}
					}
				},
				Keystone = {},
			}
		}
	}
}

-- *** Utility functions ***
local bAnd = bit.band
local bOr = bit.bor
local bXOr = bit.bxor

local TestBit = DataStore.TestBit

local function GetThisGuild()
	local key = DataStore:GetThisGuildKey()
	return key and addon.db.global.Guilds[key] 
end

local function GetBankTimestamps(guild)
	-- returns a | delimited string containing the list of alts in the same guild
	guild = guild or GetGuildInfo("player")
	if not guild then	return end
		
	local thisGuild = GetThisGuild()
	if not thisGuild then return end
	
	local out = {}
	for tabID, tab in pairs(thisGuild.Tabs) do
		if tab.name then
			table.insert(out, format("%d:%s:%d:%d:%d", tabID, tab.name, tab.ClientTime, tab.ServerHour, tab.ServerMinute))
		end
	end
	
	return table.concat(out, "|")
end

local function SaveBankTimestamps(sender, timestamps)
	if not timestamps or strlen(timestamps) == 0 then return end	-- sender has no tabs
	
	guildMembers[sender] = guildMembers[sender] or {}
	wipe(guildMembers[sender])

	for _, v in pairs( { strsplit("|", timestamps) }) do	
		local id, name, clientTime, serverHour, serverMinute = strsplit(":", v)

		-- ex: guildMembers["Thaoky"]["RaidFood"] = {	clientTime = 123, serverHour = ... }
		guildMembers[sender][name] = {}
		local tab = guildMembers[sender][name]
		tab.id = tonumber(id)
		tab.clientTime = tonumber(clientTime)
		tab.serverHour = tonumber(serverHour)
		tab.serverMinute = tonumber(serverMinute)
	end
	addon:SendMessage("DATASTORE_GUILD_BANKTABS_UPDATED", sender)
end

local function GuildBroadcast(messageType, ...)
	local serializedData = addon:Serialize(messageType, ...)
	addon:SendCommMessage(commPrefix, serializedData, "GUILD")
end

local function GuildWhisper(player, messageType, ...)
	if DataStore:IsGuildMemberOnline(player) then
		local serializedData = addon:Serialize(messageType, ...)
		addon:SendCommMessage(commPrefix, serializedData, "WHISPER", player)
	end
end

local function IsEnchanted(link)
	if not link then return end
	
	if not string.find(link, "item:%d+:0:0:0:0:0:0:%d+:%d+:0:0") then	-- 7th is the UniqueID, 8th LinkLevel which are irrelevant
		-- enchants/jewels store values instead of zeroes in the link, if this string can't be found, there's at least one enchant/jewel
		return true
	end
end

local BAGS			= 1		-- All bags, 0 to 12, and keyring ( id -2 )
local BANK			= 2		-- 28 main slots
local GUILDBANK	= 3		-- 98 main slots

local ContainerTypes = {
	[BAGS] = {
		GetSize = function(self, bagID)
				return C_Container.GetContainerNumSlots(bagID)
			end,
		GetFreeSlots = function(self, bagID)
				local freeSlots, bagType = C_Container.GetContainerNumFreeSlots(bagID)
				return freeSlots, bagType
			end,
		GetLink = function(self, slotID, bagID)
				return C_Container.GetContainerItemLink(bagID, slotID)
			end,
		GetCount = function(self, slotID, bagID)
				return C_Container.GetContainerItemInfo(bagID, slotID).stackCount
			end,
		GetCooldown = function(self, slotID, bagID)
				local startTime, duration, isEnabled = C_Container.GetContainerItemCooldown(bagID, slotID)
				return startTime, duration, isEnabled
			end,
	},
	[BANK] = {
		GetSize = function(self)
				return NUM_BANKGENERIC_SLOTS or 28		-- hardcoded in case the constant is not set
			end,
		GetFreeSlots = function(self)
				local freeSlots, bagType = C_Container.GetContainerNumFreeSlots(-1)		-- -1 = player bank
				return freeSlots, bagType
			end,
		GetLink = function(self, slotID)
				return C_Container.GetContainerItemLink(-1, slotID)
			end,
		GetCount = function(self, slotID)
				return C_Container.GetContainerItemInfo(-1, slotID).stackCount
			end,
		GetCooldown = function(self, slotID)
				local startTime, duration, isEnabled = GetInventoryItemCooldown("player", slotID)
				return startTime, duration, isEnabled
			end,
	},
	[GUILDBANK] = {
		GetSize = function(self)
				return MAX_GUILDBANK_SLOTS_PER_TAB or 98		-- hardcoded in case the constant is not set
			end,
		GetFreeSlots = function(self)
				return nil, nil
			end,
		GetLink = function(self, slotID, tabID)
				return GetGuildBankItemLink(tabID, slotID)
			end,
		GetCount = function(self, slotID, tabID)
				local _, count = GetGuildBankItemInfo(tabID, slotID)
				return count
			end,
		GetCooldown = function(self, slotID)
				return nil
			end,
	}
}

local function GetRemainingCooldown(start)
   local uptime = GetTime()
   
   if start <= uptime + 1 then
      return start - uptime
   end
   
   return -uptime - ((2 ^ 32) / 1000 - start)
end
-- *** Scanning functions ***
local function ScanContainer(bagID, containerType)
	if not bagID then return end
	
	local Container = ContainerTypes[containerType]
	
	local bag
	if containerType == GUILDBANK then
		local thisGuild = GetThisGuild()
		if not thisGuild then return end
	
		bag = thisGuild.Tabs[bagID]	-- bag is actually the current tab
	else
		bag = addon.ThisCharacter.Containers["Bag" .. bagID]
		wipe(bag.cooldowns)		-- does not exist for a guild bank
	end

	wipe(bag.ids)				-- clean existing bag data
	wipe(bag.counts)
	wipe(bag.links)
	
	local link, count
	local startTime, duration, isEnabled
	
	bag.size = Container:GetSize(bagID)
	bag.freeslots, bag.bagtype = Container:GetFreeSlots(bagID)
	
	-- Scan from 1 to bagsize for normal bags or guild bank tabs, but from 40 to 67 for main bank slots
	-- local baseIndex = (containerType == BANK) and 39 or 0
	local baseIndex = 0
	local index
	
	for slotID = baseIndex + 1, baseIndex + bag.size do
		index = slotID - baseIndex
		link = Container:GetLink(slotID, bagID)
		
		if link then
			bag.ids[index] = tonumber(link:match("item:(%d+)"))

			if link:match("|Hkeystone:") then
				-- mythic keystones are actually all using the same item id
				bag.ids[index] = 138019

			elseif link:match("|Hbattlepet:") then
				-- special treatment for battle pets, save texture id instead of item id..
				-- texture, itemCount, locked, quality, readable, _, _, isFiltered, noValue, itemID = GetContainerItemInfo(id, itemButton:GetID());
				
				-- 20/11/2022 : temporary hack, blizzard changed the main bank id from 100 to -1
				-- Changing the code everywhere to support -1 is feasible, but would require the users to reload the data.
				-- When I have time to fix this hack, I'll make it transparent for users.
				local actualBagID = (bagID == MAIN_BANK_SLOTS) and -1 or bagID
				
				local info = C_Container.GetContainerItemInfo(actualBagID, slotID)
				bag.ids[index] = info.iconFileID
			end
			
			if IsEnchanted(link) then
				bag.links[index] = link
			end
		
			count = Container:GetCount(slotID, bagID)
			if count and count > 1  then
				bag.counts[index] = count	-- only save the count if it's > 1 (to save some space since a count of 1 is extremely redundant)
			end
		end
		
		startTime, duration, isEnabled = Container:GetCooldown(slotID, bagID)
		if startTime and startTime > 0 then
			if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then
				startTime = time() + GetRemainingCooldown(startTime)
			end
		
			bag.cooldowns[index] = format("%s|%s|1", startTime, duration)
		end
	end
	
	addon.ThisCharacter.lastUpdate = time()
	addon:SendMessage("DATASTORE_CONTAINER_UPDATED", bagID, containerType)
end

local function ScanBagSlotsInfo()
	local char = addon.ThisCharacter

	local numBagSlots = 0
	local numFreeBagSlots = 0

	for bagID = 0, COMMON_NUM_BAG_SLOTS, 1 do -- 5 Slots to include Reagent Bag
		local bag = char.Containers["Bag" .. bagID]
		numBagSlots = numBagSlots + bag.size
		numFreeBagSlots = numFreeBagSlots + bag.freeslots
	end
	
	char.numBagSlots = numBagSlots
	char.numFreeBagSlots = numFreeBagSlots
end

local function ScanBankSlotsInfo()
	local char = addon.ThisCharacter
	
	local numBankSlots = NUM_BANKGENERIC_SLOTS
	local numFreeBankSlots = char.Containers["Bag"..MAIN_BANK_SLOTS].freeslots

	for bagID = COMMON_NUM_BAG_SLOTS + 1, COMMON_NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do -- 6 to 12
		local bag = char.Containers["Bag" .. bagID]
		
		numBankSlots = numBankSlots + bag.size
		numFreeBankSlots = numFreeBankSlots + bag.freeslots
	end
	
	char.numBankSlots = numBankSlots
	char.numFreeBankSlots = numFreeBankSlots
	
	local numPurchasedSlots, isFull = GetNumBankSlots()
	char.numPurchasedBankSlots = numPurchasedSlots
end

local function ScanGuildBankInfo()
	-- only the current tab can be updated
	local thisGuild = GetThisGuild()
	if not thisGuild then return end
	
	local tabID = GetCurrentGuildBankTab()
	local t = thisGuild.Tabs[tabID]	-- t = current tab

	t.name, t.icon = GetGuildBankTabInfo(tabID)
	t.visitedBy = UnitName("player")
	t.ClientTime = time()
	if GetLocale() == "enUS" then				-- adjust this test if there's demand
		t.ClientDate = date("%m/%d/%Y")
	else
		t.ClientDate = date("%d/%m/%Y")
	end
	t.ClientHour = tonumber(date("%H"))
	t.ClientMinute = tonumber(date("%M"))
	t.ServerHour, t.ServerMinute = GetGameTime()
end

local function ScanBag(bagID)
	if (bagID < 0) and (bagID ~= -2) then return end

	local char = addon.ThisCharacter
	local bag = char.Containers["Bag" .. bagID]
	
	if bagID == 0 then	-- Bag 0	
		bag.icon = "Interface\\Buttons\\Button-Backpack-Up"
		bag.link = nil
	elseif bagID == -2 then
		bag.icon = "ICONS\\INV_Misc_Key_04.blp"
		bag.link = nil	 
	else						-- Bags 1 through 12
		bag.icon = GetInventoryItemTexture("player", C_Container.ContainerIDToInventoryID(bagID))
		bag.link = GetInventoryItemLink("player", C_Container.ContainerIDToInventoryID(bagID))
		
		if bag.link then
			local _, _, rarity = GetItemInfo(bag.link)
			if rarity then	-- in case rarity was known from a previous scan, and GetItemInfo returns nil for some reason .. don't overwrite
				bag.rarity = rarity
			end
		else
			-- 10.0, due to the shift in bag id's, be sure the old rarity is not preserved for alts who do not have a reagent bag yet
			bag.rarity = nil
		end
	end
	
	ScanContainer(bagID, BAGS)
	ScanBagSlotsInfo()
end

local function ScanVoidStorage()
	-- delete the old data from the "VoidStorage" container, now stored in .Tab1, .Tab2 (since they'll likely add more later on)
	wipe(addon.ThisCharacter.Containers["VoidStorage"])

	local bag
	local itemID
	
	for tab = 1, 2 do
		bag = addon.ThisCharacter.Containers[VOID_STORAGE_TAB .. tab]
		bag.size = 80
	
		for slot = 1, bag.size do
			itemID = GetVoidItemInfo(tab, slot)
			bag.ids[slot] = itemID
		end
	end
	addon:SendMessage("DATASTORE_VOIDSTORAGE_UPDATED")
end

local function ScanReagentBank()
	if REAGENTBANK_CONTAINER then
		ScanContainer(REAGENTBANK_CONTAINER, BAGS)
	end
end

local function ScanKeystoneInfo()
	local char = addon.ThisCharacter
	wipe(char.Keystone)
	
   local mapID = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
	if not mapID then return end

	local keyName, _, _, texture = C_ChallengeMode.GetMapUIInfo(mapID)
	
	local keyInfo = char.Keystone
	keyInfo.name = keyName
	keyInfo.level = C_MythicPlus.GetOwnedKeystoneLevel()
	keyInfo.texture = texture
	
	char.lastUpdate = time()
end

-- *** Event Handlers ***
local function OnPlayerAlive()
	ScanKeystoneInfo()
end

local function OnWeeklyRewardsUpdate()
	ScanKeystoneInfo()
end

local function OnBagUpdate(event, bag)
	-- if we get an update for a bank bag but the bank is not open, exit
	if (bag >= MIN_BANK_SLOT) and (bag <= MAX_BANK_SLOT) and not addon.isBankOpen then
		return
	end

	-- -2 for the keyring in non-retail
	if (bag == -2) or (bag >= 0) then
		ScanBag(bag)
	end
	
	if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
		ScanKeystoneInfo()
	end
end

local function OnBankFrameClosed()
	addon.isBankOpen = nil
	addon:UnregisterEvent("BANKFRAME_CLOSED")
	addon:UnregisterEvent("PLAYERBANKSLOTS_CHANGED")
end

local function OnPlayerBankSlotsChanged(event, slotID)
	-- from top left to bottom right, slotID = 1 to 28 for main slots, and 29 to 35 for the additional bags
	if (slotID >= 29) and (slotID <= 35) then
		ScanBag(slotID - (35 - MAX_BANK_SLOT))		-- correction will be -23 in retail or -24 in LK
	else
		ScanContainer(MAIN_BANK_SLOTS, BANK)
		ScanBankSlotsInfo()
	end
end

local function OnPlayerReagentBankSlotsChanged(event, slotID)
	-- This event does not work in a consistent way.
	-- When triggered after crafting an item that uses reagents from the reagent bank, it is possible to properly read the container info.
	-- When triggered after validating a quest that uses reagents from the reagent bank, then C_Container.GetContainerItemInfo returns nil
	
	local bag = addon.ThisCharacter.Containers["Bag-3"]
	if not bag then return end
		
	-- Get the info for that slot
	local info = C_Container.GetContainerItemInfo(-3, slotID)
	
	-- Will work for crafts, but not for quest validation, leaving an invalid count. (at least in 10.0.002)
	if info then
		bag.ids[slotID] = info.itemID
	
		if info.stackCount and info.stackCount	> 1 then 
	
			-- only save the count if it's > 1 (to save some space since a count of 1 is extremely redundant)
			bag.counts[slotID] = info.stackCount
		else
			-- otherwise be sure to invalidate the previous count
			bag.counts[slotID] = nil
		end
	else
	
		-- the only ugly possible workaround : if info is nil (which it should not be when turning in a quest), then clear that slot.
		bag.ids[slotID] = nil
		bag.counts[slotID] = nil
	end
end

local function OnBankFrameOpened()
	addon.isBankOpen = true
	for bagID = COMMON_NUM_BAG_SLOTS + 1, COMMON_NUM_BAG_SLOTS + NUM_BANKBAGSLOTS do -- 5 to 11 or 6 to 12 in retail
		ScanBag(bagID)
	end
	
	ScanContainer(MAIN_BANK_SLOTS, BANK)
	ScanBankSlotsInfo()
	addon:RegisterEvent("BANKFRAME_CLOSED", OnBankFrameClosed)
	addon:RegisterEvent("PLAYERBANKSLOTS_CHANGED", OnPlayerBankSlotsChanged)
end

local function OnGuildBankFrameClosed()
	-- if WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC or WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC then
		-- addon:UnregisterEvent("GUILDBANKFRAME_CLOSED")
	-- end
	addon:UnregisterEvent("GUILDBANKBAGSLOTS_CHANGED")
	
	local guildName = GetGuildInfo("player")
	if guildName then
		GuildBroadcast(MSG_SEND_BANK_TIMESTAMPS, GetBankTimestamps(guildName))
	end
end

local function OnGuildBankBagSlotsChanged()
	ScanContainer(GetCurrentGuildBankTab(), GUILDBANK)
	ScanGuildBankInfo()
end

local function OnGuildBankFrameOpened()
	
	-- if WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC or WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC then
		-- addon:RegisterEvent("GUILDBANKFRAME_CLOSED", OnGuildBankFrameClosed)
	-- end
	
	addon:RegisterEvent("GUILDBANKBAGSLOTS_CHANGED", OnGuildBankBagSlotsChanged)
	
	local thisGuild = GetThisGuild()
	if thisGuild then
		thisGuild.money = GetGuildBankMoney()
		thisGuild.faction = UnitFactionGroup("player")
	end
end

local function OnAuctionMultiSellStart()
	-- if a multi sell starts, unregister bag updates.
	addon:UnregisterEvent("BAG_UPDATE")
end

local function OnAuctionMultiSellUpdate(event, current, total)
	if current == total then	-- ex: multisell = 8 items, if we're on the 8th, resume bag updates.
		addon:RegisterEvent("BAG_UPDATE", OnBagUpdate)
	end
end

local function OnAuctionHouseClosed()
	addon:UnregisterEvent("AUCTION_MULTISELL_START")
	addon:UnregisterEvent("AUCTION_MULTISELL_UPDATE")
	addon:UnregisterEvent("AUCTION_HOUSE_CLOSED")
	
	addon:RegisterEvent("BAG_UPDATE", OnBagUpdate)	-- just in case things went wrong
end

local function OnAuctionHouseShow()
	-- when going to the AH, listen to multi-sell
	addon:RegisterEvent("AUCTION_MULTISELL_START", OnAuctionMultiSellStart)
	addon:RegisterEvent("AUCTION_MULTISELL_UPDATE", OnAuctionMultiSellUpdate)
	addon:RegisterEvent("AUCTION_HOUSE_CLOSED", OnAuctionHouseClosed)
end

local function OnVoidStorageTransferDone()
	ScanVoidStorage()
end

local function OnPlayerInteractionManagerFrameHide(event, interactionType)
	-- if interactionType ~= Enum.PlayerInteractionType.VoidStorageBanker then return end

	-- Void storage specific
	if interactionType == Enum.PlayerInteractionType.VoidStorageBanker then 
		addon:UnregisterEvent("VOID_STORAGE_UPDATE")
		addon:UnregisterEvent("VOID_STORAGE_CONTENTS_UPDATE")
		addon:UnregisterEvent("VOID_TRANSFER_DONE")

	-- Guild bank specific
	elseif interactionType == Enum.PlayerInteractionType.GuildBanker then 
		OnGuildBankFrameClosed()
	end
end

local function OnPlayerInteractionManagerFrameShow(event, interactionType)

	-- Void storage specific
	if interactionType == Enum.PlayerInteractionType.VoidStorageBanker then 
		ScanVoidStorage()
		addon:RegisterEvent("VOID_STORAGE_UPDATE", ScanVoidStorage)
		addon:RegisterEvent("VOID_STORAGE_CONTENTS_UPDATE", ScanVoidStorage)
		addon:RegisterEvent("VOID_TRANSFER_DONE", OnVoidStorageTransferDone)
	
	-- Bank / Reagent bank
	elseif interactionType == Enum.PlayerInteractionType.Banker then 
		ScanReagentBank()
	
	-- Guild bank specific
	elseif interactionType == Enum.PlayerInteractionType.GuildBanker then 
		OnGuildBankFrameOpened()
	end
end


-- ** Mixins **
local function _GetContainer(character, containerID)
	-- containerID can be number or string
	if type(containerID) == "number" then
		return character.Containers["Bag" .. containerID]
	end
	return character.Containers[containerID]
end

local function _GetContainers(character)
	return character.Containers
end

local BagTypeStrings

if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
	BagTypeStrings = {
		-- [1] = "Quiver",
		-- [2] = "Ammo Pouch",
		[4] = GetItemSubClassInfo(Enum.ItemClass.Container, 1), -- "Soul Bag",
		[8] = GetItemSubClassInfo(Enum.ItemClass.Container, 7), -- "Leatherworking Bag",
		[16] = GetItemSubClassInfo(Enum.ItemClass.Container, 8), -- "Inscription Bag",
		[32] = GetItemSubClassInfo(Enum.ItemClass.Container, 2), -- "Herb Bag"
		[64] = GetItemSubClassInfo(Enum.ItemClass.Container, 3), -- "Enchanting Bag",
		[128] = GetItemSubClassInfo(Enum.ItemClass.Container, 4), -- "Engineering Bag",
		[512] = GetItemSubClassInfo(Enum.ItemClass.Container, 5), -- "Gem Bag",
		[1024] = GetItemSubClassInfo(Enum.ItemClass.Container, 6), -- "Mining Bag",
	}
else
	BagTypeStrings = {
		[1] = "Quiver",
		[2] = "Ammo Pouch",
		[4] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 1), -- "Soul Bag",
		[8] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 7), -- "Leatherworking Bag",
		[16] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 8), -- "Inscription Bag",
		[32] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 2), -- "Herb Bag"
		[64] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 3), -- "Enchanting Bag",
		[128] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 4), -- "Engineering Bag",
		[512] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 5), -- "Gem Bag",
		[1024] = GetItemSubClassInfo(LE_ITEM_CLASS_CONTAINER, 6), -- "Mining Bag",
	}
end

local function _GetContainerInfo(character, containerID)
	local bag = _GetContainer(character, containerID)
	
	local icon = bag.icon
	local size = bag.size
	
	if containerID == MAIN_BANK_SLOTS then	-- main bank slots
		icon = "Interface\\Icons\\inv_misc_enggizmos_17"
	elseif containerID == REAGENTBANK_CONTAINER then
		icon = "Interface\\Icons\\inv_misc_bag_satchelofcenarius"
	elseif string.sub(containerID, 1, string.len(VOID_STORAGE_TAB)) == VOID_STORAGE_TAB then
		icon = "Interface\\Icons\\spell_nature_astralrecalgroup"
		size = 80
	end
	
	return icon, bag.link, size, bag.freeslots, BagTypeStrings[bag.bagtype]
end

local function _GetContainerSize(character, containerID)
	-- containerID can be number or string
	if type(containerID) == "number" then
		return character.Containers["Bag" .. containerID].size
	end
	return character.Containers[containerID].size
end

local rarityColors = {
	[2] = "|cFF1EFF00",
	[3] = "|cFF0070DD",
	[4] = "|cFFA335EE"
}

local function _GetColoredContainerSize(character, containerID)
	local bag = _GetContainer(character, containerID)
	local size = _GetContainerSize(character, containerID)
	
	if bag.rarity and rarityColors[bag.rarity] then
		return format("%s%s", rarityColors[bag.rarity], size)
	end
	
	return format("%s%s", "|cFFFFFFFF", size)
end

local function _GetSlotInfo(bag, slotID)
	assert(type(bag) == "table")		-- this is the pointer to a bag table, obtained through addon:GetContainer()
	assert(type(slotID) == "number")

	local link = bag.links[slotID]
	local isBattlePet
	
	if link then
		isBattlePet = link:match("|Hbattlepet:")
	end
	
	-- return itemID, itemLink, itemCount, isBattlePet
	return bag.ids[slotID], link, bag.counts[slotID] or 1, isBattlePet
end

local function _GetContainerCooldownInfo(bag, slotID)
	assert(type(bag) == "table")		-- this is the pointer to a bag table, obtained through addon:GetContainer()
	assert(type(slotID) == "number")

	local cd = bag.cooldowns[slotID]
	if cd then
		local startTime, duration, isEnabled = strsplit("|", bag.cooldowns[slotID])
		local remaining = duration - (GetTime() - startTime)
		
		if remaining > 0 then		-- valid cd ? return it
			return tonumber(startTime), tonumber(duration), tonumber(isEnabled)
		end
		-- cooldown expired ? clean it from the db
		bag.cooldowns[slotID] = nil
	end
end

local function _GetContainerItemCount(character, searchedID)
	local bagCount = 0
	local bankCount = 0
	local voidCount = 0
	local reagentBagCount = 0
	local reagentBankCount = 0
	local id
	
	-- old voidstorage, simply delete it, might still be listed if players haven't logged on all their alts					
	character.Containers["VoidStorage"] = nil
		
	for containerName, container in pairs(character.Containers) do
		for slotID = 1, container.size do
			id = container.ids[slotID]
			
			if (id) and (id == searchedID) then
				local itemCount = container.counts[slotID] or 1
				if (containerName == "VoidStorage.Tab1") or (containerName == "VoidStorage.Tab2") then
					voidCount = voidCount + 1
				elseif (containerName == "Bag"..MAIN_BANK_SLOTS) then
					bankCount = bankCount + itemCount
				elseif (containerName == "Bag-2") then
					bagCount = bagCount + itemCount
				elseif (containerName == "Bag-3") then
					reagentBankCount = reagentBankCount + itemCount
				elseif (containerName == "Bag5") then -- Reagent Bag
					reagentBagCount = reagentBagCount + itemCount
				else
					local bagNum = tonumber(string.sub(containerName, 4))
					if (bagNum >= 0) and (bagNum <= 4) then
						bagCount = bagCount + itemCount
					else
						bankCount = bankCount + itemCount
					end
				end
			end
		end
	end

	return bagCount, bankCount, voidCount, reagentBankCount, reagentBagCount
end

local function _IterateContainerSlots(character, callback)
	for containerName, container in pairs(character.Containers) do
		for slotID = 1, container.size do
			local itemID, itemLink, itemCount, isBattlePet = _GetSlotInfo(container, slotID)
			
			-- Callback only if there is an item in that slot
			if itemID then
				callback(containerName, itemID, itemLink, itemCount, isBattlePet)
			end
		end
	end
end

local function _GetNumBagSlots(character)
	return character.numBagSlots
end

local function _GetNumFreeBagSlots(character)
	return character.numFreeBagSlots
end

local function _GetNumBankSlots(character)
	return character.numBankSlots
end

local function _GetNumFreeBankSlots(character)
	return character.numFreeBankSlots
end

local function _GetNumPurchasedBankSlots(character)
	-- nil if bank never visited
	-- 0 if zero slots actually purchased
	return character.numPurchasedBankSlots
end

local function _GetVoidStorageItem(character, index)
	return character.Containers["VoidStorage"].ids[index]
end

local function _GetKeystoneName(character)
	return character.Keystone.name or ""
end

local function _GetKeystoneLevel(character)
	return character.Keystone.level or 0
end

local function _GetGuildBankItemCount(guild, searchedID)
	local count = 0
	for _, container in pairs(guild.Tabs) do
	   for slotID, id in pairs(container.ids) do
	      if (id == searchedID) then
	         count = count + (container.counts[slotID] or 1)
	      end
	   end
	end
	return count
end
	
local function _GetGuildBankTab(guild, tabID)
	return guild.Tabs[tabID]
end
	
local function _GetGuildBankTabName(guild, tabID)
	return guild.Tabs[tabID].name
end

local function _IterateGuildBankSlots(guild, callback)
	for tabID, tab in pairs(guild.Tabs) do
		if tab.name then
			for slotID = 1, 98 do
				local itemID, itemLink, itemCount, isBattlePet = _GetSlotInfo(tab, slotID)
				
				-- Callback only if there is an item in that slot
				if itemID then
					local location = format("%s, %s - col %d/row %d)", GUILD_BANK, tab.name, floor((slotID-1)/7)+1, ((slotID-1)%7)+1)
				
					callback(location, itemID, itemLink, itemCount, isBattlePet)
				end
			end
		end
	end
end

local function _GetGuildBankTabIcon(guild, tabID)
	return guild.Tabs[tabID].icon
end

local function _GetGuildBankTabItemCount(guild, tabID, searchedID)
	local count = 0
	local container = guild.Tabs[tabID]
	
	for slotID, id in pairs(container.ids) do
		if (id == searchedID) then
			count = count + (container.counts[slotID] or 1)
		end
	end
	return count
end

local function _GetGuildBankTabLastUpdate(guild, tabID)
	return guild.Tabs[tabID].ClientTime
end

local function _GetGuildBankMoney(guild)
	return guild.money
end

local function _GetGuildBankFaction(guild)
	return guild.faction
end

local function _ImportGuildBankTab(guild, tabID, data)
	wipe(guild.Tabs[tabID])							-- clear existing data
	guild.Tabs[tabID] = data
end

local function _GetGuildBankTabSuppliers()
	return guildMembers
end

local function _GetGuildMemberBankTabInfo(member, tabName)
	-- for the current guild, return the guild member's data about a given tab
	if guildMembers[member] then
		if guildMembers[member][tabName] then
			local tab = guildMembers[member][tabName]
			return tab.clientTime, tab.serverHour, tab.serverMinute
		end
	end
end

local function _RequestGuildMemberBankTab(member, tabName)
	GuildWhisper(member, MSG_BANKTAB_REQUEST, tabName)
end

local function _RejectBankTabRequest(member)
	GuildWhisper(member, MSG_BANKTAB_REQUEST_REJECTED)
end

local function _SendBankTabToGuildMember(member, tabName)
	-- send the actual content of a bank tab to a guild member
	local thisGuild = GetThisGuild()
	if thisGuild then
		local tabID
		if guildMembers[member] then
			if guildMembers[member][tabName] then
				tabID = guildMembers[member][tabName].id
			end
		end	
	
		if tabID then
			GuildWhisper(member, MSG_BANKTAB_TRANSFER, thisGuild.Tabs[tabID])
		end
	end
end

local function _IterateBags(character, callback)
	if not character.Containers then return end
	
	for containerName, container in pairs(character.Containers) do
		for slotID = 1, container.size do
			local itemID = container.ids[slotID]
			local stop = callback(containerName, container, slotID, itemID)
			if stop then return end		-- exit if the callback returns true
		end
	end
end

local function _SearchBagsForItem(character, searchedItemID, onItemFound)
	-- Iterate bag contents, call the callback if the item is found
	_IterateBags(character, function(bagName, bag, slotID, itemID) 
		if itemID == searchedItemID then
			onItemFound(bagName, bag, slotID)
		end
	end)
end

local function _ToggleBankType(character, bankType)
	local types = DataStore.Enum.BankTypes
	
	if bankType >= types.Minimum and bankType <= types.Maximum then
		-- toggle the appropriate bit for this bank type
		character.bankType = bXOr(character.bankType, 2^(bankType - 1))
	end
end

local function _IsBankType(character, bankType)
	-- speed up the process a bit if all flags are 0
	return (character.bankType == 0)
		and false
		or TestBit(character.bankType, bankType - 1)
end

local function _GetBankType(character)
	return character.bankType
end

local function _GetBankTypes(character)
	if character.bankType == 0 then return ""	end
	
	local bankTypeLabels = {}
	
	local types = DataStore.Enum.BankTypes
	local labels = DataStore.Enum.BankTypesLabels
	
	-- loop through all types
	for i = types.Minimum, types.Maximum do
		-- add label if bit is set
		if TestBit(character.bankType, i - 1) then
			table.insert(bankTypeLabels, labels[i])
		end
	end
	
	return table.concat(bankTypeLabels, ", "), bankTypeLabels
end

local PublicMethods = {
	GetContainer = _GetContainer,
	GetContainers = _GetContainers,
	GetContainerInfo = _GetContainerInfo,
	GetContainerSize = _GetContainerSize,
	GetColoredContainerSize = _GetColoredContainerSize,
	GetSlotInfo = _GetSlotInfo,
	GetContainerCooldownInfo = _GetContainerCooldownInfo,
	GetContainerItemCount = _GetContainerItemCount,
	GetNumBagSlots = _GetNumBagSlots,
	GetNumFreeBagSlots = _GetNumFreeBagSlots,
	GetNumBankSlots = _GetNumBankSlots,
	GetNumFreeBankSlots = _GetNumFreeBankSlots,
}

if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
	-- Retail only
	PublicMethods.IterateContainerSlots = _IterateContainerSlots
	PublicMethods.GetNumPurchasedBankSlots = _GetNumPurchasedBankSlots
	PublicMethods.GetVoidStorageItem = _GetVoidStorageItem
	PublicMethods.GetKeystoneName = _GetKeystoneName
	PublicMethods.GetKeystoneLevel = _GetKeystoneLevel
	PublicMethods.ToggleBankType = _ToggleBankType
	PublicMethods.IsBankType = _IsBankType
	PublicMethods.GetBankType = _GetBankType
	PublicMethods.GetBankTypes = _GetBankTypes
else
	-- Non-retail only
	PublicMethods.IterateBags = _IterateBags
	PublicMethods.SearchBagsForItem = _SearchBagsForItem
end

if WOW_PROJECT_ID ~= WOW_PROJECT_CLASSIC then
	-- Retail and Wrath
	PublicMethods.GetGuildBankItemCount = _GetGuildBankItemCount
	PublicMethods.GetGuildBankTab = _GetGuildBankTab
	PublicMethods.GetGuildBankTabName = _GetGuildBankTabName
	PublicMethods.IterateGuildBankSlots = _IterateGuildBankSlots
	PublicMethods.GetGuildBankTabIcon = _GetGuildBankTabIcon
	PublicMethods.GetGuildBankTabItemCount = _GetGuildBankTabItemCount
	PublicMethods.GetGuildBankTabLastUpdate = _GetGuildBankTabLastUpdate
	PublicMethods.GetGuildBankMoney = _GetGuildBankMoney
	PublicMethods.GetGuildBankFaction = _GetGuildBankFaction
	PublicMethods.ImportGuildBankTab = _ImportGuildBankTab
	PublicMethods.GetGuildMemberBankTabInfo = _GetGuildMemberBankTabInfo
	PublicMethods.RequestGuildMemberBankTab = _RequestGuildMemberBankTab
	PublicMethods.RejectBankTabRequest = _RejectBankTabRequest
	PublicMethods.SendBankTabToGuildMember = _SendBankTabToGuildMember
	PublicMethods.GetGuildBankTabSuppliers = _GetGuildBankTabSuppliers
end


-- *** Guild Comm ***
--[[	*** Protocol ***

At login: 
	Broadcast of guild bank timers on the guild channel
After the guild bank frame is closed:
	Broadcast of guild bank timers on the guild channel

Client addon calls: DataStore:RequestGuildMemberBankTab()
	Client				Server

	==> MSG_BANKTAB_REQUEST 
	<== MSG_BANKTAB_REQUEST_ACK (immediate ack)   

	<== MSG_BANKTAB_REQUEST_REJECTED (stop)   
	or 
	<== MSG_BANKTAB_TRANSFER (actual data transfer)
--]]

local function OnAnnounceLogin(self, guildName)
	-- when the main DataStore module sends its login info, share the guild bank last visit time across guild members
	local timestamps = GetBankTimestamps(guildName)
	if timestamps then	-- nil if guild bank hasn't been visited yet, so don't broadcast anything
		GuildBroadcast(MSG_SEND_BANK_TIMESTAMPS, timestamps)
	end
end

local function OnGuildMemberOffline(self, member)
	guildMembers[member] = nil
	addon:SendMessage("DATASTORE_GUILD_BANKTABS_UPDATED", member)
end

local GuildCommCallbacks = {
	[MSG_SEND_BANK_TIMESTAMPS] = function(sender, timestamps)
			if sender ~= UnitName("player") then						-- don't send back to self
				local timestamps = GetBankTimestamps()
				if timestamps then
					GuildWhisper(sender, MSG_BANK_TIMESTAMPS_REPLY, timestamps)		-- reply by sending my own data..
				end
			end
			SaveBankTimestamps(sender, timestamps)
		end,
	[MSG_BANK_TIMESTAMPS_REPLY] = function(sender, timestamps)
			SaveBankTimestamps(sender, timestamps)
		end,
	[MSG_BANKTAB_REQUEST] = function(sender, tabName)
			-- trigger the event only, actual response (ack or not) must be handled by client addons
			GuildWhisper(sender, MSG_BANKTAB_REQUEST_ACK)		-- confirm that the request has been received
			addon:SendMessage("DATASTORE_BANKTAB_REQUESTED", sender, tabName)
		end,
	[MSG_BANKTAB_REQUEST_ACK] = function(sender)
			addon:SendMessage("DATASTORE_BANKTAB_REQUEST_ACK", sender)
		end,
	[MSG_BANKTAB_REQUEST_REJECTED] = function(sender)
			addon:SendMessage("DATASTORE_BANKTAB_REQUEST_REJECTED", sender)
		end,
	[MSG_BANKTAB_TRANSFER] = function(sender, data)
			local guildName = GetGuildInfo("player")
			local guild	= GetThisGuild()
			
			for tabID, tab in pairs(guild.Tabs) do
				if tab.name == data.name then	-- this is the tab being updated
					_ImportGuildBankTab(guild, tabID, data)
					addon:SendMessage("DATASTORE_BANKTAB_UPDATE_SUCCESS", sender, guildName, data.name, tabID)
					GuildBroadcast(MSG_SEND_BANK_TIMESTAMPS, GetBankTimestamps(guildName))
				end
			end
		end,
}

function addon:OnInitialize()
	addon.db = LibStub("AceDB-3.0"):New(format("%sDB", addonName), AddonDB_Defaults)

	DataStore:RegisterModule(addonName, addon, PublicMethods)

	-- All versions
	DataStore:SetCharacterBasedMethod("GetContainer")
	DataStore:SetCharacterBasedMethod("GetContainers")
	DataStore:SetCharacterBasedMethod("GetContainerInfo")
	DataStore:SetCharacterBasedMethod("GetContainerSize")
	DataStore:SetCharacterBasedMethod("GetColoredContainerSize")
	DataStore:SetCharacterBasedMethod("GetContainerItemCount")
	DataStore:SetCharacterBasedMethod("GetNumBagSlots")
	DataStore:SetCharacterBasedMethod("GetNumFreeBagSlots")
	DataStore:SetCharacterBasedMethod("GetNumBankSlots")
	DataStore:SetCharacterBasedMethod("GetNumFreeBankSlots")
	
	if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
		-- Retail only
		DataStore:SetCharacterBasedMethod("IterateContainerSlots")
		DataStore:SetCharacterBasedMethod("GetNumPurchasedBankSlots")
		DataStore:SetCharacterBasedMethod("GetVoidStorageItem")
		DataStore:SetCharacterBasedMethod("GetKeystoneName")
		DataStore:SetCharacterBasedMethod("GetKeystoneLevel")
		DataStore:SetCharacterBasedMethod("ToggleBankType")
		DataStore:SetCharacterBasedMethod("IsBankType")
		DataStore:SetCharacterBasedMethod("GetBankType")
		DataStore:SetCharacterBasedMethod("GetBankTypes")
	else
		-- Non-retail only
		DataStore:SetCharacterBasedMethod("IterateBags")
		DataStore:SetCharacterBasedMethod("SearchBagsForItem")
	end
	
	-- Classic stops here
	if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then return end
	
	-- Retail + Wrath
	DataStore:SetGuildCommCallbacks(commPrefix, GuildCommCallbacks)
	DataStore:SetGuildBasedMethod("GetGuildBankItemCount")
	DataStore:SetGuildBasedMethod("GetGuildBankTab")
	DataStore:SetGuildBasedMethod("GetGuildBankTabName")
	DataStore:SetGuildBasedMethod("IterateGuildBankSlots")
	DataStore:SetGuildBasedMethod("GetGuildBankTabIcon")
	DataStore:SetGuildBasedMethod("GetGuildBankTabItemCount")
	DataStore:SetGuildBasedMethod("GetGuildBankTabLastUpdate")
	DataStore:SetGuildBasedMethod("GetGuildBankMoney")
	DataStore:SetGuildBasedMethod("GetGuildBankFaction")
	DataStore:SetGuildBasedMethod("ImportGuildBankTab")

	addon:RegisterMessage("DATASTORE_ANNOUNCELOGIN", OnAnnounceLogin)
	addon:RegisterMessage("DATASTORE_GUILD_MEMBER_OFFLINE", OnGuildMemberOffline)
	addon:RegisterComm(commPrefix, DataStore:GetGuildCommHandler())
end

function addon:OnEnable()
	-- manually update bags 0 to 5, then register the event, this avoids reacting to the flood of BAG_UPDATE events at login
	for bagID = 0, COMMON_NUM_BAG_SLOTS do
		ScanBag(bagID)
	end

	-- Only for Classic & BC, scan the keyring
	if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE and HasKey() then
		ScanBag(-2)
	end
	
	addon:RegisterEvent("BAG_UPDATE", OnBagUpdate)
	addon:RegisterEvent("BANKFRAME_OPENED", OnBankFrameOpened)
	
	-- disable bag updates during multi sell at the AH
	addon:RegisterEvent("AUCTION_HOUSE_SHOW", OnAuctionHouseShow)
	
	-- Classic stops here
	if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then return end
	
	-- Retail + Wrath
	addon:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", OnPlayerInteractionManagerFrameShow)
	addon:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", OnPlayerInteractionManagerFrameHide)
		
	if WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC or WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC then
		-- Wrath only .. and exit
		addon:RegisterEvent("GUILDBANKFRAME_OPENED", OnGuildBankFrameOpened)
		return
	end
	
	-- Retail only
	addon:RegisterEvent("PLAYER_ALIVE", OnPlayerAlive)
	addon:RegisterEvent("PLAYERREAGENTBANKSLOTS_CHANGED", OnPlayerReagentBankSlotsChanged)
	addon:RegisterEvent("WEEKLY_REWARDS_UPDATE", OnWeeklyRewardsUpdate)
end

function addon:OnDisable()
	
	-- All versions
	addon:UnregisterEvent("BAG_UPDATE")
	addon:UnregisterEvent("BANKFRAME_OPENED")
	addon:UnregisterEvent("AUCTION_HOUSE_SHOW")	
	
	if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then return end
	
	-- Retail + Wrath
	addon:UnregisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")	
	addon:UnregisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
	
	if WOW_PROJECT_ID == WOW_PROJECT_BURNING_CRUSADE_CLASSIC or WOW_PROJECT_ID == WOW_PROJECT_WRATH_CLASSIC then
		-- Wrath only .. and exit
		addon:UnregisterEvent("GUILDBANKFRAME_OPENED")
		return 
	end
	
	-- Retail only
	addon:UnregisterEvent("PLAYER_ALIVE")
	addon:UnregisterEvent("PLAYERREAGENTBANKSLOTS_CHANGED")
	addon:UnregisterEvent("WEEKLY_REWARDS_UPDATE")	
end
