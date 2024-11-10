--!native 
--!optimize 2 
--!strict 

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

local ENTITY_MASK: number = 0x00FFFFFF
local GENERATION_SHIFT: number = 0x18
local MAX_GENERATION: number = 0xFF

local BITS_PER_MASK = 32
local NUM_BITMASKS = 2

local DIRTY_ADDITION: number = 0x1
local DIRTY_REMOVAL: number = 0x2
local DIRTY_UPDATE: number = 0x4

local Yumina = {}
Yumina.__index = Yumina

export type Yumina = typeof(setmetatable({
    _archetypeIndex = {} :: { [number]: Archetype },
    _entityIndex = {} :: { [EntityId]: Archetype },
    _freeList = {} :: { EntityId},
    _generations = {} :: { [EntityId]: Generation },
    _nextId = 1 :: EntityId,
    _edgeCache = {} :: ArchetypeEdgeCache,
    _queryCache = {} :: { [number]: QueryObject },
    _transitionCache = {} :: { [TransitionKey]: TransitionInfo },
    _pendingMoves = {} :: { MoveCommand },
}, Yumina))

local function GetBitmaskIndex(componentId: number): number
    return math.floor((componentId - 1) / BITS_PER_MASK) + 1
end

local function GetBitPosition(componentId: number): number
    return (componentId - 1) % BITS_PER_MASK
end

local function CreateEmptyBitmasks(): {number}
    local bitmasks = table.create(NUM_BITMASKS)
    for i = 1, NUM_BITMASKS do
        bitmasks[i] = 0
    end
    return bitmasks
end

local function GetArchetypeKey(bitmasks: {number}): number
    return bitmasks[1] + (bitmasks[2] * 0x100000000)
end

local function GetTransitionKey(sourceBitmasks: { number }, destBitmasks: { number }): number
    return sourceBitmasks[1] + (destBitmasks[1] * 0x100000000)
end

function Yumina.new(): Yumina
    local self = setmetatable({
        _archetypeIndex = {},
        _entityIndex = {},
        _freeList = {},
        _generations = {},
        _nextId = 1,
        _edgeCache = {},
        _queryCache = {},
        _transitionCache = {},
        _pendingMoves = {}
    }, Yumina)
    return self
end

