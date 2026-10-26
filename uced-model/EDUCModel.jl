function EDUCModel()
# MLT slack存在，不会出现infeasibility，但是对参数推断肯定有影响
    #log_file = joinpath(resultpath, "gurobi_solve_log.txt")

    # 在函数开始时初始化（每次运行都会重置）
    MLT_VIOLATION_SUMMARY = DataFrame(
        Week = Int[],
        Total_SlackUp_MW = Float64[],
        Total_SlackDown_MW = Float64[],
        Violation_Count_Hours = Int[],
        Max_Violation_MW = Float64[],
        Max_Violation_Line = String[],
        Max_Violation_Direction = String[]
    )
    
    if @isdefined(SELECTED_WEEKS) && SELECTED_WEEKS !== nothing
        weeks_to_run = isa(SELECTED_WEEKS, Int) ? [SELECTED_WEEKS] : SELECTED_WEEKS
        log_println("🎯 Running selected weeks: $weeks_to_run")
    else
        weeks_to_run = collect(1:length(load_transition))
        log_println("🔄 Running all weeks (1-$(length(load_transition)))")
    end

    for count in weeks_to_run
        load = load_transition[count]
        genvar = genvar_transition[count]
        mlt = mlt_transition[count]
        
        log_println("🔧 Processing Week $count")

        EDUC_Model = Model(optimizer_with_attributes(Gurobi.Optimizer, 
            "NonConvex" => 2,         # 允许非凸二次（双线性）约束
            "NumericFocus" => 1,
            "ScaleFlag" => 2,       
            "Threads" => 8
            #"LogFile" => log_file
            #"MIPGap" => 0.02, # 1% normally，set in solver_params.csv below
            ))

        for paramrow in eachrow(solver_params)
            if paramrow.Type == "Integer"
                set_optimizer_attribute(EDUC_Model, "$(paramrow.Parameter)", Int(paramrow.Value))
            else
                set_optimizer_attribute(EDUC_Model, "$(paramrow.Parameter)", paramrow.Value)
            end
        end

        # VARIABLES
        @variable(EDUC_Model, vCOMMIT[setUC, setTIME], Bin) # Number of committed unit commitment generators
        @variable(EDUC_Model, vSTARTUC[setUC, setTIME], Bin) # Start variable for unit commitment generators
        @variable(EDUC_Model, vSHUTUC[setUC, setTIME], Bin) # Shut variable for unit commitment generators

        # Capacity variables
        @variable(EDUC_Model, vCAPGEN[setGEN] >= 0) # Auxiliary variable for capacities of all generators
        # @variable(EDUC_Model, vMAXENGY[setSTOR]                    >= 0) # Auxiliary variable for capacities of all generators
        @variable(EDUC_Model, vMAXENGY[union(setSTOR, setHYDRO)] >= 0) # Auxiliary variable for capacities of all generators
        @variable(EDUC_Model, vCAPLINE[setLINEFWD] >= 0) # Auxiliary variable for capacity of existing transmission lines

        # Operational variables
        @variable(EDUC_Model, vGENDISPATCH[setGEN, setTIME] >= 0) # Dispatch amount from all generators and STOR for each time period
        @variable(EDUC_Model, vCHARGESTOR[setSTOR, setTIME] >= 0) # Amount of power used for charging of batteries (STOR and HYDRO's dam) 
        @variable(EDUC_Model, vCHARGEHYDRO[setHYDRO, setTIME] >= 0) # Amount of power used for charging of batteries (STOR and HYDRO's dam) 
        @variable(EDUC_Model, vSOCSTOR[setSTOR, setTIME] >= 0) # Battery charge/discharge equation for all storages (STOR and HYDRO's dam) 
        @variable(EDUC_Model, vSOCHYDRO[setHYDRO, setTIME] >= 0) # Battery charge/discharge equation for all storages (STOR and HYDRO's dam) 
        @variable(EDUC_Model, vCURTHYDRO[setHYDRO, setTIME] >= 0) # Water Curtailment of HYDRO's dam 
        @variable(EDUC_Model, vNSE[setZONE, setSEGMENT, setTIME] >= 0) # Amount of non-served demand
        @variable(EDUC_Model, vFLOWFWD[setLINEFWD, setTIME] >= 0) # Power flow amount on each forward transmission line
        @variable(EDUC_Model, vFLOWRVS[setLINERVS, setTIME] >= 0) # Power flow amount on each reverse transmission line

        # Reserve variables
        @variable(EDUC_Model, vRESUP[setGEN, setTIME] >= 0) # Allocated reserve up capacity for all unit commitment constraints for each time period
        @variable(EDUC_Model, vRESDOWN[setGEN, setTIME] >= 0) # Allocated reserve down capacity for all unit commitment constraints for each time period

        # CONSTRAINTS
        # Create auxiliary variables for generation capacities (MW)
        @constraint(EDUC_Model, cMaxCap_UC[g in setUC], vCAPGEN[g] == generators.Existing_Cap_MW[g])  # coal/gas/nuclear
        @constraint(EDUC_Model, cMaxCap_WINDSOLAR[g in setWINDSOLAR], vCAPGEN[g] == generators.Existing_Cap_MW[g])  # Wind and Solar
        @constraint(EDUC_Model, cMaxCap_STOR[g in setSTOR], vCAPGEN[g] == generators.Existing_Cap_MW[g])  # battery and reservoir
        @constraint(EDUC_Model, cMaxCap_HYDRO[g in setHYDRO], vCAPGEN[g] == generators.Existing_Cap_MW[g])  # hydro's generator
        # for energy capacity (MW·h)
        @constraint(EDUC_Model, cMaxEnergy_Stor[g in setSTOR], vMAXENGY[g] == generators.Existing_Cap_MWh[g])  # battery and reservoir
        @constraint(EDUC_Model, cMaxEnergy_Hydro[g in setHYDRO], vMAXENGY[g] == generators.Existing_Cap_MWh[g])  # hydro's dam
        # for transmission lines (MW)
        @constraint(EDUC_Model, cMaxCap_LineFwd[l in setLINEFWD], vCAPLINE[l] == network_fwd.Line_Max_Flow_MW[l])
        @constraint(EDUC_Model, cMaxCap_LineRvs[l in setLINERVS], vCAPLINE[l] == network_rvs.Line_Max_Flow_MW[l])

        #=
        if is_heating_season(count)  # Heating season weeks
                #if count in vcat(collect(1:16), collect(42:52))
                # Option to use subset of CHP units
                #essential_CHP = use_essential_subset ? setCHP[1:250] : setCHP
                @constraint(EDUC_Model, cFixCommitHeating[g in setCHP, t in setTIME],
                    vCOMMIT[g, t] == 1)
                println("Week $count: CHP plants forced to commit (heating season)")
        end
        =#

        
        if is_heating_season(count)
            min_chp_fraction = 0.82  # Require 85% of CHP capacity online in 2021, 0.82 for 2016
            
            @constraint(EDUC_Model, cMinCHPCommit[t in setTIME],
                sum(vCOMMIT[g, t] * vCAPGEN[g] for g in setCHP) >= 
                min_chp_fraction * sum(vCAPGEN[g] for g in setCHP))
            
            log_println("Week $count: Minimum $(min_chp_fraction*100)% CHP commitment (heating season)")
        end
        


        # Generation dispatch <= capacity_factor * installed capacity 
        @constraint(EDUC_Model, cMaxPower_UC[g in setUC, t in setTIME], vGENDISPATCH[g, t] <= genvar[t, g] * vCOMMIT[g, t] * vCAPGEN[g])  #for UC (coal/gas/nuclear) units, genvar[t,g] is set to 1.
        @constraint(EDUC_Model, cMaxPower_WINDSOLAR[g in setWINDSOLAR, t in setTIME], vGENDISPATCH[g, t] <= genvar[t, g] * vCAPGEN[g])
        @constraint(EDUC_Model, cMaxPower_STOR[g in setSTOR, t in setTIME], vGENDISPATCH[g, t] <= genvar[t, g] * vCAPGEN[g])   #For STOR, genvar[t,g] is set to 1.
        @constraint(EDUC_Model, cMaxPower_HYDRO[g in setHYDRO, t in setTIME], vGENDISPATCH[g,t] <= genvar[t,g] * vCAPGEN[g])   

        # Generation dispatch >= minimum level of dispatch
        @constraint(EDUC_Model, cMinPower_UC[g in setdiff(setUC, setCHP), t in setTIME], vGENDISPATCH[g, t] >= genvar[t, g] * generators.Min_Power[g] * vCOMMIT[g, t] * vCAPGEN[g]) #for UC (coal/gas/nuclear) units, min_power is greater than 0.
        @constraint(EDUC_Model, cMinPower_CHP[g in setCHP, t in setTIME], vGENDISPATCH[g, t] >= genvar[t, g] * generators.Min_Power[g] * chp_seasonal_multiplier[count]* vCOMMIT[g, t] *  vCAPGEN[g])
        @constraint(EDUC_Model, cMinPower_WINDSOLAR[g in setWINDSOLAR, t in setTIME], vGENDISPATCH[g, t] >= generators.Min_Power[g] * vCAPGEN[g])  #for wind and solar, min_power is set to 0.
        @constraint(EDUC_Model, cMinPower_STOR[g in setSTOR, t in setTIME], vGENDISPATCH[g, t] >= generators.Min_Power[g] * vCAPGEN[g]) #for STOR units (battery and reservoir), min_power is set to 0.
        @constraint(EDUC_Model, cMinPower_HYDRO[g in setHYDRO, t in setTIME], vGENDISPATCH[g, t] >= generators.Min_Power[g] * vCAPGEN[g]) #for HYDRO units, min_power is set to 0.

        # Generation dispatch at time t+1 minus generation dispatch at time t <= ramp up level
        @constraint(EDUC_Model, cRampUp_UC[g in setUC, t in setINTERIORS], vGENDISPATCH[g, t] - vGENDISPATCH[g, t-1] <= (vCOMMIT[g, t] - vCOMMIT[g, t-1]) * generators.Min_Power[g] * vCAPGEN[g] + vCOMMIT[g, t] * generators.Ramp_Up_Percentage[g] * vCAPGEN[g])
        @constraint(EDUC_Model, cRampUp_NONUC[g in setdiff(setGEN, setUC), t in setINTERIORS], vGENDISPATCH[g, t] - vGENDISPATCH[g, t-1] <= generators.Ramp_Up_Percentage[g] * vCAPGEN[g])

        # Generation dispatch at time t minus generation dispatch at time t+1 <= ramp down level
        @constraint(EDUC_Model, cRampDown_UC[g in setUC, t in setINTERIORS], vGENDISPATCH[g, t-1] - vGENDISPATCH[g, t] <= (vCOMMIT[g, t-1] - vCOMMIT[g, t]) * generators.Min_Power[g] * vCAPGEN[g] + vCOMMIT[g, t] * generators.Ramp_Dn_Percentage[g] * vCAPGEN[g])
        @constraint(EDUC_Model, cRampDown_NONUC[g in setdiff(setGEN, setUC), t in setINTERIORS], vGENDISPATCH[g, t-1] - vGENDISPATCH[g, t] <= generators.Ramp_Dn_Percentage[g] * vCAPGEN[g])


        # Non-served demand <= maximum allowed non-served demand and sum of vNSE <= load
        @constraint(EDUC_Model, cMaxNSE[z in setZONE, t in setTIME], sum(vNSE[z, s, t] for s in setSEGMENT) <= load[t, z])


        # Battery (and Hydro's dam) level <= maximum energy
        @constraint(EDUC_Model, cMaxSOC_STOR[g in setSTOR, t in setTIME], vSOCSTOR[g, t] <= vMAXENGY[g])  # max energy for Battery and Reservoir
        @constraint(EDUC_Model, cMaxSOC_HYDRO[g in setHYDRO, t in setTIME], vSOCHYDRO[g, t] <= vMAXENGY[g])  # max energy for Hydro's dam

        # For STOR, SOC(t) = SOC(t-1) + charge efficiency * amount of power used to charge - generation dispatch / discharge efficiency
        @constraint(EDUC_Model, cSOC_STOR[g in setSTOR, t in setINTERIORS], vSOCSTOR[g, t] == vSOCSTOR[g, t-1] + vCHARGESTOR[g, t] * generators.Eff_Up[g] - vGENDISPATCH[g, t] / generators.Eff_Down[g])
        @constraint(EDUC_Model, cSOCStart_STOR[g in setSTOR, t=first(setTIME)], vSOCSTOR[g, t] == initfinalstate * vMAXENGY[g] + vCHARGESTOR[g, t] * generators.Eff_Up[g] - vGENDISPATCH[g, t] / generators.Eff_Down[g])
        #@constraint(EDUC_Model, cSOCFinal_STOR[g in setSTOR, t=last(setTIME)], vSOCSTOR[g, t] == initfinalstate * vMAXENGY[g])
        @constraint(EDUC_Model, cSOCFinal_STOR_Min[g in setSTOR, t=last(setTIME)], 
            vSOCSTOR[g, t] >= (initfinalstate - 0.1) * vMAXENGY[g])  # Allow 10% lower
        @constraint(EDUC_Model, cSOCFinal_STOR_Max[g in setSTOR, t=last(setTIME)], 
            vSOCSTOR[g, t] <= (initfinalstate + 0.1) * vMAXENGY[g])  # Allow 10% higher

        # For Hydro, SOC(t) = SOC(t-1) + charge efficiency * amount of power used to charge - generation dispatch / discharge efficiency
        @constraint(EDUC_Model, cSOC_Hydro1[g in setHYDRO, t in setINTERIORS], vSOCHYDRO[g, t] == vSOCHYDRO[g, t-1] + vCAPGEN[g] * genvar[t, g] * generators.Eff_Up[g] - vCURTHYDRO[g, t] - vGENDISPATCH[g, t] / generators.Eff_Down[g]) # Assumption: river's hourly inflow (electricity) equals to vCAPGEN[g] * genvar[t,g]; for Hydro, eff_up and eff_down are set to 100%, so generators.Eff_Up[g] can leave out.
        @constraint(EDUC_Model, cSOC_Hydro2[g in setHYDRO, t in setINTERIORS], vCHARGEHYDRO[g, t] == vCAPGEN[g] * genvar[t, g] * generators.Eff_Up[g] - vCURTHYDRO[g, t])
        @constraint(EDUC_Model, cSOCStart_Hydro1[g in setHYDRO, t=first(setTIME)], vSOCHYDRO[g, t] == initfinalstate * vMAXENGY[g] + vCAPGEN[g] * genvar[t, g] * generators.Eff_Up[g] - vCURTHYDRO[g, t] - vGENDISPATCH[g, t] / generators.Eff_Down[g])
        @constraint(EDUC_Model, cSOCStart_Hydro2[g in setHYDRO, t=first(setTIME)], vCHARGEHYDRO[g, t] == vCAPGEN[g] * genvar[t, g] * generators.Eff_Up[g] - vCURTHYDRO[g, t])
        @constraint(EDUC_Model, cSOCFinal_Hydro[g in setHYDRO, t=last(setTIME)], vSOCHYDRO[g, t] == initfinalstate * vMAXENGY[g])

        # For Hydro, minimum level of dam
        @constraint(EDUC_Model, cSOCMinHydro[g in setHYDRO, t in setTIME], vSOCHYDRO[g, t] >= minreservoirlevel * vMAXENGY[g])

        # 0=< vCOMMIT[g,t], vSTARTUC, vSHUTUC <= 1
        @constraint(EDUC_Model, cCommitMax[g in setUC, t in setTIME], vCOMMIT[g, t] <= generators.num_units[g])
        @constraint(EDUC_Model, cStartCap[g in setUC, t in setTIME], vSTARTUC[g, t] <= generators.num_units[g])
        @constraint(EDUC_Model, cShutCap[g in setUC, t in setTIME], vSHUTUC[g, t] <= generators.num_units[g])
        @constraint(EDUC_Model, cTransStartShut[g in setUC, t in setdiff(setTIME, 1)], vCOMMIT[g, t] - vCOMMIT[g, t-1] == vSTARTUC[g, t] - vSHUTUC[g, t])  #ensure accurate tracking of each unit's status transitions (start-up or shut-down)


        # Unit commitment generators (coal/gas/nuclear) have to be up, and running for at least a pre-defined duration, once they are started
        @constraint(EDUC_Model, cComSta[g in setUC, t in setdiff(setTIME, 1:maximum(generators.Up_Time[setUC]))],
            vCOMMIT[g, t] >= sum(vSTARTUC[g, tt] for tt in round.(Int, Array(t-generators.Up_Time[g]:t))))
        @constraint(EDUC_Model, cComShut[g in setUC, t in setdiff(setTIME, 1:maximum(generators.Down_Time[setUC]))],
            generators.num_units[g] - vCOMMIT[g, t] >= sum(vSHUTUC[g, tt] for tt in round.(Int, Array(t-generators.Down_Time[g]:t))))


        # Power flow on transmission lines should be within capacities
        @constraint(EDUC_Model, cMaxFlow1[l in setLINEFWD, t in setTIME], vFLOWFWD[l, t] <= vCAPLINE[l] * (1 - network_fwd.Loss[l] / 2))
        @constraint(EDUC_Model, cMaxFlow2[l in setLINERVS, t in setTIME], vFLOWRVS[l, t] <= vCAPLINE[l] * (1 - network_rvs.Loss[l] / 2))

        # Power flow should be postive for the external lines (IME to SD, LN to JB)
        @constraint(EDUC_Model, cSingleDirectionFlowSD[l in setSDLINERVS, t in setTIME], vFLOWRVS[l, t] == 0) # make constraint for IME to SD so that power only transmitted from IME to SD.
        @constraint(EDUC_Model, cSingleDirectionFlowJB[l in setJBLINERVS, t in setTIME], vFLOWRVS[l, t] == 0) # make constraint for LN to JB so that power only transmitted from LN to JB.

        # Demand-balance constraint - Normal situation
        @constraint(EDUC_Model, cDemandBalance[t in setTIME, z in setZONE],
            sum(vGENDISPATCH[g, t] for g in intersect(generators[generators.Zone.==z, :R_ID], setGEN)) +
            sum(vNSE[z, s, t] for s in setSEGMENT) -
            sum(vCHARGESTOR[g, t] for g in intersect(generators[generators.Zone.==z, :R_ID], setSTOR)) -
            load[t, z] -
            sum(network_fwd[l, Symbol(string("z", z))] * vFLOWFWD[l, t] for l in setLINEFWD) -
            sum(abs(network_fwd[l, Symbol(string("z", z))]) * vFLOWFWD[l, t] / (1 - network_fwd.Loss[l] / 2) * (network_fwd.Loss[l] / 2) for l in setLINEFWD) -
            sum(network_rvs[l, Symbol(string("z", z))] * vFLOWRVS[l, t] for l in setLINERVS) -
            sum(abs(network_rvs[l, Symbol(string("z", z))]) * vFLOWRVS[l, t] / (1 - network_rvs.Loss[l] / 2) * (network_rvs.Loss[l] / 2) for l in setLINERVS)
            ==
            0
        )


        ### Slack variable for Min quota debug
        @variable(EDUC_Model, vQuotaShortfall_CHP >= 0)
        @variable(EDUC_Model, vQuotaShortfall_NonCHP >= 0) 

        ###### Minimum quota constraint ######
        # Batch run version - used with Quota_data, helper function in SetCreation.jl
        if quota_enabled
            local base_quota_for_this_run::Dict{String, Float64}
            if @isdefined(config_filepath) && !isempty(config_filepath) && isfile(config_filepath)
                # --- EXPERIMENT MODE ---
                log_println("Info: Running in EXPERIMENT mode. Loading quota from config file...")
                run_config_df = CSV.read(config_filepath, DataFrame)
                if any(contains.(run_config_df.parameter, "Minimum_Quota_%_"))
                    log_println("Using size-specific quotas from experiment config...")
                    base_quota_for_this_run = Dict{String, Float64}()
                    
                    size_classes = ["0-300", "300-660", "660-1000"]
                    missing_quotas = String[]
                    
                    for size_class in size_classes
                        param_name = "Minimum_Quota_%_$(size_class)"
                        matching_rows = run_config_df[contains.(run_config_df.parameter, param_name), :]
                        
                        if nrow(matching_rows) > 0
                            base_quota_for_this_run[size_class] = matching_rows[1, :value]
                            log_println("  Found quota for $(size_class)MW: $(base_quota_for_this_run[size_class])")
                        else
                            push!(missing_quotas, size_class)
                        end
                    end
                    if !isempty(missing_quotas)
                        error("ERROR: Missing size-specific quotas in config file for size classes: $(join(missing_quotas, ", ")). Please provide Minimum_Quota_%_$(join(missing_quotas, ", Minimum_Quota_%_")) parameters.")
                    end

                elseif any(run_config_df.parameter .== "Minimum_Quota_%")
                    # Single quota value - apply to all size classes
                    single_quota = run_config_df[run_config_df.parameter.=="Minimum_Quota_%", :value][1]
                    base_quota_for_this_run = Dict{String, Float64}(
                        "0-300" => single_quota,
                        "300-660" => single_quota,
                        "660-1000" => single_quota
                    )
                    log_println("Using single quota value $(single_quota) for all size classes")
                else
                    error("ERROR: No valid minimum quota parameters found in config file. Expected either 'Minimum_Quota_%' or size-specific 'Minimum_Quota_%_0-300', 'Minimum_Quota_%_300-660', 'Minimum_Quota_%_660-1000'.")
                end

            else
                # --- STANDALONE MODE ---
                log_println("Info: Running in STANDALONE mode. Using default size-specific base quotas...")
                base_quota_for_this_run = Dict{String, Float64}(
                    "0-300" => 0.08,     
                    "300-660" => 0.18,   
                    "660-1000" => 0.27   
                )
                log_println("Default quotas: 0-300MW: $(base_quota_for_this_run["0-300"]), 300-660MW: $(base_quota_for_this_run["300-660"]), 660-1000MW: $(base_quota_for_this_run["660-1000"])")
            end

            current_week_num = count
            is_heating_season_flag = is_heating_season(count)  
            season_name = is_heating_season_flag ? "heating" : "non-heating"
            
            log_println("Adding dynamic quota constraints for week $current_week_num ($season_name season)...")

            for zone in setIntZONE
                # CHP constraints by size class
                G_CHP = intersect(setCHP, generators[generators.Zone.==zone, :R_ID])
                if !isempty(G_CHP)
                    # Group CHP generators by size class
                    for size_class in ["0-300", "300-660", "660-1000"]
                        min_cap, max_cap = parse.(Int, split(size_class, "-"))

                        G_CHP_size = filter(g -> begin
                            unit_size = generators[generators.R_ID .== g, :Cap_Size][1]
                            unit_size > min_cap && unit_size <= max_cap
                        end, G_CHP)
                        
                        if !isempty(G_CHP_size)
                            # Apply quota constraint logic based on season
                            if is_heating_season_flag
                                # 供热季 + CHP: 跳过约束，因为有must_run
                                log_println("  Skipping CHP quota constraint for heating season (zone $zone, $(size_class)MW): must_run handles it")
                            else
                                # 非供热季 + CHP: 返回适中的quota值（确保CHP仍能运行）
                                unit_size = generators[generators.R_ID .== G_CHP_size[1], :Cap_Size][1]
                                Q_CHP = calculate_dynamic_quota(zone, current_week_num, 1, unit_size,
                                    base_calibrated_quota=base_quota_for_this_run[size_class],
                                    annual_averages=annual_avg_cf_dict)
            
                                @constraint(EDUC_Model,
                                    sum(vGENDISPATCH[g, t] for g in G_CHP_size, t in setTIME)
                                    +
                                    vQuotaShortfall_CHP >=
                                    Q_CHP * length(setTIME) * sum(generators[in.(generators.R_ID, Ref(G_CHP_size)), :Existing_Cap_MW]),
                                    base_name = "quota_z$(zone)_CHP_$(size_class)")
                                
                                log_println("  Applied CHP quota constraint (non-heating season, zone $zone, $(size_class)MW): $(round(Q_CHP*100, digits=2))%")
                            end
                        end
                    end
                end
                
                # Non-CHP constraints by size class
                G_NON_CHP = intersect(setNONCHP, generators[generators.Zone.==zone, :R_ID])
                if !isempty(G_NON_CHP)
                    for size_class in ["0-300", "300-660", "660-1000"]
                        min_cap, max_cap = parse.(Int, split(size_class, "-"))
                        
                        G_NON_CHP_size = filter(g -> begin
                            unit_size = generators[generators.R_ID .== g, :Cap_Size][1]
                            unit_size > min_cap && unit_size <= max_cap
                        end, G_NON_CHP)
                        
                        if !isempty(G_NON_CHP_size)
                            # Apply quota constraint logic based on season
                            if is_heating_season_flag
                                # 供热季 + Non-CHP: 返回quota值
                                unit_size = generators[generators.R_ID .== G_NON_CHP_size[1], :Cap_Size][1]
                                Q_NON_CHP = calculate_dynamic_quota(zone, current_week_num, 0, unit_size,
                                    base_calibrated_quota=base_quota_for_this_run[size_class],
                                    annual_averages=annual_avg_cf_dict)
            
                                @constraint(EDUC_Model,
                                    sum(vGENDISPATCH[g, t] for g in G_NON_CHP_size, t in setTIME)
                                    +
                                    vQuotaShortfall_NonCHP >=
                                    Q_NON_CHP * length(setTIME) * sum(generators[in.(generators.R_ID, Ref(G_NON_CHP_size)), :Existing_Cap_MW]),
                                    base_name = "quota_z$(zone)_nonCHP_$(size_class)")
                                
                                log_println("  Applied Non-CHP quota constraint (heating season, zone $zone, $(size_class)MW): $(round(Q_NON_CHP*100, digits=2))%")
                            else
                                # 非供热季 + Non-CHP: 跳过约束
                                log_println("  Skipping Non-CHP quota constraint for non-heating season (zone $zone, $(size_class)MW)")
                            end
                        end
                    end
                end
            end
            ###### End of minimum quota constraint ######

            ###### DEBUG quota constraint: Print constraint details for ALL zones #####
            log_println("=== DEBUG QUOTA CONSTRAINTS ALL ZONES (SIZE-BASED) ===")
            log_println("Week: $count ($season_name season)")
            for zone in setIntZONE
                G_CHP = intersect(setCHP, generators[generators.Zone .== zone, :R_ID])
                G_NON_CHP = intersect(setNONCHP, generators[generators.Zone .== zone, :R_ID])

                if !isempty(G_CHP) || !isempty(G_NON_CHP)
                    log_println("Zone $zone:")
                    
                    for size_class in ["0-300", "300-660", "660-1000"]
                        min_cap, max_cap = parse.(Int, split(size_class, "-"))
                
                        # CHP by size
                        G_CHP_size = filter(g -> begin
                            unit_size = generators[generators.R_ID .== g, :Cap_Size][1]
                            unit_size > min_cap && unit_size <= max_cap
                        end, G_CHP)
                
                        if !isempty(G_CHP_size)
                            if is_heating_season_flag
                                log_println("  CHP $(size_class)MW: $(length(G_CHP_size)) units, quota: SKIPPED (must_run)")
                            else
                                unit_size = generators[generators.R_ID .== G_CHP_size[1], :Cap_Size][1]
                                Q_CHP = calculate_dynamic_quota(zone, count, 1, unit_size;
                                    base_calibrated_quota=base_quota_for_this_run[size_class],
                                    annual_averages=annual_avg_cf_dict)
                                log_println("  CHP $(size_class)MW: $(length(G_CHP_size)) units, quota: $(round(Q_CHP*100, digits=2))%")
                            end
                        end
                
                        # Non-CHP by size
                        G_NON_CHP_size = filter(g -> begin
                            unit_size = generators[generators.R_ID .== g, :Cap_Size][1]
                            unit_size > min_cap && unit_size <= max_cap
                        end, G_NON_CHP)
            
                        if !isempty(G_NON_CHP_size)
                            if is_heating_season_flag
                                unit_size = generators[generators.R_ID .== G_NON_CHP_size[1], :Cap_Size][1]
                                Q_NON_CHP = calculate_dynamic_quota(zone, count, 0, unit_size;
                                    base_calibrated_quota=base_quota_for_this_run[size_class],
                                    annual_averages=annual_avg_cf_dict)
                                log_println("  Non-CHP $(size_class)MW: $(length(G_NON_CHP_size)) units, quota: $(round(Q_NON_CHP*100, digits=2))%")
                            else
                                log_println("  Non-CHP $(size_class)MW: $(length(G_NON_CHP_size)) units, quota: SKIPPED")
                            end
                        end
                    end
                    log_println()
                end
            end
            log_println("==========================================")
        end

        # End of minimum quota constraint batch run 

        #=
        # Minimum quota constraints - used with Quota_data_full which gets the quota values directly from this csv file
        if quota_enabled
            # Use the existing week counter from your loop
            current_week_num = count
            heating_flag = get_heating_season_flag(current_week_num)
            season_name = heating_flag == 1 ? "heating" : "non-heating"
            model_year = 2021

            log_println("Adding quota constraints for week $current_week_num ($season_name season, year $model_year)...")

            for zone in setZONE
                # CHP coal quota constraint for this week
                G_CHP = intersect(setCHP, generators[generators.Zone.==zone, :R_ID])
                Q_CHP = get_quota_value(zone, heating_flag, 1, model_year)
                total_chp_capacity = sum(generators[in.(generators.R_ID, Ref(G_CHP)), :Existing_Cap_MW])

                @constraint(EDUC_Model,
                    sum(vGENDISPATCH[g, t] for g in G_CHP, t in setTIME)
                    +
                    vQuotaShortfall_CHP >=
                    Q_CHP * length(setTIME) * total_chp_capacity,
                    base_name = "quota_z$(zone)_CHP")

                # Non-CHP coal quota constraint for this week
                G_NON_CHP = intersect(setNONCHP, generators[generators.Zone.==zone, :R_ID])
                Q_NON_CHP = get_quota_value(zone, heating_flag, 0, model_year)
                total_non_chp_capacity = sum(generators[in.(generators.R_ID, Ref(G_NON_CHP)), :Existing_Cap_MW])

                @constraint(EDUC_Model,
                    sum(vGENDISPATCH[g, t] for g in G_NON_CHP, t in setTIME)
                    +
                    vQuotaShortfall_NonCHP >=
                    Q_NON_CHP * length(setTIME) * total_non_chp_capacity,
                    base_name = "quota_z$(zone)_non_CHP")

                # Debug output
                if length(G_CHP) > 0 && Q_CHP > 0
                    log_println("  Zone $zone, CHP: $(length(G_CHP)) generators, quota = $(Q_CHP*100)%")
                end
                if length(G_NON_CHP) > 0 && Q_NON_CHP > 0
                    log_println("  Zone $zone, non-CHP: $(length(G_NON_CHP)) generators, quota = $(Q_NON_CHP*100)%")
                end
            end
        end
        =#

        ###### Equal shares implementation using size-based sets

        if equal_shares_enabled
            alpha = count in collect(7:12) ? 0.15 : 0.05

            log_println("Adding equal shares constraints (α = $alpha)...")
            log_println("Using k3 (350-660 MW) as reference size...")

            k_star = "k3"  # Reference cluster

            for z in setIntZONE # z represent province
                G_z_kstar = get_Gzk(z, k_star)

                P_kstar = get_Pzk(z, k_star)

                for k in ["k1", "k2", "k4"]
                    G_z_k = get_Gzk(z, k)
                    P_k = get_Pzk(z, k)

                    # SKIP if capacity difference is too small (not meaningful)
                    if abs(P_k - P_kstar) < 100  # Less than 100 MW difference
                        continue
                    end

                    # SKIP if very few generators (not meaningful for "equal shares")
                    if length(G_z_k) < 2 && length(G_z_kstar) < 2
                        continue
                    end

                    # SKIP during heating season for CHP-heavy size groups
                    if count in collect(7:12)  # Heating season
                        chp_in_k = length(intersect(G_z_k, setCHP))
                        if chp_in_k > length(G_z_k) * 0.7  # More than 70% CHP
                            continue  # Skip CHP-dominated groups in heating season
                        end
                    end

                    coeff_left = sum(generators[in.(generators.R_ID, Ref(G_z_k)), :Existing_Cap_MW])
                    coeff_right = sum(generators[in.(generators.R_ID, Ref(G_z_kstar)), :Existing_Cap_MW])
                    # using cross multiplication to avoid integer division error
                    @constraint(EDUC_Model,
                        sum(vGENDISPATCH[g, t] for g in G_z_k, t in setTIME) * coeff_right * length(setTIME) <=
                        (1 + alpha) * sum(vGENDISPATCH[g, t] for g in G_z_kstar, t in setTIME) * coeff_left * length(setTIME),
                        base_name = "sel_eq_up_p$(z)$(k)")

                    @constraint(EDUC_Model,
                        sum(vGENDISPATCH[g, t] for g in G_z_k, t in setTIME) * coeff_right * length(setTIME) >=
                        (1 - alpha) * sum(vGENDISPATCH[g, t] for g in G_z_kstar, t in setTIME) * coeff_left * length(setTIME),
                        base_name = "sel_eq_low_p$(z)$(k)")
                end
            end
        end

        # Flow-MLT constraints
        local mlt_band::Float64
        if @isdefined(config_filepath) && !isempty(config_filepath) && isfile(config_filepath)
            # EXPERIMENT MODE - 从配置文件读取MLT band
            run_config_df = CSV.read(config_filepath, DataFrame)
            
            # 查找MLT_Band参数
            mlt_band_rows = run_config_df[run_config_df.parameter .== "MLT_Band", :]
            if nrow(mlt_band_rows) > 0
                mlt_band = mlt_band_rows[1, :value]
                log_println("📊 Using MLT band from config: ±$(round(mlt_band*100, digits=1))%")
            else
                mlt_band = 0.20  # 默认值20%
                log_println("📊 MLT band not in config, using default: ±$(round(mlt_band*100, digits=1))%")
            end
        else
            # STANDALONE MODE - 使用默认MLT band
            mlt_band = 0.10  # 默认值20%
            log_println("📊 Running in STANDALONE mode, using default MLT band: ±$(round(mlt_band*100, digits=1))%")
        end

        # For all lines, flow <= MLT; and flow direction should align with coprresonding MLT direction.
        if scenario_name in ["PriorityMLT"]
            temp_setLINE = setLINE
            # For all lines: no MLT limit on flow's amount and direction     
        elseif scenario_name in ["SpotOnly"]
            temp_setLINE = []
            log_println(scenario_name, " scenario is running; not limit MLT-vFLOW balance")
        else
            temp_setLINE = []
            log_println(scenario_name, " Error: NO scenario is running!!!; not limit MLT-vFLOW balance")
        end

        @variable(EDUC_Model, vMLTSlackUp[setLINE, setTIME] >= 0)  # MLT上限松弛变量
        @variable(EDUC_Model, vMLTSlackDown[setLINE, setTIME] >= 0)  # MLT下限松弛变量  

        for l in temp_setLINE
            loss_rate = network_fwd[network_fwd.Network_Lines.==l, :Loss][1]  # Same: network_rvs
            line_name = network_fwd[network_fwd.Network_Lines.==l, :transmission_path_name][1]  # Same: network_rvs
            log_println("Lines limited by MLT include: ", line_name)
            for t in setTIME[1:end]
                if mlt[t, line_name] >= 0
                    @constraint(EDUC_Model, 
                        vFLOWFWD[l, t] <= (1 + mlt_band) * mlt[t, line_name] * (1 - loss_rate / 2) + vMLTSlackUp[l, t]
                    ) # 动态上界
                    @constraint(EDUC_Model, 
                        vFLOWFWD[l, t] >= (1 - mlt_band) * mlt[t, line_name] * (1 - loss_rate / 2) - vMLTSlackDown[l, t]
                    ) # 动态下界
                    @constraint(EDUC_Model, vFLOWRVS[l, t] == 0)
                else
                    @constraint(EDUC_Model, vFLOWFWD[l, t] == 0)
                    # 反向流也使用动态的mlt_band
                    @constraint(EDUC_Model, 
                        vFLOWRVS[l, t] <= (1 + mlt_band) * abs(mlt[t, line_name] * (1 - loss_rate / 2)) + vMLTSlackUp[l, t]
                    ) # 动态上界
                    @constraint(EDUC_Model, 
                        vFLOWRVS[l, t] >= (1 - mlt_band) * abs(mlt[t, line_name] * (1 - loss_rate / 2)) - vMLTSlackDown[l, t]
                    ) # 动态下界
                end
            end
        end


        # Reserve: for UC units, 
        # reserve up contribution should be less than committed capacity 
        @constraint(EDUC_Model, cResUp_UC1[g in setUC, t in setTIME], vRESUP[g, t] <= vCOMMIT[g, t] * vCAPGEN[g])
        # reserve up contribution <= commitment status * installed capacity  - dispatch amount
        @constraint(EDUC_Model, cResUp_UC2[g in setUC, t in setTIME], vRESUP[g, t] <= vCOMMIT[g, t] * vCAPGEN[g] - vGENDISPATCH[g, t])
        # reserve up amount <= maximum ramping up/down level
        @constraint(EDUC_Model, cResUp_UC3[g in setUC, t in setTIME], vRESUP[g, t] <= vCOMMIT[g, t] * generators.Ramp_Up_Percentage[g] * vCAPGEN[g])
        # reserve down contribution should be less than committed capacity 
        @constraint(EDUC_Model, cResDown_UC1[g in setUC, t in setTIME], vRESDOWN[g, t] <= vCOMMIT[g, t] * vCAPGEN[g])
        # reserve down contribution <= dispatch amount - min_power
        @constraint(EDUC_Model, cResDown_UC2[g in setUC, t in setTIME], vRESDOWN[g, t] <= vCOMMIT[g, t] * vGENDISPATCH[g, t] - vCOMMIT[g, t] * generators.Min_Power[g] * vCAPGEN[g])  # ???
        # reserve up amount <= maximum ramping up/down level
        @constraint(EDUC_Model, cResDown_UC3[g in setUC, t in setTIME], vRESDOWN[g, t] <= vCOMMIT[g, t] * generators.Ramp_Dn_Percentage[g] * vCAPGEN[g])

        # Reserve: for Wind and Solar units
        # reserve up contribution <= hourly available capacity (i.e., houlry capacity factor * installed capacity)
        @constraint(EDUC_Model, cResUp_WindSolar1[g in setWINDSOLAR, t in setTIME], vRESUP[g, t] <= genvar[t, g] * vCAPGEN[g])
        # reserve up contribution <= hourly available capacity - dispatch amount
        @constraint(EDUC_Model, cResUp_WindSolar2[g in setWINDSOLAR, t in setTIME], vRESUP[g, t] <= genvar[t, g] * vCAPGEN[g] - vGENDISPATCH[g, t]) #for wind/solar, Eff_Down/Up are set to 100%
        # reserve up amount <= maximum ramping up/down level
        @constraint(EDUC_Model, cResUp_WindSolar3[g in setWINDSOLAR, t in setTIME], vRESUP[g, t] <= generators.Ramp_Up_Percentage[g] * vCAPGEN[g])   #for wind/solar, ramp_up_percentage is in fact set to 100%
        # reserve down contribution <= hourly available capacity (i.e., houlry capacity factor * installed capacity)
        @constraint(EDUC_Model, cResDown_WindSolar1[g in setWINDSOLAR, t in setTIME], vRESDOWN[g, t] <= genvar[t, g] * vCAPGEN[g])
        # reserve down contribution <= hourly available capacity - dispatch amount
        @constraint(EDUC_Model, cResDown_WindSolar2[g in setWINDSOLAR, t in setTIME], vRESDOWN[g, t] <= vGENDISPATCH[g, t] - generators.Min_Power[g] * genvar[t, g] * vCAPGEN[g]) #for wind/solar, min_power is in fact set to 0.
        # reserve down amount <= maximum ramping up/down level
        @constraint(EDUC_Model, cResDown_WindSolar3[g in setWINDSOLAR, t in setTIME], vRESDOWN[g, t] <= generators.Ramp_Dn_Percentage[g] * vCAPGEN[g]) #for wind/solar, ramp_dn_percentage is in fact set to 100%


        # Reserve: for STOR units (battery and reservoir)
        # reserve up contribution <= maximum rated charge/discharge power of battery/reservoir
        @constraint(EDUC_Model, cResUp_Stor1[g in setSTOR, t in setTIME], vRESUP[g, t] <= vCAPGEN[g])
        # reserve up contribution + dispatch of STOR <= maximum rated charge/discharge power of battery/reservoir
        @constraint(EDUC_Model, cResUp_Stor2[g in setSTOR, t in setTIME], vRESUP[g, t] + vGENDISPATCH[g, t] <= vCAPGEN[g])
        # reserve up contribution <= maximum energy capacity of battery/reservoir - dispatch amount; 
        @constraint(EDUC_Model, cResUp_Stor3[g in setSTOR, t in setTIME], vRESUP[g, t] <= vMAXENGY[g] * generators.Eff_Down[g] - vGENDISPATCH[g, t])  # For STOR, generators.Eff_Down/Up are not 0
        # reserve up contribution <= remaing energy of battery/reservoir (i.e., SOC)
        @constraint(EDUC_Model, cResUp_Stor4[g in setSTOR, t in setTIME], vRESUP[g, t] <= vSOCSTOR[g, t] * generators.Eff_Down[g])
        # reserve up <= ramp up speed
        @constraint(EDUC_Model, cResUp_Stor5[g in setSTOR, t in setTIME], vRESUP[g, t] <= generators.Ramp_Up_Percentage[g] * vCAPGEN[g])  #for STOR, ramp_up/down_percentage is in fact set to 100%
        # reserve down contribution <= maximum rated charge/discharge power of battery/reservoir
        @constraint(EDUC_Model, cResDown_Stor1[g in setSTOR, t in setTIME], vRESDOWN[g, t] <= vCAPGEN[g])
        # reserve down <= max energy capacity - SOCt (it may swich from discharge to charge)
        @constraint(EDUC_Model, cResDown_Stor2[g in setSTOR, t in setTIME], vRESDOWN[g, t] <= vMAXENGY[g] * generators.Eff_Down[g] - vSOCSTOR[g, t] * generators.Eff_Down[g])    #for STOR, min_power is set to 0
        # reserve down <= ramp down speed
        @constraint(EDUC_Model, cResDown_Stor3[g in setSTOR, t in setTIME], vRESDOWN[g, t] <= generators.Ramp_Dn_Percentage[g] * vCAPGEN[g])  #for STOR, ramp_up/dn_percentage is in fact set to 100% 
        # Non-mutually exclusive charge and discharge for storage units  ## ???
        @constraint(EDUC_Model, cResUpAndDown_Stor[g in setSTOR, t in setTIME], (vGENDISPATCH[g, t] + vRESUP[g, t]) / generators.Eff_Down[g] + (vCHARGESTOR[g, t] + vRESDOWN[g, t]) * generators.Eff_Up[g] <= vCAPGEN[g])


        # Reserve: for Hydro units (including dam and excluding reservoir)
        # Reserve up contribution <= maximum rated power of hydro unit
        @constraint(EDUC_Model, cResUp_Hydro1[g in setHYDRO, t in setTIME], vRESUP[g, t] <= vCAPGEN[g])
        # reserve up contribution + dispatch of STOR <= maximum rated charge/discharge power of battery/reservoir
        @constraint(EDUC_Model, cResUp_Hydro2[g in setHYDRO, t in setTIME], vRESUP[g, t] + vGENDISPATCH[g, t] <= vCAPGEN[g])
        # Reserve up contribution <= maximum energy capacity of dam - dispatch amount
        @constraint(EDUC_Model, cResUp_Hydro3[g in setHYDRO, t in setTIME], vRESUP[g, t] <= vMAXENGY[g] * generators.Eff_Down[g] - vGENDISPATCH[g, t]) # for HYDRO, Eff_Down/Up are set to 100%
        # Reserve up contribution <= available remaining enegy of dam (i.e. SOC)
        @constraint(EDUC_Model, cResUp_Hydro4[g in setHYDRO, t in setTIME], vRESUP[g, t] <= vSOCHYDRO[g, t] * generators.Eff_Down[g]) # for HYDRO,  Eff_Down is set to 100%
        # Reserve up contribution <= ramp up speed
        @constraint(EDUC_Model, cResUp_Hydro5[g in setHYDRO, t in setTIME], vRESUP[g, t] <= generators.Ramp_Up_Percentage[g] * vCAPGEN[g])  #for Hydro, ramp_up/dn_percentage is set to 8.3%
        # Reserve down contribution <= maximum rated power of hydro unit
        @constraint(EDUC_Model, cResDown_Hydro1[g in setHYDRO, t in setTIME], vRESDOWN[g, t] <= vCAPGEN[g])
        # Reserve down contribution <= maximum energy capacity of dam - remaining energy of dam (i.e. SOC at time t) - minimum water lelel
        @constraint(EDUC_Model, cResDown_Hydro2[g in setHYDRO, t in setTIME], vRESDOWN[g,t] <= (vMAXENGY[g] - minreservoirlevel - vSOCHYDRO[g,t]) * generators.Eff_Down[g])  #for HYDRO, min_power is set to 0
        # Reserve down <= ramp down speed
        @constraint(EDUC_Model, cResDown_Hydro3[g in setHYDRO, t in setTIME], vRESDOWN[g, t] <= generators.Ramp_Dn_Percentage[g] * vCAPGEN[g])  #for Hydro, ramp_up/dn_percentage is set to 8.3%


        # Reserve: Total reserve up/down for each zone (setZone)
        # For external zones, vRESUP automatically equals to 0, because we set the following three parameters to 0: operatingres.Load, operatingres.Renewable, contn1[z]
        @constraint(EDUC_Model, cTotResUp[z in setZONE, t in setTIME],
            sum(vRESUP[g, t] for g in intersect(setGEN, generators[generators.Zone.==z, :R_ID])) >=
            # first(operatingres[operatingres.Zones .== z, :Load]) * (load[t,z] - sum(vNSE[z,s,t] for s in setSEGMENT)) +
            first(operatingres[operatingres.Zones.==z, :Load]) * (load[t, z]) +
            first(operatingres[operatingres.Zones.==z, :Renewable]) * sum(vGENDISPATCH[g, t] for g in intersect(setWINDSOLAR, generators[generators.Zone.==z, :R_ID])) +   #operating reserve for renewables just consider the generation from wind and soalr; not consider hydro
            contn1[z]
        )
        @constraint(EDUC_Model, cTotResDown[z in setZONE, t in setTIME],
            sum(vRESDOWN[g, t] for g in intersect(setGEN, generators[generators.Zone.==z, :R_ID])) >=
            # first(operatingres[operatingres.Zones .== z, :Load]) * (load[t,z] - sum(vNSE[z,s,t] for s in setSEGMENT)) +
            first(operatingres[operatingres.Zones.==z, :Load]) * (load[t, z]) +
            first(operatingres[operatingres.Zones.==z, :Renewable]) * sum(vGENDISPATCH[g, t] for g in intersect(setWINDSOLAR, generators[generators.Zone.==z, :R_ID]))
        )

        # Objective = Varirable cost + NSE cost + Start Cost
        @expression(EDUC_Model, eVarCostGen, sum(sample_weight[t] * Var_Cost[g, (t+(count-1)*hours_per_period)] * vGENDISPATCH[g, t] for g in setGEN, t in setTIME))
        @expression(EDUC_Model, eNSECosts, sum(sample_weight[t] * first(nse[(nse.Zone.==z).&(nse.Segment.==s), :NSE_Cost]) * vNSE[z, s, t] for z in setZONE, s in setSEGMENT, t in setTIME))
        @expression(EDUC_Model, eStartCostUC, sum(Start_Cost[g, (t+(count-1)*hours_per_period)] * generators.Cap_Size[g] * vSTARTUC[g, t] for g in setUC, t in setTIME))
        # Define the objective function
        @objective(EDUC_Model, Min, eVarCostGen + eNSECosts + eStartCostUC
                                    + 100000 * vQuotaShortfall_CHP
                                    + 100000 * vQuotaShortfall_NonCHP
                                    + 10000000 * sum(vMLTSlackUp) 
                                    + 10000000 * sum(vMLTSlackDown)
        )


        JuMP.optimize!(EDUC_Model)

        if isdir(joinpath(resultpath, string(count))) == false
            mkdir(joinpath(resultpath, string(count)))
        else
            rm(joinpath(resultpath, string(count)), recursive=true)
            mkdir(joinpath(resultpath, string(count)))
        end

        #=
        if isdir(joinpath(dispatchpath, string(count))) == false
            mkdir(joinpath(dispatchpath, string(count)))
        else
            rm(joinpath(dispatchpath, string(count)), recursive=true)
            mkdir(joinpath(dispatchpath, string(count)))
        end
        =#

        if termination_status(EDUC_Model) == MOI.OPTIMAL || termination_status(EDUC_Model) == MOI.TIME_LIMIT # If model is solved to optimality or time limit is reached
            log_println("################################")
            log_println("✅ Week ", count, " is feasible!!!")
            log_println("################################")

            # 🔍 添加MLT slack变量检查
            log_println("=== MLT SLACK VARIABLES CHECK ===")
            mlt_slack_up_total = JuMP.value(sum(vMLTSlackUp))
            mlt_slack_down_total = JuMP.value(sum(vMLTSlackDown))
            
            log_println("Week $count MLT Slack Summary:")
            log_println("  Total MLT Slack Up: $(round(mlt_slack_up_total, digits=2)) MW")
            log_println("  Total MLT Slack Down: $(round(mlt_slack_down_total, digits=2)) MW")

            if mlt_slack_up_total > 0.01 || mlt_slack_down_total > 0.01
                log_println("  ⚠️  MLT constraints violated! Slack variables activated:")

                # 创建MLT slack数据表和详细分析
                mlt_slack_data = DataFrame()
                mlt_slack_data.Line = String[]
                mlt_slack_data.Hour = Int[]
                mlt_slack_data.Direction = String[]  # 新增：标记正向/反向
                mlt_slack_data.MLT_Value = Float64[]  # 新增：当期MLT值
                mlt_slack_data.Actual_Flow = Float64[]  # 新增：实际流量
                mlt_slack_data.SlackUp = Float64[]
                mlt_slack_data.SlackDown = Float64[]
                mlt_slack_data.SlackDown = Float64[]
                
                # 合并：既保存数据又做详细分析
                for l in temp_setLINE
                    line_name = network_fwd[network_fwd.Network_Lines.==l, :transmission_path_name][1]
                    loss_rate = network_fwd[network_fwd.Network_Lines.==l, :Loss][1]
                    
                    line_slack_up_fwd = 0.0
                    line_slack_down_fwd = 0.0
                    line_slack_up_rvs = 0.0
                    line_slack_down_rvs = 0.0
                    max_slack_up = 0.0
                    max_slack_down = 0.0
                    max_slack_up_hour = 1
                    max_slack_down_hour = 1
                    max_slack_direction = "FWD"
                    
                    for t in setTIME
                        slack_up = JuMP.value(vMLTSlackUp[l, t])
                        slack_down = JuMP.value(vMLTSlackDown[l, t])
                        mlt_val = mlt[t, line_name]
                        
                        # 判断当期方向
                        if mlt_val >= 0
                            direction = "FWD"
                            actual_flow = JuMP.value(vFLOWFWD[l, t])
                            line_slack_up_fwd += slack_up
                            line_slack_down_fwd += slack_down
                        else
                            direction = "RVS"
                            actual_flow = -JuMP.value(vFLOWRVS[l, t])
                            line_slack_up_rvs += slack_up
                            line_slack_down_rvs += slack_down
                        end
                        
                        # 保存违规数据
                        if slack_up > 0.01 || slack_down > 0.01
                            # 统一用带符号的流量：正向为正，反向为负
                            signed_flow = mlt_val >= 0 ? actual_flow : -JuMP.value(vFLOWRVS[l, t])
                            push!(mlt_slack_data, [
                                line_name, 
                                t, 
                                direction,
                                mlt_val,
                                signed_flow,
                                slack_up, 
                                slack_down
                            ])
                        end
                        
                        # 记录最大违规
                        if slack_up > max_slack_up
                            max_slack_up = slack_up
                            max_slack_up_hour = t
                            max_slack_direction = direction
                        end
                        if slack_down > max_slack_down
                            max_slack_down = slack_down
                            max_slack_down_hour = t
                            max_slack_direction = direction
                        end
                    end
                    
                    # 输出线路级别的总结
                    if line_slack_up_fwd > 0.01 || line_slack_down_fwd > 0.01 || 
                       line_slack_up_rvs > 0.01 || line_slack_down_rvs > 0.01
                        log_println("    Line $line_name:")
                        
                        if line_slack_up_fwd > 0.01 || line_slack_down_fwd > 0.01
                            log_println("      [FORWARD Direction]")
                            if line_slack_up_fwd > 0.01
                                log_println("        Total Slack Up: $(round(line_slack_up_fwd, digits=2)) MW")
                            end
                            if line_slack_down_fwd > 0.01
                                log_println("        Total Slack Down: $(round(line_slack_down_fwd, digits=2)) MW")
                            end
                        end
                        
                        if line_slack_up_rvs > 0.01 || line_slack_down_rvs > 0.01
                            log_println("      [REVERSE Direction]")
                            if line_slack_up_rvs > 0.01
                                log_println("        Total Slack Up: $(round(line_slack_up_rvs, digits=2)) MW")
                            end
                            if line_slack_down_rvs > 0.01
                                log_println("        Total Slack Down: $(round(line_slack_down_rvs, digits=2)) MW")
                            end
                        end
                        
                        log_println("      Max violation: $(round(max(max_slack_up, max_slack_down), digits=2)) MW")
                        log_println("        at hour $(max_slack_up > max_slack_down ? max_slack_up_hour : max_slack_down_hour)")
                        log_println("        in $(max_slack_direction) direction")
                    end
                end
                
                # 保存违规数据
                if nrow(mlt_slack_data) > 0
                    CSV.write(joinpath(resultpath, string(count), "mlt_slack_violations.csv"), mlt_slack_data)
                    log_println("  📊 MLT violation details saved to mlt_slack_violations.csv")
                end
            else
                log_println("  ✅ All MLT constraints satisfied without slack!")
            end
            log_println("=== END MLT SLACK CHECK ===\n")

            # 记录本周违规到全局汇总
            if mlt_slack_up_total > 0.01 || mlt_slack_down_total > 0.01
                violation_hours = nrow(mlt_slack_data)
                max_violation_row = sort(mlt_slack_data, :SlackUp, rev=true)[1, :]
                if max_violation_row.SlackDown > max_violation_row.SlackUp
                    max_violation_row = sort(mlt_slack_data, :SlackDown, rev=true)[1, :]
                end
                
                push!(MLT_VIOLATION_SUMMARY, [
                    count,
                    mlt_slack_up_total,
                    mlt_slack_down_total,
                    violation_hours,
                    max(max_violation_row.SlackUp, max_violation_row.SlackDown),
                    max_violation_row.Line,
                    max_violation_row.Direction
                ])
            end
            ##

            othergenopr = [vCOMMIT, vSTARTUC, vSHUTUC, vCHARGESTOR, vSOCSTOR, vCHARGEHYDRO, vSOCHYDRO, vRESUP, vRESDOWN, vGENDISPATCH]
            # othergenopr = [vCOMMIT, vSTARTUC, vSHUTUC, vCHARGESTOR, vSOCSTOR, vRESUP, vRESDOWN, vGENDISPATCH]
            flow = vFLOWFWD .+ (-vFLOWRVS)

            RecordCSV(othergenopr, vFLOWFWD, vFLOWRVS, flow, vNSE, vCAPGEN, genvar, count, vQuotaShortfall_CHP, vQuotaShortfall_NonCHP)

            costs = DataFrame()
            cost_names = ["eVarCostGen", "eNSECosts", "eStartCostUC"]
            cost_values = [JuMP.value.(eVarCostGen), JuMP.value.(eNSECosts), JuMP.value.(eStartCostUC)]
            costs.Component = cost_names
            costs.Values = cost_values
            CSV.write(joinpath(resultpath, string(count), "cost_components.csv"), costs)



            # RecordPlot(vNSE, vGENDISPATCH, vCHARGESTOR, count)
            ProcessDispatch(vGENDISPATCH, vCHARGESTOR, count)

        elseif termination_status(EDUC_Model) == MOI.INFEASIBLE || termination_status(EDUC_Model) == MOI.INFEASIBLE_OR_UNBOUNDED
            log_println("###################################")
            log_println("❌ Week ", count, " is infeasible or unbounded")
            log_println("###################################")
        else # If the solution is neither optimal nor infeasible, be warned
            log_println("############################################################################")
            log_println("Solution status is other than optimal, time limit, infeasible, and unbounded")
            log_println("############################################################################")
        end
    end
    
    # ========== 在这里添加年度总结代码 ==========
    # 生成52周MLT违规总结报告
    log_println("\n" * "="^60)
    log_println("📊 ANNUAL MLT VIOLATION SUMMARY (52 WEEKS)")
    log_println("="^60)
    
    if nrow(MLT_VIOLATION_SUMMARY) > 0
        # 保存详细表格
        CSV.write(joinpath(resultpath, "annual_mlt_violation_summary.csv"), MLT_VIOLATION_SUMMARY)
        
        # 统计分析
        total_weeks_violated = nrow(MLT_VIOLATION_SUMMARY)
        total_slack_up = sum(MLT_VIOLATION_SUMMARY.Total_SlackUp_MW)
        total_slack_down = sum(MLT_VIOLATION_SUMMARY.Total_SlackDown_MW)
        avg_violation_per_week = (total_slack_up + total_slack_down) / total_weeks_violated
        
        log_println("Total weeks with violations: $total_weeks_violated / $(length(weeks_to_run))")
        log_println("Total annual Slack Up: $(round(total_slack_up, digits=2)) MW")
        log_println("Total annual Slack Down: $(round(total_slack_down, digits=2)) MW")
        log_println("Average violation per week: $(round(avg_violation_per_week, digits=2)) MW")
        
        # 找出违规最严重的5周
        log_println("\n🔴 Top 5 Weeks with Highest Violations:")
        top5 = sort(MLT_VIOLATION_SUMMARY, 
                   [:Total_SlackUp_MW, :Total_SlackDown_MW], 
                   rev=true)[1:min(5, nrow(MLT_VIOLATION_SUMMARY)), :]
        for row in eachrow(top5)
            log_println("  Week $(row.Week): Total=$(round(row.Total_SlackUp_MW + row.Total_SlackDown_MW, digits=2)) MW")
            log_println("    Max violation on $(row.Max_Violation_Line) ($(row.Max_Violation_Direction)): $(round(row.Max_Violation_MW, digits=2)) MW")
        end
        
        # 按线路汇总违规
        log_println("\n📍 Most Frequently Violated Lines:")
        line_counts = combine(groupby(MLT_VIOLATION_SUMMARY, [:Max_Violation_Line, :Max_Violation_Direction]), 
                             nrow => :Count)
        sort!(line_counts, :Count, rev=true)
        for row in eachrow(line_counts[1:min(3, nrow(line_counts)), :])
            log_println("  $(row.Max_Violation_Line) ($(row.Max_Violation_Direction)): violated in $(row.Count) weeks")
        end
        
    else
        log_println("✅ NO MLT violations across all $(length(weeks_to_run)) weeks!")
    end
    
    log_println("="^60 * "\n")
    # ========== 年度总结代码结束 ==========
end