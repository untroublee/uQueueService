--Services--
local TeleportService = game:GetService("TeleportService")
local RunService = game:GetService("RunService")
local Plrs = game:GetService("Players")
local MSS = game:GetService("MemoryStoreService")

--Modules--
local Janitor = require(script:WaitForChild("Janitor"))
local Signal = require(script:WaitForChild("Signal"))
local Retry = require(script:WaitForChild("Retry"))

--Private--
export type QueueParams = {
	MinimumPlayers: number?,
	MaximumPlayers: number?,
	PlaceId: number?,
	Countdown: number?,
	TeleportData: any?,
	Id: (string|number)?
}

local defaultData = {
	params = {
		map = "Baseplate",
		rounds = 3,
		players = 1
	},
	PlayerAmt = 1 -- Don't remove this line. You can edit the value based on how many players you test with
} --Edit this to test your game place with custom teleport data

local queueNum = 0

local TpDataStore = MSS:GetHashMap("TpData")

local IsGamePlace = script:GetAttribute("IsGamePlace")

local tpOptions = Instance.new("TeleportOptions")
tpOptions.ShouldReserveServer = true

local function getFromHashMemory(MemoryStore:MemoryStoreHashMap, key, retries)
	return Retry(3,1,function()
		MemoryStore:GetAsync(key)
	end)
end

