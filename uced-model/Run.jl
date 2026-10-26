using JuMP, DataFrames, CSV, Gurobi, Missings, Statistics, Dates
using Printf, ArgParse

# === 新增:自定义异常类型 ===
struct InfeasibleModelException <: Exception
    week_number::Int
    message::String
end

Base.showerror(io::IO, e::InfeasibleModelException) = 
    print(io, "InfeasibleModelException: Week $(e.week_number) - $(e.message)")

function parse_commandline()
    s = ArgParseSettings(description="Run a single UCED simulation.")
    @add_arg_table! s begin
        "--run-dir"
        help = "Path to the specific run directory (for experiment mode)."
        arg_type = String
        default = "" # Empty by default for standalone mode
        "--config-file"
        help = "Path to a run-specific config file (e.g., for quota)."
        arg_type = String
        default = ""
    end
    return parse_args(s)
end

parsed_args = parse_commandline()

SELECTED_WEEKS = [2, 20, 30, 47] # e.g., [1, 52] for first and last week only; set to 'nothing' to run all weeks
runname = "ne_2013_PriorityMLT"
actfilename = split(runname, "_")
model_year = parse(Int, actfilename[2])  # 从 runname 中提取年份（第2段）
scenario_name = actfilename[3]

quota_enabled = false
equal_shares_enabled = false
captive_scenario = false
retrofit_scenario = false # change retrofit project in SetCreation.jl

println("Summary of UCED runnning settings:")
println("runname: ", runname)
println("model_year: ", model_year)
println("quota_enabled: ", quota_enabled)
println("equal_shares_enabled: ", equal_shares_enabled) 
println("captive_scenario: ", captive_scenario)
println("retrofit_scenario: ", retrofit_scenario)

scenario_input_folder = (scenario_name != "maininput") ? runname : ""
inputpath_scenario = joinpath(@__DIR__, "..", "uced-data", scenario_input_folder)
base_data_path = joinpath(@__DIR__, "..", "uced-data", "ne_$(model_year)_maininput")

local run_specific_path, resultpath, generators_filename, config_filepath

if isempty(parsed_args["run-dir"])
    # --- STANDALONE MODE ---
    println("Info: Running in STANDALONE mode.")
    flush(stdout)
    run_specific_path = base_data_path
    generators_filename = "Generators_data.csv"
    config_filepath = ""
    resultpath = joinpath(@__DIR__, string("Batch/Results_", runname))
else
    # --- EXPERIMENT MODE ---
    println("Info: Running in EXPERIMENT mode.")
    flush(stdout)
    run_specific_path = abspath(parsed_args["run-dir"])
    generators_filename = "generators_modified.csv"
    config_filepath = abspath(parsed_args["config-file"])
    resultpath = run_specific_path
end

mkpath(resultpath)
println("Base Data Path:   ", base_data_path)
println("Run-Specific Path:", run_specific_path)
println("Results Path:     ", resultpath)

mainloc = @__DIR__
include(joinpath(mainloc, "ReadFiles.jl"))
include(joinpath(mainloc, "SetCreation.jl"))
include(joinpath(mainloc, "EDUCModel.jl"))
include(joinpath(mainloc, "RecordCSV.jl"))
include(joinpath(mainloc, "AggregateResults.jl"))
include(joinpath(mainloc, "ProcessDispatch.jl"))


load_transition = load
println("Original load rows: ", nrow(load_transition))
load_transition.Group = repeat(1:numweek, inner = hours_per_period)
global load_transition = groupby(load_transition, :Group)

genvar_transition = genvar
genvar_transition.Group = repeat(1:numweek, inner = hours_per_period)
global genvar_transition = groupby(genvar_transition, :Group)

mlt_transition = mlt
mlt_transition.Group = repeat(1:numweek, inner = hours_per_period)
global mlt_transition = groupby(mlt_transition, :Group)

println("✅ Data loaded and sets created successfully.")


# 容量充裕性检查

# Capacity adequacy check
function check_capacity_adequacy()
    total_gen_capacity = sum(generators.Existing_Cap_MW)
    
    # Calculate peak demand for each week
    peak_demands = []
    for week_data in load_transition
        week_peak = maximum([sum([week_data[h, col] for col in names(week_data) if startswith(col, "Load_MW_z")]) 
                           for h in 1:nrow(week_data)])
        push!(peak_demands, week_peak)
    end
    
    overall_peak = maximum(peak_demands)
    reserve_margin = (total_gen_capacity / overall_peak - 1) * 100
    
    println("🔍 Capacity Adequacy Check for $model_year:")
    println("   Total Generation Capacity: $(round(total_gen_capacity, digits=1)) MW")
    println("   Peak Demand: $(round(overall_peak, digits=1)) MW")
    println("   Reserve Margin: $(round(reserve_margin, digits=1))%")
    
    if reserve_margin < 10
        println("   ⚠️  WARNING: Low reserve margin may cause feasibility issues!")
    end
    
    return reserve_margin
