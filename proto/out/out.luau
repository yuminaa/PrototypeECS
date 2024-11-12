--!native
--!optimize 2
--!strict

_G.__YUMINA_CONFIG = { DEBUG_MODE = false, PROFILING_MODE = false }

type Signal<T...> = {
	_head: Connection<T...>?,
	Connect: (self: Signal<T...>, fn: (...any) -> ()) -> Connection<T...>,
	Fire: (self: Signal<T...>, ...any) -> (),
	Wait: (self: Signal<T...>) -> ...any,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> ()
}

type Connection<T...> = {
	Connected: boolean,
	_signal: Signal<T...>,
	_fn: (T...) -> (),
	_next: Connection<T...>?,
	_prev: Connection<T...>?,
	Disconnect: (self: Connection<T...>) -> (),
	Reconnect: (self: Connection<T...>) -> ()
}

local freeThreads: { thread } = {}

local function runCallback<T...>(callback:(T...) -> (), thread, ...: T...): ()
	callback(...)
	table.insert(freeThreads, thread)
end

local function yielder(): ()
	while true do
		runCallback(coroutine.yield())
	end
end

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect<T...>(self: Connection<T...>): ()
	if not self.Connected then 
		return 
	end

	self.Connected = false
	local next = self._next
	local prev = self._prev

	if next then
		next._prev = prev 
	end
	if prev then
		prev._next = next
	end

	if self._signal._head == self then
		self._signal._head = next
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.Connect<T...>(self: Signal<T...>, fn: (T...) -> ()): Connection<T...>
	local head = self._head
	local cn2 = setmetatable({
		Connected = true,
		_signal = self,
		_fn = fn,
		_next = head,
		_prev = nil
	}, Connection) :: any

	if head then 
		head._prev = cn2
	end
	self._head = cn2

	return cn2 :: any
end

