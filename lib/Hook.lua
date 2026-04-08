--!nolint DeprecatedApi

--[[
    Sigma-Spy: Optimized Performance Edition
    Fixes: Freezing/Lagging, UI-Gating, and Actor-Safe Iteration.
]]

local Hook = {
    OriginalNamecall = nil,
    OriginalIndex = nil,
    PreviousFunctions = {},
    DefaultConfig = {
        FunctionPatches = true
    },
    -- Internal Logic States
    _HookedObjects = {},
    _UIReady = false,
    _LogBuffer = {},
    _IsInitialized = false
}

type table = { [any]: any }
type MetaFunc = (Instance, ...any) -> ...any
type UnkFunc = (...any) -> ...any

--// Modules
local Modules, Process, Communication, Config, Configuration
local ExeENV = getfenv(1)

--// Logic Fix: Batched Iteration
-- Spreads heavy loops over multiple frames to prevent "Application Not Responding" errors.
local function BatchedIteration(Table, Callback)
    local ChunkSize = 60 -- Moderate chunk size for Actor safety
    local Count = 0
    for i, v in next, Table do
        Count += 1
        local s, e = pcall(Callback, i, v)
        if not s then warn("Sigma-Spy Iteration Error:", e) end
        
        if Count >= ChunkSize then
            Count = 0
            task.wait() 
        end
    end
end

--// Logic Fix: UI Synchronization
-- Call this function once your UI is fully loaded and ready to receive logs.
function Hook:SignalUIReady()
    self._UIReady = true
    Communication:ConsolePrint("UI Ready: Flushing buffered logs...")
    
    for _, logData in ipairs(self._LogBuffer) do
        task.spawn(function()
            Process:ProcessRemote(unpack(logData))
        end)
    end
    self._LogBuffer = {} -- Clear buffer to save memory
end

function Hook:Init(Data)
    Modules = Data.Modules
    Process = Modules.Process
    Communication = Modules.Communication or Communication
    Config = Modules.Config or Config
    Configuration = Modules.Configuration or Configuration
    self._IsInitialized = true
end

--// Optimized Closure Bridge
local HookMiddle = newcclosure(function(OriginalFunc, Callback, AlwaysTable: boolean?, ...)
    local ReturnValues = Callback(...)
    if ReturnValues ~= nil then
        if not AlwaysTable then
            return Process:Unpack(ReturnValues)
        end
        return ReturnValues
    end

    if AlwaysTable then
        return {OriginalFunc(...)}
    end
    return OriginalFunc(...)
end)

function Hook:HookFunction(Func: UnkFunc, Callback: UnkFunc)
    local OriginalFunc
    local WrappedCallback = newcclosure(Callback)
    OriginalFunc = clonefunction(hookfunction(Func, function(...)
        return HookMiddle(OriginalFunc, WrappedCallback, false, ...)
    end))
    return OriginalFunc
end

function Hook:HookMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
    local Func = newcclosure(Callback)
    if Config.ReplaceMetaCallFunc then
        local Metatable = getrawmetatable(Object)
        local OriginalFunc = clonefunction(Metatable[Call])
        setreadonly(Metatable, false)
        Metatable[Call] = newcclosure(function(...) return HookMiddle(OriginalFunc, Func, false, ...) end)
        setreadonly(Metatable, true)
        return OriginalFunc
    end
    
    local Metatable = getrawmetatable(Object)
    local Unhooked; Unhooked = self:HookFunction(Metatable[Call], function(...)
        return HookMiddle(Unhooked, Func, true, ...)
    end)
    return Unhooked
end

--// Central Logic: Interception vs. Gating
local function ProcessRemote(OriginalFunc, MetaMethod: string, self, Method: string, ...)
    local LogData = {
        Method = Method,
        OriginalFunc = OriginalFunc,
        MetaMethod = MetaMethod,
        TransferType = "Send",
        IsExploit = checkcaller()
    }

    if not Hook._UIReady then
        -- Store the data, but execute the original so the game doesn't lag/break
        table.insert(Hook._LogBuffer, {LogData, self, ...})
        return OriginalFunc(self, ...)
    end

    return Process:ProcessRemote(LogData, self, ...)
