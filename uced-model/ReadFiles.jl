# Read path for reading generator information, demand profile, calculation index, network and operating reserve fractions 
generators = CSV.read(joinpath(run_specific_path, generators_filename), DataFrame) # To align with Experiment setup (batch runs)
demand = CSV.read(joinpath(base_data_path, "Load_data.csv"), DataFrame) # Reading demand data and create a data frame
network_fwd = CSV.read(joinpath(base_data_path, "Network_forward.csv"), DataFrame) # Reading forward network data and create a data frame
network_rvs = CSV.read(joinpath(base_data_path, "Network_reverse.csv"), DataFrame) # Reading reserved network data and create a data frame (same line, reverse direction)
fuels = CSV.read(joinpath(base_data_path, "Fuels_data.csv"), DataFrame) # Reading fuels data and create a data frame
mlt = CSV.read(joinpath(base_data_path, "Transmission_MLT.csv"), DataFrame) #Get interprovincial MLT contract 
operatingres = CSV.read(joinpath(base_data_path, "operating_reserve.csv"), DataFrame) # Read operating reserve fractions
other_info = CSV.read(joinpath(base_data_path, "other_inputs.csv"), DataFrame) # Get other info from PowerGenome repository
heating_mw = CSV.read(joinpath(base_data_path, "heating_mw.csv"), DataFrame) # Reading heating load data and create a data frame
#quota_data = CSV.read(joinpath(base_data_path, "Quota_data.csv"), DataFrame)
solver_params = CSV.read(joinpath(mainloc, "solver_params.csv"), DataFrame)


# Read path for scenario "PriorityMLT": prioritized penalty for NCG (cNSE of NCG > cNSE of NEG)
# "Priority" means NSE cost in NC grid is more expensive than that in NE grid
if scenario_name in ["PriorityMLT"]  #North China Grid demand is prioritized over NE Grid demand through non-served energy penalties (cNSE of NCG > cNSE of NEG)
    nse_reduction = CSV.read(joinpath(inputpath_scenario, "nse_reduction.csv"), DataFrame) # Get other info from PowerGenome repository
else
    nothing
end

#### Do not want derate #####
#=
# Read path for scenarios with capped electricity price （scenario "FlexibleSpotMLT"); capped electicity price means derated generators
if scenario_name ∉ ["FlexibleSpotMLT"]    # No "Flexible" in scenario name means no electricity price cap and no derated units.
    genvar = CSV.read(joinpath(inputpath_main, "Generators_variability_derated_35%.csv"), DataFrame) # Reading generator variability data and create a data frame
    println("some units are derated due to high coal cost and capped electricity price (35% derated)")
else
    genvar = CSV.read(joinpath(inputpath_main, "Generators_variability_derated_15%.csv"), DataFrame) # Reading generator variability data and create a data frame
    println("no electricity price cap, 15% derated")
end
=#

# Always use non-derated generators regardless of scenario
genvar = CSV.read(joinpath(base_data_path, "Generators_variability.csv"), DataFrame)
println("using generators with no derating applied")

### ## ###
hours_per_period = Int(floor(first(other_info[other_info.Parameter .== "hours_per_period", :Value]))) # Reading hours per period data
println("hours_per_period = ", hours_per_period)

regdesc, netzones = [], []
for x in collect(1:length(unique(generators.region)))
    push!(regdesc, first(generators[generators.Zone .== x, :region]))
    push!(netzones, string("z", x))
end

reg_zone = DataFrame()
reg_zone.Region_description = regdesc
reg_zone.Network_zones = netzones

region_names = reg_zone.Region_description

path_names = network_fwd.transmission_path_name #array that contains path name; Same: path_names = network_rvs.transmission_path_name #array that contains path name

# Get a clearer version of demand data frame and use it in the optimization
load_names = Array{String, 1}(undef, length(region_names))
for regnum in 1:length(region_names)
    load_names[regnum] = string("Load_MW_z", regnum)
end
load = select(demand, load_names)

# if scenario_name in ["extremeweather-nomlt", "extremeweather-mltall", "extremeweather-mltexternal", "all"]
#     load = load .* (1 + high_demand)
# else
#     nothing
# end