end

# Call the check
reserve_margin = check_capacity_adequacy()


function setup_logging()
    timestamp = Dates.format(now(), "yyyy-mm-dd_HH-MM-SS")
    log_file_path = joinpath("uced-model", "Batch", "Results_$(runname)", "run_log_$(timestamp).txt")
    
    # 创建目录
    log_dir = dirname(log_file_path)
    if !isdir(log_dir)
        mkpath(log_dir)
    end
    
    return open(log_file_path, "w"), log_file_path
end

global LOG_FILE = nothing

function log_println(args...)
    println(args...)  # 输出到终端
    if LOG_FILE !== nothing
        println(LOG_FILE, args...)  # 输出到文件
        flush(LOG_FILE)
    end
end

function run_optimization_model()
    global LOG_FILE

    log_file, log_path = setup_logging()
    LOG_FILE = log_file 
    
    # 保存原始函数
    original_println = Base.println

    try
        # 记录运行信息
        log_println("🔧 UCED Model Run Started")
        log_println("📝 Log file: $log_path")
        log_println("🕐 Start time: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
        log_println("🔧 Run settings:")
        log_println("   runname: $runname")
        log_println("   model_year: $model_year")
        log_println("=" ^ 80)
        
        # === 新增:运行优化并捕获infeasibility ===
        try
            EDUCModel()
        catch e
            if isa(e, InfeasibleModelException)
                log_println("❌ MODEL INFEASIBLE - Terminating run early")
                log_println("   Week: $(e.week_number)")
                log_println("   Reason: $(e.message)")
                
                # 写入infeasibility标记文件
                infeasible_marker = joinpath(resultpath, "INFEASIBLE.txt")
                open(infeasible_marker, "w") do f
                    println(f, "INFEASIBLE")
                    println(f, "Week: $(e.week_number)")
                    println(f, "Reason: $(e.message)")
                    println(f, "Timestamp: $(Dates.now())")
                end
                
                # 返回特殊退出码
                return :infeasible
            else
                rethrow(e)
            end
        end

###################
        # 运行优化
        #EDUCModel()
        
        log_println("=" ^ 80)
        log_println("✅ UCED Model Run Completed")
        log_println("🕐 End time: $(Dates.format(now(), "yyyy-mm-dd HH:MM:SS"))")
        
        # === 新增:写入成功标记 ===
        success_marker = joinpath(resultpath, "SUCCESS.txt")
        open(success_marker, "w") do f
            println(f, "SUCCESS")
            println(f, "Timestamp: $(Dates.now())")
        end
        
        return :success
        ####################
    catch e
        log_println("❌ ERROR: $e")
        log_println("Stack trace:")
        for (exc, bt) in Base.catch_stack()
            showerror(stdout, exc, bt)
            showerror(LOG_FILE, exc, bt)
            println()
        end
        
    finally
        # 关闭日志文件
        if LOG_FILE !== nothing
            close(LOG_FILE)
            LOG_FILE = nothing
        end
        println("📝 Complete log saved to: $log_path")
    end

    # Handle captive scenario modifications if needed
    if captive_scenario && @isdefined(setCAPTIVE) && !isempty(setCAPTIVE)
        println("Captive scenario enabled - modifying load_transition data")
        for (period_idx, load_df) in enumerate(load_transition)
            for (zone, fixed_gen_mw) in captive_fixed_generation_by_zone
                if fixed_gen_mw > 0
                    col_name = "Load_MW_z$zone"
                    if col_name in names(load_df)
                        original_load = load_df[!, col_name]
                        modified_load = original_load .- fixed_gen_mw
                        load_df[!, col_name] = modified_load
                    end
                end
            end
        end
        println("load_transition modified for captive scenario.")
        total_offset = sum(values(captive_fixed_generation_by_zone)) * 168 * length(load_transition)
        println("load_transition modified: $(round(total_offset, digits=1)) MWh total captive generation offset")
    end

    model_start_time = time()

    model_end_time = time()
    model_duration = round(model_end_time - model_start_time, digits=2)
    println("✅ EDUCModel() completed in $(model_duration) seconds")

    AggResults()

    
    println("######################################################")
    println(" 🚀 Model solved successfully! Ready to launch to Mars 🪐")
    println("######################################################")

end

run_optimization_model()