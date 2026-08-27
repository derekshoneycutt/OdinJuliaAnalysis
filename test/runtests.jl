using Test
using OdinJuliaAnalysis
using JET
using JSON3

const TEST_VERBOSE = get(ENV, "ODIN_JULIA_ANALYSIS_TEST_VERBOSE", "false") == "true"

struct FixtureExtension <: AnalysisExtension
    id::String
    dependencies::Vector{String}
    phases::Set{AnalysisPhase}
    status::String
    should_throw::Bool
end

"""Return the fixture extension's stable identity."""
OdinJuliaAnalysis.extension_id(extension::FixtureExtension) = extension.id

"""Return the fixture extension's registered rule."""
function OdinJuliaAnalysis.extension_rules(extension::FixtureExtension)
    rule_id = uppercase(extension.id) * "-FIXTURE"
    return [RuleDefinition(
        rule_id,
        "common",
        "Test extension",
        "experimental",
        "stable",
        "report",
        false)]
end

"""Return fixture extension lifecycle phases."""
OdinJuliaAnalysis.extension_phases(extension::FixtureExtension) = extension.phases

"""Return fixture extension dependencies."""
function OdinJuliaAnalysis.extension_dependencies(extension::FixtureExtension)
    return extension.dependencies
end

"""Emit one repository-phase fixture finding and one artifact per phase."""
function OdinJuliaAnalysis.analyze_extension(
    extension::FixtureExtension,
    context,
    prior_results)
    extension.should_throw && error("fixture extension failed")
    diagnostics = Diagnostic[]
    if context.phase == AfterRepositoryAnalysis
        push!(diagnostics, Diagnostic(
            uppercase(extension.id) * "-FIXTURE",
            Ignore,
            first(context.paths),
            1,
            1,
            "Fixture extension finding.",
            nothing,
            nothing,
            "fixture-extension"))
    end
    artifacts = Dict{String, Any}(
        "path_count" => length(context.paths),
        "dependency_count" => length(context.dependencies),
        "declaration_count" => length(
            OdinJuliaAnalysis.analysis_declarations(context.files)),
        "prior_count" => length(prior_results))
    return ExtensionResult(
        extension.id,
        context.phase;
        status=extension.status,
        diagnostics,
        artifacts)
end

"""Return validated settings with trusted fixture extensions and their rules."""
function with_extensions(configuration, extensions)
    rules = collect(values(configuration.rules))
    for extension in extensions, definition in extension_rules(extension)
        push!(rules, RuleSetting(definition.rule_id, true, Warn))
    end
    settings = AnalysisSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        [ScanProfile(configuration.profile, configuration.enforcement_excludes)],
        rules,
        configuration.naming,
        JetSettings(JetEntryPoint[]),
        OdinBuildSettings(OdinBuildTarget[]),
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report,
        AnalysisExtension[extensions...])
    return OdinJuliaAnalysis.validate_settings(settings)
end

"""Exercise JET detection of an undefined global from a configured call root."""
jet_fixture_bad(value::Int) = value + jet_fixture_missing

"""Return effective settings with selected rule overrides."""
function with_rules(
    configuration,
    replacements;
    failure_threshold=configuration.failure_threshold)
    rules = copy(configuration.rules)
    merge!(rules, replacements)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        rules,
        configuration.naming,
        configuration.jet,
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.architecture,
        configuration.allocations,
        configuration.report,
        configuration.extensions,
        configuration.rule_registry,
        configuration.extension_rule_owners,
        configuration.duplicate_code,
        configuration.resource_lifetime,
        configuration.security,
        configuration.coverage,
        configuration.documentation)
end

"""Return effective settings with replacement documentation templates."""
function with_documentation(configuration, documentation)
    return OdinJuliaAnalysis.EffectiveSettings(
    configuration.profile,
    configuration.failure_threshold,
    configuration.thresholds,
    configuration.enforcement_excludes,
    configuration.rules,
    configuration.naming,
    configuration.jet,
    configuration.odin_build,
    configuration.return_tuples,
    configuration.parameter_counts,
    configuration.function_metrics,
    configuration.architecture,
    configuration.allocations,
    configuration.report,
    configuration.extensions,
    configuration.rule_registry,
    configuration.extension_rule_owners,
    configuration.duplicate_code,
    configuration.resource_lifetime,
    configuration.security,
    configuration.coverage,
    documentation)
