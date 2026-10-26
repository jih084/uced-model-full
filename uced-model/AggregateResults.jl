
function AggResults()

    println("=== CHECKING WEEK FOLDERS ===")
    empty_weeks = Int[]
    
    for count in 1:numweek
        week_folder = joinpath(resultpath, string(count))

        # Check if folder is empty
        folder_contents = readdir(week_folder)
        if isempty(folder_contents)
            push!(empty_weeks, count)
            println("⚠️  Week $count folder is empty")
        end
    end

    if isempty(empty_weeks)
        println("❌ Empty or incomplete week folders: $(join(empty_weeks, ", "))")
    end
    println("=== END WEEK FOLDERS CHECK ===\n")

    total_cost = DataFrame()
    sumVar, sumNSE, sumStart = 0, 0, 0
    for count in 1:numweek
        cost_week = CSV.read(joinpath(resultpath, string(count), "cost_components.csv"), DataFrame)
        sumVar += first(cost_week[cost_week.Component.=="eVarCostGen", :Values])
        sumNSE += first(cost_week[cost_week.Component.=="eNSECosts", :Values])
        sumStart += first(cost_week[cost_week.Component.=="eStartCostUC", :Values])
    end
    total_cost.Component = ["eVarCostGen", "eNSECosts", "eStartCostUC"]
    total_cost.Values = [sumVar, sumNSE, sumStart]
    total_cost.Percentage = [sumVar / sum(total_cost.Values), sumNSE / sum(total_cost.Values), sumStart / sum(total_cost.Values)]
    CSV.write(joinpath(resultpath, "totalcost.csv"), total_cost)

    # --- ADD THIS SECTION: Aggregate Quota Slack Values ---
    quota_slack_summary = DataFrame(Week=Int[], CHP_Shortfall_MWh=Float64[], NonCHP_Shortfall_MWh=Float64[])

    for count in 1:numweek
        chp_slack = 0.0
        nonchp_slack = 0.0

        # Try to read slack values from infeasibility diagnostics file
        slack_file_path = joinpath(resultpath, string(count), "infeasibility_diagnostics.csv")
        if isfile(slack_file_path)
            try
                slack_data = CSV.read(slack_file_path, DataFrame)

                # Extract CHP slack
                chp_row = filter(row -> row.SlackVariable == "QuotaShortfall_CHP", slack_data)
                if nrow(chp_row) > 0
                    chp_slack = first(chp_row.Shortfall_MWh)
                end
                # Extract non-CHP slack
                nonchp_row = filter(row -> row.SlackVariable == "QuotaShortfall_NonCHP", slack_data)
                if nrow(nonchp_row) > 0
                    nonchp_slack = first(nonchp_row.Shortfall_MWh)
                end
            catch e
                println("Warning: Could not read slack data for week $count")
            end
        end

        push!(quota_slack_summary, (count, chp_slack, nonchp_slack))
    end

    CSV.write(joinpath(resultpath, "quota_slack_summary.csv"), quota_slack_summary)
    # --- END OF QUOTA SLACK AGGREGATION ---

    
    # Original curtailment summary code
    fcur_wind = DataFrame()
    fcur_solar = DataFrame()
    for i in 1:numweek
        file_path_wind = joinpath(resultpath, string(i), "curtailment_wind_weekly.csv")
        file_path_solar = joinpath(resultpath, string(i), "curtailment_solar_weekly.csv")
        df_wind = CSV.read(file_path_wind, DataFrame)
        df_solar = CSV.read(file_path_solar, DataFrame)
        #curtailment_rate_wind = df_wind[:, :Curtailment_rate]
        #curtailment_rate_solar = df_solar[:, :Curtailment_rate]
        formatted_rate_wind = [ismissing(x) ? missing : string(round(x * 100, digits=2), "%") for x in df_wind[:, :Curtailment_rate]]
        formatted_rate_solar = [ismissing(x) ? missing : string(round(x * 100, digits=2), "%") for x in df_solar[:, :Curtailment_rate]]
        # creat 'Region' column when it is Week 1
        if i == 1
            fcur_wind[:, :Region] = df_wind[:, 1]
            fcur_solar[:, :Region] = df_solar[:, 1]
        end
        fcur_wind[:, Symbol("Week$i")] = formatted_rate_wind #curtailment_rate_wind
        fcur_solar[:, Symbol("Week$i")] = formatted_rate_solar #curtailment_rate_solar
        # println("Processed week $i")
    end
    CSV.write(joinpath(resultpath, "curtailmentsummary_wind.csv"), fcur_wind)
    CSV.write(joinpath(resultpath, "curtailmentsummary_solar.csv"), fcur_solar)
    # --- End of Original Curtailment Summary ---
    

    # VRE curtailment summary 
    generate_monthly = true
    generate_quarterly = false
    generate_yearly = false
    
    # Define proper time boundaries
    days_in_month = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    hours_in_month = days_in_month .* 24
    month_end_hours = cumsum(hours_in_month)
    
    # For test case adjustment
    if numweek < 52
        hours_in_month = fill(168 * 4, 3)  # 168 hours per week * 4 weeks per month
        month_end_hours = cumsum(hours_in_month)
    end
    num_months = length(hours_in_month)

    generators_file = joinpath(base_data_path, "Generators_data.csv")
    generators = CSV.read(generators_file, DataFrame)
    vre_generators = filter(row -> row.technology in ["onshore_wind_turbine", "solar_photovoltaic"] && 
                                  row.region ∉ ["JB", "SD"] && 
                                  row.Cap_Size > 0, generators)
                                  println("Found $(nrow(vre_generators)) VRE generators:")

    vre_resource_names = vre_generators.Resource 
    genvar_file = joinpath(base_data_path, "Generators_variability.csv")            
    genvar_df = CSV.read(genvar_file, DataFrame)
    genvar_headers = names(genvar_df)

    # Find which columns in genvar correspond to our VRE generators
    matching_columns = Int[]
    matching_names = String[]
    for (i, header) in enumerate(genvar_headers)
        if string(header) in vre_resource_names
            push!(matching_columns, i)
            push!(matching_names, string(header))
        end
    end
    
    println("Found $(length(matching_columns)) matching columns in genvar:")
    for name in matching_names
        println("  $name")
    end

    genvar_vre_only = Matrix(genvar_df[:, matching_columns])
    resource_to_col_idx = Dict(matching_names[i] => i for i in 1:length(matching_names))

    total_hours = numweek * 168
    num_months = length(hours_in_month)
    region_names = filter(x -> x ∉ ["JB", "SD"], unique(generators.region))
    
    # Calculate hourly potentials and actuals for each region
    all_vre_hourly_potential_by_region = Dict{String, Vector{Float64}}()
    all_vre_hourly_actual_by_region = Dict{String, Vector{Float64}}()
    
    for region in region_names
        # Get VRE generators for this region
        region_vre = filter(row -> row.region == region, vre_generators)
        
        # Calculate hourly potentials using capacity factors
        hourly_potentials = zeros(total_hours)
        if !isempty(region_vre)
            for row in eachrow(region_vre)
                cap = row.Cap_Size
                resource_name = row.Resource
                
                if haskey(resource_to_col_idx, resource_name)
                    col_idx = resource_to_col_idx[resource_name]
                    cf_series = genvar_vre_only[:, col_idx]
                    sim_cf = cf_series[1:min(total_hours, length(cf_series))]
                    hourly_potentials[1:length(sim_cf)] += cap .* sim_cf
                    println("  Added $(row.technology): $resource_name (cap: $cap MW)")
                else
                    println("  Warning: Resource '$resource_name' not found in genvar")
                end
            end
        end
        all_vre_hourly_potential_by_region[region] = hourly_potentials
        
        # Get hourly actuals from weekly dispatch files
        hourly_actuals = zeros(total_hours)
        hour_idx = 1
    
        for week in 1:numweek
            dispatch_file = joinpath(resultpath, string(week), "vGENDISPATCH_results.csv")
            if isfile(dispatch_file) && !isempty(region_vre)
                weekly_dispatch = CSV.read(dispatch_file, DataFrame)
                gen_ids = region_vre.R_ID
                region_vre_dispatch = filter(row -> row.Index in gen_ids, weekly_dispatch)
                
                if !isempty(region_vre_dispatch)
                    hour_cols = [Symbol("x$i") for i in 1:168]
                    week_dispatch_matrix = Matrix(region_vre_dispatch[!, hour_cols])
                    week_totals = vec(sum(week_dispatch_matrix, dims=1))
                    
                    end_hour_idx = min(hour_idx + 167, total_hours)
                    actual_length = end_hour_idx - hour_idx + 1
                    hourly_actuals[hour_idx:end_hour_idx] = week_totals[1:actual_length]
                end
            end
            hour_idx = min(hour_idx + 168, total_hours + 1)
        end
        all_vre_hourly_actual_by_region[region] = hourly_actuals
    end
    
    # Generate vre_monthly_curtailment.csv 
    if generate_monthly
        fcur_vre_monthly = DataFrame(Region=region_names)
        
        for m in 1:num_months
            start_h = m == 1 ? 1 : month_end_hours[m-1] + 1
            end_h = min(month_end_hours[m], total_hours)
            
            monthly_rates = Float64[]
            for region in region_names
                month_potential = sum(all_vre_hourly_potential_by_region[region][start_h:end_h])
                month_actual = sum(all_vre_hourly_actual_by_region[region][start_h:end_h])
                month_curtailment = month_potential - month_actual
                month_rate = month_potential > 0 ? month_curtailment / month_potential : 0.0
                push!(monthly_rates, month_rate)
            end
            
            formatted_rates = [string(round(x * 100, digits=2), "%") for x in monthly_rates]
            fcur_vre_monthly[!, Symbol("Month$m")] = formatted_rates
        end

        # If test case, expand to full 12 months and place results in Sep, Oct, Nov
        if numweek < 52
            
            full_year_monthly = DataFrame(Region=region_names)
            
            for m in 1:12
                zero_rates = fill("0.00%", length(region_names))
                full_year_monthly[!, Symbol("Month$m")] = zero_rates
            end
            
            for m in 1:num_months  # num_months = 3 for test case
                month_index = m + 8  # m=1 -> Month9, m=2 -> Month10, m=3 -> Month11
                full_year_monthly[!, Symbol("Month$month_index")] = fcur_vre_monthly[!, Symbol("Month$m")]
            end
            
            fcur_vre_monthly = full_year_monthly
        end
        
        CSV.write(joinpath(resultpath, "vre_monthly_curtailment.csv"), fcur_vre_monthly)
        println("✅ VRE monthly curtailment summary saved")
    end
    
    # Generate quarterly summary
    if generate_quarterly
        fcur_vre_quarterly = DataFrame(Region=region_names)
        
        quarterly_boundaries = [month_end_hours[3], month_end_hours[6], month_end_hours[9], month_end_hours[12]]
        
        for q in 1:4
            start_h = q == 1 ? 1 : quarterly_boundaries[q-1] + 1
            end_h = min(quarterly_boundaries[q], total_hours)
            
            quarterly_rates = Float64[]
            for region in region_names
                quarter_potential = sum(all_vre_hourly_potential_by_region[region][start_h:end_h])
                quarter_actual = sum(all_vre_hourly_actual_by_region[region][start_h:end_h])
                quarter_curtailment = quarter_potential - quarter_actual
                quarter_rate = quarter_potential > 0 ? quarter_curtailment / quarter_potential : 0.0
                push!(quarterly_rates, quarter_rate)
            end
            
            formatted_rates = [string(round(x * 100, digits=2), "%") for x in quarterly_rates]
            fcur_vre_quarterly[!, Symbol("Quarter$q")] = formatted_rates
        end
        
        CSV.write(joinpath(resultpath, "vre_quarterly_curtailment.csv"), fcur_vre_quarterly)
        println("✅ VRE quarterly curtailment summary saved")
    end
    
    # Generate yearly summary
    if generate_yearly
        fcur_vre_yearly = DataFrame(Region=region_names)
        
        yearly_rates = Float64[]
        for region in region_names
            year_potential = sum(all_vre_hourly_potential_by_region[region])
            year_actual = sum(all_vre_hourly_actual_by_region[region])
            year_curtailment = year_potential - year_actual
            year_rate = year_potential > 0 ? year_curtailment / year_potential : 0.0
            push!(yearly_rates, year_rate)
        end
        
        formatted_rates = [string(round(x * 100, digits=2), "%") for x in yearly_rates]
        fcur_vre_yearly[!, :Year] = formatted_rates
        
        CSV.write(joinpath(resultpath, "vre_yearly_curtailment.csv"), fcur_vre_yearly)
        println("✅ VRE yearly curtailment summary saved")
    end

    # Generate detailed monthly aggregation
    if generate_monthly
        monthly_vre_curt = DataFrame(Region=String[], Month=Int[], TotalPotentials=Float64[], TotalActuals=Float64[], TotalCurtailments=Float64[], Curtailment_rate=Float64[])
        
        for region in region_names
            for m in 1:num_months
                start_h = m == 1 ? 1 : month_end_hours[m-1] + 1
                end_h = min(month_end_hours[m], total_hours)
                
                month_potential = sum(all_vre_hourly_potential_by_region[region][start_h:end_h])
                month_actual = sum(all_vre_hourly_actual_by_region[region][start_h:end_h])
                month_curtailment = month_potential - month_actual
                month_rate = month_potential > 0 ? month_curtailment / month_potential : 0.0
                
                push!(monthly_vre_curt, (region, m, month_potential, month_actual, month_curtailment, month_rate))
            end
        end
        
        CSV.write(joinpath(resultpath, "curtailmentsummary_vre.csv"), monthly_vre_curt)
        println("✅ VRE detailed monthly summary saved")
    end

    # --- END OF VRE CURTAILMENT AGGREGATION ---

    flow_over_period = DataFrame()
    utilization = DataFrame()
    for count in 1:numweek
        if count == 1
            flow_over_period = CSV.read(joinpath(resultpath, string(count), "vFLOW_results.csv"), DataFrame)
            select!(flow_over_period, Not([:Index, :Path]))
            flow_over_period_pos = abs.(flow_over_period)
            utilization = flow_over_period_pos ./ network_fwd.Line_Max_Flow_MW   # Same: network_rvs
        else
            flow_tobesummed = CSV.read(joinpath(resultpath, string(count), "vFLOW_results.csv"), DataFrame)
            select!(flow_tobesummed, Not([:Index, :Path]))
            flow_over_period = flow_over_period .+ flow_tobesummed
            utilization = hcat(utilization, abs.(flow_tobesummed) ./ network_fwd.Line_Max_Flow_MW, makeunique=true) # Same: network_rvs
        end
    end
    flow_summary = DataFrame()
    flow_summary.Path = CSV.read(joinpath(resultpath, string(1), "vFLOW_results.csv"), DataFrame).Path
    flow_summary.Total = sum.(eachrow(flow_over_period)) / 1000
    utilization_summary = DataFrame()
    utilization_summary.Path = CSV.read(joinpath(resultpath, string(1), "vFLOW_results.csv"), DataFrame).Path
    utilization_summary.Rate = mean.(eachrow(utilization))
    CSV.write(joinpath(resultpath, "period_flow.csv"), flow_summary)
    CSV.write(joinpath(resultpath, "period_line_utilization.csv"), utilization_summary)

    weekly_renewable_share = []
    dispatch_over_period = DataFrame()
    for count in 1:numweek
        if count == 1
            dispatch_over_period = CSV.read(joinpath(resultpath, string(count), "dispatch_summary.csv"), DataFrame) #dispatchpath
            region_names = dispatch_over_period.Region
            select!(dispatch_over_period, Not([:Region, :STOR]))
            dispatch_over_period = coalesce.(dispatch_over_period, 0.0)
            push!(weekly_renewable_share,
                (sum(dispatch_over_period.SOLAR) + sum(dispatch_over_period.WIND) + sum(dispatch_over_period.HYDRO))
                /
                sum(sum.(eachcol(dispatch_over_period))))
        else
            dispatch_tobesummed = CSV.read(joinpath(resultpath, string(count), "dispatch_summary.csv"), DataFrame) #dispatchpath
            select!(dispatch_tobesummed, Not([:Region, :STOR]))
            dispatch_tobesummed = coalesce.(dispatch_tobesummed, 0.0)
            push!(weekly_renewable_share,
                (sum(dispatch_tobesummed.SOLAR) + sum(dispatch_tobesummed.WIND) + sum(dispatch_tobesummed.HYDRO))
                /
                sum(sum.(eachcol(dispatch_tobesummed))))
            dispatch_over_period = dispatch_over_period .+ dispatch_tobesummed
        end
    end
    push!(weekly_renewable_share,
        (sum(dispatch_over_period.SOLAR) + sum(dispatch_over_period.WIND) + sum(dispatch_over_period.HYDRO))
        /
        sum(sum.(eachcol(dispatch_over_period))))

    vre_share = DataFrame()
    week_series = collect(1:numweek)
    push!(week_series, numweek + 1)
    vre_share.Week = week_series
    vre_share.Share = weekly_renewable_share
    CSV.write(joinpath(resultpath, "renewable_share.csv"), vre_share)

    insertcols!(dispatch_over_period, 1, :Region => region_names)
    CSV.write(joinpath(resultpath, "period_dispatch.csv"), dispatch_over_period)


end
