-- =======================================================================
--  District Layout Optimizer for Detailed Map Tacks
--  Finds optimal district placement around a city by maximizing
--  total adjacency yields using constrained backtracking search.
-- =======================================================================

print("Loading DMT_Optimizer.lua");

include("dmt_yieldcalculator");

-- =======================================================================
-- Constants
-- =======================================================================
local OPT_MAP_PIN_TYPES = {
    DISTRICT = "DISTRICT",
    IMPROVEMENT = "IMPROVEMENT"
};

-- Maximum search iterations before returning best-so-far.
local MAX_SEARCH_ITERATIONS = 100000;

-- =======================================================================
-- Members
-- =======================================================================
-- Virtual pin lookup: "x_y" => pinSubject, used during optimization search.
local m_VirtualPins = {};

-- =======================================================================
-- Public API
-- =======================================================================

-- Main entry point: find the optimal placement of selected districts
-- around a city.
--
-- Params:
--     playerID:       id of the local player.
--     cityX, cityY:   coordinates of the city center.
--     districtTypes:  array of district type strings to optimize.
--                     e.g. {"DISTRICT_CAMPUS", "DISTRICT_HOLY_SITE", "DISTRICT_INDUSTRIAL_ZONE"}
--     districtWeights: optional table of district type => weight multiplier.
--                     e.g. {DISTRICT_CAMPUS = 2, DISTRICT_HOLY_SITE = 0.5}
--                     Defaults to 1 for any district not specified.
--                     When the optimizer evaluates a layout, it might get back something like:
--                     Campus +4 Science, Holy Site +3 Faith, Commercial Hub +2 Gold.
--                     To compare this layout against another one (say: Campus +3 Science, Holy Site +5 Faith, Commercial Hub +1 Gold),
--                     we need a single number.
--                     With equal weights, layout A scores 4+3+2=9, layout B scores 3+5+1=9 - a tie.
--                     If you valued Science more (weight=2), layout A would win: (2*4=8)+3+2=13 vs (2*3=6)+5+1=12.
--     assumeImproved: optional boolean, if true (default), assume bonus/luxury/strategic resource tiles are improved with their
--                     default improvement (e.g. quarry on stone).
--     respectPins:    optional boolean, if true (default), respect existing map pins and don't place districts there nor assume
--                     default resource improvements on those tiles.
-- Return:
--     bestConfig:     array of {Key, X, Y, Type} tables for optimal placement,
--                     or nil if no valid configuration found.
--     bestScore:      total weighted yield score of the best configuration.
--     bestYields:     table of yield type => total (unweighted) amount for the best config.
function OptimizeDistrictLayout(playerID, cityX, cityY, districtTypes, districtWeights, assumeImproved, respectPins)
    districtWeights = districtWeights or {};
    if assumeImproved == nil then assumeImproved = true; end
    if respectPins == nil then respectPins = true; end
    if not districtTypes or #districtTypes == 0 then
        return nil, 0, {};
    end

    print("DMT Optimizer: Starting optimization for " .. #districtTypes .. " districts at (" .. cityX .. "," .. cityY .. ")");

    -- Step 1: Get candidate tiles within 3-tile radius of city center.
    local candidatePlots = GetPlotsWithinXTiles(cityX, cityY, 3);

    -- Step 2: Collect existing fixed districts (already built) as virtual pins.
    local fixedPins = {};
    local usedTiles = {};
    for _, plot in ipairs(candidatePlots) do
        local px, py = plot:GetX(), plot:GetY();
        local districtIndex = plot:GetDistrictType();
        if districtIndex ~= -1 then
            local districtType = GameInfo.Districts[districtIndex].DistrictType;
            local fixedPin = {
                Key = districtType,
                X = px,
                Y = py,
                Type = OPT_MAP_PIN_TYPES.DISTRICT,
            };
            local cacheKey = px .. "_" .. py;
            fixedPins[cacheKey] = fixedPin;
            usedTiles[cacheKey] = true;
        end
    end

    -- Existing pins are taken into account: GetBonusYieldsWithVirtualPins falls back to
    -- GetMapPinSubject(playerID, ...) for any adjacent plot not in m_VirtualPins.

    -- Build a set of tiles which already have any map pin placed on them.
    -- Uses GetMapPins() to avoid GetMapPin(x,y) which has a create-on-access side effect.
    local pinnedTiles = {};
    if respectPins then
        local playerPins = PlayerConfigurations[playerID]:GetMapPins();
        for _, mapPinCfg in pairs(playerPins) do
            local pinKey = mapPinCfg:GetHexX() .. "_" .. mapPinCfg:GetHexY();
            pinnedTiles[pinKey] = true;
        end
    end

    -- Step 2b: If assumeImproved, infer standard improvements on resource tiles
    -- within 4-tile radius (1 beyond district placement range for adjacency).
    local inferredPins = {};
    local resourceToImprovement = GetResourceToImprovementMap();
    if assumeImproved then
        local extendedPlots = GetPlotsWithinXTiles(cityX, cityY, 4);
        for _, plot in ipairs(extendedPlots) do
            local px, py = plot:GetX(), plot:GetY();
            local cacheKey = px .. "_" .. py;
            -- Skip tiles with built districts.
            if not usedTiles[cacheKey] then
                local resourceIndex = plot:GetResourceType();
                local improvementIndex = plot:GetImprovementType();
                -- Only infer if: has resource, no built improvement, no existing pin.
                if resourceIndex ~= -1 and improvementIndex == -1 then
                    local resourceType = GameInfo.Resources[resourceIndex].ResourceType;
                    -- Only infer if the resource is visible to the player (e.g. strategic
                    -- resources require tech to reveal).
                    if IsResourceVisible(playerID, resourceType) then
                        if not pinnedTiles[cacheKey] then
                            local improvementType = resourceToImprovement[resourceType];
                            if improvementType then
                                inferredPins[cacheKey] = {
                                    Key = improvementType,
                                    X = px,
                                    Y = py,
                                    Type = OPT_MAP_PIN_TYPES.IMPROVEMENT,
                                };
                            end
                        end
                    end
                end
            end
        end
        local inferCount = 0;
        for _ in pairs(inferredPins) do inferCount = inferCount + 1; end
        print("DMT Optimizer: Inferred " .. inferCount .. " improvement(s) from resources");
    end

    -- Step 3: For each district type, find valid candidate positions.
    local candidates = {};
    for _, districtType in ipairs(districtTypes) do
        candidates[districtType] = {};
        for _, plot in ipairs(candidatePlots) do
            local px, py = plot:GetX(), plot:GetY();
            local cacheKey = px .. "_" .. py;
            -- Skip tiles that already have a built district or an existing pin.
            if not usedTiles[cacheKey] and not pinnedTiles[cacheKey] then
                -- Clear cache before each check to prevent cross-contamination.
                -- CanPlacePin (via IsValidDamPosition etc.) can cache other plots
                -- with hypothetical district data that poisons subsequent checks.
                ClearPlotFeatureCache();
                local pinSubject = {
                    Key = districtType,
                    X = px,
                    Y = py,
                    Type = OPT_MAP_PIN_TYPES.DISTRICT,
                };
                local canPlace = CanPlacePin(playerID, pinSubject);
                if canPlace then
                    table.insert(candidates[districtType], {X = px, Y = py});
                end
            end
        end
    end

    -- Step 4: Sort districts by fewest candidates first (most-constrained-first).
    local sortedDistricts = {};
    for _, districtType in ipairs(districtTypes) do
        table.insert(sortedDistricts, districtType);
    end
    table.sort(sortedDistricts, function(a, b)
        return #candidates[a] < #candidates[b];
    end);

    -- Log candidate counts.
    for _, dt in ipairs(sortedDistricts) do
        print("DMT Optimizer: " .. dt .. " has " .. #candidates[dt] .. " candidate tiles");
    end

    -- Check if any district has zero candidates.
    for _, dt in ipairs(sortedDistricts) do
        if #candidates[dt] == 0 then
            print("DMT Optimizer: " .. dt .. " has no valid placement. Aborting.");
            return nil, 0, {};
        end
    end

    -- Step 5: Run backtracking search.
    local bestConfig = nil;
    local bestScore = -1;
    local bestYields = {};
    local currentConfig = {};
    local searchIterations = 0;

    -- Initialize virtual pins with fixed pins and inferred improvements.
    m_VirtualPins = {};
    for key, pin in pairs(fixedPins) do
        m_VirtualPins[key] = pin;
    end
    for key, pin in pairs(inferredPins) do
        m_VirtualPins[key] = pin;
    end

    local function Search(districtIndex, usedSearchTiles)
        if searchIterations >= MAX_SEARCH_ITERATIONS then
            return;
        end

        if districtIndex > #sortedDistricts then
            -- All districts placed. Evaluate full configuration.
            searchIterations = searchIterations + 1;
            local score, yields = EvaluateConfiguration(playerID, currentConfig, districtWeights);
            if score > bestScore then
                bestScore = score;
                bestYields = yields;
                -- Deep copy current config as best.
                bestConfig = {};
                for _, entry in ipairs(currentConfig) do
                    table.insert(bestConfig, {Key = entry.Key, X = entry.X, Y = entry.Y, Type = entry.Type});
                end
            end
            return;
        end

        local districtType = sortedDistricts[districtIndex];
        local candidateList = candidates[districtType];

        for _, candidate in ipairs(candidateList) do
            local cacheKey = candidate.X .. "_" .. candidate.Y;
            if not usedSearchTiles[cacheKey] then
                -- Place this district at this candidate.
                local pinSubject = {
                    Key = districtType,
                    X = candidate.X,
                    Y = candidate.Y,
                    Type = OPT_MAP_PIN_TYPES.DISTRICT,
                };
                table.insert(currentConfig, pinSubject);
                usedSearchTiles[cacheKey] = true;
                m_VirtualPins[cacheKey] = pinSubject;

                -- Recurse to place next district.
                Search(districtIndex + 1, usedSearchTiles);

                -- Backtrack.
                table.remove(currentConfig);
                usedSearchTiles[cacheKey] = nil;
                m_VirtualPins[cacheKey] = nil;

                if searchIterations >= MAX_SEARCH_ITERATIONS then
                    return;
                end
            end
        end
    end

    -- Start search with already-used tiles from existing districts.
    local usedSearchTiles = {};
    for key, _ in pairs(usedTiles) do
        usedSearchTiles[key] = true;
    end
    local searchStart = os.clock();
    Search(1, usedSearchTiles);
    local searchElapsed = os.clock() - searchStart;

    print("DMT Optimizer: Search complete. Iterations: " .. searchIterations .. ", Time: " .. string.format("%.1f", searchElapsed) .. "s, Best score: " .. bestScore);

    -- Clean up.
    m_VirtualPins = {};

    return bestConfig, bestScore, bestYields;
end

-- Evaluate the total adjacency yield score for a configuration of districts.
-- Uses the virtual pin lookup to resolve adjacency between hypothetical pins.
--
-- Params:
--     playerID: id of the player.
--     config:   array of {Key, X, Y, Type} entries representing placed districts.
--     districtWeights: table of district type => weight multiplier.
-- Return:
--     totalScore: weighted sum of all yield amounts across all districts.
--     totalYields: table of yield type => total (unweighted) amount.
function EvaluateConfiguration(playerID, config, districtWeights)
    districtWeights = districtWeights or {};

    -- Clear the plot feature cache so each evaluation is fresh.
    ClearPlotFeatureCache();

    local totalScore = 0;
    local totalYields = {};

    for _, pinSubject in ipairs(config) do
        local bonusYields = GetBonusYieldsWithVirtualPins(playerID, pinSubject);
        local weight = districtWeights[pinSubject.Key] or 1;
        for yieldType, amount in pairs(bonusYields) do
            totalYields[yieldType] = (totalYields[yieldType] or 0) + amount;
            totalScore = totalScore + (amount * weight);
        end
    end

    return totalScore, totalYields;
end

-- Calculate bonus yields for a pin using virtual pin lookup instead of stored pins.
-- This is a simplified version of GetBonusYields that skips tooltip generation
-- for performance and uses m_VirtualPins for adjacency resolution.
--
-- Params:
--     playerID:   id of the player.
--     pinSubject: the pin subject to evaluate.
-- Return:
--     bonusYields: table of yield type => amount.
function GetBonusYieldsWithVirtualPins(playerID, pinSubject)
    local currentPlot = Map.GetPlot(pinSubject.X, pinSubject.Y);

    -- Aggregate features from all 6 adjacent plots.
    local allFeatures = {};
    local adjPlots = Map.GetAdjacentPlots(pinSubject.X, pinSubject.Y);
    for i, plot in pairs(adjPlots) do
        if plot ~= nil then
            -- Look up virtual pin first, then fall back to stored pin.
            local adjCacheKey = plot:GetX() .. "_" .. plot:GetY();
            local adjPinSubject = m_VirtualPins[adjCacheKey] or GetMapPinSubject(playerID, plot:GetX(), plot:GetY());

            local features = GetRealizedPlotFeatures(playerID, plot, adjPinSubject);
            for adjType, adjTarget in pairs(features) do
                allFeatures[adjType] = allFeatures[adjType] or {};
                allFeatures[adjType][adjTarget] = (allFeatures[adjType][adjTarget] or 0) + 1;
            end
        end
    end

    -- Calculate adjacency yields.
    local bonusYields = {};
    local yieldChanges = GetYieldChangesForDistrict(playerID, pinSubject.Key);

    for _, adjID in ipairs(yieldChanges) do
        local yieldType, yieldAmount = CalculateYieldFromAdjacency(adjID, allFeatures, playerID, currentPlot);
        if yieldAmount ~= 0 then
            bonusYields[yieldType] = (bonusYields[yieldType] or 0) + yieldAmount;
        end
    end

    -- Calculate modifier yields.
    local yieldTables, yieldMirrorTable = CalculateDistrictYieldFromModifiers(pinSubject, allFeatures, bonusYields, playerID);
    for _, yieldTable in ipairs(yieldTables) do
        if yieldTable.Amount ~= 0 then
            bonusYields[yieldTable.Type] = (bonusYields[yieldTable.Type] or 0) + yieldTable.Amount;
        end
    end
    -- Mirror type modifiers.
    for _, yieldMirror in ipairs(yieldMirrorTable) do
        local yieldAmount = bonusYields[yieldMirror.YieldTypeToMirror] or 0;
        if yieldAmount ~= 0 then
            local yieldType = yieldMirror.YieldTypeToGrant;
            bonusYields[yieldType] = (bonusYields[yieldType] or 0) + yieldAmount;
        end
    end

    return bonusYields;
end

-- Get the list of all placeable district types for the current player.
-- Includes unique districts where applicable, excludes replaced base districts.
--
-- Params:
--     playerID: id of the player.
-- Return:
--     array of {DistrictType, Name} tables.
function GetPlaceableDistrictTypes(playerID)
    local districts = {};
    local playerConfig = PlayerConfigurations[playerID];
    local civName = playerConfig:GetCivilizationTypeName();
    local leaderName = playerConfig:GetLeaderTypeName();

    -- Build a set of base district types that this civ replaces with uniques.
    -- Also build a set of unique districts that belong to this civ.
    local replacedBaseDistricts = {};
    local ownedUniqueDistricts = {};
    for replaceRow in GameInfo.DistrictReplaces() do
        local uniqueType = replaceRow.CivUniqueDistrictType;
        local baseType = replaceRow.ReplacesDistrictType;
        -- Check all traits for this civ/leader to see if this unique belongs to us.
        local isOurs = false;
        for traitRow in GameInfo.CivilizationTraits() do
            if traitRow.CivilizationType == civName then
                -- Check if this trait is associated with the unique district.
                -- The unique district has the same TraitType.
                local uniqueRow = GameInfo.Districts[uniqueType];
                if uniqueRow and uniqueRow.TraitType == traitRow.TraitType then
                    isOurs = true;
                    break;
                end
            end
        end
        if not isOurs then
            for traitRow in GameInfo.LeaderTraits() do
                if traitRow.LeaderType == leaderName then
                    local uniqueRow = GameInfo.Districts[uniqueType];
                    if uniqueRow and uniqueRow.TraitType == traitRow.TraitType then
                        isOurs = true;
                        break;
                    end
                end
            end
        end
        if isOurs then
            replacedBaseDistricts[baseType] = true;
            ownedUniqueDistricts[uniqueType] = true;
        end
    end

    for row in GameInfo.Districts() do
        local districtType = row.DistrictType;
        -- Skip city center and wonder placeholder.
        if not row.CityCenter and districtType ~= "DISTRICT_WONDER" then
            -- Skip base districts replaced by our unique.
            if replacedBaseDistricts[districtType] then
                -- Skip it, our unique replacement is handled below.
            elseif row.TraitType and row.TraitType ~= "" then
                -- This district requires a trait. Only include if it's our unique.
                if ownedUniqueDistricts[districtType] then
                    table.insert(districts, {
                        DistrictType = districtType,
                        Name = Locale.Lookup(row.Name),
                    });
                end
            else
                -- Standard district with no trait requirement.
                table.insert(districts, {
                    DistrictType = districtType,
                    Name = Locale.Lookup(row.Name),
                });
            end
        end
    end

    -- Sort by name for display.
    table.sort(districts, function(a, b) return a.Name < b.Name; end);
    return districts;
end

-- Resolve the correct icon name for a district type.
-- Handles a Theater Square quirk where the icon name differs.
local function GetPinIconName(districtKey)
    local icon = "ICON_" .. districtKey;
    if icon == "ICON_DISTRICT_THEATER" or icon == "ICON_DISTRICT_THEATER_SQUARE" then
        return "ICON_MAP_PIN_DISTRICT_THEATER";
    end
    return icon;
end

-- Place map pins for the optimized configuration.
-- Creates actual MapPin objects at the optimal positions.
--
-- Params:
--     playerID:    id of the player.
--     config:      array of {Key, X, Y, Type} from OptimizeDistrictLayout.
function PlaceOptimizedPins(playerID, config)
    if config == nil or #config == 0 then return; end

    local playerCfg = PlayerConfigurations[playerID];
    if not playerCfg then return; end

    for _, entry in ipairs(config) do
        local icon = GetPinIconName(entry.Key);
        local existingPin = playerCfg.GetMapPin and playerCfg:GetMapPin(entry.X, entry.Y);

        if existingPin and existingPin.SetIconName then
            -- Update existing pin in-place.
            LuaEvents.DMT_MapPinRemoved(existingPin);
            existingPin:SetIconName(icon);
            existingPin:SetName("");
            if playerCfg.UpdateMapPin then playerCfg:UpdateMapPin(existingPin); end
        else
            -- Create new pin. Try AddMapPinAt first, fall back to AddMapPin.
            local pin = nil;
            if playerCfg.AddMapPinAt then pin = playerCfg:AddMapPinAt(entry.X, entry.Y); end
            if type(pin) == "number" and playerCfg.GetMapPinByID then pin = playerCfg:GetMapPinByID(pin); end
            if not pin and playerCfg.AddMapPin then pin = playerCfg:AddMapPin(entry.X, entry.Y); end
            if type(pin) == "number" and playerCfg.GetMapPinByID then pin = playerCfg:GetMapPinByID(pin); end

            if pin and pin.SetIconName then
                pin:SetIconName(icon);
                if pin.SetName then pin:SetName(""); end
                if playerCfg.UpdateMapPin then playerCfg:UpdateMapPin(pin); end
            else
                print("DMT Optimizer: Failed to create pin at (" .. entry.X .. "," .. entry.Y .. ")");
            end
        end
    end

    -- Broadcast changes once after all pins are placed.
    if Network and Network.BroadcastPlayerInfo then Network.BroadcastPlayerInfo(); end
    UI.PlaySound("Map_Pin_Add");

    -- Trigger yield updates for all placed pins.
    for _, entry in ipairs(config) do
        local mapPinCfg = playerCfg:GetMapPin(entry.X, entry.Y);
        if mapPinCfg then
            LuaEvents.DMT_MapPinAdded(mapPinCfg);
        end
    end
end

-- Format the yield results for display.
--
-- Params:
--     yields: table of yield type => amount.
-- Return:
--     formatted string with yield icons and amounts.
function FormatYieldSummary(yields)
    local parts = {};
    for yieldType, amount in pairs(yields) do
        if amount ~= 0 then
            local yieldRow = GameInfo.Yields[yieldType];
            if yieldRow then
                table.insert(parts, yieldRow.IconString .. " " .. amount .. " " .. Locale.Lookup(yieldRow.Name));
            end
        end
    end
    return table.concat(parts, ", ");
end
