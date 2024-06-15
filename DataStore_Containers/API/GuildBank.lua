--[[ 
This file keeps track of a character's guild bank (Retail + Wrath only)
--]]

local addonName, addon = ...
local thisCharacter
local guilds

local DataStore, TableInsert, TableConcat, format, strsplit = DataStore, table.insert, table.concat, format, strsplit
local pairs, wipe, tonumber, type, time, date = pairs, wipe, tonumber, type, time, date
local GetGuildInfo, GetGuildBankItemLink, GetGuildBankItemInfo, GetGuildBankTabInfo, GetGameTime, GetLocale = GetGuildInfo, GetGuildBankItemLink, GetGuildBankItemInfo, GetGuildBankTabInfo, GetGameTime, GetLocale
local GetGuildBankMoney, UnitFactionGroup, UnitName = GetGuildBankMoney, UnitFactionGroup, UnitName
local C_Container = C_Container

local bit64 = LibStub("LibBit64")

local commPrefix = "DS_Cont"		-- let's keep it a bit shorter than the addon name, this goes on a comm channel, a byte is a byte ffs :p
local guildMembers = {} 			-- hash table containing guild member info (tab timestamps)

-- Message types
local MSG_SEND_BANK_TIMESTAMPS				= 1	-- broacast at login
local MSG_BANK_TIMESTAMPS_REPLY				= 2	-- reply to someone else's login
local MSG_BANKTAB_REQUEST						= 3	-- request bank tab data ..
local MSG_BANKTAB_REQUEST_ACK					= 4	-- .. ack the request, tell the requester to wait
local MSG_BANKTAB_REQUEST_REJECTED			= 5	-- .. refuse the request
local MSG_BANKTAB_TRANSFER						= 6	-- .. or send the data

-- *** Utility functions ***
local function GetThisGuild()
	local guildID = DataStore:GetCharacterGuildID(DataStore.ThisCharKey)
	
	if guildID then
		guilds[guildID] = guilds[guildID] or {}				-- Create the guild
		guilds[guildID].Tabs = guilds[guildID].Tabs or {}	-- Create the tab container
		
		return guilds[guildID]
	end
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
			TableInsert(out, format("%d:%s:%d:%d:%d", tabID, tab.name, tab.ClientTime, tab.ServerHour, tab.ServerMinute))
		end
	end
	
	return TableConcat(out, "|")
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
	DataStore:Broadcast("DATASTORE_GUILD_BANKTABS_UPDATED", sender)
end

local function GetBankTab(tabID)
	local guild = GetThisGuild()
	if not guild or not tabID then return end

	-- Create the tab
	guild.Tabs[tabID] = guild.Tabs[tabID] or {}
	local tab = guild.Tabs[tabID]
	tab.items = tab.items or {}
	tab.links = tab.links or {}

	return guild.Tabs[tabID]
end

-- *** Scanning functions ***
local TAB_SIZE = 98

local function ScanGuildBankTab(tabID)
	local tab = GetBankTab(tabID)
	if not tab then return end

	wipe(tab.items)				-- clean existing tab data
	wipe(tab.links)
	
	local link, itemID

	for slotID = 1, TAB_SIZE do
		link = GetGuildBankItemLink(tabID, slotID)
		
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
			tab.items[slotID] = select(2, GetGuildBankItemInfo(tabID, slotID))
				+ bit64:LeftShift(itemID, 16)		-- bits 16+ : item ID
		end
	end

	DataStore:Broadcast("DATASTORE_CONTAINER_UPDATED", tabID, 3)		-- 3 = container type: Guild Bank Tab
end

local function ScanGuildBankTabInfo(tabID)
	local tab = GetBankTab(tabID)
	if not tab then return end

	tab.name, tab.icon = GetGuildBankTabInfo(tabID)
	tab.visitedBy = DataStore.ThisChar
	tab.ClientTime = time()
	tab.ClientDate = date(GetLocale() == "enUS" and "%m/%d/%Y" or "%d/%m/%Y")
	tab.ClientHour = tonumber(date("%H"))
	tab.ClientMinute = tonumber(date("%M"))
	tab.ServerHour, tab.ServerMinute = GetGameTime()
