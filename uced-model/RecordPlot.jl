
function RecordPlot(unmetdec, poweramount, chargeamount, count)

   sumnse = zeros(size(unmetdec)[2], last(size(unmetdec)))
   for row in 1:first(size(unmetdec))
      sumnse = sumnse + value.(unmetdec).data[row,:,:]
   end

   if create_plot == true
      for seg in 1:size(unmetdec)[2]
         CreateBarLine(isbarplot = false,
                       fname = string("nonserved", seg, ".csv"),
                       barnumbers = nothing,
                       plotvalues_one = sumnse[seg,:],
                       plotvalues_two = nothing,
                       barnam = nothing,
                       ylab = "MW",
                       xlab = "Hours",
                       tlab = string("Non-served energy amount over all regions in segment ", seg),
                       leglab = nothing,
                       rpath = joinpath(resultpath, string(count)))
      end
   else
      nothing
   end

   # ProcessDispatch(poweramount, chargeamount, count)

end
