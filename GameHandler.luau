-- SERVICES

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remote = ReplicatedStorage.Remotes:WaitForChild("SystemSwitch")
local DashRemote = ReplicatedStorage.Remotes:WaitForChild("DashInput")

-- MATH

local sin = math.sin
local cos = math.cos
local newCF = CFrame.new
local lookAt = CFrame.lookAt
local angles = CFrame.Angles
local clamp = math.clamp
local rad = math.rad
local pi = math.pi

-- CONFIG

local CONFIG = {
	platformCount = math.random(12, 25),
}

local TURRET = {
	spawnPosition = Vector3.new(0, 8, 0),
	magazineSize = 6,
	reloadTime = 3,
	fireRate = 0.5,
	projectileSpeed = 65,
	projectileDamage = 5,
	detectionRange = 150,
	homingStrength = 5,
	projectileLifetime = 8,
	bobHeight = 0.8,
	bobSpeed = 1.5,
}

-- STATE

local Platforms = {}
local Orb = nil
local Enemy = {}
local Aura = {}

local ActiveSystem = nil
local PlatformConnection = nil
local AuraConnection = nil
local TurretInstance = nil
local TurretConnection = nil
local DashConnection = nil

local timer = 0
local auraTimer = 0


-- FIRST STAGE
--------------------------------------------------------------------------------------------------------------------------------

local function generatePlatforms(platformAmount)
	local x = 0
	local y = 5
	local z = 0
	local angle = 0
	local radius = 50
	local heightIncrease = 3

	for i = 1, platformAmount do
		local platform = Instance.new("Part")
		platform.Size = Vector3.new(5, 0.5, 5)
		platform.Anchored = true
		platform.Color = Color3.fromRGB(math.random(0, 255), math.random(0, 255), math.random(0, 255))

		-- x and z use cosine and sine to place each platform around a circle at the given radius
		-- y increases linearly each iteration, turning the flat circle into a rising spiral
		x = cos(rad(angle)) * radius
		z = sin(rad(angle)) * radius
		y += heightIncrease

		platform.CFrame = CFrame.new(x, y, z)
		platform.Parent = workspace

		-- dividing 360 by the total count distributes platforms evenly around the full circle
		angle += 360 / platformAmount

		table.insert(Platforms, {
			part = platform,
			baseCFrame = platform.CFrame,
			offset = i
		})
	end
end

local function movePlatforms(platformsTable)

	-- Heartbeat fires every frame, dt is the elapsed time since the last frame
	-- timer accumulates dt to drive the sine and cosine wave functions below
	PlatformConnection = RunService.Heartbeat:Connect(function(dt)
		timer += dt

		-- clamp(dt * 8, 0, 1) approximates the lerp alpha at the player's current frame rate
		-- keeping movement smooth regardless of whether the game runs at 30 or 60fps
		local lerpSpeed = clamp(dt * 8, 0, 1)

		for _, data in ipairs(platformsTable) do
			local platform = data.part
			local baseCFrame = data.baseCFrame
			local offset = data.offset

			-- sin and cos return values between -1 and 1, scaled to give each platform a gentle wave
			-- the per-platform offset staggers each platform's phase so they move independently
			local yOffset = sin(timer * 2 + offset) * 3
			local xOffset = cos(timer + offset) * 2
			local zOffset = sin(timer + offset) * 2
			local rotX = sin(timer + offset) * 0.3
			local rotY = cos(timer + offset) * 0.3

			local finalCF = baseCFrame * newCF(xOffset, yOffset, zOffset) * angles(rotX, rotY, 0)

			platform.CFrame = platform.CFrame:Lerp(finalCF, lerpSpeed)
		end
	end)
end

local function disablePlatforms()
	if PlatformConnection then
		PlatformConnection:Disconnect()
		PlatformConnection = nil
	end

	for _, data in ipairs(Platforms) do
		if data.part then
			data.part:Destroy()
		end
	end

	table.clear(Platforms)
	timer = 0
end


-- SECOND STAGE
--------------------------------------------------------------------------------------------------------------------------------

