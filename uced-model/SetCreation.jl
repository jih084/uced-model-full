# In the "Generators_data.csv", coal/gas/nuclear have 'Commit' set to 1, while other technologies are set to 0.
# Set of generators of differnt technologies
# Note that below sets should be in exact order to avoid errors in the model
setWINDSOLAR = generators[(generators.SOLAR .== 1) .| (generators.WIND .== 1), :R_ID]
setHYDRO = generators[(generators.HYDRO .== 1), :R_ID]
setSTOR = generators[(generators.STOR .== 1), :R_ID] 
setUC_full = generators[(generators.COAL .== 1) .| (generators.GAS .== 1) .| (generators.NUCLEAR .== 1), :R_ID]
setCOAL_full = generators[generators.COAL .== 1, :R_ID] # Set of coal generators
setCHP_full = generators[generators.technology .== "cogen_conventional_steam_coal", :R_ID] # Set of chp coal units
setGEN_full = union(setWINDSOLAR,setHYDRO,setUC_full,setSTOR) #all generators
setCAPTIVE = intersect(setCOAL_full, generators[generators.captive .== 1, :R_ID])
setUC = captive_scenario ? setdiff(setUC_full, setCAPTIVE) : setUC_full # Exclude captive plants if in captive scenario
setCOAL = captive_scenario ? setdiff(setCOAL_full, setCAPTIVE) : setCOAL_full # Exclude captive plants if in captive scenario
setCHP = captive_scenario ? setdiff(setCHP_full, setCAPTIVE) : setCHP_full # Exclude captive plants if in captive scenario
setGEN = captive_scenario ? setdiff(setGEN_full, setCAPTIVE) : setGEN_full # Exclude captive plants if in captive scenario
setNONCHP = setdiff(setCOAL, setCHP) # Set of generators excluding CHP units
setRetro = generators[generators.Retrofitted .== "1", :R_ID]
println("Retrofitted units: $(length(setRetro)) units")
#setQuota = quota_data

# setTIME = demand.Time_Index # Set of time periods/hours
setTIME = collect(1:hours_per_period)
temp_segment = collect(skipmissing(demand.Demand_segment)) # Set of demand segment

setSEGMENT = []
for i in 1:first(size(temp_segment))
    push!(setSEGMENT, Int(temp_segment[i]))
end

setZONE = unique(generators.Zone) # Set of zones
int_generators = filter(row -> row.region != "SD" && row.region != "JB", generators) #exclude genertors in SD and JB
setIntZONE = unique(int_generators.Zone)
println("setIntZone includes ", setIntZONE)


setLINEFWD = collect(1:first(size(network_fwd))) # Set of forward transmission liness
setLINERVS = collect(1:first(size(network_rvs))) # Set of reverse transmission lines
setLINE = setLINEFWD # Same: setLINE = setLINERVS

SD_znumber = first(reg_zone[reg_zone.Region_description .== "SD", :Network_zones])
JB_znumber = first(reg_zone[reg_zone.Region_description .== "JB", :Network_zones])
println("zone number of SD is ", SD_znumber)
println("zone number of JB is ", JB_znumber)

# Select Network_Lines from network_fwd and network_rvs DataFrame (for SD and JB, i.e., external zone(s))
setSDLINEFWD = network_fwd[(network_fwd[!, Symbol(SD_znumber)] .== -1), :Network_Lines]
setSDLINERVS = network_rvs[(network_rvs[!, Symbol(SD_znumber)] .== 1), :Network_Lines]
setJBLINEFWD = network_fwd[(network_fwd[!, Symbol(JB_znumber)] .== -1), :Network_Lines]
setJBLINERVS = network_rvs[(network_rvs[!, Symbol(JB_znumber)] .== 1), :Network_Lines]

