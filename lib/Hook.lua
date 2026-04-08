--!nolint DeprecatedApi

local Hook = {
	OriginalNamecall = nil,
	OriginalIndex = nil,
	PreviousFunctions = {},
	DefaultConfig = {
		FunctionPatches = true
	},
	-- Logic State
	_HookedObjects = {},
	_UIReady = false,
	_LogBuffer = {},
}

type table = { [any]: any }
type MetaFunc = (Instance, ...any) -> ...any
type UnkFunc = (...any) -> ...any

--// Modules
local Modules, Process, Communication, Config, Configuration
local ExeENV = getfenv(1)

--// Logic Fix: Batched Iteration (Prevents Freezing)
local function BatchedIteration(Table, Callback)
	local ChunkSize = 80 
	local Count = 0
	for i, v in next, Table do
		Count += 1
		Callback(i, v)
		if Count >= ChunkSize then
			Count = 0
			task.wait() -- Yield to keep FPS stable
		end
	end
end

--// Logic Fix: Log Gating (Prevents early log lag)
function Hook:SignalUIReady()
	self._UIReady = true
	-- Flush the buffer
	for _, data in ipairs(self._LogBuffer) do
		task.spawn(function()
			Process:ProcessRemote(unpack(data))
		end)
	end
	self._LogBuffer = {} -- Clear memory
end

function Hook:Init(Data)
    Modules = Data.Modules
	Process = Modules.Process
	Communication = Modules.Communication or Communication
	Config = Modules.Config or Config
	Configuration = Modules.Configuration or Configuration
end

--// Optimized callback bridge
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

function Hook:ReplaceMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local Metatable = getrawmetatable(Object)
	local OriginalFunc = clonefunction(Metatable[Call])
	
	setreadonly(Metatable, false)
	Metatable[Call] = newcclosure(function(...)
		return HookMiddle(OriginalFunc, Callback, false, ...)
	end)
	setreadonly(Metatable, true)

	return OriginalFunc
end

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
		return self:ReplaceMetaMethod(Object, Call, Func)
	end
	
	local Metatable = getrawmetatable(Object)
	local Unhooked
	Unhooked = self:HookFunction(Metatable[Call], function(...)
		return HookMiddle(Unhooked, Callback, true, ...)
	end)
	return Unhooked
end

--// Internal Remote Processor with Gating Logic
local function ProcessRemote(OriginalFunc, MetaMethod: string, self, Method: string, ...)
	local LogData = {
		Method = Method,
		OriginalFunc = OriginalFunc,
		MetaMethod = MetaMethod,
		TransferType = "Send",
		IsExploit = checkcaller()
	}

	-- LOGIC: If UI is not ready, save it. Do not process yet.
	if not Hook._UIReady then
		table.insert(Hook._LogBuffer, {LogData, self, ...})
		-- We still let the remote execute so the game doesn't break
		return OriginalFunc(self, ...)
	end

	return Process:ProcessRemote(LogData, self, ...)
end

function Hook:PatchFunctions()
	if Config.NoFunctionPatching then return end

	task.spawn(function()
		local Patches = {
			[pcall] =  function(OldFunc, Func, ...)
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
			local Wrapped = newcclosure(CallBack)
			local OldFunc; OldFunc = self:HookFunction(Func, function(...)
				return Wrapped(OldFunc, ...)
			end)
			self.PreviousFunctions[Func] = OldFunc
		end
	end)
end

function Hook:ConnectClientRecive(Remote)
	if self._HookedObjects[Remote] then return end
	
	local Allowed = Process:RemoteAllowed(Remote, "Receive")
	if not Allowed then return end

    local ClassData = Process:GetClassData(Remote)
	if not ClassData or ClassData.NoReciveHook then return end

	self._HookedObjects[Remote] = true
    local IsRemoteFunction = ClassData.IsRemoteFunction
    local Method = ClassData.Receive[1]

	local function Callback(...)
		local LogData = {
            Method = Method,
            IsReceive = true,
            MetaMethod = "Connect",
			IsExploit = checkcaller()
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
	-- 1. Hook Static Remote Indexes
	local RemoteClassData = Process.RemoteClassData
	for ClassName, Data in RemoteClassData do
		local FuncName = Data.Send[1]
		local Remote = Instance.new(ClassName)
		local Func = Remote[FuncName]
		
		self:HookFunction(Func, function(self, ...)
			if not Process:RemoteAllowed(self, "Send", FuncName) then return end
			return ProcessRemote(Func, "__index", self, FuncName, ...)
		end)
	end

	-- 2. Namecall Hook
	local OriginalNameCall
	OriginalNameCall = self:HookMetaMethod(game, "__namecall", function(self, ...)
		local Method = getnamecallmethod()
		return ProcessRemote(OriginalNameCall, "__namecall", self, Method, ...)
	end)

	self.OriginalNamecall = OriginalNameCall
end

function Hook:LoadReceiveHooks()
	if Config.NoReceiveHooking then return end

	game.DescendantAdded:Connect(function(Obj)
		if Obj:IsA("RemoteEvent") or Obj:IsA("RemoteFunction") then
			self:ConnectClientRecive(Obj)
		end
	end)

	task.spawn(function()
		BatchedIteration(getnilinstances(), function(_, Obj)
			if Obj:IsA("RemoteEvent") or Obj:IsA("RemoteFunction") then
				self:ConnectClientRecive(Obj)
			end
		end)

		local BlackListed = Config.BlackListedServices or {}
		for _, Service in next, game:GetChildren() do
			pcall(function()
				if not table.find(BlackListed, Service.ClassName) then
					BatchedIteration(Service:GetDescendants(), function(_, Obj)
						if Obj:IsA("RemoteEvent") or Obj:IsA("RemoteFunction") then
							self:ConnectClientRecive(Obj)
						end
					end)
				end
			end)
		end
	end)
end

function Hook:LoadHooks(ActorCode: string, ChannelId: number)
	task.spawn(function()
		self:PatchFunctions()
		self:BeginHooks()
		self:LoadReceiveHooks()
	end)
end

return Hook