local function generateOrb()
	local orb = Instance.new("Part")
	orb.Name = "BouncingOrb"
	orb.Size = Vector3.new(3, 1.5, 3)
	orb.Position = Vector3.new(0, 5, 0)
	orb.Shape = Enum.PartType.Ball
	orb.Material = Enum.Material.Neon
	orb.Color = Color3.fromRGB(0, 255, 255)
	orb.Anchored = false
	orb.CanCollide = true

	-- PhysicalProperties values: density, friction, elasticity, friction weight, elasticity weight
	-- elasticity at 1 makes the orb fully bouncy, density at 0.1 keeps it very light
	orb.CustomPhysicalProperties = PhysicalProperties.new(0.1, 1, 1, 1, 1)

	-- A BodyForce matching gravity keeps the orb hovering at its spawn position until touched
	local bodyForce = Instance.new("BodyForce")
	bodyForce.Force = Vector3.new(0, orb:GetMass() * workspace.Gravity, 0)
	bodyForce.Parent = orb

	orb.Parent = workspace

	local hasBeenPushed = false

	orb.Touched:Connect(function(hit)
		local humanoid = hit.Parent:FindFirstChild("Humanoid")

		if humanoid and not hasBeenPushed then
			hasBeenPushed = true

			-- Push the orb away from the player's touch point with a slight upward bias
			local pushDirection = (orb.Position - hit.Position).Unit
			orb.AssemblyLinearVelocity = (pushDirection + Vector3.new(0, 0.5, 0)) * 150
		end
	end)

	Orb = orb
end

local function disableOrb()
	if Orb then
		Orb:Destroy()
		Orb = nil
	end
end


-- THIRD STAGE
--------------------------------------------------------------------------------------------------------------------------------

-- startChase is defined before showEnemyStage because showEnemyStage calls it after spawning the NPC
-- It runs the pathfinding loop inside task.spawn so it does not block the server while chasing players

local function startChase(npcModel)
	local PathfindingService = game:GetService("PathfindingService")

	local function getClosestPlayer(position)
		local closestRoot = nil
		local closestDist = math.huge

		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			if not char then continue end

			local root = char:FindFirstChild("HumanoidRootPart")
			local humanoid = char:FindFirstChild("Humanoid")

			if root and humanoid and humanoid.Health > 0 then
				local dist = (root.Position - position).Magnitude
				if dist < closestDist then
					closestDist = dist
					closestRoot = root
				end
			end
		end

		return closestRoot
	end

	local humanoid = npcModel:WaitForChild("Humanoid")
	local rootPart = npcModel:WaitForChild("HumanoidRootPart")

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentCanJump = true,
		AgentHeight = 5
	})

	-- The chase loop runs on a separate thread so the rest of the server is not blocked
	-- Each iteration computes a full path and follows it waypoint by waypoint,
	-- recomputing early if the player has moved far enough that the current route is stale
	task.spawn(function()
		while npcModel.Parent do
			local target = getClosestPlayer(rootPart.Position)

			if not target then
				task.wait(0.5)
				continue
			end

			-- ComputeAsync is wrapped in pcall because it can error if the target is unreachable
			local success = pcall(function()
				path:ComputeAsync(rootPart.Position, target.Position)
			end)

			if success and path.Status == Enum.PathStatus.Success then
				local waypoints = path:GetWaypoints()

				-- Waypoint 1 is always the NPC's current position, skipping it prevents a stutter
				for i = 2, #waypoints do
					if not npcModel.Parent then break end

					local point = waypoints[i]

					if point.Action == Enum.PathWaypointAction.Jump then
						humanoid.Jump = true
					end

					humanoid:MoveTo(point.Position)

					-- Cap the wait at 1 second per waypoint so the NPC recomputes
					-- instead of hanging if it gets stuck against geometry
					local arrived = false
					local conn = humanoid.MoveToFinished:Connect(function()
						arrived = true
					end)

					local elapsed = 0
					while not arrived and elapsed < 1 do
						elapsed += task.wait(0.1)
					end

					conn:Disconnect()

					-- Break early and recompute if the target has moved significantly mid-path
					local newTarget = getClosestPlayer(rootPart.Position)
					if newTarget and (newTarget.Position - target.Position).Magnitude > 8 then
						break
					end
				end
			else
				humanoid:MoveTo(target.Position)
				task.wait(0.5)
			end

			task.wait(0.1)
		end
	end)
end

local function showEnemyStage()
	for _, part in ipairs(workspace.Labyrinth:GetChildren()) do
		if part:IsA("BasePart") then
			part.Transparency = 0
			part.CanCollide = true
		end
	end

	local NPC = ReplicatedStorage.ChaseNPC:Clone()
	NPC.Name = "EnemyNPC"
	NPC.Parent = workspace
	NPC:PivotTo(CFrame.new(0, -50, 0))

	table.insert(Enemy, NPC)
	startChase(NPC)
