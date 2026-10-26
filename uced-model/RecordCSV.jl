
function RecordCSV(unitc, flowfwd, flowrvs, flowcombine, unmetdec, allcap, genvar, count, varg_chp_shortfall, varg_nonchp_shortfall # for min quota debugging
)

    for var in unitc
        varname = first(split(name(var[first(first(axes(JuMP.value.(var)))), 1]), "["))

        # Create a combined DataFrame for results
        local data # Use 'local' to ensure it's accessible outside the if/else block
        if captive_scenario && varname == "vGENDISPATCH"
            println("Reconstructing full dispatch results to include captive plants...")

            # 1. Get results for OPTIMIZED dispatchable plants
            dispatchable_results = JuMP.value.(var)
            dispatchable_df = DataFrame(dispatchable_results.data, :auto)
            insertcols!(dispatchable_df, 1, :Index => first(axes(dispatchable_results)))

            # 2. Manually create the FIXED dispatch for captive plants
            captive_info = filter(row -> row.R_ID in setCAPTIVE, generators)

            if !isempty(captive_info)
                captive_rows = []
                for row in eachrow(captive_info)
                    fixed_generation = row.Existing_Cap_MW * 0.8
                    # Create a single row vector for this plant
                    new_row = [row.R_ID; fill(fixed_generation, hours_per_period)]
                    push!(captive_rows, new_row)
                end
                captive_matrix = reduce(hcat, captive_rows)'
                col_names = names(dispatchable_df)
                captive_df = DataFrame(captive_matrix, col_names)

                # 3. Combine, sort, and assign to the 'data' variable
                data = vcat(dispatchable_df, captive_df)
                sort!(data, :Index)

            else
                data = dispatchable_df
            end
        else
            results = JuMP.value.(var)
            data = DataFrame(results.data, :auto)
            insertcols!(data, 1, :Index => first(axes(results)))
        end
        data.Index = Int.(data.Index)
        insertcols!(data, 2, :Zone => generators.Zone[data.Index])
        insertcols!(data, 3, :Region => generators.region[data.Index])
        insertcols!(data, 4, :Resource => generators.technology[data.Index])

        varname = first(split(name(var[first(first(axes(JuMP.value.(var)))), 1]), "["))
        CSV.write(joinpath(resultpath, string(count), string(varname, "_results.csv")), data)
    end


    flowfwd_data = DataFrame(JuMP.value.(flowfwd).data, :auto)
    insertcols!(flowfwd_data, 1, :Index => first(axes(JuMP.value.(flowfwd))))
    insertcols!(flowfwd_data, 2, :Path => network_fwd.transmission_path_name[flowfwd_data.Index])
    CSV.write(joinpath(resultpath, string(count), "vFLOWFWD_results.csv"), flowfwd_data)

    flowrvs_data = DataFrame(JuMP.value.(flowrvs).data, :auto)
    insertcols!(flowrvs_data, 1, :Index => first(axes(JuMP.value.(flowrvs))))
    insertcols!(flowrvs_data, 2, :Path => network_fwd.transmission_path_name[flowrvs_data.Index])
    CSV.write(joinpath(resultpath, string(count), "vFLOWRVS_results.csv"), flowrvs_data)

    flowcombine_data = DataFrame(JuMP.value.(flowcombine).data, :auto)
    insertcols!(flowcombine_data, 1, :Index => first(axes(JuMP.value.(flowcombine))))
    insertcols!(flowcombine_data, 2, :Path => network_fwd.transmission_path_name[flowcombine_data.Index])
    CSV.write(joinpath(resultpath, string(count), "vFLOW_results.csv"), flowcombine_data)

    # flowdata_abs = DataFrame(JuMP.value.(flowabs).data, :auto)
    # insertcols!(flowdata_abs, 1, :Index => first(axes(JuMP.value.(flowabs))))
    # insertcols!(flowdata_abs, 2, :Path => network.transmission_path_name[flowdata_abs.Index])
    # CSV.write(joinpath(resultpath, string(count), "vFLOWABS_results.csv"), flowdata_abs)

    for row in 1:first(size(unmetdec))
        data = DataFrame(JuMP.value.(unmetdec).data[row, :, :], :auto)
        insertcols!(data, 1, :Index => first(axes(JuMP.value.(unmetdec)[row, :, :])))
        CSV.write(joinpath(resultpath, string(count), string("vNSE", row, ".csv")), data)
    end

    # for var in stres
    #     data = DataFrame(JuMP.value.(var).data, :auto)
    #     insertcols!(data, 1, :Index => first(axes(JuMP.value.(var))))
    #     insertcols!(data, 2, :Zone => generators.Zone[first(axes(JuMP.value.(var)))])
    #     insertcols!(data, 3, :Region => generators.region[first(axes(JuMP.value.(var)))])
    #     insertcols!(data, 4, :Resource => generators.technology[first(axes(JuMP.value.(var)))])

    #     varname = first(split(name(var[first(first(axes(JuMP.value.(var)))), 1]), "["))
    #     CSV.write(joinpath(resultpath, string(count), string(varname, "_results.csv")), data)
    # end

    allcap_data = DataFrame()
    allcap_data.R_ID = first(axes(JuMP.value.(allcap)))
    allcap_data.Zone = generators.Zone[allcap_data.R_ID]
    allcap_data.Region = generators.region[allcap_data.R_ID]
    allcap_data.Resource = generators.technology[allcap_data.R_ID]
    allcap_data.OptValues = JuMP.value.(allcap).data

    # NE China now doesn't consider CCS，Biopower, Geothermal, and other generators.
    colnames = [:R_ID, :STOR, :SOLAR, :COAL, :WIND, :GAS, :HYDRO, :NUCLEAR, :NONDISP] # Create common column names
    #colnames = [:R_ID, :STOR, :SOLAR, :BIOPOWER, :NONCCS_COAL, :CCS_COAL, :GEOTHERMAL, :WIND, :NONCCS_GAS, :CCS_GAS, :HYDRO, :NUCLEAR, :OTHER] # Create common column names

    allcap_res = innerjoin(allcap_data, generators[!, colnames], on=:R_ID) # Add Resource, region and label information from generators.csv (merge on R_ID)

    # Calculate CO2 emission amount
    dispatch_result = CSV.read(joinpath(resultpath, string(count), "vGENDISPATCH_results.csv"), DataFrame)
    start_result = CSV.read(joinpath(resultpath, string(count), "vSTARTUC_results.csv"), DataFrame)

    sort!(dispatch_result, :Index)
    sorted_dispatch = copy(dispatch_result)
    renewable_gen_ids = generators[generators.RENEW.==1, :R_ID]
    dispatch_renew = filter(row -> row.Index in renewable_gen_ids, dispatch_result)

    co2_start = CO2_Per_Start[start_result.Index]
    capsize = generators.Cap_Size[start_result.Index]

    select!(dispatch_result, Not([:Index, :Zone, :Region, :Resource]))
    select!(start_result, Not([:Index, :Zone, :Region, :Resource]))
    select!(dispatch_renew, Not([:Index, :Zone, :Region, :Resource]))

    co2_amount = sum((sum.(eachcol(CO2_Rate .* dispatch_result)) + sum.(eachcol(co2_start .* (capsize .* start_result)))) .* sample_weight)
    renew_share = sum(sum.(eachcol(dispatch_renew)) .* sample_weight) / sum(sum.(eachcol(dispatch_result)) .* sample_weight)

    environment = DataFrame()
    environment.CO2 = [co2_amount]
    # environment.Renew_Share = [renew_share]
    CSV.write(joinpath(resultpath, string(count), "environment.csv"), environment)


    # --- Record Slack Variable Values for Min Quota Debugging ---

    slack_data = DataFrame(SlackVariable=String[], Shortfall_MWh=Float64[])

    try
        chp_shortfall_value = JuMP.value(varg_chp_shortfall)
        push!(slack_data, ("QuotaShortfall_CHP", chp_shortfall_value))
    catch e
        println("Info: CHP slack variable not found or model not solved. Skipping.")
    end

    try
        nonchp_shortfall_value = JuMP.value(varg_nonchp_shortfall)
        push!(slack_data, ("QuotaShortfall_NonCHP", nonchp_shortfall_value))
    catch e
        println("Info: Non-CHP slack variable not found or model not solved. Skipping.")
    end

    # Print quota summary for this week using your dynamic quota function
    heating_flag = is_heating_season(count)
    season_name = heating_flag == 1 ? "heating" : "non-heating"

    # Get the actual slack values from the model variables
    chp_slack_value = 0.0
    nonchp_slack_value = 0.0

    try
        chp_slack_value = JuMP.value(varg_chp_shortfall)
    catch e
        chp_slack_value = 0.0
    end

    try
        nonchp_slack_value = JuMP.value(varg_nonchp_shortfall)
    catch e
        nonchp_slack_value = 0.0
    end

    println("📋 Week $count ($season_name): CHP slack = $(round(chp_slack_value, digits=2)) MWh, non-CHP slack = $(round(nonchp_slack_value, digits=2)) MWh")

    if nrow(slack_data) > 0
        CSV.write(joinpath(resultpath, string(count), "infeasibility_diagnostics.csv"), slack_data)
    end
    #### End of Slack Variable Recording ####

    select!(sorted_dispatch, Not([:Index, :Zone, :Region, :Resource]))
    sort!(allcap_res, [:R_ID])

    # final_curtailment = DataFrame()
    # # for agn in [:SOLAR, :WIND]
    # currate = []
    # for rname in region_names
    #     finalcap = allcap_res[(allcap_res.Region .== rname) .& (allcap_res.NONDISP .== 1) .& (allcap_res.OptValues .> 0), [:R_ID, :OptValues]]
    #     if first(size(finalcap)) != 0
    #         potentials = finalcap.OptValues' .* genvar[:, finalcap.R_ID]
    #         subdis = Matrix(sorted_dispatch[finalcap.R_ID, :])'
    #         weighted_cur = ((potentials .- subdis) ./ potentials) .* sample_weight
    #         for col in eachcol(weighted_cur) replace!(col, NaN => 0) end
    #         push!(currate, mean(sum.(eachcol(weighted_cur)) / sum(sample_weight)))
    #     else
    #         push!(currate, missing)
    #     end
    # end
    # final_curtailment.VRE = currate
    # # end
    # insertcols!(final_curtailment, 1, :Region => region_names)
    # CSV.write(joinpath(resultpath, string(count), "final_curtailment.csv"), final_curtailment)



    # Record Curtailment: Weekly, Wind
    # weekly curtailment =*sum(hourly potentials) - sum(hourly dispatch))/ sum(hourly_potentials)
    final_curtailment_wind = DataFrame(Region=region_names)
    total_potentials = []  # 初始化一个空数组来存储每个地区的潜在总发电量。
    total_actuals = []  # 初始化一个空数组来存储每个地区的实际总发电量。
    total_curtailments = []  # 初始化一个空数组来存储每个地区的限制率。
    total_curtailmentrate = []

    for rname in region_names
        finalcap = allcap_res[(allcap_res.Region.==rname).&(allcap_res.Resource.=="onshore_wind_turbine").&(allcap_res.OptValues.>0), [:R_ID, :OptValues]]

        if first(size(finalcap)) != 0
            potentials = finalcap.OptValues' .* genvar[:, finalcap.R_ID]
            for col in eachcol(potentials)
                replace!(col, NaN => 0)
            end
            potentials_sum = sum.(eachcol(potentials))
            push!(total_potentials, potentials_sum[1])  # 存储每个地区的潜在总发电量

            subdis = Matrix(sorted_dispatch[finalcap.R_ID, :])'
            for col in eachcol(subdis)
                replace!(col, NaN => 0)
            end
            subdis_sum = sum.(eachcol(subdis))
            push!(total_actuals, subdis_sum[1])  # 存储每个地区的实际总发电量

            curtailments_sum = potentials_sum - subdis_sum
            currate_temp = curtailments_sum / potentials_sum
            # 检查潜在发电量是否全为零
            if all(potentials_sum .== 0)
                push!(total_curtailments, missing)  # 如果潜在发电量全为零，则无法计算限制率，使用missing标记。
                push!(total_curtailmentrate, missing)  # 如果潜在发电量全为零，则无法计算限制率，使用missing标记。
            else
                push!(total_curtailments, curtailments_sum[1])
                push!(total_curtailmentrate, currate_temp[1])
            end
        else
            push!(total_potentials, 0)  # 无风力发电机的地区潜在总发电量为0
            push!(total_actuals, 0)  # 无风力发电机的地区实际总发电量为0
            push!(total_curtailments, missing)  # 如果没有风力发电机，也使用missing标记。
            push!(total_curtailmentrate, missing)  # 如果没有风力发电机，也使用missing标记。
        end
    end

    final_curtailment_wind.TotalPotentials = total_potentials  # 添加潜在总发电量列
    final_curtailment_wind.TotalActuals = total_actuals  # 添加实际总发电量列
    final_curtailment_wind.TotalCurtailments = total_curtailments
    final_curtailment_wind.Curtailment_rate = total_curtailmentrate
    CSV.write(joinpath(resultpath, string(count), "curtailment_wind_weekly.csv"), final_curtailment_wind)


    # Record Curtailment: Weekly, Solar
    final_curtailment_solar = DataFrame(Region=region_names)
    total_potentials = []  # 初始化一个空数组来存储每个地区的潜在总发电量。
    total_actuals = []  # 初始化一个空数组来存储每个地区的实际总发电量。
    total_curtailments = []  # 初始化一个空数组来存储每个地区的限制率。
    total_curtailmentrate = []

    for rname in region_names
        finalcap = allcap_res[(allcap_res.Region.==rname).&(allcap_res.Resource.=="solar_photovoltaic").&(allcap_res.OptValues.>0), [:R_ID, :OptValues]]

        if first(size(finalcap)) != 0
            potentials = finalcap.OptValues' .* genvar[:, finalcap.R_ID]
            for col in eachcol(potentials)
                replace!(col, NaN => 0)
            end
            potentials_sum = sum.(eachcol(potentials))
            push!(total_potentials, potentials_sum[1])  # 存储每个地区的潜在总发电量

            subdis = Matrix(sorted_dispatch[finalcap.R_ID, :])'
            for col in eachcol(subdis)
                replace!(col, NaN => 0)
            end
            subdis_sum = sum.(eachcol(subdis))
            push!(total_actuals, subdis_sum[1])  # 存储每个地区的实际总发电量

            curtailments_sum = potentials_sum - subdis_sum
            currate_temp = curtailments_sum / potentials_sum
            # 检查潜在发电量是否全为零
            if all(potentials_sum .== 0)
                push!(total_curtailments, missing)  # 如果潜在发电量全为零，则无法计算限制率，使用missing标记。
                push!(total_curtailmentrate, missing)  # 如果潜在发电量全为零，则无法计算限制率，使用missing标记。
            else
                push!(total_curtailments, curtailments_sum[1])
                push!(total_curtailmentrate, currate_temp[1])
            end
        else
            push!(total_potentials, 0)  # 无风力发电机的地区潜在总发电量为0
            push!(total_actuals, 0)  # 无风力发电机的地区实际总发电量为0
            push!(total_curtailments, missing)  # 如果没有风力发电机，也使用missing标记。
            push!(total_curtailmentrate, missing)  # 如果没有风力发电机，也使用missing标记。
        end
    end

    final_curtailment_solar.TotalPotentials = total_potentials  # 添加潜在总发电量列
    final_curtailment_solar.TotalActuals = total_actuals  # 添加实际总发电量列
    final_curtailment_solar.TotalCurtailments = total_curtailments
    final_curtailment_solar.Curtailment_rate = total_curtailmentrate
    CSV.write(joinpath(resultpath, string(count), "curtailment_solar_weekly.csv"), final_curtailment_solar)

    # Record Curtailment: Hourly, Wind
    num_cols = hours_per_period
    hourly_curtailment_wind = DataFrame()
    column_names = ["Hour_$i" for i in 1:num_cols]
    for col_name in column_names
        hourly_curtailment_wind[!, col_name] = Any[]
    end
    hourly_curtailment_wind = convert.(Union{Float64,Missing}, hourly_curtailment_wind)


    for rname in region_names
        finalcap = allcap_res[(allcap_res.Region.==rname).&(allcap_res.Resource.=="onshore_wind_turbine").&(allcap_res.OptValues.>0), [:R_ID, :OptValues]]
        if first(size(finalcap)) != 0
            potentials = finalcap.OptValues' .* genvar[:, finalcap.R_ID]
            subdis = Matrix(sorted_dispatch[finalcap.R_ID, :])'
            weighted_cur = ((potentials .- subdis))
            for col in eachcol(weighted_cur)
                replace!(col, NaN => 0)
            end
            push!(hourly_curtailment_wind, weighted_cur[:, 1])
        else
            push!(hourly_curtailment_wind, fill(missing, hours_per_period))
        end
    end

    insertcols!(hourly_curtailment_wind, 1, :Region => region_names)
    CSV.write(joinpath(resultpath, string(count), "curtailment_wind_hourly.csv"), hourly_curtailment_wind)

    # Record Curtailment: Hourly, Solar
    num_cols = hours_per_period
    hourly_curtailment_solar = DataFrame()
    column_names = ["Hour_$i" for i in 1:num_cols]
    for col_name in column_names
        hourly_curtailment_solar[!, col_name] = Any[]
    end
    hourly_curtailment_solar = convert.(Union{Float64,Missing}, hourly_curtailment_solar)


    for rname in region_names
        finalcap = allcap_res[(allcap_res.Region.==rname).&(allcap_res.Resource.=="solar_photovoltaic").&(allcap_res.NONDISP.==1).&(allcap_res.OptValues.>0), [:R_ID, :OptValues]]
        if first(size(finalcap)) != 0
            potentials = finalcap.OptValues' .* genvar[:, finalcap.R_ID]
            subdis = Matrix(sorted_dispatch[finalcap.R_ID, :])'
            weighted_cur = ((potentials .- subdis))
            for col in eachcol(weighted_cur)
                replace!(col, NaN => 0)
            end
            push!(hourly_curtailment_solar, weighted_cur[:, 1])
        else
            push!(hourly_curtailment_solar, fill(missing, hours_per_period))
        end
    end

    insertcols!(hourly_curtailment_solar, 1, :Region => region_names)
    CSV.write(joinpath(resultpath, string(count), "curtailment_solar_hourly.csv"), hourly_curtailment_solar)

    ############################################################################

    # Record Curtailment: Weekly, VRE (Wind + Solar)
    final_curtailment_vre = DataFrame(Region=region_names)
    total_potentials = []
    total_actuals = []
    total_curtailments = []
    total_curtailmentrate = []

    for rname in region_names
        # Get both wind and solar plants for this region
        finalcap_wind = allcap_res[(allcap_res.Region.==rname).&(allcap_res.Resource.=="onshore_wind_turbine").&(allcap_res.OptValues.>0), [:R_ID, :OptValues]]
        finalcap_solar = allcap_res[(allcap_res.Region.==rname).&(allcap_res.Resource.=="solar_photovoltaic").&(allcap_res.OptValues.>0), [:R_ID, :OptValues]]
        
        # Combine wind and solar plants
        finalcap_vre = vcat(finalcap_wind, finalcap_solar)

        if first(size(finalcap_vre)) != 0
            potentials = finalcap_vre.OptValues' .* genvar[:, finalcap_vre.R_ID]
            for col in eachcol(potentials)
                replace!(col, NaN => 0)
            end
            potentials_sum = sum.(eachcol(potentials))
            push!(total_potentials, potentials_sum[1])

            subdis = Matrix(sorted_dispatch[finalcap_vre.R_ID, :])'
            for col in eachcol(subdis)
                replace!(col, NaN => 0)
            end
            subdis_sum = sum.(eachcol(subdis))
            push!(total_actuals, subdis_sum[1])

            curtailments_sum = potentials_sum - subdis_sum
            currate_temp = curtailments_sum / potentials_sum
            
            if all(potentials_sum .== 0)
                push!(total_curtailments, missing)
                push!(total_curtailmentrate, missing)
            else
                push!(total_curtailments, curtailments_sum[1])
                push!(total_curtailmentrate, currate_temp[1])
            end
        else
            push!(total_potentials, 0)
            push!(total_actuals, 0)
            push!(total_curtailments, missing)
            push!(total_curtailmentrate, missing)
        end
    end

    final_curtailment_vre.TotalPotentials = total_potentials
    final_curtailment_vre.TotalActuals = total_actuals
    final_curtailment_vre.TotalCurtailments = total_curtailments
    final_curtailment_vre.Curtailment_rate = total_curtailmentrate
    CSV.write(joinpath(resultpath, string(count), "curtailment_vre_weekly.csv"), final_curtailment_vre)

    # Record Curtailment: Hourly, VRE (Wind + Solar)
    num_cols = hours_per_period
    hourly_curtailment_vre = DataFrame()
    column_names = ["Hour_$i" for i in 1:num_cols]
    for col_name in column_names
        hourly_curtailment_vre[!, col_name] = Any[]
    end
    hourly_curtailment_vre = convert.(Union{Float64,Missing}, hourly_curtailment_vre)

    for rname in region_names
        # Get both wind and solar plants for this region
        finalcap_wind = allcap_res[(allcap_res.Region.==rname).&(allcap_res.Resource.=="onshore_wind_turbine").&(allcap_res.OptValues.>0), [:R_ID, :OptValues]]
        finalcap_solar = allcap_res[(allcap_res.Region.==rname).&(allcap_res.Resource.=="solar_photovoltaic").&(allcap_res.NONDISP.==1).&(allcap_res.OptValues.>0), [:R_ID, :OptValues]]
        
        # Combine wind and solar plants
        finalcap_vre = vcat(finalcap_wind, finalcap_solar)
        
        if first(size(finalcap_vre)) != 0
            potentials = finalcap_vre.OptValues' .* genvar[:, finalcap_vre.R_ID]
            subdis = Matrix(sorted_dispatch[finalcap_vre.R_ID, :])'
            weighted_cur = ((potentials .- subdis))
            for col in eachcol(weighted_cur)
                replace!(col, NaN => 0)
            end
            push!(hourly_curtailment_vre, weighted_cur[:, 1])
        else
            push!(hourly_curtailment_vre, fill(missing, hours_per_period))
        end
    end

    insertcols!(hourly_curtailment_vre, 1, :Region => region_names)
    CSV.write(joinpath(resultpath, string(count), "curtailment_vre_hourly.csv"), hourly_curtailment_vre)

end
