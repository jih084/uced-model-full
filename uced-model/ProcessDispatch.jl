
function ProcessDispatch(powam, charam, count)

    #################### Processing Dispatch > ################
    solution = DataFrame(powam.data, :auto) # Extract data (rows are resources, columns are hours). It is in mathematical form, e.g., x2[1,2]
    cols = names(solution) # Get column names (x1, x2, ...)
    insertcols!(solution, 1, :R_ID => powam.axes[1]) # Create and insert R_ID column in solution
    # colnames = [:R_ID, :technology, :region, :STOR, :SOLAR, :BIOPOWER, :COAL, :GEOTHERMAL, :WIND, :NATURAL, :HYDRO, :NUCLEAR, :OTHER] # Create common column names
    colnames = [:R_ID, :technology, :region, :STOR, :SOLAR, :COAL, :WIND, :GAS, :HYDRO, :NUCLEAR] # Create common column names

    #colnames = [:R_ID, :technology, :region, :STOR, :SOLAR, :BIOPOWER, :NONCCS_COAL, :CCS_COAL, :GEOTHERMAL, :WIND, :NONCCS_GAS, :CCS_GAS, :HYDRO, :NUCLEAR, :OTHER] # Create common column names

    solution = innerjoin(solution, generators[!, colnames], on = :R_ID) # Add Resource, region and label information from generators.csv (merge on R_ID)
    solution = stack(solution, Not(colnames), variable_name = :Hour, value_name = :Dispatch) # Write columns of variable output into rows

    numresults = []
    for i in 1:first(size(solution))
        push!(numresults, JuMP.value.(solution[i,:Dispatch])) # Extract optimal values of decision variables
    end

    solution.DispatchNum = numresults # Add extracted optimal values as column
    select!(solution, Not(:Dispatch)) # Remove Dispatch column as it is in mathematical form

    solution.Hour = foldl(replace, [cols[i] => powam.axes[2][i] for i in 1:length(powam.axes[2])], init = solution.Hour) # Replace hour names (x1, x2, etc.) with 1, 2, etc.
    solution.Hour = convert.(Int64, solution.Hour) # Convert 1, 2, etc. of Any type to Integer type
    #################### < Processing Dispatch ################

    #################### Processing Charge > ################
    charge_data = DataFrame(charam.data, :auto) # Extract data (rows are resources, columns are hours). It is in mathematical form, e.g., x2[1,2]
    cols_charge = names(charge_data) # Get column names (x1, x2, ...)
    insertcols!(charge_data, 1, :R_ID => charam.axes[1]) # Create and insert R_ID column in solution
    colnames_charge = [:R_ID, :technology, :region] # Create common column names
    charge_data = innerjoin(charge_data, generators[!, colnames_charge], on = :R_ID) # Add Resource, region and label information from generators.csv (merge on R_ID)
    charge_data = stack(charge_data, Not(colnames_charge), variable_name = :Hour, value_name = :Charge) # Write columns of variable output into rows

    numresults_charge = []
    for i in 1:first(size(charge_data))
        push!(numresults_charge, JuMP.value.(charge_data[i,:Charge])) # Extract optimal values of decision variables
    end

    charge_data.ChargeNum = numresults_charge # Add extracted optimal values as column
    select!(charge_data, Not(:Charge)) # Remove Dispatch column as it is in mathematical form

    charge_data.Hour = foldl(replace, [cols_charge[i] => charam.axes[2][i] for i in 1:length(charam.axes[2])], init = charge_data.Hour) # Replace hour names (x1, x2, etc.) with 1, 2, etc.
    charge_data.Hour = convert.(Int64, charge_data.Hour) # Convert 1, 2, etc. of Any type to Integer type
    #################### < Processing Charge ################

    dispatch_summary = DataFrame()
    for c in colnames[4:end]
        dispatch_summary[!, c] = [0.0]
    end

    for rname in region_names

        sum_series = []
        types_names = String[]

        # for tp in collect(1:hours_per_period:hours_per_period * numweek)

        weight_week = first(sample_weight[1:1 + hours_per_period - 1])

        filename = string(rname, "_", Int(ceil(1/hours_per_period)))
        # filename = string(rname, "_", "dispatch")
        # filename_charge = string(rname, "_chargeSTOR", "_", Int(ceil(1/hours_per_period)))
        filename_charge = string(rname, "_charge", "_", "STOR")  # record charge amount of STOR (i.e. battery and pumped storage); not include charge power of HYDRO's dam


        solution_region_week = solution[(solution.region .== rname) .& (solution.Hour .>= 1) .& (solution.Hour .<= 1 + hours_per_period - 1), :]
        charge_region_week = charge_data[(charge_data.region .== rname) .& (charge_data.Hour .>= 1) .& (charge_data.Hour .<= 1 + hours_per_period - 1), :]

        aggregated_dispatch = DataFrame()
        for agn in colnames[4:end]
            if sum(solution_region_week[!,agn]) != 0

                sum_hours = []
                for hour in 1:1 + hours_per_period - 1
                    solution_region_hour = solution_region_week[solution_region_week.Hour .== hour, :]
                    sum_resource = combine(groupby(solution_region_hour, [agn]), :DispatchNum => sum)
                    push!(sum_hours, first(sum_resource[sum_resource[!, agn] .== 1, :DispatchNum_sum]))
                end

                aggregated_dispatch[!,agn] = sum_hours

            else
                nothing
            end
        end

        if first(size(charge_region_week)) != 0
            aggregated_charge = DataFrame()
            charge_sum_hours = []
            for hour in 1:1 + hours_per_period - 1
                charge_region_hour = charge_region_week[charge_region_week.Hour .== hour, :]
                push!(charge_sum_hours, sum(charge_region_hour.ChargeNum))
            end
            aggregated_charge.CHARGE = charge_sum_hours
        end

        # if tp == 1
        append!(types_names, names(aggregated_dispatch))
        # end
        append!(sum_series, (sum.(eachcol(aggregated_dispatch)) * weight_week))

       #CSV.write(joinpath(dispatchpath, string(count), string(filename, ".csv")), aggregated_dispatch)

       #=
        if first(size(charge_region_week)) != 0
            CSV.write(joinpath(dispatchpath, string(count), string(filename_charge, ".csv")), aggregated_charge)
        end
        =#
    
        sum_dispatch = sum(Float64.(reshape(sum_series, :, 1)), dims = 2)

        sumd = DataFrame()
        for (x, c) in enumerate(types_names)
            sumd[!, c] = [sum_dispatch[x]]
        end
        dispatch_summary = vcat(dispatch_summary, sumd, cols = :union)
    end
    delete!(dispatch_summary, 1)
    insertcols!(dispatch_summary, 1, :Region => region_names)

    CSV.write(joinpath(resultpath, string(count), "dispatch_summary.csv"), dispatch_summary)

    dispatch_summary_withoutmis = coalesce.(dispatch_summary, 0.0)
    select!(dispatch_summary_withoutmis, Not(:STOR))


end