end

local function disableEnemyStage()
	for _, part in ipairs(workspace.Labyrinth:GetChildren()) do
		if part:IsA("BasePart") then
			part.Transparency = 1
			part.CanCollide = false
		end
	end

	for _, npc in ipairs(Enemy) do
		if npc and npc.Parent then
			npc:Destroy()
		end
	end

	table.clear(Enemy)
end


-- FOURTH STAGE
--------------------------------------------------------------------------------------------------------------------------------

-- The Aura system creates 8 orbiting neon spheres around each player
-- Their positions are updated every Heartbeat using CFrame math, forming a helix pattern
-- driven by sine and cosine with per-sphere phase offsets
-- auraTimer runs independently from the platform timer so both systems can coexist

local function generateAura()

	-- Spheres are indexed by UserId so they can be cleanly retrieved and destroyed per player
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if not char then continue end

		local root = char:FindFirstChild("HumanoidRootPart")
		if not root then continue end

		Aura[player.UserId] = {}

		for i = 1, 8 do
			-- i / 8 spreads hue values evenly across the spectrum (0.125, 0.25 ... 1.0)
			local sphere = Instance.new("Part")
			sphere.Size = Vector3.new(0.6, 0.6, 0.6)
			sphere.Shape = Enum.PartType.Ball
			sphere.Material = Enum.Material.Neon
			sphere.Anchored = true
			sphere.CanCollide = false
			sphere.CastShadow = false
			sphere.Color = Color3.fromHSV(i / 8, 1, 1)
			sphere.Parent = workspace

			table.insert(Aura[player.UserId], sphere)
		end
	end

	AuraConnection = RunService.Heartbeat:Connect(function(dt)
		auraTimer += dt

		local lerpSpeed = clamp(dt * 10, 0, 1)

		for _, player in ipairs(Players:GetPlayers()) do
			if not Aura[player.UserId] then continue end

			local char = player.Character
			if not char then continue end

			local root = char:FindFirstChild("HumanoidRootPart")
			if not root then continue end

			local orbs = Aura[player.UserId]

			for i, sphere in ipairs(orbs) do
				-- Spreading 2π across all 8 orbs spaces them evenly around the full circle
				local angle = auraTimer * 2 + (i / #orbs) * (pi * 2)

				-- Spreading the sine phase across π * 2 places each orb at a different wave cycle point,
				-- creating the double-helix shape when viewed as a whole
				local height = sin(auraTimer * 3 + (i / #orbs) * pi * 2) * 2.5

				-- Multiplying by root.CFrame keeps the orbit relative to the player's own orientation
				local localOffset = newCF(cos(angle) * 4, height, sin(angle) * 4)
				local targetCF = root.CFrame * localOffset

				sphere.CFrame = sphere.CFrame:Lerp(targetCF, lerpSpeed)

				-- Each sphere pulses independently using a unique phase offset
				local scale = 0.4 + sin(auraTimer * 5 + i) * 0.15
				sphere.Size = Vector3.new(scale, scale, scale)
			end
		end
	end)
end

-- pairs is used instead of ipairs because Aura is keyed by UserId, not sequential integers
local function disableAura()
	if AuraConnection then
		AuraConnection:Disconnect()
		AuraConnection = nil
	end

	for _, orbs in pairs(Aura) do
		for _, sphere in ipairs(orbs) do
			if sphere and sphere.Parent then
				sphere:Destroy()
			end
		end
	end

	table.clear(Aura)
	auraTimer = 0
end


-- FIFTH STAGE
--------------------------------------------------------------------------------------------------------------------------------

-- Turret acts as a class via Lua's metatable system
-- __index redirects method lookups on any instance back to the Turret table
-- so all methods are shared without being copied into each one

local Turret = {}
Turret.__index = Turret

function Turret.new(position)
	local self = setmetatable({}, Turret)

	self.basePosition = position
	self.ammo = TURRET.magazineSize
	self.reloading = false
	self.cooldown = false
	self.target = nil
	self.active = true
	self.projectiles = {}
	self.timer = 0

	-- The body is an anchored sphere that rotates each frame to face the nearest player
	self.body = Instance.new("Part")
	self.body.Name = "TurretBody"
	self.body.Shape = Enum.PartType.Ball
	self.body.Size = Vector3.new(3, 3, 3)
	self.body.Anchored = true
	self.body.CanCollide = false
	self.body.CastShadow = false
	self.body.Material = Enum.Material.Metal
	self.body.Color = Color3.fromRGB(45, 45, 55)
	self.body.CFrame = newCF(position)
	self.body.Parent = workspace

	-- The barrel is repositioned every frame to protrude from the sphere's current look direction
	-- Its center sits sphere radius (1.5) + half barrel length (1.1) = 2.6 studs ahead of center
	self.barrel = Instance.new("Part")
	self.barrel.Name = "TurretBarrel"
	self.barrel.Size = Vector3.new(0.35, 0.35, 2.2)
	self.barrel.Anchored = true
	self.barrel.CanCollide = false
	self.barrel.CastShadow = false
	self.barrel.Material = Enum.Material.Metal
	self.barrel.Color = Color3.fromRGB(20, 20, 30)
	self.barrel.Parent = workspace

	-- A Roblox cylinder's long axis is X by default, rotating 90 degrees around Z reorients it to Y
	-- forming a flat neon disc that encircles the sphere — red when active, blue when reloading
	self.ring = Instance.new("Part")
	self.ring.Name = "TurretRing"
	self.ring.Shape = Enum.PartType.Cylinder
	self.ring.Size = Vector3.new(0.2, 3.6, 3.6)
	self.ring.Anchored = true
	self.ring.CanCollide = false
	self.ring.CastShadow = false
	self.ring.Material = Enum.Material.Neon
	self.ring.Color = Color3.fromRGB(255, 60, 60)
	self.ring.CFrame = newCF(position) * angles(0, 0, rad(90))
	self.ring.Parent = workspace

	-- A BillboardGui parented to the body floats above the turret showing live ammo state
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 110, 0, 36)
	billboard.StudsOffset = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = self.body

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = TURRET.magazineSize .. " / " .. TURRET.magazineSize
	label.Parent = billboard
	self.ammoLabel = label

	return self
end

-- Scans all players and returns the HumanoidRootPart of whoever is alive and within detection range

function Turret:getClosestPlayer()
	local closestRoot = nil
	local closestDist = TURRET.detectionRange

	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if not char then continue end

		local root = char:FindFirstChild("HumanoidRootPart")
		local humanoid = char:FindFirstChild("Humanoid")

		if root and humanoid and humanoid.Health > 0 then
			local dist = (root.Position - self.body.Position).Magnitude
			if dist < closestDist then
				closestDist = dist
				closestRoot = root
			end
		end
	end

	return closestRoot
end

-- Runs every Heartbeat to update the bob, rotation, and part alignment
-- The body bobs vertically with a sine wave for a floating feel
-- lookAt builds a CFrame pointing toward the target and the body lerps into it each frame for smooth tracking
-- The barrel and ring are rebuilt each frame from the body's current CFrame to stay aligned

function Turret:updateTransform(dt)
	self.timer += dt

	local bobOffset = sin(self.timer * TURRET.bobSpeed) * TURRET.bobHeight
	local bobbedPosition = self.basePosition + Vector3.new(0, bobOffset, 0)

	self.target = self:getClosestPlayer()

	if self.target and self.target.Parent then
		self.body.CFrame = self.body.CFrame:Lerp(lookAt(bobbedPosition, self.target.Position), clamp(dt * 7, 0, 1))
	else
		self.body.CFrame = newCF(bobbedPosition) * angles(0, self.timer * 0.8, 0)
	end

	-- Roblox's forward axis is -Z, offsetting by -2.6 places the barrel flush past the sphere surface
	self.barrel.CFrame = self.body.CFrame * newCF(0, 0, -2.6)

	-- The ring stays flat in world space so it is rebuilt from the bobbed position directly
	self.ring.CFrame = newCF(bobbedPosition) * angles(0, 0, rad(90))
end

-- Spawns a homing projectile from the barrel tip and decrements ammo
-- A BodyVelocity drives the launch and is updated each frame by updateHoming
-- The target is captured at fire time so the projectile always tracks the same player

function Turret:fire()
	if self.reloading or self.cooldown then return end
	if not self.target or not self.target.Parent then return end

	self.cooldown = true
	self.ammo -= 1
	self:refreshDisplay()

	-- Muzzle tip: sphere radius (1.5) + barrel length (2.2) = 3.7 studs ahead of center
	local muzzleCF = self.body.CFrame * newCF(0, 0, -3.7)

	local projectile = Instance.new("Part")
	projectile.Name = "TurretProjectile"
	projectile.Size = Vector3.new(0.45, 0.45, 0.45)
	projectile.Shape = Enum.PartType.Ball
	projectile.Material = Enum.Material.Neon
	projectile.Color = Color3.fromRGB(255, 90, 0)
	projectile.CanCollide = false
	projectile.CastShadow = false
	projectile.CFrame = muzzleCF
	projectile.Parent = workspace

	-- Trail requires two attachments with an offset between them
	-- The color fades from orange to yellow over its lifetime for a flame effect
	local a0 = Instance.new("Attachment")
	a0.Parent = projectile

	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, 0.18, 0)
	a1.Parent = projectile

	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.14
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 90, 0)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 220, 50)),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Parent = projectile

	local bv = Instance.new("BodyVelocity")
	bv.Velocity = self.body.CFrame.LookVector * TURRET.projectileSpeed
	bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
	bv.P = 1e4
	bv.Parent = projectile

	local targetRef = self.target

	local hitConn
	hitConn = projectile.Touched:Connect(function(hit)
		if not projectile.Parent then return end

		if hit.Name == "TurretBody" or hit.Name == "TurretBarrel"
			or hit.Name == "TurretRing" or hit.Name == "TurretProjectile" then return end

		hitConn:Disconnect()

		local humanoid = hit.Parent and hit.Parent:FindFirstChild("Humanoid")
		if humanoid and humanoid.Health > 0 then
			humanoid:TakeDamage(TURRET.projectileDamage)
		end

		self:explode(projectile.Position)
		projectile:Destroy()
	end)

	table.insert(self.projectiles, { part = projectile, bv = bv, target = targetRef })
	Debris:AddItem(projectile, TURRET.projectileLifetime)

	task.delay(TURRET.fireRate, function()
		self.cooldown = false
	end)

	if self.ammo <= 0 then self:reload() end