end

"""Return effective settings with replacement architecture policy."""
function with_architecture(configuration, architecture)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        configuration.jet,
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        architecture,
        configuration.allocations,
        configuration.report,
        configuration.extensions,
        configuration.rule_registry,
        configuration.extension_rule_owners)
end

"""Return effective settings with replacement allocation policies."""
function with_allocation_policies(configuration, policies)
    allocations = AllocationSettings(
        configuration.allocations.known_procedures,
        configuration.allocations.source_patterns,
        policies)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        configuration.jet,
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        allocations,
        configuration.report)
end

"""Return effective settings with replacement JET entry points."""
function with_jet_entries(configuration, entry_points)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        JetSettings(entry_points),
        configuration.odin_build,
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report)
end

"""Return effective settings with replacement analytical Odin build targets."""
function with_odin_build_targets(configuration, targets)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        configuration.jet,
        OdinBuildSettings(targets),
        configuration.return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report)
end

"""Return effective settings with independently replaced return tuple maxima."""
function with_return_tuples(configuration, return_tuples)
    return OdinJuliaAnalysis.EffectiveSettings(
        configuration.profile,
        configuration.failure_threshold,
        configuration.thresholds,
        configuration.enforcement_excludes,
        configuration.rules,
        configuration.naming,
        configuration.jet,
        configuration.odin_build,
        return_tuples,
        configuration.parameter_counts,
        configuration.function_metrics,
        configuration.allocations,
        configuration.report)
end

"""Return effective settings with replacement parameter count thresholds."""
function with_parameter_counts(configuration, parameter_counts)
    return OdinJuliaAnalysis.EffectiveSettings(
    configuration.profile,
    configuration.failure_threshold,
    configuration.thresholds,
    configuration.enforcement_excludes,
    configuration.rules,
    configuration.naming,
    configuration.jet,
    configuration.odin_build,
    configuration.return_tuples,
    parameter_counts,
    configuration.function_metrics,
    configuration.allocations,
    configuration.report)
end

"""Return effective settings with replacement function metric thresholds."""
function with_function_metrics(configuration, function_metrics)
    return OdinJuliaAnalysis.EffectiveSettings(
    configuration.profile,
    configuration.failure_threshold,
    configuration.thresholds,
    configuration.enforcement_excludes,
    configuration.rules,
    configuration.naming,
    configuration.jet,
    configuration.odin_build,
    configuration.return_tuples,
    configuration.parameter_counts,
    function_metrics,
    configuration.allocations,
    configuration.report)
end

"""Write package settings with replacement JET entry points for CLI fixtures."""
function write_jet_settings(path, entry_points_expression)
    default_path = repr(OdinJuliaAnalysis.DEFAULT_SETTINGS_PATH)
    write(path, """
        using OdinJuliaAnalysis

        base = Base.include(@__MODULE__, $default_path)
        AnalysisSettings(
            base.profile,
            base.failure_threshold,
            base.thresholds,
            base.profiles,
            base.rules,
            base.naming,
            JetSettings($entry_points_expression),
            OdinBuildSettings(OdinBuildTarget[]),
            base.allocations,
            base.report)
        """)
    return path
end

@testset verbose=TEST_VERBOSE "OdinJuliaAnalysis" begin
    @test OdinJuliaAnalysis.main(["unknown"]) == 2

    include("configuration_tests.jl")
    include("repository_inventory_tests.jl")
    include("julia_analysis_tests.jl")
    include("odin_analysis_tests.jl")
    include("source_statistics_tests.jl")
    include("reporting_tests.jl")
    include("odin_engine_tests.jl")
    include("advanced_analysis_tests.jl")
    include("verification_tool_tests.jl")
end
