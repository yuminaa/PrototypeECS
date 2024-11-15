--!native
--!optimize 2
--!strict

type EntityId = number
type ComponentId = number
type Generation = number

type Edge = {
	from: Archetype,
	to: Archetype,
	next: Edge?,
	prev: Edge?,
	componentId: ComponentId,
	transition: TransitionInfo
}

export type Archetype = {
	bitmasks: { [number]: number },
	entities: { [number]: EntityId },
	entityRow: { [EntityId]: number },
	componentData: { [ComponentId]: { [number]: any } },
	entityCount: number,
	dirtyFlags: number,
	addEdges: { [ComponentId]: Edge },
	removeEdges: { [ComponentId]: Edge },
	edgeRefs: {
		next: Edge?,
		prev: Edge?
	}
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

type Signal<T...> = {
	_head: Connection<T...>?,
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> (),
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
	local cn = setmetatable({
		Connected = true,
		_signal = self,
		_fn = fn,
		_next = head,
		_prev = nil
	}, Connection) :: any

	if head then 
		head._prev = cn
	end
	self._head = cn

	return cn :: any
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
	local cn
	cn = self:Connect(function(...): ()
		cn:Disconnect()
		local success, err = coroutine.resume(thread, ...)
		if not success then
			error(string.format("Wait callback error: %s", err), 2)
		end
	end)
	return coroutine.yield()
end

function Signal.Once<T...>(self: Signal<T...>, fn: (...any) -> ()): Connection<T...>
	local cn
	cn = self:Connect(function(...): ()
		cn:Disconnect()
		fn(...)
	end)
	return cn
end

function Signal.DisconnectAll<T...>(self: Signal<T...>)
	local cn = self._head
	while cn do
		cn:Disconnect()
		cn = cn._next
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

local CONFIG = _G.__YUMINA_CONFIG or { DEBUG_MODE = false, PROFILING_MODE = false }
local DEBUG_MODE = CONFIG.DEBUG_MODE or false
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

local bit32 = bit32

local Tools = {}
Tools.Debugger = {}
Tools.Profiler = {}
Tools.Profiler._metrics = {}
Tools.Profiler._startTimes = {}
Tools.Profiler._enabled = CONFIG.PROFILING_MODE or false

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
	if not Tools.Profiler._enabled then 
		return "" 
	end

	local lines = { "Performance Report:" }
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
	return bit32.rshift(componentId - 1, 5) + 1
end

local function GetBitPosition(componentId: number): number
	return bit32.band(componentId - 1, BITS_PER_MASK - 1)
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

local function GetQueryKey(includeBitmasks: { number }, excludeBitmasks: { number }): number
	local include1 = bit32.band(includeBitmasks[1], 0xFFFF)
	local include2 = bit32.band(includeBitmasks[2], 0xFFFF)
	local exclude1 = bit32.band(excludeBitmasks[1], 0xFFFF)
	local exclude2 = bit32.band(excludeBitmasks[2], 0xFFFF)

	return include1 + 
		(include2 * 0x10000) + 
		(exclude1 * 0x100000000) + 
		(exclude2 * 0x1000000000000)
end

local function memmove<T>(dest: { any }, destOffset: number, src: { any }, srcOffset: number, count: number): ()
	if count <= 8 then
		for i = 0, count-1 do
			dest[destOffset + i] = src[srcOffset + i]
		end
		return
	end

	if count <= 32 then
		table.move(src, srcOffset, srcOffset + count - 1, destOffset, dest)
		return
	end

	local buf = buffer.create(count * 8)
	for i = 0, count - 1, 8 do
		buffer.writef64(buf, i * 8, src[srcOffset + i])
	end

	for i = 0, count - 1, 8 do
		dest[destOffset + i] = buffer.readf64(buf, i * 8)
	end
end

--[[
    @class Yumina
    @description Core ECS implementation with archetype-based storage
]]
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

	OnSet = Signal.new() :: Signal<EntityId, ComponentId, any>,
	OnTransition = Signal.new() :: Signal<EntityId, Archetype, Archetype>,
	OnCached = Signal.new() :: Signal<"Transition" | "Query", number>,
	OnCleanup = Signal.new() :: Signal<()>,
}, Yumina))