end


-- *** Event Handlers ***
local function OnGuildBankFrameClosed()
	addon:StopListeningTo("GUILDBANKBAGSLOTS_CHANGED")
	
	local guildName = GetGuildInfo("player")
	if guildName then
		DataStore:GuildBroadcast(commPrefix, MSG_SEND_BANK_TIMESTAMPS, GetBankTimestamps(guildName))
	end
end

local function OnGuildBankBagSlotsChanged()
	local currentTabID = GetCurrentGuildBankTab()
	
	ScanGuildBankTab(currentTabID)
	ScanGuildBankTabInfo(currentTabID)
end

local function OnGuildBankFrameOpened()
	addon:ListenTo("GUILDBANKBAGSLOTS_CHANGED", OnGuildBankBagSlotsChanged)
	
	local thisGuild = GetThisGuild()
	if thisGuild then
		thisGuild.money = GetGuildBankMoney()
		thisGuild.faction = UnitFactionGroup("player")
	end
end


-- ** Mixins **
local function _GetGuildBankItemCount(guild, searchedID)
	local count = 0
	
	for _, container in pairs(guild.Tabs) do
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
	
local function _GetGuildBankTab(guild, tabID)
	return guild.Tabs[tabID]
end
	
local function _GetGuildBankTabName(guild, tabID)
	if guild.Tabs and guild.Tabs[tabID] then
		return guild.Tabs[tabID].name
	end
end

local function _GetSlotInfo(bag, slotID)
	if not bag then return end

	local link = bag.links[slotID]
	local isBattlePet
	
	if link then
		isBattlePet = link:match("|Hbattlepet:")
	end
	
	local slot = bag.items[slotID]
	local itemID, count
	
	if slot then
		local pos = DataStore:GetItemCountPosition(slot)
		
		count = bit64:GetBits(slot, 0, pos)			-- bits 0-9 : item count (10 bits, up to 1024)
		itemID = bit64:RightShift(slot, pos)		-- bits 10+ : item ID
	end

	return itemID, link, count, isBattlePet	
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

local function _GetGuildBankTabItemCount(guild, tabID, searchedID)
	local count = 0
	local container = guild.Tabs[tabID]
	
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

local function _ImportGuildBankTab(guild, tabID, data)
	wipe(guild.Tabs[tabID])							-- clear existing data
	guild.Tabs[tabID] = data
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

local function _SendBankTabToGuildMember(member, tabName)
	-- send the actual content of a bank tab to a guild member
	local thisGuild = GetThisGuild()
	if not thisGuild then return end

	local tabID
	if guildMembers[member] then
		if guildMembers[member][tabName] then
			tabID = guildMembers[member][tabName].id
		end
	end	

	if tabID then
		DataStore:GuildWhisper(commPrefix, member, MSG_BANKTAB_TRANSFER, thisGuild.Tabs[tabID])
	end
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
		DataStore:GuildBroadcast(commPrefix, MSG_SEND_BANK_TIMESTAMPS, timestamps)
	end
end

local function OnGuildMemberOffline(self, member)
	guildMembers[member] = nil
	DataStore:Broadcast("DATASTORE_GUILD_BANKTABS_UPDATED", member)
end