local function teleportQueue(queue,placeId,tpData)
	local success, err = pcall(function()
		table.insert(tpData["PlayerAmt"],#queue)
		local result:TeleportAsyncResult = TeleportService:TeleportAsync(placeId,queue,tpOptions)

		TpDataStore:SetAsync(result.PrivateServerId,tpData,300)

		return result.PrivateServerId
	end)
	if not success then warn(err) end
	return success
end

local function getQueueFromUniqueId(id:(string|number), cache:{})
	local toReturn = nil
	for i, queue in pairs(cache) do
		if queue["_uniqueId"][1] == id then
			toReturn = queue
		end
	end

	return toReturn
end

local function getWholeNum(num)
	if num % 10 == 0 then
		return num / 10
	end
end

local function numToHex(num:number)
	return string.format("%X",num)
end

--Public--
local QueueService = {}
local Queue = {}
local QueueCache = {}

-- Creates a new Queue object.
function QueueService.new(queueParams:Types.QueueParams)
	queueNum += 1
	local newJanitor = Janitor.new()

	local QueueObj = {
		PlayerAdded = Signal.new(),
		PlayerRemoved = Signal.new(),
		Initiated = Signal.new(),
		CountTick = Signal.new(),

		minPlayers = queueParams["MinimumPlayers"],
		maxPlayers = queueParams["MaximumPlayers"],
		placeId = queueParams["PlaceId"],
		countdown = queueParams["Countdown"],
		tpData = queueParams["TeleportData"],
		id = queueParams["Id"],
		ticking = false,
		queued = {},


		_uniqueId = {numToHex(queueNum)},
		_janitor = newJanitor
	}

	table.freeze(QueueObj._uniqueId)

	QueueObj._janitor:Add(QueueObj.PlayerAdded,"Destroy")
	QueueObj._janitor:Add(QueueObj.PlayerRemoved,"Destroy")
	QueueObj._janitor:Add(QueueObj.Initiated,"Destroy")
	QueueObj._janitor:Add(QueueObj.CountTick,"Destroy")

	if QueueObj.maxPlayers == nil then
		warn("Maximum players not provided. Defaulting to 50")
		QueueObj.maxPlayers = 50
	end
	if QueueObj.countdown == nil then
		warn("Countdown time not provided. Defaulting to 5 seconds")
		QueueObj.countdown = 5
	end
	if QueueObj.minPlayers == nil then
		warn("Minimum players not provided. Defaulting to 1")
		QueueObj.minPlayers = 1
	end

	local left = Plrs.PlayerRemoving:Connect(function(plr)
		local index = table.find(QueueObj.queued,plr)
		if index then
			QueueObj.PlayerRemoved:Fire(plr)
			table.remove(QueueObj.queued,index)
		else
			warn("Could not remove player from queue: Player not found in queue!")
		end
	end)

	local heartbeat = RunService.Heartbeat:Connect(function()
		if #QueueObj.queued < QueueObj.minPlayers then
			QueueObj.ticking = false
		end

		--print(#object.queued < object.minPlayers, #object.queued, object.minPlayers)
		if #QueueObj.queued >= QueueObj.minPlayers and not QueueObj.ticking then
			task.spawn(function()
				QueueObj.ticking = true

				for i = QueueObj.countdown * 10,0,-1 do
					wait(0.1)
					--print(object.ticking,i)
					if not QueueObj.ticking then break end
					local num = getWholeNum(i)
					if num then
						QueueObj.CountTick:Fire(num)
					end
				end

				if not QueueObj.ticking then return end

				QueueObj.Initiated:Fire()

				--print(object.placeId)
				if RunService:IsStudio() then
					warn("Running Studio. Player will not be teleported")
				else
					if QueueObj.placeId then
						teleportQueue(QueueObj.queued,QueueObj.placeId, QueueObj.tpData)
					end
				end
			end)
		end
	end)

	heartbeat = newJanitor:Add(heartbeat,"Disconnect")
	left = newJanitor:Add(left,"Disconnect")

	table.insert(QueueCache,QueueObj)

	return setmetatable(QueueObj,{
		__index = Queue,
		__tostring = function() print("Queue") end
	})
end

--[[ 
Fetches the teleport data of the place if it is marked as a game place. 
Enable that by going into the attributes of the uQueueService module and
enabling the IsGamePlace attribute. 
]]
function QueueService:GetTeleportData()
	if not IsGamePlace then 
		warn("Game must be a game place to get teleport data!") 
		return 
	end

	local tpData
	local key = game.PrivateServerId

	if key ~= "" then 
		tpData = getFromHashMemory(TpDataStore,key)
	else
		warn("Server not created from a queue. Using default data (Edit in uQueueService module)")
		tpData = defaultData -- This is just used for testing your game
	end

	return tpData
end

-- Returns a table of all the queues currently active.
function QueueService:GetQueues()
	return QueueCache
end

-- Returns a Queue based on its ID optionally given in the QueueParams parameter of .new()
function QueueService:GetQueueById(id:string | number)
	local toReturn = nil
	for i, queue in pairs(QueueCache) do
		if queue["id"] == id then
			toReturn = queue 
		end
	end

	return toReturn
end

-- Queue Obj Methods --

-- Adds a player to the queue. Does basic checks to make sure the player can fit.
function Queue:AddPlayer(plr:Player)
	local queued = self.queued
	if plr then
		if not table.find(queued,plr) then
			if #queued < self.maxPlayers then
				print("Inserting player..")
				table.insert(queued,plr)
				print(queued)
				self.PlayerAdded:Fire(plr)
			else
				warn("Queue is full!","Amount of players queued:",#queued,"Maximum players:",self.maxPlayers)
			end
		else
			warn("Player is already in queue!")
		end
	else
		warn("Attempt to add player to queue but player was nil!")
	end
end

-- Removes the player from the queue. Does basic checks to make sure the player can be removed properly.
function Queue:RemovePlayer(plr)
	local queued = self.queued
	if plr then
		local plrIndex = table.find(queued,plr)
		if plrIndex then 
			table.remove(queued,plrIndex)
			self.PlayerRemoved:Fire(plr)
		else
			warn("Attempt to remove player from queue but player was not found in queue!")
		end
	else
		warn("Attempt to remove player from queue but player was nil")
	end
end
-- Optionally use this function to initiate the queue early. Will teleport with teleport data if provided
function Queue:Initiate()
	local toReturn
	if #self.queued > 0 then
		if self.placeId then
			local success = teleportQueue(self.queued,self.placeId, self.tpData)
			if not success then
				warn("Players could not be teleported")
				toReturn = false
			else
				print("Players teleported successfully")
				toReturn = true
			end
		elseif not self.placeId then
			toReturn = true
		end
	end

	if toReturn then
		self.Initiated:Fire()
	end
	return toReturn
end

-- Destroys the queue
function Queue:Destroy()
	self._janitor:Cleanup()

	table.remove(QueueCache,table.find(QueueCache,getQueueFromUniqueId(self._uniqueId,QueueCache)))
	setmetatable(self,nil)
	table.clear(self)
end

return QueueService