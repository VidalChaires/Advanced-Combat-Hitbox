--!strict

--[[
	WeaponController.server.lua
	Author: Senior Combat Systems Engineer
	Description:
		Production server-side demonstration of RaycastHitbox integration on a Melee Weapon.
		Demonstrates clean separation of concerns:
		  - Raycast engine handles spatial trajectory
		  - WeaponController handles combat math, state validation, damage, and audio/VFX replication
]]

local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

-- Require core hitbox module
-- Adjust path according to your Rojo or game hierarchy (e.g. ReplicatedStorage or ServerScriptService)
local RaycastHitbox = require(ServerScriptService:WaitForChild("Hitbox"):WaitForChild("RaycastHitbox"))

--------------------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------------------

local COMBAT_CONFIG = {
	BASE_DAMAGE = 25,
	KNOCKBACK_FORCE = 35,
	ATTACK_COOLDOWN = 0.85,
	-- Hitbox active window (can also be driven precisely via Animation Events / KeyframeMarkers)
	WINDUP_TIME = 0.12,
	ACTIVE_WINDOW = 0.35,
	RECOVERY_TIME = 0.38,
}

--------------------------------------------------------------------------------
-- WEAPON LIFECYCLE & COMBAT CONTROLLER
--------------------------------------------------------------------------------

local function setupWeapon(tool: Tool)
	local handle = tool:WaitForChild("Handle") :: BasePart
	local hitbox: RaycastHitbox.RaycastHitbox? = nil
	local isAttacking = false
	local lastAttackTimestamp = 0

	-- Pre-allocate dedicated RaycastParams
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true

	--[[
		Decoupled Hit Reaction Handler
		Invoked whenever a raycast sweeps through an enemy model.
	]]
	local function onHit(hitPart: BasePart, targetHumanoid: Humanoid?, raycastResult: RaycastResult)
		if not targetHumanoid or targetHumanoid.Health <= 0 then
			-- Optional: Spawn surface impact particles / play metallic clash sound
			return
		end

		local character = tool.Parent :: Model?
		if not character then return end

		local attackerRoot = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local targetRoot = targetHumanoid.Parent and targetHumanoid.Parent:FindFirstChild("HumanoidRootPart") :: BasePart?

		-- Apply deterministic server-validated damage
		targetHumanoid:TakeDamage(COMBAT_CONFIG.BASE_DAMAGE)

		-- Apply directional impulse (knockback)
		if attackerRoot and targetRoot then
			local knockbackDirection = (targetRoot.Position - attackerRoot.Position).Unit
			knockbackDirection = Vector3.new(knockbackDirection.X, 0.2, knockbackDirection.Z).Unit
			targetRoot:ApplyImpulse(knockbackDirection * (targetRoot.AssemblyMass * COMBAT_CONFIG.KNOCKBACK_FORCE))
		end

		-- Spawn impact feedback at exact contact position
		local hitVfxAttachment = Instance.new("Attachment")
		hitVfxAttachment.WorldPosition = raycastResult.Position
		hitVfxAttachment.Parent = workspace.Terrain

		-- Replicate or trigger hit sound/VFX
		task.delay(0.5, function()
			hitVfxAttachment:Destroy()
		end)
	end

	--[[
		Tool Equipped: Initialize Hitbox & Exclude Owner from Collision
	]]
	tool.Equipped:Connect(function()
		local character = tool.Parent :: Model?
		if not character then return end

		-- Update exclude list to avoid self-hitting
		raycastParams.FilterDescendantsInstances = { character }

		-- Construct the hitbox instance using the weapon model
		if not hitbox then
			hitbox = RaycastHitbox.new(tool, raycastParams)
			hitbox.DebugMode = false -- Set to true during QA testing to visualize ray sweeps

			-- Connect observer signal
			hitbox.OnHit:Connect(onHit)
		else
			hitbox:SetRaycastParams(raycastParams)
		end
	end)

	--[[
		Tool Unequipped: Safety Stop
	]]
	tool.Unequipped:Connect(function()
		if hitbox then
			hitbox:Stop()
		end
		isAttacking = false
	end)

	--[[
		Tool Activated: Swing Execution
	]]
	tool.Activated:Connect(function()
		local now = os.clock()
		if isAttacking or (now - lastAttackTimestamp) < COMBAT_CONFIG.ATTACK_COOLDOWN then
			return
		end

		local character = tool.Parent :: Model?
		if not character then return end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end

		isAttacking = true
		lastAttackTimestamp = now

		-- Play attack animation (ensure Animation object exists)
		local animator = humanoid:FindFirstChildOfClass("Animator")
		local attackAnim = tool:FindFirstChild("SlashAnimation") :: Animation?

		local animTrack: AnimationTrack? = nil
		if animator and attackAnim then
			animTrack = animator:LoadAnimation(attackAnim)
			animTrack:Play()
		end

		-- Execution Window:
		-- Option A: Driven by Animation Markers (Best practice in production games)
		-- Option B: Deterministic micro-task scheduling (Fallback / Default below)
		task.delay(COMBAT_CONFIG.WINDUP_TIME, function()
			if not isAttacking or not hitbox then return end
			
			-- Activate continuous collision detection
			hitbox:Start()

			task.delay(COMBAT_CONFIG.ACTIVE_WINDOW, function()
				if hitbox then
					-- Deactivate collision detection as swing finishes active frames
					hitbox:Stop()
				end
			end)
		end)

		-- Reset attack state after full cycle
		task.delay(COMBAT_CONFIG.ATTACK_COOLDOWN, function()
			isAttacking = false
		end)
	end)

	--[[
		Clean cleanup when weapon is disposed
	]]
	tool.Destroying:Connect(function()
		if hitbox then
			hitbox:Destroy()
			hitbox = nil
		end
	end)
end

-- Hook onto weapons dynamically or in StarterPack
for _, player in Players:GetPlayers() do
	player.CharacterAdded:Connect(function(character)
		local tool = character:FindFirstChildOfClass("Tool")
		if tool then
			setupWeapon(tool)
		end
	end)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		character.ChildAdded:Connect(function(child)
			if child:IsA("Tool") then
				setupWeapon(child)
			end
		end)
	end)
end)
