--[[
Container-related enumerations
--]]

local enum = DataStore.Enum

enum.ContainerIDs = {
	MainBankSlots = Enum.BagIndex.Characterbanktab or -1,		-- bag id of the main bank slots (originally 28, now 98)
	Keyring = Enum.BagIndex.Keyring or -2,				-- keyring bag id (non-retail)
	VoidStorageTab1 = -5,	-- bag id for the void storage (arbitrary)
	VoidStorageTab2 = -6,	-- bag id for the void storage (arbitrary)
	ReagentBank = -7,  -- this should have been -3 before 11.2?
	ReagentBag = 5,
}
