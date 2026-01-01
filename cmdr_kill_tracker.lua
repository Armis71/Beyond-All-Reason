function widget:GetInfo()
    return {
        name      = "Commander Kill Tracker",
        desc      = "Tracks commander kills with icons, team colors, tooltips, custom AI names, totals, sorting, draggable/resizable, replay-safe",
        author    = "Armis71 + Copilot",
        date      = "2025",
        license   = "GPLv2",
        layer     = 0,
        enabled   = true,
    }
end

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local cfg = {
    x = 0.02,
    y = 0.70,
    w = 0.24,
    h = 0.30,
}

local BASE_ICON_SIZE = 48
local ICON_SIZE = math.floor(BASE_ICON_SIZE * 1.2)
local RESIZE_HANDLE = 18

------------------------------------------------------------
-- SHORTCUTS
------------------------------------------------------------

local spGetUnitTeam        = Spring.GetUnitTeam
local spGetUnitDefID       = Spring.GetUnitDefID
local spGetPlayerInfo      = Spring.GetPlayerInfo
local spGetPlayerList      = Spring.GetPlayerList
local spGetTeamInfo        = Spring.GetTeamInfo
local spGetTeamList        = Spring.GetTeamList
local spGetSpectatingState = Spring.GetSpectatingState
local spGetGameFrame       = Spring.GetGameFrame
local spGetViewGeometry    = Spring.GetViewGeometry
local spGetTeamColor       = Spring.GetTeamColor
local spGetGameRulesParam  = Spring.GetGameRulesParam
local spGetMouseState      = Spring.GetMouseState

local glColor         = gl.Color
local glText          = gl.Text
local glRect          = gl.Rect
local glTexture       = gl.Texture
local glTexRect       = gl.TexRect
local glGetTextWidth  = gl.GetTextWidth

------------------------------------------------------------
-- STATE
------------------------------------------------------------

local commanderKills       = {}
local commanderKillReasons = {}
local commanderUnitDefIDs  = {}

local lastFrame = 0

local dragging    = false
local resizing    = false
local dragOffsetX = 0
local dragOffsetY = 0

widget.box = {}
widget.iconHitboxes = {}

-- Tooltip state
local tooltipText   = nil
local tooltipMouseX = nil
local tooltipMouseY = nil

-- AI naming
local aiTeamNameMap = {}

local widgetFlashFrame = nil

local aiNamePool = {
    "JB_Nemesis_(AI)",
    "Skooliano(AI)",
    "Mannyx47(AI)",
    "MidKnightchaos(AI)",
    "knowledge121(AI)",
    "Virtute71(AI)",
    "Zer01er(AI)",
    "Madfire(AI)",
    "8swarm(AI)",
    "ObelixXV11(AI)",
    "Rayn(AI)",
    "Sheepbon(AI)",
    "TeaBagRumble(AI)",
    "WeaponOfChoiz(AI)",
    "CanIhavesomeshoes(AI)",
    "Harvardboy(AI)",
    "Miodrag(AI)",
}

------------------------------------------------------------
-- UTILS
------------------------------------------------------------

local function Shuffle(tbl)
    for i = #tbl, 2, -1 do
        local j = math.random(i)
        tbl[i], tbl[j] = tbl[j], tbl[i]
    end
end

local function SeedRandomDeterministically()
    local seed = nil

    local gameID = spGetGameRulesParam("gameID") or spGetGameRulesParam("GameID")
    if type(gameID) == "number" then
        seed = gameID
    elseif type(gameID) == "string" then
        local sum = 0
        for i = 1, #gameID do
            sum = sum + string.byte(gameID, i)
        end
        seed = sum
    end

    if not seed then
        seed = os.time()
    end

    math.randomseed(seed)
end

