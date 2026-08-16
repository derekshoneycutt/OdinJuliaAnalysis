#!/usr/bin/env julia

import Pkg

Pkg.activate(@__DIR__; io=devnull)

using OdinJuliaAnalysis

exit(OdinJuliaAnalysis.main(ARGS))