--[[
    @function Yumina.new
    @description Creates a new ECS instance
    @return Yumina New ECS instance
]]
function Yumina.new(): Yumina
	local self = setmetatable({}, Yumina)
	self._archetypeIndex = {}
	self._entityIndex = {}
	self._freeList = {}
	self._generations = {}
	self._nextId = 1
	self._edgeCache = {}
	self._queryCache = {}

	self.OnSet = Signal.new() :: Signal<EntityId, ComponentId, any>
	self.OnTransition = Signal.new() :: Signal<EntityId, Archetype, Archetype>
	self.OnCached = Signal.new() :: Signal<"Transition" | "Query", number>
	self.OnCleanup = Signal.new() :: Signal<()>
	return self
end

--[[
    @function Yumina.Entity
    @description Creates a new entity with a unique ID and generation
    @return EntityId Encoded entity ID containing both ID and generation
]]
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

--[[
    @function Yumina.Despawn
    @description Removes an entity and all its components
    @param encodedId EntityId The encoded entity ID to despawn
]]
function Yumina.Despawn(self: Yumina, encodedId: EntityId): ()
	local entityId = bit32.band(encodedId, ENTITY_MASK)
	local generation = bit32.rshift(encodedId, GENERATION_SHIFT)
	if self._generations[entityId] ~= generation then
		return
	end

	local archetype = self._entityIndex[entityId]
	if not archetype then
		return
	end

	local row = archetype.entityRow[entityId]
	local lastRow = archetype.entityCount

	if row == lastRow then
		for _, componentArray in archetype.componentData do
			componentArray[row] = nil
		end
	else
		local lastEntity = archetype.entities[lastRow]
		archetype.entities[row] = lastEntity
		archetype.entityRow[lastEntity] = row
		for _, componentArray in archetype.componentData do
			componentArray[row] = componentArray[lastRow]
			componentArray[lastRow] = nil
		end
	end

	archetype.entityCount -= 1
	archetype.entities[lastRow] = nil
	archetype.entityRow[entityId] = nil

	if archetype.entityCount == 0 then
		self._archetypeIndex[GetArchetypeKey(archetype.bitmasks)] = nil
	end

	archetype.dirtyFlags = bit32.bor(archetype.dirtyFlags, DIRTY_REMOVAL)
	self._entityIndex[entityId] = nil
	table.insert(self._freeList, entityId)
	self._generations[entityId] = (self._generations[entityId] + 1) % MAX_GENERATION
end

function Yumina.__CreateArchetype(self: Yumina, bitmasks: { number }): Archetype
	local archetype = {
		bitmasks = bitmasks,
		componentData = {},
		entities = {},
		entityRow = {},
		entityCount = 0,
		dirtyFlags = DIRTY_ADDITION,
		addEdges = {},
		removeEdges = {},
		edgeRefs = { next = nil, prev = nil }
	} :: Archetype

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

	local shared = table.create(4)
	local added = table.create(1)
	local sharedCount = 0
	local addedCount = 0

	for maskIndex = 1, NUM_BITMASKS do
		local sourceMask = source.bitmasks[maskIndex]
		local destMask = destination.bitmasks[maskIndex]
		local baseComponent = (maskIndex - 1) * BITS_PER_MASK

		local sharedMask = bit32.band(sourceMask, destMask)
		while sharedMask ~= 0 do
			local bit = bit32.countrz(sharedMask)
			sharedCount += 1
			shared[sharedCount] = baseComponent + bit + 1
			sharedMask = bit32.band(sharedMask, bit32.bnot(bit32.lshift(1, bit)))
		end

		local addedMask = bit32.band(bit32.bnot(sourceMask), destMask)
		while addedMask ~= 0 do
			local bit = bit32.countrz(addedMask)
			addedCount += 1
			added[addedCount] = baseComponent + bit + 1
			addedMask = bit32.band(addedMask, bit32.bnot(bit32.lshift(1, bit)))
		end
	end

	local transition = {
		source = source,
		destination = destination,
		sharedComponents = table.move(shared, 1, sharedCount, 1, table.create(sharedCount)),
		addedComponents = table.move(added, 1, addedCount, 1, table.create(addedCount)),
		removedComponents = {},
		frequency = 0
	}

	self._edgeCache[transitionKey] = { to = destination, transition = transition }
	self.OnCached:Fire("Transition", transitionKey)
	return transition
end