local function AssignCustomAINames()
    if next(aiTeamNameMap) ~= nil then return end

    SeedRandomDeterministically()

    local teams = spGetTeamList()
    if not teams then return end

    local aiTeams = {}
    for _, teamID in ipairs(teams) do
        local _, _, _, isAI = spGetTeamInfo(teamID)
        if isAI then
            aiTeams[#aiTeams + 1] = teamID
        end
    end

    if #aiTeams == 0 then return end

    local names = {}
    for i = 1, #aiNamePool do
        names[i] = aiNamePool[i]
    end
    Shuffle(names)

    local nameCount = #names
    for i = 1, #aiTeams do
        local teamID = aiTeams[i]
        local idx = ((i - 1) % nameCount) + 1
        aiTeamNameMap[teamID] = names[idx]
    end
end

local function DetectCommanderDefs()
    for udid, ud in pairs(UnitDefs) do
        if ud.customParams and ud.customParams.iscommander then
            commanderUnitDefIDs[udid] = true
        end
    end
end

------------------------------------------------------------
-- NAME RESOLUTION
------------------------------------------------------------

local function GetKillerLabel(attackerID)
    if not attackerID then return nil, nil, nil end

    local team = spGetUnitTeam(attackerID)
    if not team then return nil, nil, nil end

    if aiTeamNameMap[team] then
        return "T"..team, aiTeamNameMap[team], team
    end

    local players = spGetPlayerList(team, true)
    if players then
        for _, pid in ipairs(players) do
            local name, active, spec, pTeam = spGetPlayerInfo(pid)
            if pTeam == team and not spec and name then
                return "P"..pid, tostring(name), team
            end
        end
    end

    return "T"..team, "Team " .. team, team
end

local function GetVictimName(teamID)
    if aiTeamNameMap[teamID] then
        return aiTeamNameMap[teamID]
    end

    local players = spGetPlayerList(teamID, true)
    if players then
        for _, pid in ipairs(players) do
            local name, active, spec, pTeam = spGetPlayerInfo(pid)
            if pTeam == teamID and not spec and name then
                return tostring(name)
            end
        end
    end

    return "Team " .. teamID
end

------------------------------------------------------------
-- KILL REASON + WEAPON NAME
------------------------------------------------------------

local function GetKillReason(attackerDefID)
    local ud = UnitDefs[attackerDefID]
    return (ud and ud.humanName) or "Unknown"
end

------------------------------------------------------------
-- RESET ON REPLAY JUMP
------------------------------------------------------------

local function ResetAll()
    commanderKills       = {}
    commanderKillReasons = {}
end

------------------------------------------------------------
-- ICON DRAW
------------------------------------------------------------

local function DrawUnitIcon(unitDefID, x, y, size)
    if not unitDefID then return end
    glTexture("#"..unitDefID)
    glTexRect(x, y, x + size, y + size)
    glTexture(false)
end

------------------------------------------------------------
-- WIDGET EVENTS
------------------------------------------------------------

function widget:Initialize()
    DetectCommanderDefs()
    AssignCustomAINames()
end

function widget:GameFrame(frame)
    if frame < lastFrame then
        ResetAll()
    end
    lastFrame = frame
end

function widget:UnitDestroyed(unitID, unitDefID, unitTeam, attackerID, attackerDefID, attackerTeam, weaponDefID)
    if not commanderUnitDefIDs[unitDefID] then return end
    if attackerTeam == unitTeam then return end

    local killerKey, killerName, killerTeamID = GetKillerLabel(attackerID)
    if not killerKey then return end

    local victimName = GetVictimName(unitTeam)

    local weaponName = nil
    if weaponDefID and WeaponDefs[weaponDefID] then
        weaponName = WeaponDefs[weaponDefID].description
    end

    commanderKills[killerKey] = (commanderKills[killerKey] or 0) + 1

    commanderKillReasons[killerKey] = commanderKillReasons[killerKey] or {}
table.insert(commanderKillReasons[killerKey], {
    killerName    = killerName,
    killerTeamID  = killerTeamID,
    victimName    = victimName,
    victimTeamID  = unitTeam,
    attackerDefID = attackerDefID,
    reason        = GetKillReason(attackerDefID),
    weaponName    = weaponName,
    timestamp     = spGetGameFrame(),   -- NEW: highlight timestamp
})
 widgetFlashFrame = spGetGameFrame()

end

------------------------------------------------------------
-- DRAW PANEL
------------------------------------------------------------

local function DrawPanel()
    local vsx, vsy = spGetViewGeometry()
    local x1 = vsx * cfg.x
    local y1 = vsy * cfg.y
    local w  = vsx * cfg.w
    local h  = vsy * cfg.h

if widgetFlashFrame then
        local age = spGetGameFrame() - widgetFlashFrame
        if age < 45 then
            local t = age / 45
            local pulse = math.abs(math.sin(t * math.pi * 12))
            glColor(1, 1, 0.4, pulse * 0.55)
            glRect(x1 - 4, y1 - 4, x1 + w + 4, y1 + h + 4)
            glColor(1,1,1,1)
        else
            widgetFlashFrame = nil
        end
    end


    widget.box = {x1=x1, y1=y1, x2=x1+w, y2=y1+h}
    widget.iconHitboxes = {}

    glColor(0,0,0,0.35)
    glRect(x1, y1, x1+w, y1+h)

    glColor(1,1,1,1)
    glText("Commander Kills:", x1 + 10, y1 + h - 24, 18, "o")

    local y = y1 + h - 60

    --------------------------------------------------------
    -- SORT KILLERS BY TOTAL KILLS (DESCENDING)
    --------------------------------------------------------
    local sortedKillers = {}
    for killerKey, total in pairs(commanderKills) do
        sortedKillers[#sortedKillers + 1] = { key = killerKey, total = total }
    end

    table.sort(sortedKillers, function(a, b)
        return a.total > b.total
    end)

    --------------------------------------------------------
    -- DRAW SORTED KILLERS
    --------------------------------------------------------
    for _, data in ipairs(sortedKillers) do
        local killerKey = data.key
        local total     = data.total
        local entries   = commanderKillReasons[killerKey]

        if entries and #entries > 0 then
            local killerName   = entries[1].killerName
            local killerTeamID = entries[1].killerTeamID

            -- Team color for killer (safe fallback)
            local kr, kg, kb = spGetTeamColor(killerTeamID)
            kr, kg, kb = kr or 1, kg or 1, kb or 1

            glColor(kr, kg, kb, 1)
            glText(string.format("%s: %d", killerName, total), x1 + 12, y, 16, "o")
            glColor(1,1,1,1)

            y = y - 30

for _, entry in ipairs(entries) do
    if y < y1 + 20 then break end

    local ix1 = x1 + 12
    local iy1 = y - ICON_SIZE + 4
    local ix2 = ix1 + ICON_SIZE
    local iy2 = iy1 + ICON_SIZE

    ------------------------------------------------------------
    -- STRONG HIGHLIGHT EFFECT (A + C combined)
    ------------------------------------------------------------
    local age = spGetGameFrame() - (entry.timestamp or 0)
    if age < 36 then  -- ~1.2 seconds at 30fps
        local t = age / 36
        local alpha = 1 - t

        -- Full row flash (background bar)
        glColor(1, 1, 0.4, alpha * 0.55)
        glRect(x1 + 6, y - ICON_SIZE - 2, x1 + w - 6, y + 6)

        -- Icon glow
        glColor(1, 1, 0.2, alpha * 0.9)
        glRect(ix1 - 6, iy1 - 6, ix2 + 6, iy2 + 6)

        glColor(1,1,1,1)
    end
    ------------------------------------------------------------

    -- Draw icon
    DrawUnitIcon(entry.attackerDefID, ix1, iy1, ICON_SIZE)

    -- Victim name
    local nameX = x1 + ICON_SIZE + 24
    local nameY = y - (ICON_SIZE * 0.5)
    local nameWidth = (glGetTextWidth(entry.victimName) or 0) * 14

    glText(entry.victimName, nameX, nameY, 14, "o")

    -- Tooltip hitbox
    widget.iconHitboxes[#widget.iconHitboxes + 1] = {
        x1 = ix1, y1 = iy1,
        x2 = ix2, y2 = iy2,

        unitDefID  = entry.attackerDefID,
        weaponName = entry.weaponName,

        nameRightX = nameX + nameWidth,
        nameMidY   = nameY,
    }

    y = y - (ICON_SIZE + 12)
end

            y = y - 10
        end
    end

    glColor(1,1,1,0.7)
    glRect(x1 + w - RESIZE_HANDLE, y1, x1 + w, y1 + RESIZE_HANDLE)
end

------------------------------------------------------------
-- CUSTOM TOOLTIP (RIGHT OF NAME)
------------------------------------------------------------

local function DrawCustomTooltip()
    if not tooltipText or not tooltipMouseX or not tooltipMouseY then
        return
    end

    local padding  = 6
    local fontSize = 14

    local width  = (glGetTextWidth(tooltipText) or 0) * fontSize
    local height = fontSize * 2

    local x1 = tooltipMouseX
    local x2 = x1 + width + padding * 2

    local y1 = tooltipMouseY - (height * 0.5)
    local y2 = y1 + height + padding * 2

    glColor(0, 0, 0, 0.75)
    glRect(x1, y1, x2, y2)

    glColor(1, 1, 1, 1)
    glText(tooltipText, x1 + padding, y1 + padding, fontSize, "o")
end

------------------------------------------------------------
-- DRAW SCREEN
------------------------------------------------------------

function widget:DrawScreen()
    -- Always draw, both in games and replays
    DrawPanel()

    tooltipText   = nil
    tooltipMouseX = nil
    tooltipMouseY = nil

    local mx, my = spGetMouseState()

    for _, box in ipairs(widget.iconHitboxes) do
        if mx >= box.x1 and mx <= box.x2 and my >= box.y1 and my <= box.y2 then
            local ud = UnitDefs[box.unitDefID]

            local unitName =
                (ud and (ud.translatedHumanName or ud.humanName or ud.name))
                or "Unknown Unit"

            local weapon = box.weaponName or "Unknown Weapon"

            tooltipText   = string.format("Unit: %s\nWeapon: %s", unitName, weapon)
            tooltipMouseX = box.nameRightX + 12
            tooltipMouseY = box.nameMidY
            break
        end
    end

    DrawCustomTooltip()
end

------------------------------------------------------------
-- DRAG + RESIZE
------------------------------------------------------------

local function IsInBox(mx, my)
    local b = widget.box
    if not b.x1 or not b.x2 or not b.y1 or not b.y2 then
        return false
    end
    return mx >= b.x1 and mx <= b.x2 and my >= b.y1 and my <= b.y2
end

local function IsInResize(mx, my)
    local b = widget.box
    if not b.x1 or not b.x2 or not b.y1 or not b.y2 then
        return false
    end
    return mx >= b.x2 - RESIZE_HANDLE and mx <= b.x2
       and my >= b.y1 and my <= b.y1 + RESIZE_HANDLE
end

function widget:MousePress(mx, my, button)
    local b = widget.box
    if not b.x1 then return false end
    if button ~= 1 then return false end

    if IsInResize(mx, my) then
        resizing = true
        return true
    end

    if IsInBox(mx, my) then
        dragging    = true
        dragOffsetX = mx - widget.box.x1
        dragOffsetY = my - widget.box.y1
        return true
    end

    return false
end

function widget:MouseMove(mx, my, dx, dy, button)
    local vsx, vsy = spGetViewGeometry()

    if dragging then
        cfg.x = math.max(0, math.min((mx - dragOffsetX) / vsx, 1 - cfg.w))
        cfg.y = math.max(0, math.min((my - dragOffsetY) / vsy, 1 - cfg.h))
    end

    if resizing then
        local newW = (mx - widget.box.x1) / vsx
        local bottom = widget.box.y1
        local newH   = (my - bottom) / vsy

        cfg.w = math.max(0.10, math.min(newW, 0.80))
        cfg.h = math.max(0.10, math.min(newH, 0.80))
    end
end

function widget:MouseRelease(mx, my, button)
    dragging = false
    resizing = false
end

------------------------------------------------------------
-- SAVE/LOAD
------------------------------------------------------------

function widget:GetConfigData()
    return cfg
end

function widget:SetConfigData(data)
    if type(data) == "table" then
        cfg.x = data.x or cfg.x
        cfg.y = data.y or cfg.y
        cfg.w = data.w or cfg.w
        cfg.h = data.h or cfg.h
    end
end