local commCallbacks = {
	[MSG_SEND_BANK_TIMESTAMPS] = function(sender, timestamps)
			if sender ~= UnitName("player") then						-- don't send back to self
				local timestamps = GetBankTimestamps()
				if timestamps then
					DataStore:GuildWhisper(commPrefix, sender, MSG_BANK_TIMESTAMPS_REPLY, timestamps)		-- reply by sending my own data..
				end
			end
			SaveBankTimestamps(sender, timestamps)
		end,
	[MSG_BANK_TIMESTAMPS_REPLY] = function(sender, timestamps)
			SaveBankTimestamps(sender, timestamps)
		end,
	[MSG_BANKTAB_REQUEST] = function(sender, tabName)
			-- trigger the event only, actual response (ack or not) must be handled by client addons
			DataStore:GuildWhisper(commPrefix, sender, MSG_BANKTAB_REQUEST_ACK)		-- confirm that the request has been received
			DataStore:Broadcast("DATASTORE_BANKTAB_REQUESTED", sender, tabName)
		end,
	[MSG_BANKTAB_REQUEST_ACK] = function(sender)
			DataStore:Broadcast("DATASTORE_BANKTAB_REQUEST_ACK", sender)
		end,
	[MSG_BANKTAB_REQUEST_REJECTED] = function(sender)
			DataStore:Broadcast("DATASTORE_BANKTAB_REQUEST_REJECTED", sender)
		end,
	[MSG_BANKTAB_TRANSFER] = function(sender, data)
			local guildName = GetGuildInfo("player")
			local guild	= GetThisGuild()
			
			for tabID, tab in pairs(guild.Tabs) do
				if tab.name == data.name then	-- this is the tab being updated
					_ImportGuildBankTab(guild, tabID, data)
					DataStore:Broadcast("DATASTORE_BANKTAB_UPDATE_SUCCESS", sender, guildName, data.name, tabID)
					DataStore:GuildBroadcast(commPrefix, MSG_SEND_BANK_TIMESTAMPS, GetBankTimestamps(guildName))
				end
			end
		end,
}


DataStore:OnAddonLoaded(addonName, function() 
	DataStore:RegisterTables({
		addon = addon,
		guildTables = {
			["DataStore_Containers_Guilds"] = {
				GetGuildBankItemCount = _GetGuildBankItemCount,
				GetGuildBankTab = _GetGuildBankTab,
				GetGuildBankTabName = _GetGuildBankTabName,
				IterateGuildBankSlots = _IterateGuildBankSlots,
				GetGuildBankTabIcon = function(guild, tabID) return guild.Tabs[tabID].icon end,
				GetGuildBankTabItemCount = _GetGuildBankTabItemCount,
				GetGuildBankTabLastUpdate = function(guild, tabID) return guild.Tabs[tabID].ClientTime end,
				GetGuildBankMoney = function(guild) return guild.money end,
				GetGuildBankFaction = function(guild) return guild.faction end,
				ImportGuildBankTab = _ImportGuildBankTab,
			},
		},
	})
	
	guilds = DataStore_Containers_Guilds
	
	DataStore:RegisterMethod(addon, "GetGuildMemberBankTabInfo", _GetGuildMemberBankTabInfo)
	DataStore:RegisterMethod(addon, "RequestGuildMemberBankTab", function(member, tabName)
		DataStore:GuildWhisper(commPrefix, member, MSG_BANKTAB_REQUEST, tabName)
	end)
	DataStore:RegisterMethod(addon, "RejectBankTabRequest", function(member)
		DataStore:GuildWhisper(commPrefix, member, MSG_BANKTAB_REQUEST_REJECTED)
	end)
	DataStore:RegisterMethod(addon, "SendBankTabToGuildMember", _SendBankTabToGuildMember)
	DataStore:RegisterMethod(addon, "GetGuildBankTabSuppliers", function() return guildMembers end)
	
	DataStore:SetGuildCommCallbacks(commPrefix, commCallbacks)
	DataStore:ListenTo("DATASTORE_ANNOUNCELOGIN", OnAnnounceLogin)
	DataStore:ListenTo("DATASTORE_GUILD_MEMBER_OFFLINE", OnGuildMemberOffline)
	DataStore:OnGuildComm(commPrefix, DataStore:GetGuildCommHandler())
end)

DataStore:OnPlayerLogin(function()
	addon:ListenTo("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(event, interactionType)
		if interactionType == Enum.PlayerInteractionType.GuildBanker then 
			OnGuildBankFrameOpened()
		end
	end)
	
	addon:ListenTo("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(event, interactionType)
		if interactionType == Enum.PlayerInteractionType.GuildBanker then 
			OnGuildBankFrameClosed()
		end
	end)
	
	if WOW_PROJECT_ID == WOW_PROJECT_CATACLYSM_CLASSIC then
		addon:ListenTo("GUILDBANKFRAME_OPENED", OnGuildBankFrameOpened)
	end
end)
