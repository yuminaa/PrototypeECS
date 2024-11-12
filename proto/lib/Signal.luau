--!native
--!optimize 2
--!strict

export type Signal<T...> = {
    _head: Connection<T...>?,
    Connect: (self: Signal<T...>, fn: (...any) -> ()) -> Connection<T...>,
    Fire: (self: Signal<T...>, ...any) -> (),
    Wait: (self: Signal<T...>) -> ...any,
    Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection<T...>,
    DisconnectAll: (self: Signal<T...>) -> (),
    Destroy: (self: Signal<T...>) -> ()
}

export type Connection<T...> = {
    Connected: boolean,
    _signal: Signal<T...>,
    _fn: (...any) -> (),
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
            
            local success, err = coroutine.resume(thread, cn._fn, thread, ...)
            if not success then
                error(string.format("Signal callback error: %s", err), 2)
            end
        end
        cn = cn._next
    end
end

function Signal.Wait<T...>(self: Signal<T...>): T...
    local thread = coroutine.running()
    local cnn
    cnn = self:Connect(function(...)
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
    cnn = self:Connect(function(...)
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
    Signal:DisconnectAll()
    setmetatable(self, nil)
end

function Signal.new<T...>(): Signal<T...>
    return setmetatable({
        _head = nil,
    }, Signal) :: any
end

return Signal
