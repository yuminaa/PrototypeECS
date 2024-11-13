# YuminaECS

Yumina is a high-performance Entity Component System (ECS) library written in Luau.

> [!NOTE]
> Luau Yumina is a prototype to its [C++ version]().

## Philosophy
Yumina aims to provide users with minimal and robust boilerplate while being performant. In short, users can define their own policies.

## Features
- Lightweight Entity Component System
- Flexible component queries
- Resource management system
- Support for complex entity relationships
- Efficient archetype-based storage
- Query result caching
- Memory pooling
- Optimized bitmask-based component tracking

## Getting started
Simply head to [out](./out/out.luau) and copy the file onto your project.

## Core Concepts

### Entity
- Unique identifier representing an object in the system
- 24-bit ID with 8-bit generation counter
- Automatically recycled when despawned

### Component
- Data containers attached to entities
- Must have an ID between 1 and 64 (32 bits × 2 bitmasks)
- Efficiently stored in archetype-based arrays

### System
- Logic that operates on entities with specific component combinations
- Uses queries to find relevant entities

## Usage

### Basic
```lua
local world = require(path.to.Yumina)
local components = { eat = 1 }

local alice = world:Entity()
local apple = world:Entity()

world:Set(alice, components.eat, apple)

for entity, eaten in world:Query({components.eat}):View() do
   DoStuff()
end
```

### Advanced Queries
```lua
-- // Multiple component query with modifiers
local query = world:Query({ COMPONENT_A, COMPONENT_B })
    :With({ COMPONENT_C })
    :Without({ COMPONENT_D })
    :Any({ COMPONENT_E, COMPONENT_F })

for entityId, componentA, componentB in query:View() do
    -- // Process entities
end
```

### Sophisticated Example
```lua
local city = world:Entity()
world:Set(city, Name, "Metropolis-7")

local districts = {}
for i = 1, 3 do
    local district = world:Entity()
    world:Set(district, ChildOf, city)
    world:Set(district, Name, "District-" .. i)
    
    local powerGrid = world:Entity()
    world:Set(powerGrid, DistrictOwner, district)
    world:Set(powerGrid, ResourceType, "Power")
    
    for j = 1, 2 do
      local powerStation = world:Entity()
      world:Set(powerStation, ChildOf, district)
      world:Set(powerStation, ConnectedGrid, powerGrid)
      world:Set(powerStation, Production, {
        resource = "Power",
        amount = 1000
      })
    end
    
    districts[i] = district
end

for i = 1, #districts do
    local current = districts[i]
    local next = districts[i % #districts + 1]
    
    world:Set(current, ResourceSharing, {
      partner = next,
      resources = { "Power", "Water" }
    })
end

-- // Entity Querying and Hierarchy Traversal
-- // Find all machines in a district
local machines = {}
for entity, parent in world:Query({ ChildOf }):View() do
    if parent == districtId and world:Has(entity, PowerConsumption) then
      table.insert(machines, entity)
    end
end

-- // Find entities needing maintenance in hierarchy
local needsMaintenance = {}
local function CheckEntity(entityId)
    -- // Check maintenance status
    local maintenance = world:Has(entityId, MaintenanceData)
    if maintenance and maintenance.condition < 50 then
      table.insert(needsMaintenance, entityId)
    end
    -- // Recursively check children
    for childEntity, parent in world:Query({ ChildOf }):View() do
      if parent == entityId then
        CheckEntity(childEntity)
      end
    end
end
CheckEntity(districtId)
```

## Events
```lua
-- Component changes
world.OnSet:Connect(function(entity: number, componentId: number, data: any?)
    -- Handle component change
end)

-- // Archetype transitions
world.OnTransition:Connect(function(entity: number, source: Archetype, destination: Archetype)
    -- Handle transition
end)

-- // Cache operations 
world.OnCached:Connect(function(cacheType: "Query" | "Transition", key: number)
    -- Handle cache update
end)

-- // Cleanup operations
world.OnCleanup:Connect(function()
    -- // Handle cleanup
end)
```

## API Reference

### Core 

- `World:Entity()` - Creates a new entity
- `World:Set(entity, component, value)` - Sets a component value for an entity
- `World:Has(entity, component)` - Checks if entity has a component
- `World:Remove(entity, component)` - Removes a component from an entity
- `World:Despawn(entity)` - Deletes an entity
- `World:Cleanup()` - Performs memory maintenance

### Queries
- `World:Query(components)` - Creates a query for entities with specified components
- `Query:View()` - Returns iterator for query results

> [!INFO]
> In testing methods

- `Query:With(components)` - Adds required components to query
- `Query:Without(components)` - Excludes entities with specified components
- `Query:Any(components)` - Matches entities with any of the components

## Debug Tools

> [!NOTE]
> In progress!

```lua
local Tools = require("Yumina").Tools

-- // Profiling
Tools.Profiler.Begin()
Tools.Profiler.Mark("category", "label")
Tools.Profiler.End("category", "label")
local report = Tools.Profiler.GetReport()

-- // Debugging
Tools.Debugger.Log("category", "message", context)
```

## LICENSE
MIT. See [LICENSE](../LICENSE) for more info.

## Contributing
Contributions are always welcomed.