if WOW_PROJECT_ID ~= WOW_PROJECT_MAINLINE then return end

--[[ 
This file keeps track of bank types marks set on a character
--]]

local addonName, addon = ...
local bankTypes

local DataStore, TableInsert, TableConcat = DataStore, table.insert, table.concat
local enum = DataStore.Enum
local bit64 = LibStub("LibBit64")


-- ** Mixins **
local function _ToggleBankType(characterID, bankType)
	local types = enum.BankTypes
	
	if bankType >= types.Minimum and bankType <= types.Maximum then
		local info = bankTypes[characterID] or 0
		
		-- toggle the appropriate bit for this bank type
		bankTypes[characterID] = bit64:ToggleBit(info, bankType - 1) 
	end
end

local function _IsBankType(characterID, bankType)
	local info = bankTypes[characterID] or 0
	
	return bit64:TestBit(info, bankType - 1)
end

local function _GetBankType(characterID)
	return bankTypes[characterID] or 0
end

local function _GetBankTypes(characterID)
	local info = bankTypes[characterID]
	if not info then return ""	end
	
	local bankTypeLabels = {}
	
	local types = enum.BankTypes
	local labels = enum.BankTypesLabels
	
	-- loop through all types
	for i = types.Minimum, types.Maximum do
		-- add label if bit is set
		if bit64:TestBit(info, i - 1) then
			TableInsert(bankTypeLabels, labels[i])
		end
	end
	
	return TableConcat(bankTypeLabels, ", "), bankTypeLabels
end

AddonFactory:OnAddonLoaded(addonName, function() 
	DataStore:RegisterTables({
		addon = addon,
		characterIdTables = {
			["DataStore_Containers_BankTypes"] = {
				ToggleBankType = _ToggleBankType,
				IsBankType = _IsBankType,
				GetBankType = _GetBankType,
				GetBankTypes = _GetBankTypes,
			},
		}
	})
	
	bankTypes = DataStore_Containers_BankTypes
end)
