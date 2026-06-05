-- =======================================================================
--  District Layout Optimizer Popup
--  UI for selecting which districts to optimize around a city.
-- =======================================================================

print("Loading DMT_OptimizerPopup.lua");

include("dmt_optimizer");

-- =======================================================================
-- Members
-- =======================================================================
local m_SelectedDistricts = {};
local m_CityX = -1;
local m_CityY = -1;
local m_CheckboxInstances = {};
local m_IsOpen = false;
local m_AssumeImproved = true;
local m_RespectPins = true;

-- =======================================================================
-- Functions
-- =======================================================================

-- Open the optimizer popup for the given city position.
function ShowOptimizerPopup(cityX, cityY)
    local playerID = Game.GetLocalPlayer();
    if playerID == -1 then return; end
    
    -- Find the city at or near this position.
    local city = Cities.GetCityInPlot(cityX, cityY);
    if not city or city:GetOwner() ~= playerID then
        city = Cities.GetPlotPurchaseCity(cityX, cityY);
    end

    local cityName = "";
    if city and city:GetOwner() == playerID then
        cityName = Locale.Lookup(city:GetName());
        -- Use the city center coordinates for optimization.
        cityX = city:GetX();
        cityY = city:GetY();
    else
        -- No city found, use cursor position as center.
        cityName = Locale.Lookup("LOC_DMT_OPTIMIZER_NO_CITY");
    end
    
    m_CityX = cityX;
    m_CityY = cityY;

    -- Update city label.
    Controls.CityLabel:SetText(cityName);

    -- Populate district checklist.
    PopulateDistrictChecklist(playerID);

    -- Clear previous results.
    Controls.ResultLabel:SetText("");
    
    -- Show the popup.
    ContextPtr:SetHide(false);
    Controls.OptimizerPopup:SetHide(false);
    m_IsOpen = true;
end

-- Populate the district checklist with available district types.
function PopulateDistrictChecklist(playerID)
    -- Clear existing instances.
    Controls.ChecklistStack:DestroyAllChildren();
    m_CheckboxInstances = {};
    m_SelectedDistricts = {};

    local districtTypes = GetPlaceableDistrictTypes(playerID);

    for _, districtInfo in ipairs(districtTypes) do
        local instance = {};
        ContextPtr:BuildInstanceForControl("DistrictCheckboxInstance", instance, Controls.ChecklistStack);
        
        instance.DistrictLabel:SetText(districtInfo.Name);
        instance.DistrictCheckBox:SetSelected(false);
        instance.DistrictCheckBox:RegisterCallback(Mouse.eLClick, function()
            local isChecked = not instance.DistrictCheckBox:IsSelected();
            instance.DistrictCheckBox:SetSelected(isChecked);
            m_SelectedDistricts[districtInfo.DistrictType] = isChecked or nil;
        end);

        m_CheckboxInstances[districtInfo.DistrictType] = instance;
    end

    Controls.ChecklistStack:CalculateSize();
    Controls.ChecklistStack:ReprocessAnchoring();
    Controls.ChecklistScrollPanel:CalculateSize();
end

-- Run the optimization.
function OnOptimize()
    local playerID = Game.GetLocalPlayer();
    if playerID == -1 then return; end

    -- Collect selected district types.
    local districtTypes = {};
    for districtType, _ in pairs(m_SelectedDistricts) do
        table.insert(districtTypes, districtType);
    end

    if #districtTypes == 0 then
        Controls.ResultLabel:SetText(Locale.Lookup("LOC_DMT_OPTIMIZER_NO_DISTRICTS_SELECTED"));
        return;
    end

    -- Collect per-district weights from the UI inputs.
    local districtWeights = {};
    for districtType, instance in pairs(m_CheckboxInstances) do
        local val = tonumber(instance.WeightInput:GetText());
        if val then
            districtWeights[districtType] = val;
        end
    end

    -- Show a "working" message.
    Controls.ResultLabel:SetText(Locale.Lookup("LOC_DMT_OPTIMIZER_WORKING"));
    Controls.OptimizeButton:SetDisabled(true);

    -- Run the optimizer.
    local bestConfig, bestScore, bestYields = OptimizeDistrictLayout(playerID, m_CityX, m_CityY, districtTypes, districtWeights, m_AssumeImproved, m_RespectPins);

    Controls.OptimizeButton:SetDisabled(false);

    if bestConfig and #bestConfig > 0 then
        -- Place the optimized pins.
        PlaceOptimizedPins(playerID, bestConfig);

        -- Show result.
        local summary = FormatYieldSummary(bestYields);
        Controls.ResultLabel:SetText(Locale.Lookup("LOC_DMT_OPTIMIZER_RESULT", summary));

        -- Close the popup.
        ClosePopup();
    else
        Controls.ResultLabel:SetText(Locale.Lookup("LOC_DMT_OPTIMIZER_NO_SOLUTION"));
    end
end

-- Close the popup.
function ClosePopup()
    Controls.OptimizerPopup:SetHide(true);
    ContextPtr:SetHide(true);
    m_IsOpen = false;
end

function IsOpen()
    return m_IsOpen;
end

-- =======================================================================
-- Callbacks
-- =======================================================================
function OnOverlayClick()
    ClosePopup();
end

-- =======================================================================
-- Initialization
-- =======================================================================
function Initialize()
    Controls.OptimizeButton:RegisterCallback(Mouse.eLClick, OnOptimize);
    Controls.CloseButton:RegisterCallback(Mouse.eLClick, ClosePopup);
    Controls.OverlayButton:RegisterCallback(Mouse.eLClick, OnOverlayClick);

    -- Track state manually because SetSelected() at init time doesn't sync
    -- the visual in AddUserInterface contexts (control hasn't rendered yet).
    Controls.AssumeImprovedCheckBox:RegisterCallback(Mouse.eLClick, function()
        m_AssumeImproved = not m_AssumeImproved;
        Controls.AssumeImprovedCheckBox:SetSelected(m_AssumeImproved);
    end);
    
    Controls.RespectPinsCheckBox:RegisterCallback(Mouse.eLClick, function()
        m_RespectPins = not m_RespectPins;
        Controls.RespectPinsCheckBox:SetSelected(m_RespectPins);
    end);

    -- Listen for optimizer requests.
    LuaEvents.DMT_ShowOptimizerPopup.Add(ShowOptimizerPopup);
end

Initialize();