function Yumina.Entity(self: Yumina): EntityId
    local entityId: EntityId
    local generation: Generation

    if #self._freeList > 0 then
        entityId = table.remove(self._freeList) :: number
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
    local archetype = self._entityIndex[entityId]
    
    if not archetype then 
		return 
	end
    
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
    self._entityIndex[entityId] = nil

    if archetype.entityCount == 0 then
        self._archetypeIndex[GetArchetypeKey(archetype.bitmasks)] = nil
    end

    archetype.dirtyFlags = bit32.bor(archetype.dirtyFlags, DIRTY_REMOVAL)
    self._freeList[#self._freeList + 1] = entityId
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

local function CreateTransitionInfo(source: Archetype, destination: Archetype): TransitionInfo
    local sharedComponents = {}
    local addedComponents = {}
    local removedComponents = {}

    for componentId = 1, BITS_PER_MASK * NUM_BITMASKS do
        local maskIndex = GetBitmaskIndex(componentId)
        local bitPosition = GetBitPosition(componentId)
        local bit = bit32.lshift(1, bitPosition)
        
        local inSource = bit32.band(source.bitmasks[maskIndex], bit) ~= 0
        local inDest = bit32.band(destination.bitmasks[maskIndex], bit) ~= 0
        
        if inSource and inDest then
            table.insert(sharedComponents, componentId)
        elseif inSource and not inDest then
            table.insert(removedComponents, componentId)
        elseif not inSource and inDest then
            table.insert(addedComponents, componentId)
        end
    end

    return {
        source = source,
        destination = destination,
        sharedComponents = sharedComponents,
        addedComponents = addedComponents,
        removedComponents = removedComponents,
        frequency = 0
    }
end

function Yumina.__FastPathMove(
    self: Yumina,
    entity: EntityId,
    source: Archetype,
    destination: Archetype,
    transition: TransitionInfo,
    data: any?
)
    local fromRow = source.entityRow[entity]
    local toRow = destination.entityCount + 1

    destination.entities[toRow] = entity
    destination.entityRow[entity] = toRow
    destination.entityCount += 1

    for _, componentId in transition.sharedComponents do
        local sourceArray = source.componentData[componentId]
        local destArray = destination.componentData[componentId]
        if not destArray then
            destArray = {}
            destination.componentData[componentId] = destArray
        end
        destArray[toRow] = sourceArray[fromRow]
    end

    if data and #transition.addedComponents > 0 then
        local componentId = transition.addedComponents[1]
        local destArray = destination.componentData[componentId]
        if not destArray then
            destArray = {}
            destination.componentData[componentId] = destArray
        end
        destArray[toRow] = data
    end

    -- // FIXME: fromRow can be null
    if fromRow ~= source.entityCount then
        local lastEntity = source.entities[source.entityCount]
        source.entities[fromRow] = lastEntity
        source.entityRow[lastEntity] = fromRow

        for componentId in source.componentData do
            local array = source.componentData[componentId]
            array[fromRow] = array[source.entityCount]
            array[source.entityCount] = nil
        end
    else
        for componentId in source.componentData do
            source.componentData[componentId][fromRow] = nil
        end
    end

    source.entityCount -= 1
    source.entities[source.entityCount + 1] = nil
    source.entityRow[entity] = nil

    self._entityIndex[entity] = destination
end

function Yumina.Set<T>(self: Yumina, entity: EntityId, component: ComponentId, data: T): Yumina
    local entityId = bit32.band(entity, ENTITY_MASK)
    local generation = bit32.rshift(entity, GENERATION_SHIFT)

    if self._generations[entityId] ~= generation then
        error("[Yumina]: Invalid entity reference", 0)
    end

    local currentArchetype = self._entityIndex[entity]
    if not currentArchetype then
        currentArchetype = self:__CreateArchetype(CreateEmptyBitmasks())
        self._entityIndex[entity] = currentArchetype
    end

    local newBitmasks = table.clone(currentArchetype.bitmasks)
    local maskIndex = GetBitmaskIndex(component)
    local bitPosition = GetBitPosition(component)
    newBitmasks[maskIndex] = bit32.bor(
        newBitmasks[maskIndex],
        bit32.lshift(1, bitPosition)
    )
    
    local newKey = GetArchetypeKey(newBitmasks)
    local currentKey = GetArchetypeKey(currentArchetype.bitmasks)
    
    if newKey == currentKey then
        local componentArray = currentArchetype.componentData[component]
        if not componentArray then
            componentArray = {}
            currentArchetype.componentData[component] = componentArray
        end
        componentArray[currentArchetype.entityRow[entity]] = data
        currentArchetype.dirtyFlags = bit32.bor(currentArchetype.dirtyFlags, DIRTY_UPDATE)
        return self
    end

    local targetArchetype = self._archetypeIndex[newKey]
    if not targetArchetype then
        targetArchetype = self:__CreateArchetype(newBitmasks)
    end

    local transitionKey = GetTransitionKey(currentArchetype.bitmasks, newBitmasks)
    local transitionInfo = self._transitionCache[transitionKey]
    
    if not transitionInfo then
        transitionInfo = CreateTransitionInfo(currentArchetype, targetArchetype)
        self._transitionCache[transitionKey] = transitionInfo
    end

    transitionInfo.frequency += 1
    self:__FastPathMove(entity, currentArchetype, targetArchetype, transitionInfo, data)
    
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
    local transitionInfo = self._transitionCache[transitionKey]
    
    if not transitionInfo then
        transitionInfo = CreateTransitionInfo(currentArchetype, targetArchetype)
        self._transitionCache[transitionKey] = transitionInfo
    end

    transitionInfo.frequency += 1
    self:__FastPathMove(entity, currentArchetype, targetArchetype, transitionInfo)
    
    return self
end

local QueryObject = {}
QueryObject.__index = QueryObject

export type QueryObject = typeof(setmetatable({
    archetypes = {} :: { Archetype },
    components = {} :: { ComponentId },
    includeBitmasks = {} :: { number },
    excludeBitmasks = {} :: { number },
    ecs = nil :: Yumina?
}, QueryObject))

function QueryObject.new(q: {
    archetypes: { Archetype },
    components: { ComponentId },
    includeBitmasks: { number },
    excludeBitmasks: { number },
    ecs: Yumina
}): QueryObject
    return setmetatable(q, QueryObject)
end

function QueryObject.Include(self: QueryObject, componentIds: { ComponentId }): QueryObject
    for _, componentId in componentIds do
        local maskIndex = GetBitmaskIndex(componentId)
        local bitPosition = GetBitPosition(componentId)
        self.includeBitmasks[maskIndex] = bit32.bor(
            self.includeBitmasks[maskIndex],
            bit32.lshift(1, bitPosition)
        )
    end
    
    for i = #self.archetypes, 1, -1 do
        local archetype = self.archetypes[i]
        local matches = true
        
        for j = 1, NUM_BITMASKS do
            if bit32.band(archetype.bitmasks[j], self.includeBitmasks[j]) ~= self.includeBitmasks[j] then
                matches = false
                break
            end
        end
        
        if not matches then
            local last = self.archetypes[#self.archetypes]
            self.archetypes[i] = last
            self.archetypes[#self.archetypes] = nil
        end
    end
    
    return self
end

function QueryObject.Exclude(self: QueryObject, componentIds: { ComponentId }): QueryObject
    for _, componentId in componentIds do
        local maskIndex = GetBitmaskIndex(componentId)
        local bitPosition = GetBitPosition(componentId)
        self.excludeBitmasks[maskIndex] = bit32.bor(
            self.excludeBitmasks[maskIndex],
            bit32.lshift(1, bitPosition)
        )
    end
    
    for i = #self.archetypes, 1, -1 do
        local archetype = self.archetypes[i]
        local shouldExclude = false
        
        for j = 1, NUM_BITMASKS do
            if bit32.band(archetype.bitmasks[j], self.excludeBitmasks[j]) ~= 0 then
                shouldExclude = true
                break
            end
        end
        
        if shouldExclude then
            local last = self.archetypes[#self.archetypes]
            self.archetypes[i] = last
            self.archetypes[#self.archetypes] = nil
        end
    end
    
    return self
end

function QueryObject.View(self: QueryObject): () -> (EntityId?, ...any?)
    local currentArchetypeIndex = 1
    local currentEntityIndex = 1
    local currentArchetype = self.archetypes[currentArchetypeIndex]
    
    local componentArrays = table.create(#self.components)
    local numComponents = #self.components
    
    local componentIndices = table.create(numComponents)
    for i, componentId in self.components do
        componentIndices[i :: number] = componentId
    end
    
    local componentValues = table.create(numComponents)
    
    return function(): (EntityId?, ...any?)
        while currentArchetype do
            if currentArchetype.entityCount == 0 then
                currentArchetypeIndex += 1
                currentArchetype = self.archetypes[currentArchetypeIndex]
                currentEntityIndex = 1
                if currentArchetype then
                    for i, componentId in componentIndices do
                        componentArrays[i] = currentArchetype.componentData[componentId]
                    end
                end
                continue
            end
            
            while currentEntityIndex <= currentArchetype.entityCount do
                local entityId = currentArchetype.entities[currentEntityIndex]
                local row = currentArchetype.entityRow[entityId]
                
                for i = 1, numComponents do
                    local componentArray = componentArrays[i]
                    componentValues[i] = if componentArray then componentArray[row] else nil
                end
                
                currentEntityIndex += 1
                return entityId, table.unpack(componentValues, 1, numComponents)
            end
            
            currentArchetypeIndex += 1
            currentArchetype = self.archetypes[currentArchetypeIndex]
            currentEntityIndex = 1
            
            if currentArchetype then
                for i, componentId in componentIndices do
                    componentArrays[i] = currentArchetype.componentData[componentId]
                end
            end
        end
        return nil, nil
    end
end

function Yumina.Query(self: Yumina, components: {ComponentId}): QueryObject
    local queryBitmasks = CreateEmptyBitmasks()
    
    for _, componentId in components do
        local maskIndex = GetBitmaskIndex(componentId)
        local bitPosition = GetBitPosition(componentId)
        queryBitmasks[maskIndex] = bit32.bor(
            queryBitmasks[maskIndex],
            bit32.lshift(1, bitPosition)
        )
    end
    
    local queryKey = GetArchetypeKey(queryBitmasks)
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
    
    local matchingArchetypes = table.create(32)
    local matchCount = 0
    
    for _, archetype in self._archetypeIndex do
        local matches = true
        for i = 1, NUM_BITMASKS do
            if bit32.band(archetype.bitmasks[i], queryBitmasks[i]) ~= queryBitmasks[i] then
                matches = false
                break
            end
        end
        
        if matches then
            matchCount += 1
            matchingArchetypes[matchCount] = archetype
        end
    end
    
    local query = QueryObject.new({
        archetypes = matchingArchetypes,
        includeBitmasks = queryBitmasks,
        excludeBitmasks = CreateEmptyBitmasks(),
        components = components,
        ecs = self
    })
    
    self._queryCache[queryKey] = query
    return query
end

function Yumina.GetArchetypeInfo(self: Yumina, entity: EntityId): { [string]: any }?
    local entityId = bit32.band(entity, ENTITY_MASK)
    local archetype = self._entityIndex[entityId]
    
    if not archetype then
        return nil
    end
    
    return {
        bitmasks = table.clone(archetype.bitmasks),
        entityCount = archetype.entityCount,
        components = table.create(BITS_PER_MASK * NUM_BITMASKS),
        row = archetype.entityRow[entityId]
    }
end

function Yumina.Has(self: Yumina, entity: EntityId, component: ComponentId): any?
    local entityId = bit32.band(entity, ENTITY_MASK)
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

function Yumina.Cleanup(self: Yumina)
    for archetypeKey, archetype in self._archetypeIndex do
        if archetype.entityCount == 0 then
            self._archetypeIndex[archetypeKey] = nil
        end
    end
    
    self._queryCache = {}
    
    if #self._transitionCache > 1000 then
        local sortedTransitions = {}
        for key, info in self._transitionCache do
            table.insert(sortedTransitions, { key = key, freq = info.frequency })
        end
        
        table.sort(sortedTransitions, function(a, b)
            return a.freq > b.freq
        end)
        
        local newCache = {}
        for i = 1, 500 do
            newCache[sortedTransitions[i].key] = self._transitionCache[sortedTransitions[i].key]
        end
        
        self._transitionCache = newCache
    end
end

return Yumina.new()