function Yumina.__AddEdge(self: Yumina, from: Archetype, to: Archetype, componentId: ComponentId): Edge
	local edge = {
		from = from,
		to = to,
		next = nil,
		prev = nil,
		componentId = componentId,
		transition = CreateTransitionInfo(self, from, to)
	} :: Edge

	if to.edgeRefs.next then
		edge.next = to.edgeRefs and to.edgeRefs.next
		to.edgeRefs.next.prev = edge
	end
	to.edgeRefs.next = edge
	edge.prev = from.edgeRefs.prev

	from.addEdges[componentId] = edge
	to.removeEdges[componentId] = edge

	return edge
end

function Yumina.__FastPathMove(
	self: Yumina,
	entity: EntityId,
	source: Archetype,
	destination: Archetype,
	transition: TransitionInfo,
	newComponentsData: { [ComponentId]: any }?
)
	local toRow = destination.entityCount + 1
	local fromRow = source.entityRow[entity]
	local sourceCount = source.entityCount
	local sharedCount = #transition.sharedComponents

	local dstComponents = destination.componentData
	local srcComponents = source.componentData

	if fromRow then
		local expectedSize = toRow + 32
		for _, componentId in transition.sharedComponents do
			if not dstComponents[componentId] then
				dstComponents[componentId] = table.create(expectedSize)
			end
		end

		local needsBackfill = fromRow < sourceCount
		local lastEntity = needsBackfill and source.entities[sourceCount]

		local firstComponentId = transition.sharedComponents[1]
		if firstComponentId then
			local firstSrcColumn = srcComponents[firstComponentId]
			local firstValue = firstSrcColumn and firstSrcColumn[fromRow]
			local useBuffer = firstValue and type(firstValue) == "number"

			if useBuffer and sharedCount > 3 then
				local buf = buffer.create(8)
				for _, componentId in transition.sharedComponents do
					local srcColumn = srcComponents[componentId]
					local dstColumn = dstComponents[componentId]
					local value = srcColumn[fromRow]

					if typeof(value) == "number" then
						if needsBackfill and lastEntity then
							local lastValue = srcColumn[sourceCount]
							if typeof(lastValue) == "number" then
								buffer.writef64(buf, 0, lastValue)
								memmove(dstColumn, toRow, srcColumn, fromRow, 1)
								srcColumn[fromRow] = buffer.readf64(buf, 0)
							else
								dstColumn[toRow] = value
								if needsBackfill then
									srcColumn[fromRow] = lastValue
								end
							end
						else
							memmove(dstColumn, toRow, srcColumn, fromRow, 1)
						end
					else
						dstColumn[toRow] = value
						if needsBackfill and lastEntity then
							srcColumn[fromRow] = srcColumn[sourceCount]
						end
					end
					srcColumn[sourceCount] = nil
				end
			else
				for _, componentId in transition.sharedComponents do
					local srcColumn = srcComponents[componentId]
					local dstColumn = dstComponents[componentId]

					if needsBackfill and lastEntity then
						table.move(srcColumn, fromRow, fromRow, toRow, dstColumn)
						table.move(srcColumn, sourceCount, sourceCount, fromRow)
					else
						table.move(srcColumn, fromRow, fromRow, toRow, dstColumn)
					end
					srcColumn[sourceCount] = nil
				end
			end
		end

        local lastE = lastEntity :: EntityId
		if needsBackfill and lastEntity then
			source.entities[fromRow] = lastE
			source.entityRow[lastE] = fromRow
		end

		source.entityCount = sourceCount - 1
		source.entities[sourceCount] = nil
		source.entityRow[entity] = nil
		source.dirtyFlags = bit32.bor(source.dirtyFlags, DIRTY_REMOVAL)
	end

	if newComponentsData then
		for _, componentId in transition.addedComponents do
			if not dstComponents[componentId] then
				dstComponents[componentId] = table.create(toRow + 32)
			end
			dstComponents[componentId][toRow] = newComponentsData[componentId]
		end
	end

	destination.entities[toRow] = entity
	destination.entityRow[entity] = toRow
	destination.entityCount = toRow
	destination.dirtyFlags = bit32.bor(destination.dirtyFlags, DIRTY_ADDITION)
	self._entityIndex[entity] = destination

	self.OnTransition:Fire(entity, source, destination)
end

--[[
    @function Yumina.Has
    @description Checks if an entity has a specific component
    @param entity EntityId The entity to check
    @param component ComponentId The component ID to check for
    @return any? The component data if found, nil otherwise
]]
function Yumina.Has(self: Yumina, entity: EntityId, component: ComponentId): any?
	local entityId = ValidateEntity(self, entity)
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