end

-- Steers in-flight projectiles toward their target each frame
-- Blending the current velocity with the direction to target and normalizing keeps speed constant

function Turret:updateHoming(dt)
	for i = #self.projectiles, 1, -1 do
		local data = self.projectiles[i]

		if not data.part or not data.part.Parent then
			table.remove(self.projectiles, i)
			continue
		end

		if not data.target or not data.target.Parent then
			table.remove(self.projectiles, i)
			continue
		end

		local toTarget = (data.target.Position - data.part.Position).Unit
		local newDir = (data.bv.Velocity.Unit + toTarget * TURRET.homingStrength * dt).Unit
		data.bv.Velocity = newDir * TURRET.projectileSpeed
	end
end

-- DestroyJointRadiusPercent is 0 so the blast never dismantles map geometry

function Turret:explode(position)
	local explosion = Instance.new("Explosion")
	explosion.Position = position
	explosion.BlastRadius = 5
	explosion.BlastPressure = 5e4
	explosion.DestroyJointRadiusPercent = 0
	explosion.Parent = workspace
end

-- Locks firing for TURRET.reloadTime and turns the ring blue to signal the vulnerability window
-- task.delay restores state automatically without blocking the Heartbeat loop

function Turret:reload()
	self.reloading = true
	self.ring.Color = Color3.fromRGB(50, 100, 255)
	self:refreshDisplay()

	task.delay(TURRET.reloadTime, function()
		if not self.active then return end
		self.ammo = TURRET.magazineSize
		self.reloading = false
		self.ring.Color = Color3.fromRGB(255, 60, 60)
		self:refreshDisplay()
	end)
