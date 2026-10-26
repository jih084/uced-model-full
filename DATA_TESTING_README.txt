NEG DATA TESTING MODEL
======================

This package is based on Ziying's original UCED model.
No Julia model logic was changed.

Only two run-configuration values in uced-model/Run.jl were changed:
  SELECTED_WEEKS = [2, 20, 30, 47]
  runname = "ne_2021_PriorityMLT"

To test a different year, edit ONLY the runname year, for example:
  runname = "ne_2011_PriorityMLT"
  runname = "ne_2012_PriorityMLT"
  ...
  runname = "ne_2024_PriorityMLT"

Then, from the uced-model-full directory, run:
  julia --project=. uced-model/Run.jl

Results use the original model location:
  uced-model/Batch/Results_ne_<YEAR>_PriorityMLT/

Data organization follows the ORIGINAL model convention:
  uced-data/ne_<YEAR>_maininput/

Generator_availability.csv from the reorganized pipeline is copied into each
maininput folder under the ORIGINAL model filename:
  Generators_variability.csv

Therefore ReadFiles.jl and all downstream model scripts remain unchanged.
