-- =======================================================================
--  District Layout Optimizer for Detailed Map Tacks
--  Finds optimal district placement around a city by maximizing
--  total adjacency yields using a branch and bound search.
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

-- Maximum time in seconds for finding the starting layout and searching. If the search can't finish in time,
-- the best layout found so far is returned, which might not be the best possible layout.
local MAX_SEARCH_SECONDS = 30;
-- Number of random layouts improved to find a good starting layout, in addition to the greedy one.
-- Stops early once a quarter of MAX_SEARCH_SECONDS has passed.
local STARTING_LAYOUT_RESTARTS = 16;
-- Seed of the random layouts. Fixed, so the same input always gives the same result.
local RANDOM_SEED = 12345;
-- Score differences up to this are treated as rounding errors, since weights can be decimal numbers.
local SCORE_EPSILON = 1e-6;
-- Number of steps the search takes between checks of the time limit.
local TIME_CHECK_INTERVAL = 1024;

-- Set to true to also score every layout with the slower reference calculation (same code path as the
-- map tack yields) and log any difference. Only meant for verifying the optimizer, makes it much slower.
local DEBUG_VERIFY_SCORES = false;
-- Set to true to check the best cases the search uses to skip layouts. After the search, every possible layout
-- is scored without skipping any, and every best case below the score of a layout it covers is logged, as well
-- as whether the search found the best score. Only meant for verifying the optimizer with a few districts.
local DEBUG_VERIFY_BOUNDS = false;
-- Maximum time in seconds of the check when DEBUG_VERIFY_BOUNDS is on.
local DEBUG_VERIFY_BOUNDS_MAX_SECONDS = 60;
-- Maximum number of problems each debug check logs in detail.
local DEBUG_MAX_LOGGED_MISMATCHES = 10;

-- =======================================================================
-- Members
-- =======================================================================
-- Virtual pin lookup: "x_y" => pinSubject, used during optimization search.
local m_VirtualPins = {};
-- Stored pin lookup: "x_y" => pinSubject, loaded once per optimization run.
-- GetMapPinSubject() deserializes all stored pins on every call, which is too slow for the search.
local m_StoredPins = {};
-- District type => Adjacency_YieldChanges IDs that apply to the player, cached per optimization run.
local m_ApplicableYieldChanges = {};

-- =======================================================================
-- Layout scoring
-- During the search, only the candidate tiles of the selected districts change: each one is either
-- as it is now, or has one of the selected districts placed on it. So the yield rules of every
-- district on every candidate tile are prepared once per run, and scoring a layout only adds up
-- the prepared numbers instead of reading the map and game database again.
-- The same numbers give the best case (upper bound) of each district on each tile, which the search
-- uses to skip layouts that can't beat the best layout found so far.
-- =======================================================================
local floor = math.floor;

-- Get the Adjacency_YieldChanges IDs of the given district that apply to the player.
-- Cached per optimization run, since the player's techs, civics and traits can't change during the search.
local function GetApplicableYieldChanges(playerID, districtType)
    local yieldChanges = m_ApplicableYieldChanges[districtType];
    if yieldChanges == nil then
        yieldChanges = {};
        for _, adjID in ipairs(GetYieldChangesForDistrict(playerID, districtType)) do
            if IsAdjacencyApplicable(adjID, playerID) then
                table.insert(yieldChanges, adjID);
            end
        end
        m_ApplicableYieldChanges[districtType] = yieldChanges;
    end
    return yieldChanges;
end

-- Get how many times each yield of a district counts in its yield total. Mirror type modifiers add one yield
-- onto another one, which makes the total a fixed multiple of each yield before mirroring.
--
-- Params:
--     evaluator: evaluator of the district on its tile, see PrepareLayoutScoring.
-- Return: table of yield index => factor. Yields without an entry count once.
local function GetYieldFactors(evaluator)
    local factors = {};
    local mirrors = evaluator.Mirrors;
    if mirrors == nil then
        return factors;
    end
    local yieldIndices = {};
    for yieldIndex, _ in pairs(evaluator.Fixed) do
        yieldIndices[yieldIndex] = true;
    end
    for _, term in ipairs(evaluator.Terms) do
        yieldIndices[term.YieldIndex] = true;
    end
    for yieldIndex, _ in pairs(yieldIndices) do
        -- Apply the mirrors like GetDistrictYields does to a yield of 1, then add up all yields.
        local yields = {[yieldIndex] = 1};
        for _, mirror in ipairs(mirrors) do
            yields[mirror.To] = (yields[mirror.To] or 0) + (yields[mirror.From] or 0);
        end
        local factor = 0;
        for _, amount in pairs(yields) do
            factor = factor + amount;
        end
        factors[yieldIndex] = factor;
    end
    return factors;
end