setExtLINE = vcat(setSDLINEFWD, setJBLINEFWD) # Same: setExtLINE = vcat(setSDLINEREV, setJBLINEREV)
setIntLINE = setdiff(setLINEFWD, setExtLINE) # Same: setIntLINE = setdiff(setLINERVS, setExtLINE)
println("setIntLINE is ", setIntLINE)
println("setExtLINE is ", setExtLINE)
println("line number of SD (forward) is ", setSDLINEFWD)  
println("line number of SD (reverse) is ",setSDLINERVS)

# setSTARTS = 1:hours_per_period:maximum(setTIME) # Set of time periods indicating a period starts
# setINTERIORS = setdiff(setTIME, setSTARTS) # Set of time periods within a period
setSTARTS = [1]
setINTERIORS = setdiff(setTIME, setSTARTS)

contn1 = []
for z in setZONE
    if string("z", z) != SD_znumber && string("z", z) != JB_znumber
        maxuc = maximum(generators[intersect(setUC, generators[generators.Zone .== z, :R_ID]), :Cap_Size])
        maxline = maximum(network_fwd[(network_fwd[!, string("z", z)] .== 1) .| (network_fwd[!, string("z", z)] .== -1), :Max_AC_Cap])
        # Same: maxline = maximum(network_fwd[(network_fwd[!, string("z", z)] .== 1) .| (network_fwd[!, string("z", z)] .== -1), :Max_AC_Cap])
        push!(contn1, maximum([maxuc, maxline]))
    elseif string("z", z) == SD_znumber
        push!(contn1, SDcont) # Assign a 0 for SD zone to avoid simulated exports that cannot satisfy the n-1-1 operating reserve.
    elseif string("z", z) == JB_znumber
        push!(contn1, JBcont) # Assign a 0 for JB zone to avoid simulated exports that cannot satisfy the n-1-1 operating reserve.
    else
        nothing
    end
end
println("contingency requirements (N-1-1) for each zone: ", contn1)

# Reading non-served energy data and create a data frame
nse = DataFrame(Segment = collect(skipmissing(demand.Demand_segment)),
                NSE_Cost = collect(skipmissing(demand.Cost_of_demand_curtailment_perMW)) * first(demand.Voll),
                NSE_Max = collect(skipmissing(demand.Max_demand_curtailment)))


# If only 1 segment, use the codes below
# for z in 1:length(setZONE)-1
    #push!(nse, nse[1,:])
# end
# insertcols!(nse, 1, :Zone => setZONE)

# If multiple segments, use the codes below
nse_final = DataFrame()
for zone in setZONE
    nse_zone = copy(nse)
    if !hasproperty(nse_zone, :Zone)  # Only insert Zone column if it doesn't exist
        insertcols!(nse_zone, 1, :Zone => fill(zone, nrow(nse_zone)))
    else
        nse_zone.Zone .= zone  # If Zone column exists, just update its values
    end
    append!(nse_final, nse_zone)
end
nse = nse_final

# "Priority" means NSE cost in NC grid is more expensive than that in NE grid
if scenario_name in ["PriorityMLT"]
    nse.NSE_Cost = nse.NSE_Cost
    nse[nse.Zone .== parse(Int64, string(SD_znumber[end])), :NSE_Cost] = nse[nse.Zone .== parse(Int64, string(SD_znumber[end])), :NSE_Cost] * NE_nonserved_reduction
    nse[nse.Zone .== parse(Int64, string(JB_znumber[end])), :NSE_Cost] = nse[nse.Zone .== parse(Int64, string(JB_znumber[end])), :NSE_Cost] * NE_nonserved_reduction
else
    nothing
end


# println("NE_nonserved_reduction: ", NE_nonserved_reduction)
# println("NCG's NSE penalty is ", NE_nonserved_reduction," times of NEG's NSE penalty")
NEG_NSEcost = nse.NSE_Cost
println("NEG: NSE penalty is ", NEG_NSEcost)
SD_NSEcost = nse[nse.Zone .== parse(Int64, string(SD_znumber[end])), :NSE_Cost]
println("SD and JB: NSE penalty is ", SD_NSEcost)
println(nse)


