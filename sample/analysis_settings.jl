using OdinJuliaAnalysis

const ANALYZER_PACKAGE_ROOT = dirname(dirname(pathof(OdinJuliaAnalysis)))
const BASE_SETTINGS = Base.include(
    @__MODULE__, joinpath(ANALYZER_PACKAGE_ROOT, "settings.jl"))

Base.include(@__MODULE__, joinpath(@__DIR__, "analysis_extension.jl"))
Base.include(@__MODULE__, joinpath(@__DIR__, "src", "HelloWorldSample.jl"))
using .HelloWorldSample

AnalysisSettings(
    :default,
    Fail,
    BASE_SETTINGS.thresholds,
    [ScanProfile(:default, String[])],
    [BASE_SETTINGS.rules; RuleSetting("SAMPLE-BOTH-LANGUAGES", true, Fail)],
    default_naming_settings(),
    JetSettings([
        JetEntryPoint(
            "julia-hello",
            "src/HelloWorldSample.jl",
            HelloWorldSample.main,
            (IO,)),
    ]),
    OdinBuildSettings([
        OdinBuildTarget(
            "odin-hello",
            "src",
            "hello-odin-analysis",
            ["-vet", "-strict-style", "-disallow-do", "-warnings-as-errors"]),
    ]),
    default_return_tuple_settings(),
    default_parameter_count_settings(),
    default_function_metric_settings(),
    AllocationSettings(
        KnownAllocatingProcedure[],
        [
            AllocatorSourcePattern("context.allocator", :context),
            AllocatorSourcePattern("context.temp_allocator", :temporary),
            AllocatorSourcePattern("heap.allocator()", :heap),
        ],
        ReviewedAllocationPolicy[]),
    ReportSettings(:auto, 50, 50),
    AnalysisExtension[SampleExtension()])
