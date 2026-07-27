--!nolint DeprecatedApi

local Hook = {
	OriginalNamecall = nil,
	OriginalIndex = nil,
	PreviousFunctions = {},
	DefaultConfig = {
		FunctionPatches = true
	}
}

type table = {
	[any]: any
}

type MetaFunc = (Instance, ...any) -> ...any
type UnkFunc = (...any) -> ...any

--// Modules
local Modules
local Process
local Configuration
local Config
local Communication

local ExeENV = getfenv(1)

function Hook:Init(Data)
    Modules = Data.Modules

	Process = Modules.Process
	Communication = Modules.Communication or Communication
	Config = Modules.Config or Config
	Configuration = Modules.Configuration or Configuration
end

local HookMiddle = newcclosure(function(OriginalFunc, Callback, AlwaysTable: boolean?, ...)
	local ReturnValues = Callback(...)
	if ReturnValues then
		if not AlwaysTable then
			return Process:Nils(ReturnValues) -- updated to safe unpack/nil handler if needed
		end
		return ReturnValues
	end

	if AlwaysTable then
		return {OriginalFunc(...)}
	end

	return OriginalFunc(...)
end)

local function Merge(Base: table, New: table)
	for Key, Value in next, New do
		Base[Key] = Value
	end
end

function Hook:Index(Object: Instance, Key: string)
    local identity = getthreadidentity()
    setthreadidentity(8)
    local returned = Object[Key]
    setthreadidentity(identity)
	return returned
end

function Hook:PushConfig(Overwrites)
    Merge(self, Overwrites)
end

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

function Hook:HookMetaCall(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local Metatable = getrawmetatable(Object)
	local Unhooked
	
	Unhooked = self:HookFunction(Metatable[Call], function(...)
		return HookMiddle(Unhooked, Callback, true, ...)
	end)
	return Unhooked
end

function Hook:HookMetaMethod(Object: Instance, Call: string, Callback: MetaFunc): MetaFunc
	local Func = newcclosure(Callback)
	
	if Config.ReplaceMetaCallFunc then
		return self:ReplaceMetaMethod(Object, Call, Func)
	end
	
	return self:HookMetaCall(Object, Call, Func)
end

function Hook:PatchFunctions()
	if Config.NoFunctionPatching then return end
end

function Hook:GetOriginalFunc(Func)
	return self.PreviousFunctions[Func] or Func
end

--// ==========================================
--// REGUI / SIGMA-UI BRIDGE PROCESSOR
--// ==========================================
local function SendToSigmaUI(Remote, Method, Args, IsReceive, ReturnValues)
	if not _G.SigmaUI then return end

	pcall(function()
		_G.SigmaUI:QueueLog({
			Remote = Remote,
			Method = Method,
			Args = Args,
			IsReceive = IsReceive,
			Id = tostring(Remote:GetDebugId()),
			Timestamp = tick(),
			IsExploit = checkcaller(),
			ReturnValues = ReturnValues
		})
	end)
end

local function ProcessRemote(OriginalFunc, MetaMethod: string, self, Method: string, ...)
	local Args = {...}
	
	-- Forward execution to Cobalt's core processor
	local Results = { Process:ProcessRemote({
		Method = Method,
		OriginalFunc = OriginalFunc,
		MetaMethod = MetaMethod,
		TransferType = "Send",
		IsExploit = checkcaller()
	}, self, ...) }

	-- Bridge data directly to your ReGui UI interface
	SendToSigmaUI(self, Method, Args, false, Results)

	return unpack(Results)
end

function Hook:HookRemoteTypeIndex(ClassName: string, FuncName: string)
	local Remote = Instance.new(ClassName)
	local Func = Remote[FuncName]
	local OriginalFunc

	OriginalFunc = self:HookFunction(Func, function(self, ...)
		if not Process:RemoteAllowed(self, "Send", FuncName) then return end
		return ProcessRemote(OriginalFunc, "__index", self, FuncName, ...)
	end)
end

function Hook:HookRemoteIndexes()
	local RemoteClassData = Process.RemoteClassData
	for ClassName, Data in RemoteClassData do
		local FuncName = Data.Send[1]
		self:HookRemoteTypeIndex(ClassName, FuncName)
	end
end

function Hook:BeginHooks()
	self:HookRemoteIndexes()

	local OriginalNameCall
	OriginalNameCall = self:HookMetaMethod(game, "__namecall", function(self, ...)
		local Method = getnamecallmethod()
		return ProcessRemote(OriginalNameCall, "__namecall", self, Method, ...)
	end)

	Merge(self, {
		OriginalNamecall = OriginalNameCall,
	})
end

function Hook:ConnectClientRecive(Remote)
	local Allowed = Process:RemoteAllowed(Remote, "Receive")
	if not Allowed then return end

    local ClassData = Process:GetClassData(Remote)
    local IsRemoteFunction = ClassData.IsRemoteFunction
	local NoReciveHook = ClassData.NoReciveHook
    local Method = ClassData.Receive[1]

	if NoReciveHook then return end

	local function Callback(...)
		local Args = {...}
		local Results = { Process:ProcessRemote({
			Method = Method,
			IsReceive = true,
			MetaMethod = "Connect",
			IsExploit = checkcaller()
		}, Remote, ...) }

		-- Bridge incoming server events into the ReGui interface
		SendToSigmaUI(Remote, Method, Args, true, Results)

		return unpack(Results)
	end

	if not IsRemoteFunction then
   		Remote[Method]:Connect(Callback)
	else
		-- Safe fallback for client invokes
		local Success, Function = pcall(getcallbackvalue, Remote, Method)
		if Success and Function then
			self:HookFunction(Function, Callback)
		end
	end
end

function Hook:BeginService(Libraries, ExtraData, ChannelId, ...)
	local ReturnSpoofs = Libraries.ReturnSpoofs
	local ProcessLib = Libraries.Process
	local Communication = Libraries.Communication
	local Generation = Libraries.Generation
	local Config = Libraries.Config

	ProcessLib:CheckConfig(Config)

	local InitData = {
		Modules = {
			ReturnSpoofs = ReturnSpoofs,
			Generation = Generation,
			Communication = Communication,
			Process = ProcessLib,
			Config = Config,
			Hook = self
		},
		Services = setmetatable({}, {
			__index = function(self, Name: string): Instance
				local Service = game:GetService(Name)
				return cloneref(Service)
			end,
		})
	}

	Communication:Init(InitData)
	ProcessLib:Init(InitData)
	self:Init(InitData)

	self:BeginHooks()
end

function Hook:LoadHooks(ActorCode: string, ChannelId: number)
	self:BeginService(Modules, nil, ChannelId)
end

return Hook
