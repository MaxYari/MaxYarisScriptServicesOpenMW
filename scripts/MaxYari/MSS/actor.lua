--[[
Max Yari's Script Services (MSS) - one script on every actor, interface I.MSS.
Declared by MSS's own MaxYariScriptServices.omwscripts (NPC, CREATURE, PLAYER).

Engine reads that several mods make are made here once and shared. MSS only caches: values are
returned as the engine gave them, and what they mean is up to each mod. Nothing is read until a mod
asks; until then the script only counts frames and sums dt.

Cached getters take an optional maxAge (seconds):
  nil or 0  read at most once per frame, shared by every caller that frame
  > 0       reuse the value until it is that old
  < 0       always read (and refresh the cache for everyone else)
The clock advances in onFrame on the player (the engine runs it before any script's onUpdate) and in
onUpdate on other actors. A pause starting or ending expires every maxAge cache, so something changed
in a menu is seen on the first frame after it.
]]
local core = require('openmw.core')
local types = require('openmw.types')
local omwself = require('openmw.self')
local nearby = require('openmw.nearby')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local VERSION = 1
-- Updates a noted hit waits for its health decrease: health changed by the hit can show up one update
-- after the hit event.
local HIT_KEEP_UPDATES = 2

local selfObject = omwself.object
local selfId = omwself.id
local isPlayer = types.Player.objectIsInstance(omwself)

-- Frame clock ------------------------------------------------------------------------------------
local frame = 0
local time = 0 -- sum of dt, which is 0 while paused
local paused = false
local PAUSE_EXPIRY = 1e6

local function advance(dt)
    frame = frame + 1
    local nowPaused = dt == 0
    if nowPaused ~= paused then
        paused = nowPaused
        time = time + PAUSE_EXPIRY
    end
    time = time + dt
end

local function newEntry()
    return { frame = -1, time = -math.huge }
end

local function isFresh(entry, maxAge)
    if maxAge == nil or maxAge == 0 then return entry.frame == frame end
    if maxAge < 0 then return false end
    return time - entry.time < maxAge
end

local function markFetched(entry)
    entry.frame = frame
    entry.time = time
end

local function nilIfEmpty(list)
    if list == nil or next(list) == nil then return nil end
    return list
end

-- Position and cell --------------------------------------------------------------------------------
-- Each read of omwself.position / .cell makes a new userdata.
local positionEntry = newEntry()
local function getPosition()
    if not isFresh(positionEntry) then
        positionEntry.value = omwself.position
        markFetched(positionEntry)
    end
    return positionEntry.value
end

local cellEntry = newEntry()
local function getCell()
    if not isFresh(cellEntry) then
        cellEntry.value = omwself.cell
        markFetched(cellEntry)
    end
    return cellEntry.value
end

-- Equipment ------------------------------------------------------------------------------------------
local equipmentEntries = {}
local function equipmentEntry(slot, maxAge)
    local entry = equipmentEntries[slot]
    if entry == nil then
        entry = newEntry()
        equipmentEntries[slot] = entry
    end
    if not isFresh(entry, maxAge) then
        local item = types.Actor.getEquipment(omwself, slot)
        markFetched(entry)
        if item ~= entry.item then
            -- Type, id and record are only read when the item changes.
            entry.item = item
            if item == nil then
                entry.info = nil
            else
                local itemType = item.type
                entry.info = {
                    item = item,
                    recordId = item.recordId,
                    type = itemType,
                    record = itemType.record(item),
                }
            end
        end
    end
    return entry
end

local function getEquipment(slot, maxAge)
    return equipmentEntry(slot, maxAge).item
end

local function getEquipmentInfo(slot, maxAge)
    return equipmentEntry(slot, maxAge).info
end

-- Active effects -------------------------------------------------------------------------------------
-- The magnitude is kept rather than the effect, so reading it again costs no engine call.
local selfEffects = nil -- a handle to this actor's live effects, taken on first use
local effectEntries = {}
local function getActiveEffect(effectId, maxAge, extraParam)
    local byParam = effectEntries[effectId]
    if byParam == nil then
        byParam = {}
        effectEntries[effectId] = byParam
    end
    local paramKey = extraParam or false
    local entry = byParam[paramKey]
    if entry == nil then
        entry = newEntry()
        byParam[paramKey] = entry
    end
    if not isFresh(entry, maxAge) then
        if selfEffects == nil then selfEffects = types.Actor.activeEffects(omwself) end
        local effect = selfEffects:getEffect(effectId, extraParam)
        entry.value = effect and effect.magnitude
        markFetched(entry)
    end
    return entry.value
end

-- Health decreases ----------------------------------------------------------------------------------
-- Health is only read while this actor has a listener. Spells don't go through I.Combat onHit, which is why
-- health is read at all. A successful hit is only noted, and the next decrease carries it: one event per
-- decrease, never one for the hit and another for the drop.
local damageListeners = {}
local tracking = false
local health = nil
local lastHealth = nil
local pendingHit = nil
local pendingHitAge = 0
local hitHandlerAdded = false

local function updateTracking()
    local wanted = #damageListeners > 0
    if wanted and not tracking then
        if health == nil then health = types.Actor.stats.dynamic.health(omwself) end
        lastHealth = health.current
        if not hitHandlerAdded then
            hitHandlerAdded = true
            -- Handlers run newest first, so this one sees the hit before the engine applies it.
            -- Returns nothing, so the chain goes on.
            I.Combat.addOnHitHandler(function(attack)
                if tracking and attack.successful then
                    pendingHit = attack
                    pendingHitAge = 0
                end
            end)
        end
    end
    if not wanted then pendingHit = nil end
    tracking = wanted
end

local function trackHealth()
    local current = health.current
    if current ~= lastHealth then
        local previous = lastHealth
        lastHealth = current
        if current < previous then
            local hit = pendingHit
            pendingHit = nil
            local e = {
                actor = selfObject,
                actorId = selfId,
                previousHealth = previous,
                health = current,
                baseHealth = health.base,
                -- The I.Combat AttackInfo of the successful hit noted before this decrease, nil when none.
                hit = hit,
            }
            for i = #damageListeners, 1, -1 do
                damageListeners[i](e)
            end
        end
    end
    if pendingHit then
        pendingHitAge = pendingHitAge + 1
        if pendingHitAge > HIT_KEEP_UPDATES then pendingHit = nil end
    end
end

local function addDamageListener(fn)
    damageListeners[#damageListeners + 1] = fn
    updateTracking()
end

local function removeDamageListener(fn)
    for i = #damageListeners, 1, -1 do
        if damageListeners[i] == fn then table.remove(damageListeners, i) end
    end
    updateTracking()
end

-- Per-frame handler ---------------------------------------------------------------------------------------
local function onUpdate(dt)
    advance(dt)
    if tracking and dt > 0 then trackHealth() end
end

local interface = {
    version = VERSION,
    getPosition = getPosition,
    getCell = getCell,
    getEquipment = getEquipment,
    getEquipmentInfo = getEquipmentInfo,
    getActiveEffect = getActiveEffect,
    addDamageListener = addDamageListener,
    removeDamageListener = removeDamageListener,
}
local eventHandlers = {}
local engineHandlers = {}

-- Combat targets ------------------------------------------------------------------------------------------
-- OpenMW's built-in music script (scripts/omw/music/actor.lua, on every NPC and creature) polls
-- AI.getTargets("Combat") on its actor and sends every change to the player as
-- OMWMusicCombatTargetsChanged. MSS's player script stores them and sends each one back to the actor it
-- belongs to. No AI polling in MSS; if that script is missing, combat targets don't update (the player
-- script checks for it once when it loads and reports it).

if not isPlayer then
    -- NPCs and creatures: own combat targets. The first call reads them once to start from; after that
    -- they only change by event.
    local ownTargets = nil
    local ownTargetsKnown = false

    function interface.getCombatTargets()
        if not ownTargetsKnown then
            ownTargets = nilIfEmpty(I.AI.getTargets("Combat"))
            ownTargetsKnown = true
        end
        return ownTargets
    end

    eventHandlers.MSS_CombatTargets = function(e)
        ownTargets = nilIfEmpty(e.targets)
        ownTargetsKnown = true
    end
    engineHandlers.onUpdate = onUpdate
else
    -- Player: interaction ray and other actors' combat targets ---------------------------------------------
    local camera = require('openmw.camera')
    local ui = require('openmw.ui')
    local vfs = require('openmw.vfs')

    local ACTIVATE_DIST = core.getGMST("iMaxActivateDist")
    local SCREEN_CENTER = util.vector2(0.5, 0.5)
    local RAY_OPTIONS = { ignore = selfObject }
    local NO_HIT = { hit = false }
    local rayEntry = newEntry()
    rayEntry.value = NO_HIT

    -- A rendering ray from the camera through the screen center, activation distance plus the third
    -- person camera distance, as Dynamic Camera casts it to find doors.
    function interface.getInteractionTarget(maxAge)
        if not isFresh(rayEntry, maxAge) then
            local from = camera.getPosition()
            local to = from + camera.viewportToWorldVector(SCREEN_CENTER) * (ACTIVATE_DIST + camera.getThirdPersonDistance())
            local result = nearby.castRenderingRay(from, to, RAY_OPTIONS)
            if result.hit then
                rayEntry.value = { hit = true, hitObject = result.hitObject, hitPos = result.hitPos }
            else
                rayEntry.value = NO_HIT
            end
            markFetched(rayEntry)
        end
        return rayEntry.value
    end

    -- [actor id] = targets; nil when none.
    local combatTable = {}

    function interface.getCombatTargetsOther(actorId)
        return combatTable[actorId]
    end

    -- Stored, and always sent back to the actor it belongs to (its I.MSS.getCombatTargets).
    eventHandlers.OMWMusicCombatTargetsChanged = function(e)
        if e.actor == nil then return end
        local targets = nilIfEmpty(e.targets)
        combatTable[e.actor.id] = targets
        e.actor:sendEvent("MSS_CombatTargets", { targets = targets })
    end

    -- Once per load: the built-in music script still exists and still sends the event. Reported on the
    -- first frame, so the message shows in game.
    local MUSIC_ACTOR_SCRIPT = "scripts/omw/music/actor.lua"
    local MUSIC_EVENT = "OMWMusicCombatTargetsChanged"
    local function musicScriptSendsEvent()
        if not vfs.fileExists(MUSIC_ACTOR_SCRIPT) then return false end
        local file = vfs.open(MUSIC_ACTOR_SCRIPT)
        local text = file:read("*a")
        file:close()
        return string.find(text, MUSIC_EVENT, 1, true) ~= nil
    end
    local reportMissing = not musicScriptSendsEvent()

    -- onFrame runs before any script's onUpdate, so every onUpdate sees this frame's values.
    engineHandlers.onFrame = function(dt)
        if reportMissing then
            reportMissing = false
            local line = string.rep("!", 100)
            print(line)
            print("MSS ERROR: " .. MUSIC_ACTOR_SCRIPT .. " is missing or no longer sends " .. MUSIC_EVENT .. ".")
            print("Combat targets from MSS will not update: mods that use them will not work correctly.")
            print(line)
            ui.showMessage("MSS: OpenMW combat target events not found. Mods using MSS combat targets will not work correctly.")
        end
        onUpdate(dt)
    end
end

return {
    engineHandlers = engineHandlers,
    eventHandlers = eventHandlers,
    interfaceName = "MSS",
    interface = interface,
}