--[[
    @function Yumina.Set
    @description Sets a component value for an entity
    @param entity EntityId Target entity
    @param component ComponentId Component ID to set
    @param data T Component data
    @return Yumina Self for chaining
]]
function Yumina.Set<T>(self: Yumina, entity: EntityId, component: ComponentId, data: T): Yumina
	local entityId = if DEBUG_MODE then ValidateEntity(self, entity) else entity
	local currentArchetype = self._entityIndex[entityId]

	if not currentArchetype then
		local maskIndex = GetBitmaskIndex(component)
		local bitMask = bit32.lshift(1, GetBitPosition(component))
		local newArchetype = self:__CreateArchetype({
			maskIndex == 1 and bitMask or 0,
			maskIndex == 2 and bitMask or 0
		})

		newArchetype.componentData[component] = table.create(32)
		newArchetype.componentData[component][1] = data
		newArchetype.entities[1] = entityId
		newArchetype.entityRow[entityId] = 1
		newArchetype.entityCount = 1
		self._entityIndex[entityId] = newArchetype
		self.OnSet:Fire(entity, component, data)
		return self
	end

	local maskIndex = GetBitmaskIndex(component)
	local mask = bit32.lshift(1, GetBitPosition(component))

	if bit32.band(currentArchetype.bitmasks[maskIndex], mask) ~= 0 then
		local row = currentArchetype.entityRow[entityId]
		currentArchetype.componentData[component][row] = data
		currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_UPDATE)
		self.OnSet:Fire(entity, component, data)
		return self
	end

	local edge = currentArchetype.addEdges[component]
	if edge then
		self:__FastPathMove(entityId, currentArchetype, edge.to, edge.transition, { [component] = data })
		self.OnSet:Fire(entity, component, data)
		return self
	end

	local newBits = { currentArchetype.bitmasks[1], currentArchetype.bitmasks[2] }
	newBits[maskIndex] = bit32.bor(newBits[maskIndex], mask)

	local targetArchetype = self._archetypeIndex[GetArchetypeKey(newBits)]
	if not targetArchetype then
		targetArchetype = self:__CreateArchetype(newBits)
	end

	local edg2 = self:__AddEdge(currentArchetype, targetArchetype, component)
	self:__FastPathMove(entityId, currentArchetype, targetArchetype, edg2.transition, { [component] = data })
	self.OnSet:Fire(entity, component, data)
	return self
end

--[[
    @function Yumina.Remove  
    @description Removes a component from an entity
    @param entity EntityId Target entity
    @param component ComponentId Component to remove
    @return Yumina Self for chaining
]]
function Yumina.Remove(self: Yumina, entity: EntityId, component: ComponentId): Yumina
	local entityId = ValidateEntity(self, entity)
	local currentArchetype = self._entityIndex[entityId]
	if not currentArchetype then
		return self
	end

	local maskIndex = GetBitmaskIndex(component)
	local mask = bit32.lshift(1, GetBitPosition(component))
	if bit32.band(currentArchetype.bitmasks[maskIndex], mask) == 0 then
		return self
	end

	local edge = currentArchetype.removeEdges[component]
	if edge then
		self:__FastPathMove(entityId, currentArchetype, edge.to, edge.transition)
		return self
	end

	local newBits = {currentArchetype.bitmasks[1], currentArchetype.bitmasks[2]} 
	newBits[maskIndex] = bit32.band(newBits[maskIndex], bit32.bnot(mask))

	local targetArchetype = self._archetypeIndex[GetArchetypeKey(newBits)]
	if not targetArchetype then
		targetArchetype = self:__CreateArchetype(newBits)
	end

	local edge2 = self:__AddEdge(targetArchetype, currentArchetype, component)
	self:__FastPathMove(entityId, currentArchetype, edge2.from, edge2.transition)
	return self
end

--[[
    @class QueryViewer
    @description Query iterator for filtered entity views
]]
local QueryViewer = {}
QueryViewer.__index = QueryViewer

export type QueryViewer = typeof(setmetatable({
	archetypes = {} :: { Archetype },
	components = {} :: { ComponentId },
	includeBitmasks = {} :: { number },
	excludeBitmasks = {} :: { number },
}, QueryViewer))