function Signal.Fire<T...>(self: Signal<T...>, ...: T...): ()
	local cn = self._head
	while cn do
		if cn.Connected then
			local thread
			if #freeThreads > 0 then
				thread = freeThreads[#freeThreads]
				freeThreads[#freeThreads] = nil
			else
				thread = coroutine.create(yielder)
				coroutine.resume(thread)
			end
			coroutine.resume(thread, cn._fn, thread, ...)
		end
		cn = cn._next
	end
end

function Signal.Wait<T...>(self: Signal<T...>): T...
	local thread = coroutine.running()
	local cnn
	cnn = self:Connect(function(...): ()
		cnn:Disconnect()
		local success, err = coroutine.resume(thread, ...)
		if not success then
			error(string.format("Wait callback error: %s", err), 2)
		end
	end)
	return coroutine.yield()
end

function Signal.Once<T...>(self: Signal<T...>, fn: (...any) -> ()): Connection<T...>
	local cnn
	cnn = self:Connect(function(...): ()
		cnn:Disconnect()
		fn(...)
	end)
	return cnn
end

function Signal.DisconnectAll<T...>(self: Signal<T...>)
	local cnn = self._head
	while cnn do
		cnn:Disconnect()
		cnn = cnn._next
	end
end

function Signal.Destroy<T...>(self: Signal<T...>)
	self:DisconnectAll()
	setmetatable(self, nil)
end

function Signal.new<T...>(): Signal<T...>
	return setmetatable({
		_head = nil,
	}, Signal) :: any
end

type EntityId = number
type ComponentId = number
type Generation = number
export type Archetype = {
	bitmasks: { [number]: number },
	entities: { [number]: EntityId },
	entityRow: { [EntityId]: number },
	componentData: { [ComponentId]: { [number]: any } },
	entityCount: number,
	dirtyFlags: number
}
type MoveCommand = {
	source: Archetype,
	destination: Archetype,
	moves: { [number]: { entityId: EntityId, fromRow: number, toRow: number } },
	moveCount: number
}
type TransitionKey = number
type TransitionInfo = {
	source: Archetype,
	destination: Archetype,
	sharedComponents: { ComponentId },
	addedComponents: { ComponentId },
	removedComponents: { ComponentId },
	frequency: number
}
type ArchetypeEdgeCache = {
	[TransitionKey]: {
		to: Archetype,
		transition: TransitionInfo
	}
}
type QueryCache = {
	archetypes: { Archetype },
	includeBitmasks: { number },
	excludeBitmasks: { number },
	components: { ComponentId }
}

local CONFIG = _G.__YUMINA_CONFIG
local DEBUG_MODE = CONFIG ~= nil and CONFIG.DEBUG_MODE or false
local PROFILING_MODE = CONFIG.PROFILING_MODE or false

local ENTITY_MASK: number = 0x00FFFFFF
local GENERATION_SHIFT: number = 0x18
local MAX_GENERATION: number = 0xFF

local BITS_PER_MASK = 32
local NUM_BITMASKS = 2

local DIRTY_ADDITION: number = 0x1
local DIRTY_REMOVAL: number = 0x2
local DIRTY_UPDATE: number = 0x4

local ERROR_TYPE = {
	INVALID_ENTITY = "INVALID_ENTITY",
	INVALID_COMPONENT = "INVALID_COMPONENT", 
	INVALID_OPERATION = "INVALID_OPERATION",
	ARCHETYPE_ERROR = "ARCHETYPE_ERROR",
	QUERY_ERROR = "QUERY_ERROR",
	TRANSITION_ERROR = "TRANSITION_ERROR",
	MEMORY_ERROR = "MEMORY_ERROR"
}

local Tools = {}
Tools.Debugger = {}
Tools.Profiler = {}
Tools.Profiler._metrics = {}
Tools.Profiler._startTimes = {}
Tools.Profiler._enabled = false

function Tools.Debugger.Log(category: string, message: string, context: any?): ()
	if not DEBUG_MODE then 
		return 
	end
	print(string.format("[Yumina:%s] %s %s", 
		category,
		message,
		context and (" (" .. tostring(context) .. ")") or ""
		))
end

function Tools.Debugger.ThrowError(category: string, message: string, context: any?): ()
	if not DEBUG_MODE then 
		return 
	end
	error(string.format("[Yumina:%s] %s %s", 
		category,
		message,
		context and ("(" .. tostring(context) .. ")") or ""
		), 2)
end

function Tools.Debugger.AssertArgument(condition: boolean, errorType: string, message: string)
	if not DEBUG_MODE then 
		return 
	end
	if not condition then
		error(string.format("[Yumina:%s] %s", errorType, message), 2)
	end
end

function Tools.Profiler.Begin()
	if not PROFILING_MODE then 
		return 
	end
	Tools.Profiler._enabled = true
	Tools.Profiler._metrics = {}
	Tools.Profiler._startTimes = {}
end

function Tools.Profiler.Mark(category: string, label: string)
	if not Tools.Profiler._enabled then 
		return 
	end

	local key = category .. ":" .. label
	Tools.Profiler._startTimes[key] = os.clock()
end

function Tools.Profiler.End(category: string, label: string)
	if not Tools.Profiler._enabled then return end

	local key = category .. ":" .. label
	local startTime = Tools.Profiler._startTimes[key]
	if not startTime then return end

	local duration = (os.clock() - startTime) * 1000

	Tools.Profiler._metrics[key] = Tools.Profiler._metrics[key] or {
		count = 0,
		totalTime = 0,
		minTime = math.huge,
		maxTime = 0
	}

	local metric = Tools.Profiler._metrics[key]
	metric.count += 1
	metric.totalTime += duration
	metric.minTime = math.min(metric.minTime, duration)
	metric.maxTime = math.max(metric.maxTime, duration)
end

function Tools.Profiler.GetReport(): string
	if not Tools.Profiler._enabled then return "" end

	local lines = {"Performance Report:"}
	for key, metric in Tools.Profiler._metrics do
		table.insert(lines, string.format(
			"%s: %d calls, %.2fms avg (%.2f min, %.2f max)",
			key,
			metric.count,
			metric.totalTime / metric.count,
			metric.minTime,
			metric.maxTime
			))
	end

	return table.concat(lines, "\n")
end

local function ValidateComponentId(componentId: number): ()
	Tools.Debugger.AssertArgument(typeof(componentId) == "number", 
		ERROR_TYPE.INVALID_COMPONENT, 
		"Component ID must be a number"
	)
	Tools.Debugger.AssertArgument(componentId > 0 and componentId <= BITS_PER_MASK * NUM_BITMASKS, 
		ERROR_TYPE.INVALID_COMPONENT, 
		string.format(" Component ID must be between 1 and %d", BITS_PER_MASK * NUM_BITMASKS)
	)
end

local function ValidateEntity(self: Yumina, entityId: EntityId): number
	Tools.Debugger.AssertArgument(
		typeof(entityId) == "number",
		ERROR_TYPE.INVALID_ENTITY,
		"Entity ID must be a number"
	)

	local id = bit32.band(entityId, ENTITY_MASK)
	local generation = bit32.rshift(entityId, GENERATION_SHIFT)
	local currentGen = self._generations[id]

	if not currentGen then
		Tools.Debugger.ThrowError(
			ERROR_TYPE.INVALID_ENTITY,
			"Entity does not exist",
			tostring(id)
		)
	end
	if currentGen ~= generation then
		Tools.Debugger.ThrowError(
			ERROR_TYPE.INVALID_ENTITY,
			string.format("Invalid generation (expected %d, got %d)", 
				currentGen, 
				generation
			),
			tostring(id)
		) 
	end
	return id
end

local function GetBitmaskIndex(componentId: number): number
	return math.floor((componentId - 1) / BITS_PER_MASK) + 1
end

local function GetBitPosition(componentId: number): number
	return (componentId - 1) % BITS_PER_MASK
end

local function CreateEmptyBitmasks(): { number }
	local bitmasks = table.create(NUM_BITMASKS)
	for i = 1, NUM_BITMASKS do
		bitmasks[i] = 0
	end
	return bitmasks
end

local function GetArchetypeKey(bitmasks: { number }): number
	return bitmasks[1] + (bitmasks[2] * 0x100000000)
end

local function GetTransitionKey(sourceBitmasks: { number }, destBitmasks: { number }): number
	local source1 = bit32.band(sourceBitmasks[1], 0xFFFF)
	local source2 = bit32.band(sourceBitmasks[2], 0xFFFF)
	local dest1 = bit32.band(destBitmasks[1], 0xFFFF)
	local dest2 = bit32.band(destBitmasks[2], 0xFFFF)

	return source1 + 
		(source2 * 0x10000) + 
		(dest1 * 0x100000000) + 
		(dest2 * 0x1000000000000)
end

local function GetQueryKey(includeBitmasks: {number}, excludeBitmasks: {number}): number
	local include1 = bit32.band(includeBitmasks[1], 0xFFFF)
	local include2 = bit32.band(includeBitmasks[2], 0xFFFF)
	local exclude1 = bit32.band(excludeBitmasks[1], 0xFFFF)
	local exclude2 = bit32.band(excludeBitmasks[2], 0xFFFF)

	return include1 + 
		(include2 * 0x10000) + 
		(exclude1 * 0x100000000) + 
		(exclude2 * 0x1000000000000)
end

local Yumina = {}
Yumina.__index = Yumina

export type Yumina = typeof(setmetatable({
	_archetypeIndex = {} :: { [number]: Archetype },
	_entityIndex = {} :: { [EntityId]: Archetype },
	_freeList = {} :: { EntityId},
	_generations = {} :: { [EntityId]: Generation },
	_nextId = 1 :: EntityId,
	_edgeCache = {} :: ArchetypeEdgeCache,
	_queryCache = {} :: { [number]: QueryViewer },
	_pendingMoves = {} :: { MoveCommand },

	OnSet = Signal.new(),
	OnTransition = Signal.new(),
	OnCached = Signal.new(),
	OnCleanup = Signal.new(),
}, Yumina))

function Yumina.new(): Yumina
	local self = setmetatable({}, Yumina)
	self._archetypeIndex = {}
	self._entityIndex = {}
	self._freeList = {}
	self._generations = {}
	self._nextId = 1
	self._edgeCache = {}
	self._queryCache = {}
	self._pendingMoves = {}

	self.OnSet = Signal.new()
	self.OnTransition = Signal.new()
	self.OnCached = Signal.new()
	self.OnCleanup = Signal.new()
	return self
end

function Yumina.Entity(self: Yumina): EntityId
	local entityId: EntityId
	local generation: Generation

	if #self._freeList > 0 then
		entityId = table.remove(self._freeList, #self._freeList) :: number
		generation = self._generations[entityId] + 1
		if generation > MAX_GENERATION then
			generation = 0
		end
	else
		entityId = self._nextId
		self._nextId += 1
		generation = 0
	end

	self._generations[entityId] = generation
	return bit32.bor(bit32.lshift(generation, GENERATION_SHIFT), entityId)
end

function Yumina.Despawn(self: Yumina, encodedId: EntityId): ()
	local entityId = bit32.band(encodedId, ENTITY_MASK)
	local generation = bit32.rshift(encodedId, GENERATION_SHIFT)
	if self._generations[entityId] ~= generation then
		return
	end

	local archetype = self._entityIndex[entityId]
	if archetype then
		local row = archetype.entityRow[entityId]
		if row == archetype.entityCount then
			for _, componentArray in archetype.componentData do
				componentArray[row] = nil
			end
		else
			local lastEntity = archetype.entities[archetype.entityCount]
			archetype.entities[row] = lastEntity
			archetype.entityRow[lastEntity] = row

			for _, componentArray in archetype.componentData do
				componentArray[row] = componentArray[archetype.entityCount]
				componentArray[archetype.entityCount] = nil
			end
		end

		archetype.entityCount -= 1
		archetype.entities[archetype.entityCount + 1] = nil
		archetype.entityRow[entityId] = nil

		if archetype.entityCount == 0 then
			self._archetypeIndex[GetArchetypeKey(archetype.bitmasks)] = nil
		end
		archetype.dirtyFlags = bit32.bor(archetype.dirtyFlags, DIRTY_REMOVAL)
	end

	self._entityIndex[entityId] = nil
	self._freeList[#self._freeList + 1] = entityId
	self._generations[entityId] = (self._generations[entityId] + 1) % MAX_GENERATION
end

function Yumina.__CreateArchetype(self: Yumina, bitmasks: { number }): Archetype
	local archetype = {
		bitmasks = table.clone(bitmasks),
		componentData = {},
		entities = {},
		entityRow = {},
		entityCount = 0,
		dirtyFlags = DIRTY_ADDITION
	}

	local key = GetArchetypeKey(bitmasks)
	self._archetypeIndex[key] = archetype
	return archetype
end

local function CreateTransitionInfo(self: Yumina, source: Archetype, destination: Archetype): TransitionInfo
	local transitionKey = GetTransitionKey(source.bitmasks, destination.bitmasks)
	local cachedTransition = self._edgeCache[transitionKey]
	if cachedTransition then
		return cachedTransition.transition
	end
	local sharedComponents = {}
	local addedComponents = {}
	local removedComponents = {}
	for maskIndex = 1, NUM_BITMASKS do
		local sourceMask = source.bitmasks[maskIndex]
		local destMask = destination.bitmasks[maskIndex]
		local diffMask = bit32.bxor(sourceMask, destMask)
		
		if diffMask ~= 0 then
			local bit = 1
			local baseComponent = (maskIndex - 1) * BITS_PER_MASK + 1
			while diffMask ~= 0 do
				if bit32.band(diffMask, 1) ~= 0 then
					local componentId = baseComponent + bit32.countrz(bit)
					local inSource = bit32.band(sourceMask, bit) ~= 0
					local inDest = bit32.band(destMask, bit) ~= 0
					
					if inSource and inDest then
						table.insert(sharedComponents, componentId)
					elseif inSource then
						table.insert(removedComponents, componentId)
					else
						table.insert(addedComponents, componentId)
					end
				end
				diffMask = bit32.rshift(diffMask, 1)
				bit = bit32.lshift(bit, 1)
			end
		end
	end

	local transition = {
		source = source,
		destination = destination,
		sharedComponents = sharedComponents,
		addedComponents = addedComponents,
		removedComponents = removedComponents,
		frequency = 0
	}

	self._edgeCache[transitionKey] = { to = destination, transition = transition }
	self.OnCached:Fire("Transition", transitionKey)
	return transition
end

function Yumina.__FastPathMove<T>(
	self: Yumina,
	entity: EntityId,
	source: Archetype,
	destination: Archetype,
	transition: TransitionInfo,
	newComponentsData: { [ComponentId]: T }?
)
	local toRow = destination.entityCount + 1
	local fromRow = source.entityRow and source.entityRow[entity]
	if fromRow then
		for _, componentId in transition.sharedComponents do
			local srcColumn = source.componentData[componentId]
			if not destination.componentData[componentId] then
				destination.componentData[componentId] = {}
			end
			local dstColumn = destination.componentData[componentId]

			if #transition.sharedComponents > 3 then
				table.move(srcColumn, fromRow, fromRow, toRow, dstColumn)
			else
				dstColumn[toRow] = srcColumn[fromRow]
			end
			srcColumn[fromRow] = nil
		end
	end

	if newComponentsData then
		for _, componentId in transition.addedComponents do
			if not destination.componentData[componentId] then
				destination.componentData[componentId] = {}
			end
			destination.componentData[componentId][toRow] = newComponentsData[componentId]
		end
	end

	destination.entities[toRow] = entity
	destination.entityRow[entity] = toRow
	destination.entityCount += 1
	if fromRow and fromRow < source.entityCount then
		local lastEntity = source.entities[source.entityCount]
		source.entities[fromRow] = lastEntity
		source.entityRow[lastEntity] = fromRow
		for _, componentId in transition.sharedComponents do
			local column = source.componentData[componentId]
			if #transition.sharedComponents > 3 then
				table.move(column, source.entityCount, source.entityCount, fromRow)
			else
				column[fromRow] = column[source.entityCount]
			end
			column[source.entityCount] = nil
		end
	end

	if source.entityCount then
		source.entityCount -= 1
		source.entities[source.entityCount + 1] = nil
		source.entityRow[entity] = nil
		source.dirtyFlags = bit32.bor(source.dirtyFlags, DIRTY_REMOVAL)
	end

	self._entityIndex[entity] = destination
	destination.dirtyFlags = bit32.bor(destination.dirtyFlags, DIRTY_ADDITION)

	self.OnTransition:Fire(entity, source, destination)
end

function Yumina.Has(self: Yumina, entity: EntityId, component: ComponentId): any?
	local entityId = bit32.band(entity, ENTITY_MASK)
	local generation = bit32.rshift(entity, GENERATION_SHIFT)
	if self._generations[entityId] ~= generation then
		error("[Yumina]: Invalid entity reference", 0)
	end

	local archetype = self._entityIndex[entityId]
	if not archetype then
		return nil
	end
	local componentArray = archetype.componentData[component]
	if not componentArray then
		return nil
	end

	return componentArray[archetype.entityRow[entityId]]
end

function Yumina.Set<T>(self: Yumina, entity: EntityId, component: ComponentId, data: T): Yumina
	ValidateComponentId(component)
	Tools.Debugger.AssertArgument(
		data ~= nil,
		ERROR_TYPE.INVALID_COMPONENT,
		string.format("Component %d data cannot be nil", component)
	)
	local entityId = ValidateEntity(self, entity)
	local currentArchetype = self._entityIndex[entityId]
	if not currentArchetype then
		local bitmasks = CreateEmptyBitmasks()
		local maskIndex = GetBitmaskIndex(component)
		local bitPosition = GetBitPosition(component)
		bitmasks[maskIndex] = bit32.lshift(1, bitPosition)

		local newArchetype = self:__CreateArchetype(bitmasks)
		local transition = CreateTransitionInfo(self, { 
			bitmasks = CreateEmptyBitmasks(),
			entities = {},
			entityRow = {},
			componentData = {},
			entityCount = 0,
			dirtyFlags = 0
		}, newArchetype)

		self:__FastPathMove(entityId, currentArchetype or {
			bitmasks = CreateEmptyBitmasks(),
			entities = {},
			entityRow = {},
			componentData = {},
			entityCount = 0,
			dirtyFlags = 0
		}, newArchetype, transition, {[component] = data})

		self.OnSet:Fire(entity, component, data)
		return self
	end

	local maskIndex = GetBitmaskIndex(component)
	local bitPosition = GetBitPosition(component)
	local mask = bit32.lshift(1, bitPosition)

	if bit32.band(currentArchetype.bitmasks[maskIndex], mask) ~= 0 then
		local row = currentArchetype.entityRow[entityId]
		local currentValue = currentArchetype.componentData[component][row]
		if currentValue == data then
			return self
		end
		currentArchetype.componentData[component][row] = data
		currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_UPDATE)
		self.OnSet:Fire(entity, component, data)
		return self
	end

	local newBitmasks = table.clone(currentArchetype.bitmasks)
	newBitmasks[maskIndex] = bit32.bor(newBitmasks[maskIndex], mask)

	local newKey = GetArchetypeKey(newBitmasks)
	local targetArchetype = self._archetypeIndex[newKey]
	if not targetArchetype then
		targetArchetype = self:__CreateArchetype(newBitmasks)
	end

	local transitionKey = GetTransitionKey(currentArchetype.bitmasks, newBitmasks)
	local edgeInfo = self._edgeCache[transitionKey]
	if not edgeInfo then
		local transition = CreateTransitionInfo(self, currentArchetype, targetArchetype)
		edgeInfo = { to = targetArchetype, transition = transition }
		self._edgeCache[transitionKey] = edgeInfo
	end

	edgeInfo.transition.frequency += 1
	self:__FastPathMove(entityId, currentArchetype, targetArchetype, edgeInfo.transition, {[component] = data})
	self.OnSet:Fire(entity, component, data)

	return self
end

function Yumina.Remove(self: Yumina, entity: EntityId, component: ComponentId): Yumina
	local entityId = bit32.band(entity, ENTITY_MASK)
	local generation = bit32.rshift(entity, GENERATION_SHIFT)

	if self._generations[entityId] ~= generation then
		error("[Yumina]: Invalid entity reference", 0)
	end

	local currentArchetype = self._entityIndex[entity]
	if not currentArchetype then
		return self
	end

	local maskIndex = GetBitmaskIndex(component)
	local bitPosition = GetBitPosition(component)

	if bit32.band(currentArchetype.bitmasks[maskIndex], bit32.lshift(1, bitPosition)) == 0 then
		return self
	end

	local newBitmasks = table.clone(currentArchetype.bitmasks)
	newBitmasks[maskIndex] = bit32.band(
		newBitmasks[maskIndex], 
		bit32.bnot(bit32.lshift(1, bitPosition))
	)

	local targetArchetype = self._archetypeIndex[GetArchetypeKey(newBitmasks)]
	if not targetArchetype then
		targetArchetype = self:__CreateArchetype(newBitmasks)
	end

	local transitionKey = GetTransitionKey(currentArchetype.bitmasks, newBitmasks)
	local edgeInfo = self._edgeCache[transitionKey]

	if not edgeInfo then
		local transition = CreateTransitionInfo(self, currentArchetype, targetArchetype)
		edgeInfo = { to = targetArchetype, transition = transition }
		self._edgeCache[transitionKey] = edgeInfo
	end

	edgeInfo.transition.frequency += 1
	self:__FastPathMove(entity, currentArchetype, targetArchetype, edgeInfo.transition)

	return self
end

local QueryViewer = {}
QueryViewer.__index = QueryViewer

export type QueryViewer = typeof(setmetatable({
	archetypes = {} :: { Archetype },
	components = {} :: { ComponentId },
	includeBitmasks = {} :: { number },
	excludeBitmasks = {} :: { number },
	ecs = nil :: Yumina?
}, QueryViewer))

function QueryViewer.new(q: {
	archetypes: { Archetype },
	components: { ComponentId },
	includeBitmasks: { number },
	excludeBitmasks: { number },
	ecs: Yumina
	}): QueryViewer
	return setmetatable(q, QueryViewer)
end

function QueryViewer.With(self: QueryViewer, componentIds: { ComponentId }): QueryViewer
	if not _G.__YUMINA_DEBUG then
		Tools.Debugger.AssertArgument(
			#componentIds > 0,
			ERROR_TYPE.QUERY_ERROR,
			"Must provide at least one component ID"
		)
	end

	local newIncludeBitmasks = table.clone(self.includeBitmasks)
	local filteredArchetypes = {}
	local componentSet = {}
	for _, existingId in self.components do
		componentSet[existingId] = true
	end

	for _, componentId in componentIds do
		local maskIndex = GetBitmaskIndex(componentId)
		local bitPosition = GetBitPosition(componentId)
		newIncludeBitmasks[maskIndex] = bit32.bor(
			newIncludeBitmasks[maskIndex],
			bit32.lshift(1, bitPosition)
		)

		if not componentSet[componentId] then
			table.insert(self.components, componentId)
		end
	end
	for _, archetype in self.archetypes do
		local matches = true
		for maskIndex = 1, NUM_BITMASKS do
			if bit32.band(archetype.bitmasks[maskIndex], newIncludeBitmasks[maskIndex]) ~= newIncludeBitmasks[maskIndex] then
				matches = false
				break
			end
		end
		if matches then
			filteredArchetypes[archetype] = true
		end
	end

	local result = {}
	for archetype in filteredArchetypes do
		table.insert(result, archetype)
	end

	self.archetypes = result
	self.includeBitmasks = newIncludeBitmasks
	return self
end

function QueryViewer.Without(self: QueryViewer, componentIds: { ComponentId }): QueryViewer
	local newExcludeBitmasks = table.clone(self.excludeBitmasks)
	for _, componentId in componentIds do
		local maskIndex = GetBitmaskIndex(componentId)
		local bitPosition = GetBitPosition(componentId)
		newExcludeBitmasks[maskIndex] = bit32.bor(
			newExcludeBitmasks[maskIndex],
			bit32.lshift(1, bitPosition)
		)
	end

	local filteredArchetypes = {}
	for _, archetype in self.archetypes do
		local valid = true
		for maskIndex = 1, NUM_BITMASKS do
			if bit32.band(archetype.bitmasks[maskIndex], newExcludeBitmasks[maskIndex]) ~= 0 then
				valid = false
				break
			end
		end
		if valid then
			table.insert(filteredArchetypes, archetype)
		end
	end

	self.archetypes = filteredArchetypes
	self.excludeBitmasks = newExcludeBitmasks
	return self
end

function QueryViewer.Any(self: QueryViewer, componentIds: { ComponentId }): QueryViewer
	local anyBitmasks = CreateEmptyBitmasks()
	for _, componentId in componentIds do
		local maskIndex = GetBitmaskIndex(componentId)
		local bitPosition = GetBitPosition(componentId)
		anyBitmasks[maskIndex] = bit32.bor(
			anyBitmasks[maskIndex],
			bit32.lshift(1, bitPosition)
		)
		local exists = false
		for _, existingId in self.components do
			if existingId == componentId then
				exists = true
				break
			end
		end
		if not exists then
			table.insert(self.components, componentId)
		end
	end

	local filteredArchetypes = {}
	for _, archetype in self.archetypes do
		local hasAny = false
		for maskIndex = 1, NUM_BITMASKS do
			if bit32.band(archetype.bitmasks[maskIndex], anyBitmasks[maskIndex]) ~= 0 then
				hasAny = true
				break
			end
		end
		if hasAny then
			table.insert(filteredArchetypes, archetype)
		end
	end

	self.archetypes = filteredArchetypes
	return self
end

function QueryViewer.View(self: QueryViewer): () -> (EntityId?, ...any?)
	local snapshotArchetypes = table.clone(self.archetypes) -- // Copy the arch in case of race conditions
	local snapshotData = {}

	for _, archetype in snapshotArchetypes do
		local archetypeSnapshot = {
			entityCount = archetype.entityCount,
			entities = table.clone(archetype.entities),
			entityRow = table.clone(archetype.entityRow),
			components = {}
		}
		for _, componentId in self.components do
			if archetype.componentData[componentId] then
				archetypeSnapshot.components[componentId] = table.clone(archetype.componentData[componentId])
			end
		end

		snapshotData[archetype] = archetypeSnapshot
	end

	local currentArchIndex = 1
	local currentEntityIndex = 1
	local currentArchetype = snapshotArchetypes[currentArchIndex]

	local numComponents = #self.components
	if numComponents == 0 then
		return function(): (EntityId?, ...any?)
			return nil 
		end
	end

	if numComponents == 1 then
		return function(): (EntityId?, ...any?)
			while currentArchetype do
				local snapshot = snapshotData[currentArchetype]
				if currentEntityIndex <= snapshot.entityCount then
					local entityId = snapshot.entities[currentEntityIndex]
					local value = snapshot.components[self.components[1]][snapshot.entityRow[entityId]]
					currentEntityIndex += 1
					return entityId, value
				end
				currentArchIndex += 1
				currentArchetype = snapshotArchetypes[currentArchIndex]
				currentEntityIndex = 1
			end
			return nil
		end
	elseif numComponents == 2 then
		return function(): (EntityId?, ...any?)
			while currentArchetype do
				local snapshot = snapshotData[currentArchetype]
				if currentEntityIndex <= snapshot.entityCount then
					local entityId = snapshot.entities[currentEntityIndex]
					local row = snapshot.entityRow[entityId]
					currentEntityIndex += 1
					return entityId, 
						snapshot.components[self.components[1]][row],
						snapshot.components[self.components[2]][row]
				end
				currentArchIndex += 1
				currentArchetype = snapshotArchetypes[currentArchIndex]
				currentEntityIndex = 1
			end
			return nil
		end
	end

	local componentValues = table.create(numComponents)
	return function(): (EntityId?, ...any?)
		while currentArchetype do
			local snapshot = snapshotData[currentArchetype]
			if currentEntityIndex <= snapshot.entityCount then
				local entityId = snapshot.entities[currentEntityIndex]
				local row = snapshot.entityRow[entityId]
				for i = 1, numComponents do
					componentValues[i] = snapshot.components[self.components[i]][row]
				end
				currentEntityIndex += 1
				return entityId, table.unpack(componentValues, 1, numComponents)
			end
			currentArchIndex += 1
			currentArchetype = snapshotArchetypes[currentArchIndex]
			currentEntityIndex = 1
		end
		return nil
	end
end

function Yumina.Query(self: Yumina, components: { ComponentId }): QueryViewer
	local queryBitmasks = CreateEmptyBitmasks()
	local result = {}

	for _, componentId in components do
		ValidateComponentId(componentId)
		local maskIndex = GetBitmaskIndex(componentId)
		local bitPosition = GetBitPosition(componentId)
		queryBitmasks[maskIndex] = bit32.bor(
			queryBitmasks[maskIndex],
			bit32.lshift(1, bitPosition)
		)
	end

	local queryKey = GetQueryKey(queryBitmasks, CreateEmptyBitmasks())
	local cachedQuery = self._queryCache[queryKey]
	if cachedQuery then
		local isValid = true
		for _, archetype in cachedQuery.archetypes do
			if bit32.band(archetype.dirtyFlags, DIRTY_UPDATE) ~= 0 then
				isValid = false
				break
			end
		end

		if isValid then
			return cachedQuery
		end
	end

	for _, archetype in self._archetypeIndex do
		local matches = true
		for i = 1, NUM_BITMASKS do
			if bit32.band(archetype.bitmasks[i], queryBitmasks[i]) ~= queryBitmasks[i] then
				matches = false
				break
			end
		end
		if matches then
			table.insert(result, archetype)
		end
	end

	local query = QueryViewer.new({
		archetypes = result,
		includeBitmasks = queryBitmasks,
		excludeBitmasks = CreateEmptyBitmasks(),
		components = components,
		ecs = self
	})

	self._queryCache[queryKey] = query
	self.OnCached:Fire("Query", queryKey)

	return query
end

-- // TODO: Need a smarter way to clean up the cache
-- // Plan: Remove all the cache entries that are not frequently used [<= 60%] of the most frequent 
--      // and keep the most frequently used ones
function Yumina.Cleanup(self: Yumina): ()
	if self._nextId >= ENTITY_MASK then
		Tools.Debugger.ThrowError(
			ERROR_TYPE.MEMORY_ERROR,
			"Entity ID space exhausted"
		)
	end

	self._queryCache = {}
	if #self._edgeCache > 1200 then
		local transitions = {}
		for key, info in self._edgeCache do
			table.insert(transitions, {
				key = key, 
				freq = info.transition.frequency
			})
		end

		table.sort(transitions, function(a, b): boolean
			return a.freq > b.freq 
		end)

		local newCache = {}
		for i = 1, math.min(500, #transitions) do
			local key = transitions[i].key
			newCache[key] = self._edgeCache[key]
		end

		self._edgeCache = newCache
	end
	self.OnCleanup:Fire()
end

return {
	Yumina = Yumina.new(),
	Tools = Tools
}