# ============================================================================
# Helper functions
# ============================================================================

function load_annual_avg_cf(quota_df::DataFrame, model_year::Int)
    year_data_row = first(filter(row -> row.year == model_year, quota_df), 1)

    if isempty(year_data_row)
        error("Could not find data for year $model_year in the provided quota DataFrame.")
    end
    # This mapping assumes Zone 1=HL, 2=IME, 3=JL, 4=LN.
    annual_averages = Dict(
        1 => year_data_row.avg_HL[1],
        2 => year_data_row.avg_IME[1],
        3 => year_data_row.avg_JL[1],
        4 => year_data_row.avg_LN[1]
    )
    println("-------------------------------------------------")
    println("Successfully loaded annual average quotas for year $model_year:")
    flush(stdout)
    for (zone, quota) in annual_averages
        @printf("  -> Zone %d (avg_quota): %.2f%%\n", zone, quota * 100)
        flush(stdout)
    end
    println("-------------------------------------------------")
    return annual_averages
end

if quota_enabled
    annual_avg_cf_dict = load_annual_avg_cf(quota_data, model_year)
    println("✅ Successfully extracted annual avg cf for use in the model.")
end


# ====================================================
# heating season and quota values
# ====================================================
const QUOTA_INFO_PRINTED = Dict{Int, Bool}()  # Track printing status for each zone

function is_heating_season(week_number::Int)::Bool
    result = (week_number >= 42 && week_number <= 52) || (week_number >= 1 && week_number <= 15)
    return result
end

function heating_stage(week::Int)::Symbol
    # 深冬（严寒期）- 11月中旬到2月底
    if (week >= 46 && week <= 52) || (week >= 1 && week <= 8)
        return :deep
    # 浅冬（过渡期）- 10月中旬到11月中旬 & 3-4月中旬
    elseif (week >= 42 && week <= 45) || (week >= 9 && week <= 15)
        return :shoulder
    # 非供热季
    else
        return :off
    end
end



function create_chp_seasonal_multiplier(weeks_per_year=52)
    multiplier = ones(Float64, weeks_per_year)
    
    for week in 1:weeks_per_year
        stage = heating_stage(week)
        
        multiplier[week] = if stage == :deep
            1.22  # 深冬 （90%）#1.22 for 2016, 1.30 for 2021
        elseif stage == :shoulder
            1.00  # 浅冬：（80%）#1.00 for 2016, 1.15 for 2021
        else  # :off
            1.00  # 非供热季：无调整
        end
        println("Week $week: $(stage) stage, CHP Min_power multiplier = $(multiplier[week])")
    end
    
    return multiplier
end
chp_seasonal_multiplier = create_chp_seasonal_multiplier()



function calculate_dynamic_quota(zone::Int, week_number::Int, is_chp::Int, unit_size::Float64; 
    base_calibrated_quota::Float64,
    annual_averages::Dict{Int, Float64},
    annual_tolerance::Float64 = 0.10)

    heating_season = is_heating_season(week_number)
    annual_avg = annual_averages[zone]
    
    effective_quota = base_calibrated_quota
    
    # Apply zone-specific adjustments
    zone_adjusted_quota = (zone == 2) ? effective_quota + 0.10 : effective_quota # IME zone gets 10% boost

    # 返回配额：CHP供热季跳过，Non-CHP非供热季跳过
    if is_chp == 1  # CHP units
        return heating_season ? 0.0 : zone_adjusted_quota  # 供热季无配额（must-run处理）
    else  # Non-CHP units
        return heating_season ? zone_adjusted_quota : 0.0  # 非供热季无配额（灵活调度）
    end
end

# ============================================================================
# THIS IS FOR Quota_data_full (that directly reads from the csv file)
# ============================================================================