-- Prepare an evaluator for calculating best cases (upper bounds) of its district's weighted yield total.
--
-- The weighted total is the weighted fixed yields plus Weight * factor * Amount * floor(count / TilesRequired)
-- of each term (see GetYieldFactors). That only grows with the count if Weight * factor * Amount is positive,
-- and only shrinks if it is negative (like the Seowon's -1 per adjacent district). So the best case of a term
-- uses the highest possible count if it is positive, and the lowest possible count if it is negative.
-- Adds these fields:
--     BoundFixed:           weighted total of the fixed yields.
--     Terms[i].BoundAmount: Weight * factor * Amount of the term.
--     Terms[i].Limits:      k => (depth => best case count of the k-th adjacent candidate tile while it is free
--                           and only the districts from that depth on can still be placed on it).
--
-- Params:
--     evaluator:     evaluator of the district on its tile, see PrepareLayoutScoring.
--     districtIndex: district index of the evaluator's district.
--     numDistricts:  number of districts in the search.
-- Return: the best case of the district on its tile in any layout.
local function PrepareEvaluatorBounds(evaluator, districtIndex, numDistricts)
    local factors = GetYieldFactors(evaluator);
    local weight = evaluator.Weight;

    local boundFixed = 0;
    for yieldIndex, amount in pairs(evaluator.Fixed) do
        boundFixed = boundFixed + weight * (factors[yieldIndex] or 1) * amount;
    end
    evaluator.BoundFixed = boundFixed;

    local bound = boundFixed;
    for _, term in ipairs(evaluator.Terms) do
        local boundAmount = weight * (factors[term.YieldIndex] or 1) * term.Amount;
        term.BoundAmount = boundAmount;
        term.Limits = {};
        if boundAmount ~= 0 then
            local useHighest = boundAmount > 0;
            local function IsBetter(count, limit)
                if useHighest then
                    return count > limit;
                end
                return count < limit;
            end

            local count = term.Base;
            for k, counts in ipairs(term.Counts) do
                -- In any layout, the adjacent tile is free or has another district (not this one) on it.
                local limit = counts[0];
                for state = 1, numDistricts do
                    if state ~= districtIndex and IsBetter(counts[state], limit) then
                        limit = counts[state];
                    end
                end
                count = count + limit;

                -- During the search, only the districts not placed yet can still be placed on a free tile.
                local limits = {};
                limits[numDistricts + 1] = counts[0];
                for depth = numDistricts, 1, -1 do
                    limits[depth] = limits[depth + 1];
                    if IsBetter(counts[depth], limits[depth]) then
                        limits[depth] = counts[depth];
                    end
                end
                term.Limits[k] = limits;
            end
            bound = bound + boundAmount * floor(count / term.TilesRequired);
        end
    end
    return bound;
end

-- Prepare the scoring of all selected districts on all of their candidate tiles.
--
-- The yield rules of each district on each candidate tile (the same rules the map tacks use) are split
-- into fixed yields and terms that count matching adjacent plots. If an adjacent plot is a candidate
-- tile itself, the term stores its count for every state that plot can be in during the search.
-- Requires m_VirtualPins and m_StoredPins to be set up for the run.
--
-- Params:
--     playerID:        id of the player.
--     sortedDistricts: array of district types in search order. Their array index is the "district index".
--     candidates:      table of district type => array of {X, Y} candidate tiles.
--     districtWeights: table of district type => weight multiplier.
-- Return: a table with
--     NumDistricts:    number of districts.
--     Candidates:      district index => array of {Slot, CacheKey, Pin, Evaluator, Bound, Order}. Bound is the best case
--                      of the district on that tile in any layout. Sorted by Bound (highest first), then by Order, the
--                      index in candidates.
--     CandidateBySlot: district index => (slot => candidate of that district on that candidate tile).
--     State:           slot => district index of the district placed on that candidate tile, 0 if none. All 0 initially.
--     Placed:          district index => candidate the district is placed on, nil if not placed. Empty initially.
--     YieldTypes:      yield index => yield type.
--     ScratchYields:   yield index => amount, reused to calculate the yields of a single district.
--     NumEvaluators:   number of district/candidate tile combinations.
local function PrepareLayoutScoring(playerID, sortedDistricts, candidates, districtWeights)
    local numDistricts = #sortedDistricts;
    local layout = {
        NumDistricts = numDistricts,
        Candidates = {},
        CandidateBySlot = {},
        State = {},
        Placed = {},
        YieldTypes = {},
        ScratchYields = {},
        NumEvaluators = 0,
    };

    -- Give every candidate tile a slot and remember which districts can be placed on it.
    local slotByPlotIndex = {};
    local districtsBySlot = {};
    for districtIndex, districtType in ipairs(sortedDistricts) do
        for _, candidate in ipairs(candidates[districtType]) do
            local plotIndex = Map.GetPlot(candidate.X, candidate.Y):GetIndex();
            local slot = slotByPlotIndex[plotIndex];
            if slot == nil then
                slot = #districtsBySlot + 1;
                slotByPlotIndex[plotIndex] = slot;
                districtsBySlot[slot] = {};
                layout.State[slot] = 0;
            end
            table.insert(districtsBySlot[slot], districtIndex);
        end
    end

    -- Realized features of a plot as an adjacent plot (aggregated, see AddAdjacentPlotFeatures) per state:
    -- 0 = as it is now, district index = that district placed on it.
    local stateFeaturesByPlotIndex = {};
    local function GetPlotStateFeatures(plot, state)
        local plotIndex = plot:GetIndex();
        local stateFeatures = stateFeaturesByPlotIndex[plotIndex];
        if stateFeatures == nil then
            stateFeatures = {};
            stateFeaturesByPlotIndex[plotIndex] = stateFeatures;
        end
        local adjFeatures = stateFeatures[state];
        if adjFeatures == nil then
            local px, py = plot:GetX(), plot:GetY();
            local pinSubject = nil;
            if state == 0 then
                -- Same lookup as GetBonusYieldsWithVirtualPins: virtual pin first, then stored pin.
                local cacheKey = px .. "_" .. py;
                pinSubject = m_VirtualPins[cacheKey] or m_StoredPins[cacheKey];
            else
                pinSubject = {Key = sortedDistricts[state], X = px, Y = py, Type = OPT_MAP_PIN_TYPES.DISTRICT};
            end
            -- The plot feature cache is keyed by plot only, so clear it to not get the features of another state.
            ClearPlotFeatureCache();
            adjFeatures = {};
            AddAdjacentPlotFeatures(adjFeatures, GetRealizedPlotFeatures(playerID, plot, pinSubject));
            stateFeatures[state] = adjFeatures;
        end
        return adjFeatures;
    end

    local yieldIndices = {};
    local function GetYieldIndex(yieldType)
        local yieldIndex = yieldIndices[yieldType];
        if yieldIndex == nil then
            table.insert(layout.YieldTypes, yieldType);
            yieldIndex = #layout.YieldTypes;
            yieldIndices[yieldType] = yieldIndex;
        end
        return yieldIndex;
    end

    local function AddFixedYield(evaluator, yieldIndex, amount)
        if amount ~= 0 then
            evaluator.Fixed[yieldIndex] = (evaluator.Fixed[yieldIndex] or 0) + amount;
            evaluator.FixedTotal = evaluator.FixedTotal + amount;
        end
    end

    -- Build the evaluator of a district on a candidate tile:
    -- {
    --     Weight:     weight multiplier of the district.
    --     Fixed:      yield index => amount that is the same in every layout.
    --     FixedTotal: sum of Fixed.
    --     Terms:      array of {YieldIndex, Amount, TilesRequired, Base, Slots, Counts}. The number of matching
    --                 adjacent plots is Base plus Counts[i][State[Slots[i]]] for each adjacent candidate tile i.
    --     Mirrors:    array of {From, To} yield indices of mirror type modifiers, nil if there are none.
    -- }
    local function BuildEvaluator(pinSubject, plot)
        local districtType = pinSubject.Key;

        -- Same yield rules as the map tacks: adjacencies first, then modifiers.
        local rules = {};
        for _, adjID in ipairs(GetApplicableYieldChanges(playerID, districtType)) do
            table.insert(rules, GetAdjacencyYieldRule(adjID, playerID, plot));
        end
        local activeModifiers, yieldMirrorTable = GetActiveDistrictModifiers(pinSubject, playerID);
        for _, modifierSubject in ipairs(activeModifiers) do
            table.insert(rules, GetModifierYieldRule(modifierSubject, pinSubject, playerID));
        end

        local adjPlots = {};
        for _, adjPlot in pairs(Map.GetAdjacentPlots(pinSubject.X, pinSubject.Y)) do
            if adjPlot ~= nil then
                table.insert(adjPlots, adjPlot);
            end
        end

        local evaluator = {
            Weight = districtWeights[districtType] or 1,
            Fixed = {},
            FixedTotal = 0,
            Terms = {},
        };
        for _, rule in ipairs(rules) do
            if rule.YieldType ~= nil and rule.Amount ~= 0 then
                local yieldIndex = GetYieldIndex(rule.YieldType);
                if rule.AdjType == nil then
                    AddFixedYield(evaluator, yieldIndex, rule.Amount);
                else
                    local term = {
                        YieldIndex = yieldIndex,
                        Amount = rule.Amount,
                        TilesRequired = rule.TilesRequired,
                        Base = 0,
                        Slots = {},
                        Counts = {},
                    };
                    for _, adjPlot in ipairs(adjPlots) do
                        local baseCount = CountYieldRuleMatches(rule, GetPlotStateFeatures(adjPlot, 0));
                        local slot = slotByPlotIndex[adjPlot:GetIndex()];
                        local counts = nil;
                        if slot ~= nil then
                            for _, districtIndex in ipairs(districtsBySlot[slot]) do
                                local count = CountYieldRuleMatches(rule, GetPlotStateFeatures(adjPlot, districtIndex));
                                if count ~= baseCount then
                                    counts = counts or {};
                                    counts[districtIndex] = count;
                                end
                            end
                        end
                        if counts == nil then
                            -- This adjacent plot counts the same in every layout.
                            term.Base = term.Base + baseCount;
                        else
                            -- Fill in every state, so the search doesn't need nil checks.
                            for state = 0, numDistricts do
                                counts[state] = counts[state] or baseCount;
                            end
                            table.insert(term.Slots, slot);
                            table.insert(term.Counts, counts);
                        end
                    end
                    if #term.Slots == 0 then
                        AddFixedYield(evaluator, yieldIndex, CalculateYieldRuleAmount(rule, term.Base));
                    else
                        table.insert(evaluator.Terms, term);
                    end
                end
            end
        end

        -- Mirror type modifiers, applied after all other yields like in GetBonusYields.
        for _, yieldMirror in ipairs(yieldMirrorTable) do
            if yieldMirror.YieldTypeToMirror ~= nil and yieldMirror.YieldTypeToGrant ~= nil then
                evaluator.Mirrors = evaluator.Mirrors or {};
                table.insert(evaluator.Mirrors, {
                    From = GetYieldIndex(yieldMirror.YieldTypeToMirror),
                    To = GetYieldIndex(yieldMirror.YieldTypeToGrant),
                });
            end
        end

        return evaluator;
    end

    for districtIndex, districtType in ipairs(sortedDistricts) do
        local candidateList = {};
        local candidateBySlot = {};
        for order, candidate in ipairs(candidates[districtType]) do
            local plot = Map.GetPlot(candidate.X, candidate.Y);
            local pinSubject = {
                Key = districtType,
                X = candidate.X,
                Y = candidate.Y,
                Type = OPT_MAP_PIN_TYPES.DISTRICT,
            };
            local evaluator = BuildEvaluator(pinSubject, plot);
            local entry = {
                Slot = slotByPlotIndex[plot:GetIndex()],
                CacheKey = candidate.X .. "_" .. candidate.Y,
                Pin = pinSubject,
                Evaluator = evaluator,
                Bound = PrepareEvaluatorBounds(evaluator, districtIndex, numDistricts),
                Order = order,
            };
            table.insert(candidateList, entry);
            candidateBySlot[entry.Slot] = entry;
        end
        -- Highest best case first, so good layouts are found early, and the search can skip all remaining
        -- tiles of a district once their best case is too low.
        table.sort(candidateList, function(a, b)
            if a.Bound ~= b.Bound then
                return a.Bound > b.Bound;
            end
            return a.Order < b.Order;
        end);
        layout.Candidates[districtIndex] = candidateList;
        layout.CandidateBySlot[districtIndex] = candidateBySlot;
        layout.NumEvaluators = layout.NumEvaluators + #candidateList;
    end

    for yieldIndex = 1, #layout.YieldTypes do
        layout.ScratchYields[yieldIndex] = 0;
    end

    -- Don't leave hypothetical plot features in the cache shared with the map tacks.
    ClearPlotFeatureCache();

    return layout;
end

-- Calculate the yields of a district in the layout given by state.
--
-- Params:
--     evaluator: evaluator of the district on its tile, see PrepareLayoutScoring.
--     state:     slot => district index of the district placed on that candidate tile, 0 if none.
--     yields:    yield index => amount for all yield types, overwritten with the district's yields.
-- Return: the total (unweighted) yield amount of the district.
local function GetDistrictYields(evaluator, state, yields)
    local numYieldTypes = #yields;
    local fixed = evaluator.Fixed;
    for i = 1, numYieldTypes do
        yields[i] = fixed[i] or 0;
    end
    local terms = evaluator.Terms;
    for i = 1, #terms do
        local term = terms[i];
        local count = term.Base;
        local slots, counts = term.Slots, term.Counts;
        for k = 1, #slots do
            count = count + counts[k][state[slots[k]]];
        end
        if count ~= 0 then
            yields[term.YieldIndex] = yields[term.YieldIndex] + term.Amount * floor(count / term.TilesRequired);
        end
    end
    local mirrors = evaluator.Mirrors;
    if mirrors then
        for i = 1, #mirrors do
            local mirror = mirrors[i];
            yields[mirror.To] = yields[mirror.To] + yields[mirror.From];
        end
    end
    local total = 0;
    for i = 1, numYieldTypes do
        total = total + yields[i];
    end
    return total;
end

-- Same as GetDistrictYields, but only returns the total, which is faster for districts without mirror type modifiers.
local function GetDistrictYieldTotal(evaluator, state, scratchYields)
    if evaluator.Mirrors then
        return GetDistrictYields(evaluator, state, scratchYields);
    end
    local total = evaluator.FixedTotal;
    local terms = evaluator.Terms;
    for i = 1, #terms do
        local term = terms[i];
        local count = term.Base;
        local slots, counts = term.Slots, term.Counts;
        for k = 1, #slots do
            count = count + counts[k][state[slots[k]]];
        end
        if count ~= 0 then
            total = total + term.Amount * floor(count / term.TilesRequired);
        end
    end
    return total;
end

-- Calculate the best case (upper bound) of a placed district's weighted yield total during the search.
-- Adjacent candidate tiles with a district on them count exactly, free ones count their best case
-- among the districts not placed yet (or none).
--
-- Params:
--     evaluator: evaluator of the district on its tile, prepared with PrepareEvaluatorBounds.
--     state:     slot => district index of the district placed on that candidate tile, 0 if none.
--     depth:     district index of the next district to place. All districts before it are placed, none after it.
-- Return: the best case of the weighted yield total. Equals the weighted yield total if all districts are placed.
local function GetPlacedDistrictBound(evaluator, state, depth)
    local bound = evaluator.BoundFixed;
    local terms = evaluator.Terms;
    for i = 1, #terms do
        local term = terms[i];
        local amount = term.BoundAmount;
        if amount ~= 0 then
            local count = term.Base;
            local slots, counts, limits = term.Slots, term.Counts, term.Limits;
            for k = 1, #slots do
                local districtIndex = state[slots[k]];
                if districtIndex ~= 0 then
                    count = count + counts[k][districtIndex];
                else
                    count = count + limits[k][depth];
                end
            end
            bound = bound + amount * floor(count / term.TilesRequired);
        end
    end
    return bound;
end

-- Sum up the (unweighted) yields of all placed districts. Their placement must be set in layout.State.
--
-- Params:
--     layout: see PrepareLayoutScoring.
--     placed: district index => candidate the district is placed on.
-- Return: table of yield type => total amount.
local function SumLayoutYields(layout, placed)
    local sums = {};
    local yields = layout.ScratchYields;
    for j = 1, #placed do
        GetDistrictYields(placed[j].Evaluator, layout.State, yields);
        for i = 1, #yields do
            sums[i] = (sums[i] or 0) + yields[i];
        end
    end
    local totalYields = {};
    for i, yieldType in ipairs(layout.YieldTypes) do
        if sums[i] ~= nil and sums[i] ~= 0 then
            totalYields[yieldType] = sums[i];
        end
    end
    return totalYields;
end

local function FormatYieldsForLog(yields)
    local parts = {};
    for yieldType, amount in pairs(yields) do
        table.insert(parts, yieldType .. "=" .. amount);
    end
    table.sort(parts);
    return table.concat(parts, ", ");
end

-- Score the layout again with the reference calculation (EvaluateConfiguration, same code path as the
-- map tack yields) and log any difference to the prepared scoring. Used when DEBUG_VERIFY_SCORES is on.
-- The placement must be set in layout.State.
local function VerifyLayoutScore(playerID, layout, placed, districtWeights, score, stats)
    stats.Layouts = stats.Layouts + 1;

    -- Put the placed districts into the virtual pins, so the reference calculation sees them.
    local config = {};
    local coveredPins = {};
    for j, candidate in ipairs(placed) do
        coveredPins[j] = m_VirtualPins[candidate.CacheKey];
        m_VirtualPins[candidate.CacheKey] = candidate.Pin;
        table.insert(config, candidate.Pin);
    end
    local referenceScore, referenceYields = EvaluateConfiguration(playerID, config, districtWeights);
    for j = #placed, 1, -1 do
        m_VirtualPins[placed[j].CacheKey] = coveredPins[j];
    end

    local yields = SumLayoutYields(layout, placed);
    local isMatch = math.abs(score - referenceScore) <= 1e-6;
    for yieldType, amount in pairs(referenceYields) do
        if math.abs((yields[yieldType] or 0) - amount) > 1e-6 then isMatch = false; end
    end
    for yieldType, amount in pairs(yields) do
        if math.abs((referenceYields[yieldType] or 0) - amount) > 1e-6 then isMatch = false; end
    end

    if not isMatch then
        stats.Mismatches = stats.Mismatches + 1;
        if stats.Mismatches <= DEBUG_MAX_LOGGED_MISMATCHES then
            local layoutParts = {};
            for _, candidate in ipairs(placed) do
                table.insert(layoutParts, candidate.Pin.Key .. "(" .. candidate.Pin.X .. "," .. candidate.Pin.Y .. ")");
            end
            print("DMT Optimizer: Score mismatch for " .. table.concat(layoutParts, " ")
                .. ": prepared " .. score .. " (" .. FormatYieldsForLog(yields) .. ")"
                .. ", reference " .. referenceScore .. " (" .. FormatYieldsForLog(referenceYields) .. ")");
        end
    end
end

-- =======================================================================
-- Layout search
-- First a good starting layout is found by placing the districts greedily and improving the layout with
-- small changes. Then a branch and bound search goes through all layouts, but skips every partial layout
-- whose best case can't beat the best layout found so far.
-- =======================================================================

-- Calculate the score of the placed districts. Also works for partial layouts.
local function GetLayoutScore(layout)
    local state, placed, scratchYields = layout.State, layout.Placed, layout.ScratchYields;
    local score = 0;
    for districtIndex = 1, layout.NumDistricts do
        local candidate = placed[districtIndex];
        if candidate ~= nil then
            local evaluator = candidate.Evaluator;
            score = score + evaluator.Weight * GetDistrictYieldTotal(evaluator, state, scratchYields);
        end
    end
    return score;
end

-- Place a district on a candidate tile. The district must not be placed and the tile must be free.
local function PlaceDistrict(layout, districtIndex, candidate)
    layout.State[candidate.Slot] = districtIndex;
    layout.Placed[districtIndex] = candidate;
end

-- Remove a district from the layout, if it is placed.
local function RemoveDistrict(layout, districtIndex)
    local candidate = layout.Placed[districtIndex];
    if candidate ~= nil then
        layout.State[candidate.Slot] = 0;
        layout.Placed[districtIndex] = nil;
    end
end

local function RemoveAllDistricts(layout)
    for districtIndex = 1, layout.NumDistricts do
        RemoveDistrict(layout, districtIndex);
    end
end

-- Return: district index => candidate the district is placed on in the current layout.
local function CopyPlaced(layout)
    local copy = {};
    for districtIndex = 1, layout.NumDistricts do
        copy[districtIndex] = layout.Placed[districtIndex];
    end
    return copy;
end

-- Create a small pseudo random number generator (Park-Miller). Unlike math.random, it always gives the
-- same numbers for the same seed.
-- Return: a function(n) that returns a random integer from 1 to n.
local function CreateRandom(seed)
    local value = seed % 2147483646 + 1;
    return function(n)
        value = (16807 * value) % 2147483647;
        return value % n + 1;
    end
end

-- Place the districts one after another in search order, each on the free tile that gives the districts
-- placed so far the best score.
-- Return: true if all districts could be placed.
local function PlaceDistrictsGreedily(layout)
    for districtIndex = 1, layout.NumDistricts do
        local bestCandidate = nil;
        local bestScore = 0;
        for _, candidate in ipairs(layout.Candidates[districtIndex]) do
            if layout.State[candidate.Slot] == 0 then
                PlaceDistrict(layout, districtIndex, candidate);
                local score = GetLayoutScore(layout);
                RemoveDistrict(layout, districtIndex);
                if bestCandidate == nil or score > bestScore + SCORE_EPSILON then
                    bestCandidate = candidate;
                    bestScore = score;
                end
            end
        end
        if bestCandidate == nil then
            return false;
        end
        PlaceDistrict(layout, districtIndex, bestCandidate);
    end
    return true;
end

-- Place the districts in random order, each on a random free tile.
-- Return: true if all districts could be placed.
local function PlaceDistrictsRandomly(layout, random)
    local order = {};
    for districtIndex = 1, layout.NumDistricts do
        order[districtIndex] = districtIndex;
    end
    for i = #order, 2, -1 do
        local k = random(i);
        order[i], order[k] = order[k], order[i];
    end
    for _, districtIndex in ipairs(order) do
        local freeCandidates = {};
        for _, candidate in ipairs(layout.Candidates[districtIndex]) do
            if layout.State[candidate.Slot] == 0 then
                table.insert(freeCandidates, candidate);
            end
        end
        if #freeCandidates == 0 then
            return false;
        end
        PlaceDistrict(layout, districtIndex, freeCandidates[random(#freeCandidates)]);
    end
    return true;
end

-- Improve a complete layout by moving a district to a free tile or swapping the tiles of two districts,
-- as long as any such change increases the score.
-- Return: the score of the improved layout.
local function ImproveLayout(layout)
    local numDistricts = layout.NumDistricts;
    local state, placed = layout.State, layout.Placed;
    local score = GetLayoutScore(layout);
    local isImproved = true;
    while isImproved do
        isImproved = false;

        -- Move a district to a free tile.
        for districtIndex = 1, numDistricts do
            for _, candidate in ipairs(layout.Candidates[districtIndex]) do
                if state[candidate.Slot] == 0 then
                    local current = placed[districtIndex];
                    RemoveDistrict(layout, districtIndex);
                    PlaceDistrict(layout, districtIndex, candidate);
                    local newScore = GetLayoutScore(layout);
                    if newScore > score + SCORE_EPSILON then
                        score = newScore;
                        isImproved = true;
                    else
                        RemoveDistrict(layout, districtIndex);
                        PlaceDistrict(layout, districtIndex, current);
                    end
                end
            end
        end

        -- Swap the tiles of two districts, if each can be placed on the other's tile.
        for first = 1, numDistricts - 1 do
            for second = first + 1, numDistricts do
                local firstCurrent, secondCurrent = placed[first], placed[second];
                local firstNew = layout.CandidateBySlot[first][secondCurrent.Slot];
                local secondNew = layout.CandidateBySlot[second][firstCurrent.Slot];
                if firstNew ~= nil and secondNew ~= nil then
                    state[firstCurrent.Slot], state[secondCurrent.Slot] = second, first;
                    placed[first], placed[second] = firstNew, secondNew;
                    local newScore = GetLayoutScore(layout);
                    if newScore > score + SCORE_EPSILON then
                        score = newScore;
                        isImproved = true;
                    else
                        state[firstCurrent.Slot], state[secondCurrent.Slot] = first, second;
                        placed[first], placed[second] = firstCurrent, secondCurrent;
                    end
                end
            end
        end
    end
    return score;
end

-- Find a good starting layout for the search: place the districts greedily and improve that layout, then
-- improve some random layouts as well, and keep the best one.
--
-- Params:
--     layout:   see PrepareLayoutScoring. Must have no districts placed, and has none placed afterwards.
--     deadline: os.clock() time after which no more random layouts are tried.
-- Return:
--     bestPlaced:  district index => candidate of the best layout found, nil if no layout could be completed.
--     bestScore:   score of bestPlaced.
--     numImproved: number of layouts that were improved.
local function FindStartingLayout(layout, deadline)
    local bestPlaced = nil;
    local bestScore = 0;
    local numImproved = 0;
    local function ImproveAndKeepBest()
        local score = ImproveLayout(layout);
        numImproved = numImproved + 1;
        if bestPlaced == nil or score > bestScore + SCORE_EPSILON then
            bestPlaced = CopyPlaced(layout);
            bestScore = score;
        end
    end

    if PlaceDistrictsGreedily(layout) then
        ImproveAndKeepBest();
    end
    RemoveAllDistricts(layout);

    local random = CreateRandom(RANDOM_SEED);
    for _ = 1, STARTING_LAYOUT_RESTARTS do
        if os.clock() > deadline then
            break;
        end
        if PlaceDistrictsRandomly(layout, random) then
            ImproveAndKeepBest();
        end
        RemoveAllDistricts(layout);
    end

    return bestPlaced, bestScore, numImproved;
end

-- Calculate the best case of the placed districts (all before the given depth) in any layout completing the current one.
local function GetPlacedBound(layout, depth)
    local state, placed = layout.State, layout.Placed;
    local bound = 0;
    for districtIndex = 1, depth - 1 do
        bound = bound + GetPlacedDistrictBound(placed[districtIndex].Evaluator, state, depth);
    end
    return bound;
end

-- Calculate the best case of the districts after the given depth: the best case of each one's best free tile.
-- Return: the best case, or nil if one of these districts has no free tile left, so the layout can't be completed.
local function GetRemainingBound(layout, depth)
    local state = layout.State;
    local bound = 0;
    for districtIndex = depth + 1, layout.NumDistricts do
        local candidateList = layout.Candidates[districtIndex];
        local districtBound = nil;
        for i = 1, #candidateList do
            -- Sorted by best case, so the first free tile is the best one.
            if state[candidateList[i].Slot] == 0 then
                districtBound = candidateList[i].Bound;
                break;
            end
        end
        if districtBound == nil then
            return nil;
        end
        bound = bound + districtBound;
    end
    return bound;
end

-- Search for the best layout with a branch and bound search. The districts are placed one after another in
-- search order, trying their tiles with the highest best case first. Before trying a tile, the search adds up
-- the best cases of all districts: the placed ones given what is around them now, the one being placed on this
-- tile, and the remaining ones on their best free tile. If that can't beat the best layout found so far, the
-- tile and all following tiles of the district are skipped, since their best cases are even lower.
--
-- Params:
--     layout:     see PrepareLayoutScoring. Must have no districts placed, and has none placed afterwards.
--     bestPlaced: district index => candidate of the best layout found so far, nil if there is none.
--     bestScore:  score of bestPlaced.
--     deadline:   os.clock() time at which the search stops.
--     onScored:   optional function(score), called for every complete layout the search scores.
-- Return:
--     bestPlaced: district index => candidate of the best layout found, nil if there is none.
--     bestScore:  score of bestPlaced.
--     isComplete: true if the search finished before the deadline, so bestPlaced is the best possible layout.
--     numScored:  number of complete layouts scored.
--     numSteps:   number of (partial) layouts the search went through.
local function SearchBestLayout(layout, bestPlaced, bestScore, deadline, onScored)
    local numDistricts = layout.NumDistricts;
    local state, placed, scratchYields = layout.State, layout.Placed, layout.ScratchYields;
    local numScored = 0;
    local numSteps = 0;
    local nextTimeCheck = TIME_CHECK_INTERVAL;
    local isTimedOut = false;

    local function Search(depth)
        numSteps = numSteps + 1;
        if numSteps >= nextTimeCheck then
            nextTimeCheck = numSteps + TIME_CHECK_INTERVAL;
            if os.clock() > deadline then
                isTimedOut = true;
            end
        end
        if isTimedOut then
            return;
        end

        if depth > numDistricts then
            -- All districts placed. Score the layout.
            numScored = numScored + 1;
            local score = 0;
            for districtIndex = 1, numDistricts do
                local evaluator = placed[districtIndex].Evaluator;
                score = score + evaluator.Weight * GetDistrictYieldTotal(evaluator, state, scratchYields);
            end
            if onScored ~= nil then
                onScored(score);
            end
            if bestPlaced == nil or score > bestScore + SCORE_EPSILON then
                bestPlaced = CopyPlaced(layout);
                bestScore = score;
            end
            return;
        end

        local remainingBound = GetRemainingBound(layout, depth);
        if remainingBound == nil then
            return;
        end
        local placedBound = GetPlacedBound(layout, depth);

        local candidateList = layout.Candidates[depth];
        for i = 1, #candidateList do
            local candidate = candidateList[i];
            if bestPlaced ~= nil and placedBound + candidate.Bound + remainingBound <= bestScore + SCORE_EPSILON then
                return;
            end
            local slot = candidate.Slot;
            if state[slot] == 0 then
                state[slot] = depth;
                placed[depth] = candidate;
                Search(depth + 1);
                state[slot] = 0;
                placed[depth] = nil;
                if isTimedOut then
                    return;
                end
            end
        end
    end

    Search(1);
    return bestPlaced, bestScore, not isTimedOut, numScored, numSteps;
end

-- Score every possible layout without skipping any, and check the best cases the search uses against them.
-- Used when DEBUG_VERIFY_BOUNDS is on. Logs every best case that is lower than the score of a layout it covers.
--
-- Params:
--     layout:   see PrepareLayoutScoring. Must have no districts placed, and has none placed afterwards.
--     deadline: os.clock() time at which the check stops.
-- Return:
--     bestScore:     best score of all layouts, nil if there is none.
--     isComplete:    true if all layouts were checked before the deadline.
--     numLayouts:    number of layouts checked.
--     numViolations: number of best cases found too low.
local function VerifyBoundsExhaustively(layout, deadline)
    local numDistricts = layout.NumDistricts;
    local state, placed, scratchYields = layout.State, layout.Placed, layout.ScratchYields;
    local numLayouts = 0;
    local numViolations = 0;
    local isTimedOut = false;

    -- Log a best case that is too low for the current (partial) layout.
    local function LogViolation(message)
        numViolations = numViolations + 1;
        if numViolations <= DEBUG_MAX_LOGGED_MISMATCHES then
            local layoutParts = {};
            for districtIndex = 1, numDistricts do
                local candidate = placed[districtIndex];
                if candidate ~= nil then
                    table.insert(layoutParts, candidate.Pin.Key .. "(" .. candidate.Pin.X .. "," .. candidate.Pin.Y .. ")");
                end
            end
            print("DMT Optimizer: Best case too low for " .. table.concat(layoutParts, " ") .. ": " .. message);
        end
    end

    -- Return: the best score of all layouts completing the current one, nil if there is none.
    local function Explore(depth)
        if isTimedOut then
            return nil;
        end

        if depth > numDistricts then
            numLayouts = numLayouts + 1;
            if numLayouts % TIME_CHECK_INTERVAL == 0 and os.clock() > deadline then
                isTimedOut = true;
            end
            local score = 0;
            for districtIndex = 1, numDistricts do
                local candidate = placed[districtIndex];
                local evaluator = candidate.Evaluator;
                local districtScore = evaluator.Weight * GetDistrictYieldTotal(evaluator, state, scratchYields);
                score = score + districtScore;
                if districtScore > candidate.Bound + SCORE_EPSILON then
                    LogViolation(candidate.Pin.Key .. " scores " .. districtScore .. ", but its best case on its tile is " .. candidate.Bound);
                end
                local completeBound = GetPlacedDistrictBound(evaluator, state, numDistricts + 1);
                if math.abs(completeBound - districtScore) > SCORE_EPSILON then
                    LogViolation(candidate.Pin.Key .. " scores " .. districtScore .. ", but its best case in this layout is " .. completeBound);
                end
            end
            return score;
        end

        local remainingBound = GetRemainingBound(layout, depth);
        local placedBound = GetPlacedBound(layout, depth);
        local bestScore = nil;
        for _, candidate in ipairs(layout.Candidates[depth]) do
            if state[candidate.Slot] == 0 then
                state[candidate.Slot] = depth;
                placed[depth] = candidate;
                local score = Explore(depth + 1);
                if score ~= nil then
                    -- Same best case as the search uses for this tile.
                    if remainingBound == nil then
                        LogViolation("can be completed, although a district has no free tile left");
                    elseif score > placedBound + candidate.Bound + remainingBound + SCORE_EPSILON then
                        LogViolation("can reach a score of " .. score .. ", but its best case is " .. (placedBound + candidate.Bound + remainingBound));
                    end
                    if bestScore == nil or score > bestScore then
                        bestScore = score;
                    end
                end
                state[candidate.Slot] = 0;
                placed[depth] = nil;
            end
        end
        return bestScore;
    end

    local bestScore = Explore(1);
    return bestScore, not isTimedOut, numLayouts, numViolations;
end

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
--     isOptimal:      true if the search finished within MAX_SEARCH_SECONDS, so no configuration scores higher.
--                     false if it stopped at the time limit, so bestConfig is only the best one found.
function OptimizeDistrictLayout(playerID, cityX, cityY, districtTypes, districtWeights, assumeImproved, respectPins)
    districtWeights = districtWeights or {};
    if assumeImproved == nil then assumeImproved = true; end
    if respectPins == nil then respectPins = true; end
    if not districtTypes or #districtTypes == 0 then
        return nil, 0, {}, true;
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
    -- m_StoredPins for any adjacent plot not in m_VirtualPins.

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
        candidates[districtType] = GetCandidateTilesForDistrict(playerID, districtType, candidatePlots, usedTiles, pinnedTiles);
    end

    -- Step 4: Sort districts by fewest candidates first (most-constrained-first).
    local sortedDistricts = {};
    for _, districtType in ipairs(districtTypes) do
        table.insert(sortedDistricts, districtType);
    end
    table.sort(sortedDistricts, function(a, b)
        if #candidates[a] ~= #candidates[b] then
            return #candidates[a] < #candidates[b];
        end
        -- Break ties by name, so the same selection is always searched in the same order.
        return a < b;
    end);

    -- Log candidate counts.
    for _, dt in ipairs(sortedDistricts) do
        print("DMT Optimizer: " .. dt .. " has " .. #candidates[dt] .. " candidate tiles");
    end

    -- Check if any district has zero candidates.
    for _, dt in ipairs(sortedDistricts) do
        if #candidates[dt] == 0 then
            print("DMT Optimizer: " .. dt .. " has no valid placement. Aborting.");
            return nil, 0, {}, true;
        end
    end

    -- Initialize virtual pins with fixed pins and inferred improvements.
    m_VirtualPins = {};
    for key, pin in pairs(fixedPins) do
        m_VirtualPins[key] = pin;
    end
    for key, pin in pairs(inferredPins) do
        m_VirtualPins[key] = pin;
    end

    -- Stored pins, techs, civics and traits can't change during the search, so look them up once per run.
    m_StoredPins = GetMapPinSubjectTable(playerID);
    m_ApplicableYieldChanges = {};

    -- Step 5: Prepare the layout scoring.
    local prepareStart = os.clock();
    local layout = PrepareLayoutScoring(playerID, sortedDistricts, candidates, districtWeights);
    print("DMT Optimizer: Prepared scoring for " .. layout.NumEvaluators .. " district/tile combinations in "
        .. string.format("%.2f", os.clock() - prepareStart) .. "s");

    -- Step 6: Find a good starting layout, so the search can skip more layouts right from the start.
    local searchStart = os.clock();
    local bestPlaced, bestScore, numImproved = FindStartingLayout(layout, searchStart + MAX_SEARCH_SECONDS / 4);
    if bestPlaced ~= nil then
        print("DMT Optimizer: Starting layout found in " .. string.format("%.2f", os.clock() - searchStart)
            .. "s (best of " .. numImproved .. " improved layout(s)), score: " .. bestScore);
    else
        print("DMT Optimizer: No starting layout found");
    end

    -- Step 7: Search for the best layout.
    local verifyStats = nil;
    local onScored = nil;
    if DEBUG_VERIFY_SCORES then
        verifyStats = {Layouts = 0, Mismatches = 0};
        onScored = function(score)
            VerifyLayoutScore(playerID, layout, layout.Placed, districtWeights, score, verifyStats);
        end
    end
    local isOptimal, numScored, numSteps;
    bestPlaced, bestScore, isOptimal, numScored, numSteps = SearchBestLayout(layout, bestPlaced, bestScore,
        searchStart + MAX_SEARCH_SECONDS, onScored);
    local searchElapsed = os.clock() - searchStart;

    local searchResult = "finished";
    if not isOptimal then
        searchResult = "stopped at the time limit of " .. MAX_SEARCH_SECONDS .. "s";
    end
    local bestResult = "no layout found";
    if bestPlaced ~= nil and isOptimal then
        bestResult = "best possible score: " .. bestScore;
    elseif bestPlaced ~= nil then
        bestResult = "best score found: " .. bestScore;
    end
    print("DMT Optimizer: Search " .. searchResult .. ". Steps: " .. numSteps .. ", layouts scored: " .. numScored
        .. ", time: " .. string.format("%.2f", searchElapsed) .. "s, " .. bestResult);

    if DEBUG_VERIFY_BOUNDS then
        local allBestScore, isAllChecked, numLayouts, numViolations = VerifyBoundsExhaustively(layout,
            os.clock() + DEBUG_VERIFY_BOUNDS_MAX_SECONDS);
        local checkedText = "all " .. numLayouts .. " layout(s)";
        if not isAllChecked then
            checkedText = numLayouts .. " layout(s) (stopped at the time limit of " .. DEBUG_VERIFY_BOUNDS_MAX_SECONDS .. "s)";
        end
        print("DMT Optimizer: Checked best cases against " .. checkedText .. ", " .. numViolations .. " too low");
        if isAllChecked and isOptimal then
            local searchBestScore = nil;
            if bestPlaced ~= nil then
                searchBestScore = bestScore;
            end
            if (allBestScore == nil) ~= (searchBestScore == nil)
                or (allBestScore ~= nil and allBestScore > searchBestScore + SCORE_EPSILON) then
                print("DMT Optimizer: Search missed the best layout! Best score of all layouts: " .. tostring(allBestScore)
                    .. ", found by the search: " .. tostring(searchBestScore));
            else
                print("DMT Optimizer: Search found the best score of all layouts: " .. tostring(allBestScore));
            end
        end
    end

    local bestConfig = nil;
    local bestYields = {};
    if bestPlaced ~= nil then
        bestConfig = {};
        for districtIndex, candidate in ipairs(bestPlaced) do
            local pin = candidate.Pin;
            table.insert(bestConfig, {Key = pin.Key, X = pin.X, Y = pin.Y, Type = pin.Type});
            PlaceDistrict(layout, districtIndex, candidate);
        end
        bestYields = SumLayoutYields(layout, bestPlaced);
        if verifyStats ~= nil then
            -- The best layout may be the starting layout, which the search doesn't score again.
            VerifyLayoutScore(playerID, layout, bestPlaced, districtWeights, bestScore, verifyStats);
        end
        RemoveAllDistricts(layout);
    end
    if verifyStats ~= nil then
        print("DMT Optimizer: Verified " .. verifyStats.Layouts .. " layout(s) against the reference calculation, "
            .. verifyStats.Mismatches .. " mismatch(es)");
    end

    -- Clean up.
    m_VirtualPins = {};
    m_StoredPins = {};
    m_ApplicableYieldChanges = {};
    ClearPlotFeatureCache();

    return bestConfig, bestScore, bestYields, isOptimal;
end

-- Find valid candidate tiles for a single district type.
-- Shared by the optimizer search and the UI availability pre-check.
--
-- Params:
--     playerID:       id of the player.
--     districtType:   district type string, e.g. "DISTRICT_CAMPUS".
--     candidatePlots: array of plot objects to consider.
--     usedTiles:      set of "x_y" keys for tiles already occupied.
--     pinnedTiles:    set of "x_y" keys for tiles with existing pins.
-- Return:
--     array of {X, Y} tables for valid placement positions.
function GetCandidateTilesForDistrict(playerID, districtType, candidatePlots, usedTiles, pinnedTiles)
    local results = {};
    for _, plot in ipairs(candidatePlots) do
        local px, py = plot:GetX(), plot:GetY();
        local cacheKey = px .. "_" .. py;
        -- Skip tiles that already have a built district, an existing pin or are owned by another player.
        local isOwnedByOthers = plot:IsOwned() and plot:GetOwner() ~= playerID;
        if not usedTiles[cacheKey] and not pinnedTiles[cacheKey] and not isOwnedByOthers then
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
                table.insert(results, {X = px, Y = py});
            end
        end
    end
    return results;
end

-- Count how many districts of a given type the player has built empire-wide.
local function CountPlayerDistrictsByType(playerID, districtIndex)
    local playerDistricts = Players[playerID]:GetDistricts();
    local count = 0;
    for _, district in playerDistricts:Members() do
        if district and district:GetType() == districtIndex then
            count = count + 1;
        end
    end
    return count;
end

-- Check availability of each district type for the optimizer popup.
-- Determines whether each district can be selected (not already built as
-- one-per-city, and has at least one valid candidate tile).
--
-- Params:
--     playerID:       id of the player.
--     cityX, cityY:   coordinates of the city center.
--     districtTypes:  array of {DistrictType, Name} tables from GetPlaceableDistrictTypes.
--     respectPins:    boolean, whether to respect existing map pins.
-- Return:
--     table of districtType => {available = bool, reason = string|nil}.
function GetDistrictAvailability(playerID, cityX, cityY, districtTypes, respectPins)
    local availability = {};

    -- Get candidate plots within 3-tile radius.
    local candidatePlots = GetPlotsWithinXTiles(cityX, cityY, 3);

    -- Build usedTiles set from plot radius (includes districts from any city).
    local usedTiles = {};
    for _, plot in ipairs(candidatePlots) do
        local px, py = plot:GetX(), plot:GetY();
        local districtIndex = plot:GetDistrictType();
        if districtIndex ~= -1 then
            usedTiles[px .. "_" .. py] = true;
        end
    end

    -- Build builtDistricts set from the actual city's district collection,
    -- not from plot radius, so neighboring cities' districts don't count.
    local builtDistricts = {};
    local player = Players[playerID];
    local playerCities = player:GetCities();
    for _, city in playerCities:Members() do
        if city:GetX() == cityX and city:GetY() == cityY then
            local cityDistricts = city:GetDistricts();
            for _, districtInfo in ipairs(districtTypes) do
                local dt = districtInfo.DistrictType;
                local districtRow = GameInfo.Districts[dt];
                if districtRow and cityDistricts:HasDistrict(districtRow.Index) then
                    builtDistricts[dt] = true;
                end
            end
            break;
        end
    end

    -- Build pinned tiles set.
    local pinnedTiles = {};
    if respectPins then
        local playerPins = PlayerConfigurations[playerID]:GetMapPins();
        for _, mapPinCfg in pairs(playerPins) do
            pinnedTiles[mapPinCfg:GetHexX() .. "_" .. mapPinCfg:GetHexY()] = true;
        end
    end

    for _, districtInfo in ipairs(districtTypes) do
        local districtType = districtInfo.DistrictType;
        local districtRow = GameInfo.Districts[districtType];

        -- Check if one-per-city and already built in this city.
        if districtRow and districtRow.OnePerCity and builtDistricts[districtType] then
            availability[districtType] = {available = false, reason = Locale.Lookup("LOC_DMT_OPTIMIZER_ALREADY_BUILT")};
        -- Check if max-per-player and already built in the empire.
        elseif districtRow and districtRow.MaxPerPlayer and districtRow.MaxPerPlayer > 0
               and CountPlayerDistrictsByType(playerID, districtRow.Index) >= districtRow.MaxPerPlayer then
            availability[districtType] = {available = false, reason = Locale.Lookup("LOC_DMT_OPTIMIZER_ALREADY_BUILT_CIV")};
        else
            -- Check if there are any valid candidate tiles.
            local candidates = GetCandidateTilesForDistrict(playerID, districtType, candidatePlots, usedTiles, pinnedTiles);
            if #candidates == 0 then
                availability[districtType] = {available = false, reason = Locale.Lookup("LOC_DMT_OPTIMIZER_NO_VALID_TILES")};
            else
                availability[districtType] = {available = true, reason = nil};
            end
        end
    end

    return availability;
end

-- Evaluate the total adjacency yield score for a configuration of districts.
-- Reference calculation with the same code path as the map tack yields, using the virtual pin lookup to resolve
-- adjacency between hypothetical pins. The search uses the much faster prepared scoring instead (see
-- PrepareLayoutScoring), so this is only used to verify it (see DEBUG_VERIFY_SCORES).
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

-- Calculate bonus yields for a pin using the virtual pin lookup, falling back to the stored pins.
-- This is a simplified version of GetBonusYields that skips tooltip generation
-- for performance. Only valid during OptimizeDistrictLayout, since it relies on the per-run lookups.
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
            local adjPinSubject = m_VirtualPins[adjCacheKey] or m_StoredPins[adjCacheKey];
            AddAdjacentPlotFeatures(allFeatures, GetRealizedPlotFeatures(playerID, plot, adjPinSubject));
        end
    end

    -- Calculate adjacency yields.
    local bonusYields = {};
    for _, adjID in ipairs(GetApplicableYieldChanges(playerID, pinSubject.Key)) do
        local yieldType, yieldAmount = CalculateYieldFromAdjacency(adjID, allFeatures, playerID, currentPlot, true);
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
        return "ICON_DISTRICT_THEATER";
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