function QueryViewer.new(q: {
	archetypes: { Archetype },
	components: { ComponentId },
	includeBitmasks: { number },
	excludeBitmasks: { number },
	}): QueryViewer
	return setmetatable(q, QueryViewer)
end

--[[
    @function QueryViewer.With
    @description Adds required components to query
    @param componentIds { ComponentId } Components that must be present
    @return QueryViewer Self for chaining
]]
function QueryViewer.__With(self: QueryViewer, componentIds: { ComponentId }): QueryViewer
	if _G.__YUMINA_DEBUG then
		Tools.Debugger.AssertArgument(
			#componentIds > 0,
			ERROR_TYPE.QUERY_ERROR,
			"Must provide at least one component ID"
		)
	end

	local newIncludeBitmasks = self.includeBitmasks
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

--[[
    @function QueryViewer.Without  
    @description Excludes components from query
    @param componentIds { ComponentId } Components that must not be present
    @return QueryViewer Self for chaining
]]
function QueryViewer.__Without(self: QueryViewer, componentIds: { ComponentId }): QueryViewer
	local newExcludeBitmasks = self.excludeBitmasks
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

--[[
    @function QueryViewer.Any
    @description Matches entities with any of the specified components
    @param componentIds { ComponentId } Components to match any of
    @return QueryViewer Self for chaining
]]
function QueryViewer.__Any(self: QueryViewer, componentIds: { ComponentId }): QueryViewer
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