#=
function get_quota_value(zone::Int, heating_season::Int, is_chp::Int, year::Int=2012)
    quota_row = setQuota[(setQuota.zone .== zone) .& 
                        (setQuota.heating_season .== heating_season) .& 
                        (setQuota.CHP .== is_chp) .&
                        (setQuota.year .== year), :]
    return nrow(quota_row) > 0 ? first(quota_row.quota) : 0.0
end
=#

# ============================================================================
# Create size-based sets for coal generators to implement equal share
# ============================================================================

if equal_shares_enabled
    setSIZE = ["k1", "k2", "k3", "k4"]
    size_ranges = Dict(
        "k1" => (0, 200),      # Small units: 0-200 MW
        "k2" => (200, 350),    # Medium-small units: 200-350 MW  
        "k3" => (350, 660),    # Medium-large units: 350-660 MW
        "k4" => (660, 1000)    # Large units: 660-1000 MW
    )

    setk1 = Int[]  
    setk2 = Int[]  
    setk3 = Int[]  
    setk4 = Int[]  

    for gen_id in setCOAL
        
        capacity = generators[generators.R_ID .== gen_id, :Existing_Cap_MW][1]
        
        if capacity >= 0 && capacity < 200
            push!(setk1, gen_id)
        elseif capacity >= 200 && capacity < 350
            push!(setk2, gen_id)
        elseif capacity >= 350 && capacity < 660
            push!(setk3, gen_id)
        elseif capacity >= 660 && capacity <= 1000
            push!(setk4, gen_id)
        else
            println("Warning: Generator $gen_id has capacity $capacity MW outside expected range")
        end
    end

    # Create combined dictionary for easy access
    setSIZE_DICT = Dict(
        "k1" => setk1,
        "k2" => setk2, 
        "k3" => setk3,
        "k4" => setk4
    )

    # Verify all coal generators are categorized
    total_categorized = length(setk1) + length(setk2) + length(setk3) + length(setk4)
    if total_categorized != length(setCOAL)
        println("Warning: Some coal generators not categorized correctly!")
        println("Coal generators: $(length(setCOAL)), Categorized: $total_categorized")
    end

    # Create zone-size intersection sets for direct use
    # G_z,k sets: generators in province p and size cluster k
    G_zone_size = Dict()

    for zone in setIntZONE
        for size_cluster in setSIZE
            
            zone_gens = generators[generators.Zone .== zone, :R_ID]
            size_gens = setSIZE_DICT[size_cluster]
            intersection_gens = intersect(zone_gens, size_gens)
            
            key = "$(zone)_$(size_cluster)"
            G_zone_size[key] = intersection_gens
            
            #if !isempty(intersection_gens)
                #println("G_$(zone),$(size_cluster): $(length(intersection_gens)) generators")
            #end
        end
    end

    # Helper function to get G_z,k
    function get_Gzk(z::Int, k::String)
        """
        Get generators in zone z and size cluster k
        z: province/zone number
        k: size cluster ("k1", "k2", "k3", "k4")
        """
        key = "$(z)_$(k)"
        return haskey(G_zone_size, key) ? G_zone_size[key] : Int[]
    end

    # Helper function to get total capacity for G_z,k
    function get_Pzk(z::Int, k::String)
        """
        Get total capacity of generators in zone z and size cluster k
        """
        gens = get_Gzk(z, k)
        if isempty(gens)
            return 0.0
        end
        return sum(generators[generators.R_ID .== g, :Existing_Cap_MW][1] for g in gens)
    end

    const REFERENCE_SIZE_CLUSTER = "k3"  # 350-660 MW as reference

    function get_reference_size_cluster(z::Int)
        """
        Get reference size cluster for zone z
        Always returns k3 (350-660 MW) as the reference cluster
        """
        return REFERENCE_SIZE_CLUSTER
    end

    println("\nSize-based sets creation completed!")