end

function Turret:refreshDisplay()
	if self.reloading then
		self.ammoLabel.Text = "RELOADING..."
		self.ammoLabel.TextColor3 = Color3.fromRGB(80, 150, 255)
	else
		self.ammoLabel.Text = self.ammo .. " / " .. TURRET.magazineSize
		self.ammoLabel.TextColor3 = Color3.new(1, 1, 1)
	end
end

function Turret:destroy()
	self.active = false
	self.body:Destroy()
	self.barrel:Destroy()
	self.ring:Destroy()
end

local function enableTurret()
	TurretInstance = Turret.new(TURRET.spawnPosition)

	TurretConnection = RunService.Heartbeat:Connect(function(dt)
		if not TurretInstance.active then return end
		TurretInstance:updateTransform(dt)
		TurretInstance:updateHoming(dt)
		TurretInstance:fire()
	end)
end

local function disableTurret()
	if TurretConnection then
		TurretConnection:Disconnect()
		TurretConnection = nil
	end

	if TurretInstance then
		TurretInstance:destroy()
		TurretInstance = nil
	end
end


-- SIXTH STAGE
--------------------------------------------------------------------------------------------------------------------------------

-- CooldownTracker manages per-player dash cooldown state using metatables
-- __index allows all instances to share methods without copying them per object

