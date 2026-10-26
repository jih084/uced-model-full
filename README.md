Updates/Documentation of changes made to this code from parent repo can be found here: https://docs.google.com/document/d/1MNM-sufFMfnnGlSfxBrsar4ULfDR3JYbkRC8-xb8CpQ/edit?usp=sharing

uced-data 

  ne_2021_0000000000maininput : this folder contains the large majority of data for the model
  
      Fuels_data
      
      Generators_data
      
          378 generators total
          
          contains Resource ID (R_ID), type of resource (SOLAR, WIND, COAL, etc.), location in the transmission map (Region), capacity information, ramping information, heat rate information, fuel needs by generator, variable and start costs 
          
      Generators_variability (_derated, _derated_15%, _derated_30%, _no_derate)
      
          2016 hours of data by 378 generators
          
          0 (not in use) or 1 (in use) based on if a generator is in operation in a certain hour
          
      Load_data
      
          2016 hours of demand by 6 transmission zones 
          
          contains demand for zone for hour
          
          also contains information on $/MW, Voll(?), maximum curtailment 
          
      Network_forward
      
          sets up network in one direction in transmission lines
          
      Network_reverse
      
          sets up network in other direction in transmission lines
          
      operating_reserve
      
          reserves % for each zone for loads and VRE
          
      other_inputs
      
          initfinalstate = ??, minimum reservoir level, hours per period, contingency info  
          
      Transmission_MLT
      
          Required amount of power transmitted between regions per hour based on MLT contracts
          
  
uced-model 

    Batch
    
          this contains all generated info for each scenario once the model is ran > most output data is broken down by week (then by hour)
          
    Run.jl
    
          this runs the entire model
          
          currently requires you to specify runname in line 11: runname = "ne_2021_PriorityMLT" 
          
          will generate "ready to launch to mars" message when the model finishes running > after which the data can be found in Batch
          
    Paths.jl
    
          specifies directory paths (tells model where it's calling information from -- usually uced_data> main input file -- and where it's putting output data -- usually batch > scenario folders)
          
          if you can't figure out where a directory specification (most are in readFiles and readCSV) came from, this is the culprit
          
    ReadFiles.jl
    
          this reads all the files from uced_data (the main data file + any scenario specific file that matches the scenario specified in Run.jl)
          
    SetCreation.jl
    
          this creates sets of data that'll be called later in the model (sets of generator names, regions, etc.)
          
          the sets created here are mainly used for indexing > if you can't figure out where an indexing variable came from, setcreation.jl or readfiles.jl is most likely the source > can trace it backwards to find the uced_data file the variable was derived from

          Added "captive scenario" here, can opt out or in by changing one line
          
    solver_params.csv
    
          Gurobi solving parameters used in EDUCModel.jl 
          
    EDUCModel.jl
    
          this is a function that runs an economic dispatch + unit committment model for each week in the scenario specified
          
          this function calls ReadCSV.jl to save outputs per week > this is why all the output data is weekly 
          
    ReadCSV.jl
    
          reads all relevant outputs from the optimization model to a csv data file in Batch > scenario folder
          
    ProcessDispatch.jl
    
        similar to readCSV.jl but for optimized dispatch data specifically > saves to its own special folder in Batch>Scenario
        
    debug.jl
    
          an extra script to be used for troubleshooting the code 
          
          currently a frankenstein-ed version of run.jl and EDUCModel.jl that runs through the first week only of a specified scenario 
          
     
    
-------
CHP heating season constraint: add to SetCreation, EDUCModel, Run
Captive plant dispatch: 
- add to the end of SetCreation.jl, there is a flagger, turn it to be true if want to include this scenario. 
- also have to change demand balance contraint at around line 139 in EDUCModel.jl, just comment off or on with original
- RecordCSV.jl has some issue