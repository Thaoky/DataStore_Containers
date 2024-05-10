--[[
Container-related enumerations
--]]

local enum = DataStore.Enum

enum.ContainerIDs = {
	MainBankSlots = -1,		-- bag id of the 28 main bank slots
	Keyring = -2,				-- keyring bag id (non-retail)
	VoidStorageTab1 = -5,	-- bag id for the void storage (arbitrary)
	VoidStorageTab2 = -6,	-- bag id for the void storage (arbitrary)
	ReagentBank = -7,
	ReagentBag = 5,
}
