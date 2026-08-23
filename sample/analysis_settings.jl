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
    default_architecture_settings(),
    AllocationSettings(
        KnownAllocatingProcedure[],
        [
            AllocatorSourcePattern("context.allocator", :context),
            AllocatorSourcePattern("context.temp_allocator", :temporary),
            AllocatorSourcePattern("heap.allocator()", :heap),
        ],
        ReviewedAllocationPolicy[]),
    ReportSettings(:auto, 50, 50),
    AnalysisExtension[SampleExtension()],
    default_duplicate_code_settings(),
    default_resource_lifetime_settings(),
    default_security_settings(),
    default_coverage_settings(),
    default_documentation_settings(),
    CallRootSettings([
        CallRootEntryPoint(
            "extension-api:extension_id",
            :julia,
            "extension_id",
            "The analyzer invokes this method through the extension API."),
        CallRootEntryPoint(
            "extension-api:extension_rules",
            :julia,
            "extension_rules",
            "The analyzer invokes this method through the extension API."),
        CallRootEntryPoint(
            "extension-api:extension_phases",
            :julia,
            "extension_phases",
            "The analyzer invokes this method through the extension API."),
        CallRootEntryPoint(
            "extension-api:analyze_extension",
            :julia,
            "analyze_extension",
            "The analyzer invokes this method through the extension API."),
        CallRootEntryPoint(
            "odin-test:greeting_test",
            :odin,
            "greeting_test",
            "The Odin test runner invokes this procedure through @(test)."),
    ]))
