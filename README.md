# YuminaECS

Serves as a prototype ECS for a C++ port. Not ready for production as of right now.

## Usage

### Basic
```lua
local world = require(path.to.Yumina)
local components = { eat = 1 }

local alice = world:Entity()
local apple = world:Entity()

world:Set(alice, components.eat, apple)

for entity, eaten in world:Query(components.eat) do
      -- do stuff
end
```

### Complex Relationship
```lua
local city = world:Entity()
world:Set(city, Cenum.Name, "Metropolis-7")

local districts = {}
for i = 1, 3 do
    local district = world:Entity()
    world:Set(district, Cenum.ChildOf, city)
    world:Set(district, Cenum.Name, "District-" .. i)
    
    local powerGrid = world:Entity()
    world:Set(powerGrid, Cenum.DistrictOwner, district)
    world:Set(powerGrid, Cenum.ResourceType, "Power")
    
    for j = 1, 2 do
        local powerStation = world:Entity()
        world:Set(powerStation, Cenum.ChildOf, district)
        world:Set(powerStation, Cenum.ConnectedGrid, powerGrid)
        world:Set(powerStation, Cenum.Production, {
            resource = "Power",
            amount = 1000
        })
    end
    
    districts[i] = district
end

for i = 1, #districts do
    local current = districts[i]
    local next = districts[i % #districts + 1]
    
    world:Set(current, Cenum.ResourceSharing, {
        partner = next,
        resources = {"Power", "Water"}
    })
end

-- Entity Querying and Hierarchy Traversal
-- Find all machines in a district
local machines = {}
for entity, parent in world:Query(Cenum.ChildOf):View() do
    if parent == districtId and world:Has(entity, Cenum.PowerConsumption) then
        table.insert(machines, entity)
    end
end

-- Find entities needing maintenance in hierarchy
local needsMaintenance = {}
local function CheckEntity(entityId)
    -- Check maintenance status
    local maintenance = world:GetComponentData(entityId, Cenum.MaintenanceData)
    if maintenance and maintenance.condition < 50 then
        table.insert(needsMaintenance, entityId)
    end
    -- Recursively check children
    for childEntity, parent in world:Query(Cenum.ChildOf):View() do
        if parent == entityId then
            CheckEntity(childEntity)
        end
    end
end
CheckEntity(districtId)
```