end
# ============================================================================
# CAPTIVE PLANT SET CREATION AND FIXED GENERATION CALCULATION
# ============================================================================

if captive_scenario 
    CAPTIVE_CAPACITY_FACTOR = 0.80  # 80% of installed capacity

    captive_fixed_generation_by_zone = Dict{Int, Float64}()

    for zone in setZONE[1:4]  # Only zones 1-4 have generators
        captive_fixed_generation_by_zone[zone] = 0.0
    end

    # Calculate total fixed generation for each zone from captive COAL plants
    for captive_gen in setCAPTIVE
        gen_row = generators[generators.R_ID .== captive_gen, :]
        if nrow(gen_row) > 0
            zone = gen_row.Zone[1]
            capacity = gen_row.Existing_Cap_MW[1]
            technology = gen_row.technology[1]
            fixed_gen = capacity * CAPTIVE_CAPACITY_FACTOR
        
            captive_fixed_generation_by_zone[zone] += fixed_gen
        end
    end

    # Print summary of captive COAL generation by zone (only zones 1-4)
    println("\nCaptive coal fixed generation summary by zone:")
    for zone in sort(collect(keys(captive_fixed_generation_by_zone)))
        fixed_gen = captive_fixed_generation_by_zone[zone]
        if fixed_gen > 0
            println("  Zone $zone: $(round(fixed_gen, digits=1)) MW")
        else
            println("  Zone $zone: 0.0 MW (no captive coal plants)")
        end
    end

    total_captive_generation = sum(values(captive_fixed_generation_by_zone))
    println("Total captive coal fixed generation: $(round(total_captive_generation, digits=1)) MW")
end

# ============================================================================
# LINE CAPACITY OVERRIDE FUNCTION (for year-specific topology changes)
# ============================================================================

"""
    apply_line_capacity_override!(network_df::DataFrame, year::Int)

Override transmission line capacities based on year-specific rules.
Currently implements:
- IME→SD line: Capacity=0 before 2016, normal capacity from 2016 onwards

Args:
    network_df: network_fwd or network_rvs DataFrame
    year: Model year being simulated

Returns:
    Modified DataFrame (in-place modification)
"""
function apply_line_capacity_override!(network_df::DataFrame, year::Int)
    # Rule 1: IME→SD line activation in 2016
    ime_sd_lines = filter(row -> occursin("IME", row.transmission_path_name) && 
                                 occursin("SD", row.transmission_path_name), 
                          network_df)
    if nrow(ime_sd_lines) > 0
        for idx in eachindex(ime_sd_lines.Network_Lines)
            line_idx = ime_sd_lines.Network_Lines[idx]
            line_name = ime_sd_lines.transmission_path_name[idx]
            
            if year <= 2016
                # Override capacity to 0 for years before 2016
                network_df[network_df.Network_Lines .== line_idx, :Line_Max_Flow_MW] .= 0.0
                println("⚠️  Line capacity override: $line_name set to 0 MW (year $year <= 2016)")
            else
                # Restore original capacity (assumes Line_Max_Flow_MW is already correct in CSV)
                original_cap = first(network_df[network_df.Network_Lines .== line_idx, :Line_Max_Flow_MW])
                println("✅ Line capacity normal: $line_name = $(original_cap) MW (year $year >= 2016)")
            end
        end
    end
    
    # Rule 2: 可扩展 - 添加其他线路的年份规则
    # 例如：某条线路2020年扩容
    # if year >= 2020
    #     network_df[network_df.transmission_path_name .== "HL_to_LN", :Line_Max_Flow_MW] .= 2000.0
    # end
    
    return network_df
end
# Apply overrides to both forward and reverse network DataFrames
apply_line_capacity_override!(network_fwd, model_year)
apply_line_capacity_override!(network_rvs, model_year)