--[[
    @function QueryViewer.View
    @description Creates an iterator over matching entities
    @return function Iterator returning (EntityId, ...component values)
]]
function QueryViewer.View(self: QueryViewer): () -> (EntityId?, ...any?)
	if #self.components == 0 then
		return function() 
			return nil 
		end
	end

	local numComponents = #self.components
	local currentArchetype = self.archetypes[1]
	if not currentArchetype then 
		return function() 
			return nil 
		end 
	end
	local componentArrays = table.create(numComponents)
	local componentValues = table.create(numComponents)
	for i, componentId in self.components do
		componentArrays[i] = currentArchetype.componentData[componentId]
	end

	-- // Specialized iterators for different component counts
	-- // To avoid table unpacking overhead for the common case
	if numComponents == 1 then
		local componentId = self.components[1]
		local archIndex = 1
		local entityIndex = 1

		return function()
			while currentArchetype do
				if entityIndex <= currentArchetype.entityCount then
					local entityId = currentArchetype.entities[entityIndex]
					local value = componentArrays[1] and componentArrays[1][currentArchetype.entityRow[entityId]]
					entityIndex += 1
					return entityId, value
				end

				archIndex += 1
				currentArchetype = self.archetypes[archIndex]
				if currentArchetype then
					componentArrays[1] = currentArchetype.componentData[componentId]
				end
				entityIndex = 1
			end
			return nil
		end
	end

	if numComponents == 2 then
		local c1, c2 = self.components[1], self.components[2]
		local archIndex = 1
		local entityIndex = 1

		return function()
			while currentArchetype do
				if entityIndex <= currentArchetype.entityCount then
					local entityId = currentArchetype.entities[entityIndex]
					local row = currentArchetype.entityRow[entityId]
					entityIndex += 1
					return entityId,
                        componentArrays[1] and componentArrays[1][row],
                        componentArrays[2] and componentArrays[2][row]
				end

				archIndex += 1
				currentArchetype = self.archetypes[archIndex]
				if currentArchetype then
					componentArrays[1] = currentArchetype.componentData[c1]
					componentArrays[2] = currentArchetype.componentData[c2]
				end
				entityIndex = 1
			end
			return nil
		end
	end

	if numComponents == 3 then
		local c1, c2, c3 = self.components[1], self.components[2], self.components[3]
		local archIndex = 1
		local entityIndex = 1

		return function()
			while currentArchetype do
				if entityIndex <= currentArchetype.entityCount then
					local entityId = currentArchetype.entities[entityIndex]
					local row = currentArchetype.entityRow[entityId]
					entityIndex += 1
					return entityId,
                        componentArrays[1] and componentArrays[1][row],
                        componentArrays[2] and componentArrays[2][row],
                        componentArrays[3] and componentArrays[3][row]
				end

				archIndex += 1
				currentArchetype = self.archetypes[archIndex]
				if currentArchetype then
					componentArrays[1] = currentArchetype.componentData[c1]
					componentArrays[2] = currentArchetype.componentData[c2]
					componentArrays[3] = currentArchetype.componentData[c3]
				end
				entityIndex = 1
			end
			return nil
		end
	end

	if numComponents == 4 then
		local c1, c2, c3, c4 = self.components[1], self.components[2], self.components[3], self.components[4]
		local archIndex = 1
		local entityIndex = 1

		return function()
			while currentArchetype do
				if entityIndex <= currentArchetype.entityCount then
					local entityId = currentArchetype.entities[entityIndex]
					local row = currentArchetype.entityRow[entityId]
					entityIndex += 1
					return entityId,
                        componentArrays[1] and componentArrays[1][row],
                        componentArrays[2] and componentArrays[2][row],
                        componentArrays[3] and componentArrays[3][row],
                        componentArrays[4] and componentArrays[4][row]
				end

				archIndex += 1
				currentArchetype = self.archetypes[archIndex]
				if currentArchetype then
					componentArrays[1] = currentArchetype.componentData[c1]
					componentArrays[2] = currentArchetype.componentData[c2]
					componentArrays[3] = currentArchetype.componentData[c3]
					componentArrays[4] = currentArchetype.componentData[c4]
				end
				entityIndex = 1
			end
			return nil
		end
	end

	if numComponents == 5 then
		local c1, c2, c3, c4, c5 = self.components[1], self.components[2], self.components[3], self.components[4], self.components[5]
		local archIndex = 1
		local entityIndex = 1

		return function()
			while currentArchetype do
				if entityIndex <= currentArchetype.entityCount then
					local entityId = currentArchetype.entities[entityIndex]
					local row = currentArchetype.entityRow[entityId]
					entityIndex += 1
					return entityId,
                        componentArrays[1] and componentArrays[1][row],
                        componentArrays[2] and componentArrays[2][row],
                        componentArrays[3] and componentArrays[3][row],
                        componentArrays[4] and componentArrays[4][row],
                        componentArrays[5] and componentArrays[5][row]
				end

				archIndex += 1
				currentArchetype = self.archetypes[archIndex]
				if currentArchetype then
					componentArrays[1] = currentArchetype.componentData[c1]
					componentArrays[2] = currentArchetype.componentData[c2]
					componentArrays[3] = currentArchetype.componentData[c3]
					componentArrays[4] = currentArchetype.componentData[c4]
					componentArrays[5] = currentArchetype.componentData[c5]
				end
				entityIndex = 1
			end
			return nil
		end
	end

	local archIndex = 1
	local entityIndex = 1
	local components = self.components

	return function()
		while currentArchetype do
			if entityIndex <= currentArchetype.entityCount then
				local entityId = currentArchetype.entities[entityIndex]
				local row = currentArchetype.entityRow[entityId]
				for i = 1, numComponents do
					componentValues[i] = componentArrays[i] and componentArrays[i][row]
				end
				entityIndex += 1
				return entityId, table.unpack(componentValues, 1, numComponents)
			end

			archIndex += 1
			currentArchetype = self.archetypes[archIndex]
			if currentArchetype then
				for i = 1, numComponents do
					componentArrays[i] = currentArchetype.componentData[components[i]]
				end
			end
			entityIndex = 1
		end
		return nil
	end
end

