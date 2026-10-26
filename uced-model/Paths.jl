
inputpath_main = joinpath(@__DIR__, "..", "uced-data", main_input_folder)
inputpath_scenario = joinpath(@__DIR__, "..", "uced-data", scenario_input_folder)
resultpath = joinpath(@__DIR__, string("Batch/Results_", runname))
#dispatchpath = joinpath(resultpath, "Dispatch")

if isdir(inputpath_main) == false
    mkdir(inputpath_main)
end


if isdir(inputpath_scenario) == false
    mkdir(inputpath_scenario)
end


if isdir(resultpath) == false
    mkdir(resultpath)
end

#=
if isdir(dispatchpath) == false
    mkdir(dispatchpath)
end
=#