# 🧪 临时调试：验证 override 结果
println("\n=== LINE CAPACITY OVERRIDE VERIFICATION ===")
ime_sd_fwd = filter(row -> occursin("IME", row.transmission_path_name) && 
                           occursin("SD", row.transmission_path_name), 
                    network_fwd)
if nrow(ime_sd_fwd) > 0
    for row in eachrow(ime_sd_fwd)
        println("  $(row.transmission_path_name): $(row.Line_Max_Flow_MW) MW")
    end
else
    println("  No IME-SD lines found in network_fwd")
end
println("===========================================\n")


#=
# ---====================================================---
# ---      COAL FLEXIBILITY RETROFIT SCENARIO BLOCK      ---
# ---====================================================---
# List of R_IDs for all coal units that are ELIGIBLE for retrofitting.
eligible_retrofit_ids = [
    20,22,60,63,64,106,107,122,123,152,153,170,171,181,182,220,221,225,226,232,248,250,272,306,326,332,350,351,352,353,354
]

# Total capacity of the entire multi-year retrofit program (in MW).
total_retrofit_target = 12750.0

# Set the progress percentage for the current simulation year (e.g., 0.50 for 50%).
# This determines how many of the eligible units are selected for this run.
retrofit_progress_percent = 1.0

# --- Implementation ---
# This block will only run if the scenario is activated.
if retrofit_scenario
    println("--- CONFIGURING COAL FLEXIBILITY RETROFIT SCENARIO ---")

    # Calculate the capacity target for this specific run in MW.
    target_mw = total_retrofit_target * retrofit_progress_percent
    println("Retrofit Target for this run: $(round(target_mw, digits=2)) MW")

    # Filter the main generators DataFrame to get only the eligible units.
    eligible_units_df = filter(row -> row.R_ID in eligible_retrofit_ids, generators)

    if isempty(eligible_units_df)
        println("Warning: No eligible units found in the generators data. No retrofits will be applied.")
    else
        # Sort eligible units to make the selection process deterministic.
        # Sorting by size (largest first) is a common, reasonable strategy.
        sort!(eligible_units_df, :Cap_Size, rev=true)

        local retrofitted_units_ids = []
        local retrofitted_capacity_mw = 0.0

        # Iterate through the sorted eligible units and select them for retrofitting
        # until the cumulative capacity meets or exceeds the target for this run.
        for unit_to_consider in eachrow(eligible_units_df)
            if retrofitted_capacity_mw < target_mw
                # --- Select this unit for retrofitting ---
                push!(retrofitted_units_ids, unit_to_consider.R_ID)
                retrofitted_capacity_mw += unit_to_consider.Cap_Size

                # Find the index of this unit in the main 'generators' DataFrame to modify it.
                unit_index = findfirst(isequal(unit_to_consider.R_ID), generators.R_ID)

                if !isnothing(unit_index)
                    # --- Apply retrofit modifications directly to the main DataFrame ---
                    
                    # Min_Power Rule:
                    if generators[unit_index, :Cap_Size] < 600
                        generators[unit_index, :Min_Power] = 0.35
                    else # Cap_Size >= 600
                        generators[unit_index, :Min_Power] = 0.30
                    end

                    # Up_Time and Down_Time Rule:
                    # Subtract 2 hours, but ensure they don't go below a safe minimum (e.g., 2).
                    generators[unit_index, :Up_Time] = max(2, generators[unit_index, :Up_Time] - 2)
                    generators[unit_index, :Down_Time] = max(2, generators[unit_index, :Down_Time] - 2)
                end
            else
                # Stop selecting units once the capacity target has been met.
                break
            end
        end

        # --- Verification ---
        println("Retrofitted $(length(retrofitted_units_ids)) units for a total of $(round(retrofitted_capacity_mw, digits=2)) MW.")
        println("Retrofitted Unit R_IDs: ", retrofitted_units_ids)
    end
    println("----------------------------------------------------")
end
=#