end

function Hook:PatchFunctions()
    if Config.NoFunctionPatching then return end

    task.spawn(function()
        local Patches = {
            [pcall] = function(OldFunc, Func, ...)
                local Res = {OldFunc(Func, ...)}
                if Res[1] == false and iscclosure(Func) then
                    Res[2] = Process:CleanCError(Res[2])
                end
                return unpack(Res)
            end,
            [getfenv] = function(OldFunc, Level: number, ...)
                Level = (type(Level) == "number") and (Level + 2) or Level
                local Res = {OldFunc(Level, ...)}
                if not checkcaller() and Res[1] == ExeENV then
                    return OldFunc(999999, ...)
                end
                return unpack(Res)
            end
        }

        for Func, CallBack in Patches do
            self.PreviousFunctions[Func] = self:HookFunction(Func, CallBack)
        end
    end)
end

function Hook:ConnectClientRecive(Remote)
    if self._HookedObjects[Remote] then return end
    
    local ClassData = Process:GetClassData(Remote)
    if not ClassData or ClassData.NoReciveHook then return end
    if not Process:RemoteAllowed(Remote, "Receive") then return end

    self._HookedObjects[Remote] = true
    local IsRemoteFunction = ClassData.IsRemoteFunction
    local Method = ClassData.Receive[1]

    local function Callback(...)
        local LogData = {
            Method = Method, IsReceive = true, MetaMethod = "Connect", IsExploit = checkcaller()
        }
        if not Hook._UIReady then
            table.insert(Hook._LogBuffer, {LogData, Remote, ...})
            return
        end
        return Process:ProcessRemote(LogData, Remote, ...)
    end

    if not IsRemoteFunction then
        Remote[Method]:Connect(Callback)
    else
        self:HookClientInvoke(Remote, Method, Callback)
    end
end

function Hook:BeginHooks()
    -- Hook Global Index calls (Remote:FireServer style)
    local RemoteClassData = Process.RemoteClassData
    for ClassName, Data in next, RemoteClassData do
        local FuncName = Data.Send[1]
        pcall(function()
            local Dummy = Instance.new(ClassName)
            local Original = Dummy[FuncName]
            self:HookFunction(Original, function(self, ...)
                if not Process:RemoteAllowed(self, "Send", FuncName) then return end
                return ProcessRemote(Original, "__index", self, FuncName, ...)
            end)
        end)
    end

    -- Hook Namecall (__namecall style)
    self.OriginalNamecall = self:HookMetaMethod(game, "__namecall", function(self, ...)
        return ProcessRemote(self.OriginalNamecall, "__namecall", self, getnamecallmethod(), ...)
    end)
end

function Hook:LoadReceiveHooks()
    if Config.NoReceiveHooking then return end

    game.DescendantAdded:Connect(function(Obj)
        if Obj:IsA("RemoteEvent") or Obj:IsA("RemoteFunction") then
            self:ConnectClientRecive(Obj)
        end
    end)

    task.spawn(function()
        -- Nil instances scan
        BatchedIteration(getnilinstances(), function(_, Obj)
            if Obj:IsA("RemoteEvent") or Obj:IsA("RemoteFunction") then
                self:ConnectClientRecive(Obj)
            end
        end)

        -- Service scan
        local Blacklisted = Config.BlackListedServices or {}
        for _, Service in next, game:GetChildren() do
            if not table.find(Blacklisted, Service.ClassName) then
                BatchedIteration(Service:GetDescendants(), function(_, Obj)
                    if Obj:IsA("RemoteEvent") or Obj:IsA("RemoteFunction") then
                        self:ConnectClientRecive(Obj)
                    end
                end)
            end
        end
    end)
end

function Hook:LoadHooks(ActorCode: string, ChannelId: number)
    -- Logic: Spawn everything in a separate thread so execution is instant
    task.spawn(function()
        self:PatchFunctions()
        self:BeginHooks()
        self:LoadReceiveHooks()
        Communication:ConsolePrint("Sigma-Spy Hooks Loaded. Buffering logs until UI ready.")
    end)
end

return Hook