### ## ###
# First, check the actual size of each DataFrame before slicing
println("Original sizes:")
println("demand rows: ", nrow(demand))
println("load rows: ", nrow(load))
println("genvar rows: ", nrow(genvar))
println("fuels rows: ", nrow(fuels))
println("mlt rows: ", nrow(mlt))

numweek = Int(floor(size(load, 1) / hours_per_period))
usable_hours = (numweek) * hours_per_period
### For shorter run - check purpose
#numweek = 332 / hours_per_period
#usable_hours = 332

println("Adjusted values:")
println("usable_hours: ", usable_hours)
println("numweek: ", numweek)

# Now slice each DataFrame safely
demand = demand[1:usable_hours, :]
load = load[1:usable_hours, :]
genvar = genvar[1:usable_hours, :]
fuels = fuels[1:usable_hours+1, :]
mlt = mlt[1:usable_hours, :]
### ## ###



# Set weight for each week if running annual model, here is 1 for all time
sample_weight = repeat(1:1, hours_per_period)

initfinalstate = first(other_info[other_info.Parameter .== "initfinalstate", :Value])
minreservoirlevel = first(other_info[other_info.Parameter .== "reservoirminlevel", :Value])

fuelnames = names(fuels)[2:end]
fuels = select(fuels, Not(:Time_Index))

co2_content = DataFrame(Matrix(fuels[1:1, :])', :auto)
rename!(co2_content, :x1 => :CO2_content_tons_per_MMBtu)
insertcols!(co2_content, 1, :Fuel => fuelnames)

fuel_cost = DataFrame(Matrix(fuels[2:end, :])', :auto)
insertcols!(fuel_cost, 1, :Fuel => fuelnames)

println("=== Debugging Dimension Mismatch ===")
println("generators rows: ", size(generators, 1))
println("load size: ", size(load))
println(fuelnames)
println("fuels size after removing Time_Index: ", size(fuels))
println("fuel_cost size: ", size(fuel_cost))

println("Check fuel and fuel_cost:")
println(fuels[1, :])
println(fuel_cost[:, 1])
println("Var_Cost will be initialized as: ", size(generators, 1), " × ", size(load, 1))
println("fuel_cost columns available: ", size(fuel_cost, 2))
println("====================================")

Var_Cost = zeros(first(size(generators)), first(size(load)))
CO2_Rate = zeros(first(size(generators)))
Start_Cost = zeros(first(size(generators)), first(size(load)))
CO2_Per_Start = zeros(first(size(generators)))

for g in 1:first(size(generators))
    Var_Cost[g,:] = Array(generators.Var_OM_Cost_per_MWh[g] .+ fuel_cost[fuel_cost.Fuel .== generators.Fuel[g], 2:end] .* generators.Heat_Rate_MMBTU_per_MWh[g])
    CO2_Rate[g] = first(co2_content[co2_content.Fuel .== generators.Fuel[g], :CO2_content_tons_per_MMBtu]) * generators.Heat_Rate_MMBTU_per_MWh[g]
    Start_Cost[g,:] = Array(generators.Start_Cost_per_MW[g] .+ fuel_cost[fuel_cost.Fuel .== generators.Fuel[g], 2:end] .* generators.Start_Fuel_MMBTU_per_MW[g])
    # Start_Cost[g,:] .= 0
    CO2_Per_Start[g] = first(co2_content[co2_content.Fuel .== generators.Fuel[g], :CO2_content_tons_per_MMBtu]) * generators.Start_Fuel_MMBTU_per_MW[g]
end

SDcont = first(other_info[other_info.Parameter .== "contingency_for_SD", :Value])
JBcont = first(other_info[other_info.Parameter .== "contingency_for_JB", :Value])

# "Priority" means NSE cost in NC grid is more expensive than that in NE grid
if scenario_name in ["PriorityMLT"]
    NE_nonserved_reduction = first(nse_reduction[nse_reduction.Parameter .== "NE_nonserved_reduction", :Value])
else
    nothing
end