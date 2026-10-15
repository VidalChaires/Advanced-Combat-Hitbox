--!strict

--[[
	RaycastHitbox.lua
	Author: Senior Combat Systems Engineer
	Description:
		High-Performance Melee Raycast Hitbox Engine designed for competitive Roblox combat.
		Utilizes Continuous Collision Detection (CCD) by vector-sweeping raycasts between
		previous and current attachment frames on RunService.Heartbeat.

		Completely obsoletes BasePart.Touched by eliminating tunneling, desync,
		and physics engine simulation overhead.
]]

local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

--------------------------------------------------------------------------------
-- PURE LUAU FAST-SIGNAL (Decoupled Observer Pattern)
--------------------------------------------------------------------------------

export type Connection = {
	Disconnect: (self: Connection) -> (),
	Connected: boolean,
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

local function createSignal<T...>(): Signal<T...>
	local listeners: { [(T...) -> ()]: boolean } = {}

	local signal = {} :: Signal<T...>

	function signal:Connect(fn: (T...) -> ()): Connection
		listeners[fn] = true
		local connection = {
			Connected = true,
			Disconnect = function(self: Connection)
				if not self.Connected then return end
				self.Connected = false
				listeners[fn] = nil
			end,
		}
		return connection
	end

	function signal:Once(fn: (T...) -> ()): Connection
		local conn: Connection
		conn = signal:Connect(function(...)
			conn:Disconnect()
			fn(...)
		end)
		return conn
	end

	function signal:Wait(): T...
		local thread = coroutine.running()
		signal:Once(function(...)
			task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end

	function signal:Fire(...: T...)
		for callback in listeners do
			task.spawn(callback, ...)
		end
	end

	function signal:Destroy()
		table.clear(listeners)
	end

	return signal
end

--------------------------------------------------------------------------------
-- MODULE TYPING & DEFINITION
--------------------------------------------------------------------------------

export type RaycastHitbox = {
	-- Public Properties
	DebugMode: boolean,
	RaycastParams: RaycastParams,
	OnHit: Signal<BasePart, Humanoid?, RaycastResult>,

	-- Public Methods
	Start: (self: RaycastHitbox) -> (),
	Stop: (self: RaycastHitbox) -> (),
	ResetDebounce: (self: RaycastHitbox) -> (),
	AddAttachment: (self: RaycastHitbox, attachment: Attachment) -> (),
	RemoveAttachment: (self: RaycastHitbox, attachment: Attachment) -> (),
	SetAttachments: (self: RaycastHitbox, attachments: { Attachment }) -> (),
	SetRaycastParams: (self: RaycastHitbox, params: RaycastParams) -> (),
	Destroy: (self: RaycastHitbox) -> (),

	-- Internal
	_active: boolean,
	_attachments: { Attachment },
	_previousPositions: { [Attachment]: Vector3 },
	_hitTargets: { [Model]: boolean },
}

local RaycastHitbox = {}
RaycastHitbox.__index = RaycastHitbox

-- Centralized Registry to run a SINGLE Heartbeat connection for O(1) loop pooling
local activeHitboxes: { [RaycastHitbox]: boolean } = {}
local heartbeatConnection: RBXScriptConnection? = nil

--------------------------------------------------------------------------------
-- DEBUG VISUALIZATION UTILITY
--------------------------------------------------------------------------------

local function drawDebugRay(origin: Vector3, target: Vector3, wasHit: boolean)
	local distance = (target - origin).Magnitude
	if distance < 0.001 then return end

	local beamPart = Instance.new("Part")
	beamPart.Name = "HitboxRay_Debug"
	beamPart.Anchored = true
	beamPart.CanCollide = false
	beamPart.CanTouch = false
	beamPart.CanQuery = false
	beamPart.CastShadow = false
	beamPart.Material = Enum.Material.Neon
	beamPart.Color = if wasHit then Color3.fromRGB(255, 50, 50) else Color3.fromRGB(0, 200, 255)
	beamPart.Transparency = 0.35
	beamPart.Size = Vector3.new(0.05, 0.05, distance)
	beamPart.CFrame = CFrame.lookAt(origin, target) * CFrame.new(0, 0, -distance / 2)
	beamPart.Parent = workspace

	Debris:AddItem(beamPart, 0.15)
end

--------------------------------------------------------------------------------
-- CENTRALIZED ENGINE TICK (Continuous Collision Detection)
--------------------------------------------------------------------------------

local function onHeartbeat(_dt: number)
	for hitbox in activeHitboxes do
		if not hitbox._active then continue end

		local attachments = hitbox._attachments
		local previousPositions = hitbox._previousPositions
		local hitTargets = hitbox._hitTargets
		local raycastParams = hitbox.RaycastParams
		local debugEnabled = hitbox.DebugMode

		for i = 1, #attachments do
			local attachment = attachments[i]
			if not attachment:IsDescendantOf(workspace) then continue end

			local currentPos = attachment.WorldPosition
			local prevPos = previousPositions[attachment]

			-- Prime initial position if missing
			if not prevPos then
				previousPositions[attachment] = currentPos
				continue
			end

			local displacement = currentPos - prevPos
			local distance = displacement.Magnitude

			-- Only cast if spatial delta exceeds precision threshold to save CPU cycles
			if distance >= 0.001 then
				local raycastResult = workspace:Raycast(prevPos, displacement, raycastParams)

				if raycastResult then
					local hitInstance = raycastResult.Instance
					local targetModel = hitInstance:FindFirstAncestorOfClass("Model")

					if targetModel then
						-- Deduplication / Swing Debounce Check
						if not hitTargets[targetModel] then
							local humanoid = targetModel:FindFirstChildOfClass("Humanoid")

							-- Hit confirmation
							hitTargets[targetModel] = true
							hitbox.OnHit:Fire(hitInstance, humanoid, raycastResult)

							if debugEnabled then
								drawDebugRay(prevPos, raycastResult.Position, true)
							end
						end
					else
						-- Hit scenery or unrigged part
						hitbox.OnHit:Fire(hitInstance, nil, raycastResult)
						if debugEnabled then
							drawDebugRay(prevPos, raycastResult.Position, true)
						end
					end
				else
					if debugEnabled then
						drawDebugRay(prevPos, currentPos, false)
					end
				end
			end

			-- Advance previous frame position
			previousPositions[attachment] = currentPos
		end
	end
end

local function updateHeartbeatConnection()
	local hasActive = next(activeHitboxes) ~= nil
	if hasActive and not heartbeatConnection then
		heartbeatConnection = RunService.Heartbeat:Connect(onHeartbeat)
	elseif not hasActive and heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

--------------------------------------------------------------------------------
-- CONSTRUCTOR & PUBLIC API
--------------------------------------------------------------------------------

--[=[
	Creates a new RaycastHitbox instance.
	@param target Model | BasePart | { Attachment } - Object to automatically harvest attachments from, or explicit attachment array.
	@param customParams RaycastParams? - Custom filtering params. If omitted, a default Exclude list will be configured.
	@return RaycastHitbox
]=]
function RaycastHitbox.new(
	target: Model | BasePart | { Attachment },
	customParams: RaycastParams?
): RaycastHitbox
	local self = setmetatable({}, RaycastHitbox) :: any

	self.DebugMode = false
	self._active = false
	self._attachments = {} :: { Attachment }
	self._previousPositions = {} :: { [Attachment]: Vector3 }
	self._hitTargets = {} :: { [Model]: boolean }
	self.OnHit = createSignal() :: Signal<BasePart, Humanoid?, RaycastResult>

	-- Configure RaycastParams
	if customParams then
		self.RaycastParams = customParams
	else
		local defaultParams = RaycastParams.new()
		defaultParams.FilterType = Enum.RaycastFilterType.Exclude
		defaultParams.IgnoreWater = true

		if typeof(target) == "Instance" then
			local rootModel = target:FindFirstAncestorOfClass("Model") or target
			defaultParams.FilterDescendantsInstances = { rootModel }
		else
			defaultParams.FilterDescendantsInstances = {}
		end

		self.RaycastParams = defaultParams
	end

	-- Extract Attachments
	if typeof(target) == "table" then
		self:SetAttachments(target)
	elseif typeof(target) == "Instance" then
		local collected = {}
		for _, descendant in target:GetDescendants() do
			if descendant:IsA("Attachment") then
				table.insert(collected, descendant)
			end
		end
		self:SetAttachments(collected)
	end

	return self
end

--[=[
	Activates hitbox continuous collision detection.
	Flushes the internal target debounce table for a fresh swing.
]=]
function RaycastHitbox:Start()
	if self._active then return end

	self._active = true
	self:ResetDebounce()

	-- Prime frame positions to avoid ghost raycasts stretching from origin
	for _, attachment in self._attachments do
		self._previousPositions[attachment] = attachment.WorldPosition
	end

	activeHitboxes[self] = true
	updateHeartbeatConnection()
end

--[=[
	Deactivates hitbox tracing.
]=]
function RaycastHitbox:Stop()
	if not self._active then return end

	self._active = false
	activeHitboxes[self] = nil
	table.clear(self._previousPositions)
	updateHeartbeatConnection()
end

--[=[
	Clears the hit target record without stopping the hitbox.
	Useful for combo attacks or multi-strike frames.
]=]
function RaycastHitbox:ResetDebounce()
	table.clear(self._hitTargets)
end

--[=[
	Updates the attachment points used for tracing.
]=]
function RaycastHitbox:SetAttachments(attachments: { Attachment })
	table.clear(self._attachments)
	table.clear(self._previousPositions)

	for _, att in attachments do
		if att:IsA("Attachment") then
			table.insert(self._attachments, att)
		end
	end
end

--[=[
	Appends an attachment point to the hitbox.
]=]
function RaycastHitbox:AddAttachment(attachment: Attachment)
	if not table.find(self._attachments, attachment) then
		table.insert(self._attachments, attachment)
		if self._active then
			self._previousPositions[attachment] = attachment.WorldPosition
		end
	end
end

--[=[
	Removes an attachment point.
]=]
function RaycastHitbox:RemoveAttachment(attachment: Attachment)
	local index = table.find(self._attachments, attachment)
	if index then
		table.remove(self._attachments, index)
		self._previousPositions[attachment] = nil
	end
end

--[=[
	Overrides the RaycastParams configuration.
]=]
function RaycastHitbox:SetRaycastParams(params: RaycastParams)
	self.RaycastParams = params
end

--[=[
	Cleans up all references, disconnects internal events, and unregisters from active hitboxes.
]=]
function RaycastHitbox:Destroy()
	self:Stop()
	self.OnHit:Destroy()
	table.clear(self._attachments)
	table.clear(self._previousPositions)
	table.clear(self._hitTargets)
	setmetatable(self, nil)
end

return RaycastHitbox