local CooldownTracker = {}
CooldownTracker.__index = CooldownTracker

function CooldownTracker.new()
	return setmetatable({ active = {} }, CooldownTracker)
end

function CooldownTracker:canDash(userId)
	return not self.active[userId]
end

-- task.delay clears the cooldown automatically after the duration without blocking the server
function CooldownTracker:setCooldown(userId, duration)
	self.active[userId] = true
	task.delay(duration, function()
		self.active[userId] = nil
	end)
end

local function enableDash()
	local cooldowns = CooldownTracker.new()
	local dashPower = 85
	local dashCooldown = 1.5
	local dashDuration = 0.18

	DashConnection = DashRemote.OnServerEvent:Connect(function(player)
		local char = player.Character
		if not char then return end

		local root = char:FindFirstChild("HumanoidRootPart")
		local humanoid = char:FindFirstChild("Humanoid")

		if not root or not humanoid or humanoid.Health <= 0 then return end
		if not cooldowns:canDash(player.UserId) then return end

		cooldowns:setCooldown(player.UserId, dashCooldown)

		-- Stripping Y from the look vector keeps the dash horizontal regardless of camera angle
		local look = root.CFrame.LookVector
		local dashDir = Vector3.new(look.X, 0, look.Z).Unit

		-- BodyVelocity is used instead of AssemblyLinearVelocity because the character is client-owned
		-- a one-shot velocity from the server gets overridden almost instantly by the client simulation
		-- BodyVelocity holds the force for the full dash duration so it carries through
		-- MaxForce Y is 0 so the player cannot be launched vertically during the dash
		local bv = Instance.new("BodyVelocity")
		bv.Velocity = dashDir * dashPower
		bv.MaxForce = Vector3.new(1e5, 0, 1e5)
		bv.P = 1e4
		bv.Parent = root

		task.delay(dashDuration, function()
			if bv and bv.Parent then
				bv:Destroy()
			end
		end)
	end)
end

local function disableDash()
	if DashConnection then
		DashConnection:Disconnect()
		DashConnection = nil
	end
end


-- REMOTE HANDLER
--------------------------------------------------------------------------------------------------------------------------------

-- This is the main controller that listens for messages coming from the UI
-- through the RemoteEvent named "SystemSwitch" inside ReplicatedStorage
-- The LocalScript sends strings like: "Platforms", "Orbs", "Dash", etc.

Remote.OnServerEvent:Connect(function(player, systemName)

	-- If the system the player clicked is already active, we turn it OFF
	-- This means clicking the same button twice disables the current system
	if ActiveSystem == systemName then
		if systemName == "Platforms" then disablePlatforms() end
		if systemName == "Orbs" then disableOrb() end
		if systemName == "Enemy" then disableEnemyStage() end
		if systemName == "Aura" then disableAura() end
		if systemName == "Build" then disableTurret() end
		if systemName == "Dash" then disableDash() end

		ActiveSystem = nil
		return
	end

	-- If there was a previous system running, we make sure it is disabled first
	-- This guarantees that only one system can run at the same time
	if ActiveSystem == "Platforms" then disablePlatforms() end
	if ActiveSystem == "Orbs" then disableOrb() end
	if ActiveSystem == "Enemy" then disableEnemyStage() end
	if ActiveSystem == "Aura" then disableAura() end
	if ActiveSystem == "Build" then disableTurret() end
	if ActiveSystem == "Dash" then disableDash() end

	ActiveSystem = systemName

	if systemName == "Platforms" then
		generatePlatforms(CONFIG.platformCount)
		movePlatforms(Platforms)
	end

	if systemName == "Orbs" then generateOrb() end
	if systemName == "Enemy" then showEnemyStage() end
	if systemName == "Aura" then generateAura() end
	if systemName == "Build" then enableTurret() end
	if systemName == "Dash" then enableDash() end
end)