--[[
    @function Yumina.Query
    @description Creates a query for entities matching component criteria
    @param components { ComponentId } Array of component IDs to query for
    @return QueryViewer Query iterator
]]
function Yumina.Query(self: Yumina, components: { ComponentId }): QueryViewer
	if #components == 1 then
		local componentId = components[1]
		if DEBUG_MODE then 
			ValidateComponentId(componentId)
		end

		local maskIndex = GetBitmaskIndex(componentId)
		local bitMask = bit32.lshift(1, GetBitPosition(componentId))
		local queryKey = bit32.band(maskIndex == 1 and bitMask or 0, 0xFFFF) + 
			(bit32.band(maskIndex == 2 and bitMask or 0, 0xFFFF) * 0x10000)

		local cached = self._queryCache[queryKey]
		if cached and bit32.band(cached.archetypes[1] and cached.archetypes[1].dirtyFlags or 0, DIRTY_UPDATE) == 0 then
			return cached
		end

		local result = {}
		for _, archetype in self._archetypeIndex do
			if bit32.band(archetype.bitmasks[maskIndex], bitMask) == bitMask then
				result[#result + 1] = archetype
			end
		end

		local query = QueryViewer.new({
			archetypes = result,
			includeBitmasks = { maskIndex == 1 and bitMask or 0, maskIndex == 2 and bitMask or 0 },
			excludeBitmasks = { 0, 0 },
			components = components,
		})
		self._queryCache[queryKey] = query
		self.OnCached:Fire("Query", queryKey)
		return query
	end

	if #components == 2 then
		local c1, c2 = components[1], components[2]
		if DEBUG_MODE then
			ValidateComponentId(c1)
			ValidateComponentId(c2)
		end

		local m1, m2 = GetBitmaskIndex(c1), GetBitmaskIndex(c2)
		local b1, b2 = bit32.lshift(1, GetBitPosition(c1)), bit32.lshift(1, GetBitPosition(c2))

		local mask1 = m1 == 1 and b1 or 0
		local mask2 = m2 == 1 and b2 or 0
		local queryKey = bit32.band(bit32.bor(mask1, mask2), 0xFFFF) + 
			(bit32.band(bit32.bor(m1 == 2 and b1 or 0, m2 == 2 and b2 or 0), 0xFFFF) * 0x10000)

		local cached = self._queryCache[queryKey]
		if cached and bit32.band(cached.archetypes[1] and cached.archetypes[1].dirtyFlags or 0, DIRTY_UPDATE) == 0 then
			return cached
		end

		local result = {}
		for _, archetype in self._archetypeIndex do
			if bit32.band(archetype.bitmasks[m1], b1) == b1 and
				bit32.band(archetype.bitmasks[m2], b2) == b2 then
				result[#result + 1] = archetype
			end
		end

		local query = QueryViewer.new({
			archetypes = result,
			includeBitmasks = {
				m1 == 1 and b1 or (m2 == 1 and b2 or 0),
				m1 == 2 and b1 or (m2 == 2 and b2 or 0)
			},
			excludeBitmasks = { 0, 0 },
			components = components,
			ecs = self
		})
		self._queryCache[queryKey] = query
		self.OnCached:Fire("Query", queryKey)
		return query
	end

	local queryBitmasks = { 0, 0 }
	for _, componentId in components do
		if DEBUG_MODE then
			ValidateComponentId(componentId)
		end
		local maskIndex = GetBitmaskIndex(componentId)
		queryBitmasks[maskIndex] = bit32.bor(
			queryBitmasks[maskIndex],
			bit32.lshift(1, GetBitPosition(componentId))
		)
	end

	local queryKey = GetQueryKey(queryBitmasks, { 0, 0 })
	local cached = self._queryCache[queryKey]
	if cached and bit32.band(cached.archetypes[1] and cached.archetypes[1].dirtyFlags or 0, DIRTY_UPDATE) == 0 then
		return cached
	end

	local result = {}
	for _, archetype in self._archetypeIndex do
		if bit32.band(archetype.bitmasks[1], queryBitmasks[1]) == queryBitmasks[1] and
			bit32.band(archetype.bitmasks[2], queryBitmasks[2]) == queryBitmasks[2] then
			result[#result + 1] = archetype
		end
	end

	local query = QueryViewer.new({
		archetypes = result,
		includeBitmasks = queryBitmasks,
		excludeBitmasks = {0, 0},
		components = components,
		ecs = self
	})
	self._queryCache[queryKey] = query
	self.OnCached:Fire("Query", queryKey)
	return query
end

--[[
    @function Yumina.Cleanup
    @description Performs cache cleanup and maintenance
]]
function Yumina.Cleanup(self: Yumina): ()
	if self._nextId >= ENTITY_MASK then
		Tools.Debugger.ThrowError(
			ERROR_TYPE.MEMORY_ERROR,
			"Entity ID space exhausted"
		)
	end

	for _, archetype in self._archetypeIndex do
		if #archetype.entities == 0 then
			for componentId, edge in archetype.addEdges do
				edge.from.addEdges[componentId] = nil
				edge.to.removeEdges[componentId] = nil
				if edge.next then
					edge.next.prev = edge.prev
				end
				if edge.prev then
					edge.prev.next = edge.next
				end
			end
			archetype.addEdges = {}
			archetype.removeEdges = {}
			archetype.edgeRefs = { next = nil, prev = nil }
		end
	end

	self._queryCache = {}
	self.OnCleanup:Fire()
end

return {
	ECS = Yumina,
	Tools = Tools
}
