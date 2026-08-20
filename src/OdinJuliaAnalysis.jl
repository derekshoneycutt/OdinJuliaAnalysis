module OdinJuliaAnalysis

export main
export AnalysisSettings, AnalysisThresholds, FindingResponse, Ignore, Report, Warn, Fail
export AllocationSettings, AllocatorSourcePattern, ReviewedAllocationPolicy
export KnownAllocatingProcedure, ReportSettings, RuleSetting, ScanProfile
export OdinBuildSettings, OdinBuildTarget
export ReturnTupleSettings
export ParameterCountSettings
export FunctionMetricSettings, ResponseThresholds, ReviewedComplexity
export AnalysisExtension, AnalysisPhase
export AfterDiscovery, AfterLanguageAnalysis, AfterRepositoryAnalysis
export AnalysisContext, ExtensionResult, RuleDefinition
export CallEdge, CallRoot, CloneGroup, CloneOccurrence, DeclarationRecord
export ResourceLifetimeSummary
export SecurityBoundaryPath
export TestCoverageEvidence, TestCoverageCounts, TestCoverageStatistics
export DependencyEdge, Diagnostic, ImportBinding
export ReferenceRecord
export InteropSignature, InteropBridgePair
export ArchitectureLayer, ArchitectureDependency, ArchitectureSettings
export extension_id, extension_api_version, extension_rules
export extension_phases, extension_dependencies, analyze_extension
export EXTENSION_API_VERSION
export NamingConvention, NamingSettings
export ReviewedNamingPolicy
export JetEntryPoint, JetSettings
export CallRootEntryPoint, CallRootSettings, default_call_root_settings
export default_jet_settings, default_naming_settings
export default_odin_build_settings
export default_return_tuple_settings
export default_parameter_count_settings
export default_function_metric_settings
export default_architecture_settings
export DuplicateCodeSettings, ReviewedClonePolicy, default_duplicate_code_settings
export ResourceLifetimeContract, ResourceLifetimeSettings
export default_resource_lifetime_settings
export SecurityCallContract, SecuritySettings, default_security_settings
export CoverageSettings, default_coverage_settings
export DocumentationSettings, default_documentation_settings

using JSON3
using JuliaSyntax
using StructTypes

include("configuration/settings_types.jl")
include("core/model.jl")
include("core/statistics.jl")
include("configuration/rule_registry.jl")
include("core/extension_api.jl")
include("configuration/settings_loader.jl")
include("analysis/architecture_engine.jl")
include("analysis/reachability_engine.jl")
include("analysis/duplicate_code.jl")
include("analysis/resource_lifetime.jl")
include("analysis/security_boundaries.jl")
include("analysis/test_coverage.jl")
include("analysis/unused_imports.jl")
include("analysis/interop_engine.jl")
include("analysis/naming_policies.jl")
include("analysis/reviewed_complexity.jl")
include("core/discovery.jl")
include("analysis/common_rules.jl")
include("markdown_engine/MarkdownEngine.jl")
include("julia_engine/JuliaEngine.jl")
include("jet_engine/JetEngine.jl")
include("odin_engine/OdinEngine.jl")
include("odin_engine/OdinBuildEngine.jl")
include("reporting/reporting.jl")
include("reporting/markdown_report.jl")

const VERSION = v"0.1.0"
const ANALYSIS_ROOT = normpath(joinpath(@__DIR__, ".."))

mutable struct CheckOptionState
    root::String
    format::String
    color::Symbol
    progress::Symbol
    settings_path::String
    report_path::Union{Nothing, String}
    full_report_path::Union{Nothing, String}
end

struct SourceLineCounts
    blank::Int
    comment::Int
    code::Int
end

"""Write analyzer command-line usage information."""
function usage(io::IO)
    println(io, "Usage: julia analyze.jl check [PATH] [OPTIONS]")
    println(io)
    println(io,
       "Analyze Julia, Odin, and Markdown files under PATH (default: current directory).")
    println(io, "Options:")
    println(io, "    --format=text|json         Select human or machine output")
    println(io, "    --color=auto|always|never  Control text report colors")
    println(io, "    --progress=auto|always|never")
    println(io, "                                Control progress written to stderr")
    println(io, "    --settings=PATH            Load settings from PATH")
    println(io, "    --report=PATH              Write a compact Markdown report")
    println(io, "    --full-report=PATH         Write a comprehensive Markdown report")
    println(io, "    -h, --help                 Show this help")
    println(io)
    println(io, "Examples:")
    println(io, "    julia analyze.jl check .")
    println(io, "    julia analyze.jl check src --format=json")
    println(io)
    println(io,
        "Exit codes: 0 pass, 1 policy findings, 2 incomplete analysis or bad usage.")
end

"""Run the analyzer command requested by command-line arguments."""
function main(arguments::Vector{String})
    if isempty(arguments) || first(arguments) in ("-h", "--help")
        usage(stdout)
        return 0
    end

    command = first(arguments)
    if command != "check"
        println(stderr, "OdinJuliaAnalysis: command not implemented: ", command)
        return 2
    end

    options = parse_check_options(arguments[2:end])
    options === nothing && return 2
    options === :help && return 0

    progress = progress_callback(options.progress)
    report_progress(progress, "Loading analysis settings")
    configuration = try
        load_settings(options.settings_path)
    catch error
        println(stderr, "OdinJuliaAnalysis: ", sprint(showerror, error))
        return 2
    end
    report = check_repository(options.root; configuration, progress)
    write_analysis_outputs(report, options, configuration)
    return report.exit_code
end

"""Write configured terminal and Markdown analysis outputs."""
function write_analysis_outputs(report, options, configuration)
    write_report(
        stdout,
        report,
        options.format;
        color=options.color,
        warning_limit=configuration.report.warning_limit,
        report_limit=configuration.report.report_limit)
    options.report_path === nothing ||
        write_markdown_file(options.report_path, report; comprehensive=false)
    options.full_report_path === nothing ||
        write_markdown_file(options.full_report_path, report; comprehensive=true)
end

"""Write one Markdown report artifact at the requested path."""
function write_markdown_file(path, report; comprehensive::Bool)
    report_path = abspath(path)
    mkpath(dirname(report_path))
    open(report_path, "w") do io
        write_markdown_report(io, report; comprehensive=comprehensive)
    end
end

"""Parse check-command options into repository and output settings."""
function parse_check_options(arguments::Vector{String})
    options = CheckOptionState(
        ".", "text", :auto, :auto, DEFAULT_SETTINGS_PATH, nothing, nothing)
    for argument in arguments
        if argument in ("-h", "--help")
            usage(stdout)
            return :help
        end
        parse_check_option!(options, argument) || return nothing
    end
    if options.format ∉ ("text", "json")
        println(stderr, "OdinJuliaAnalysis: unsupported format: ", options.format)
        return nothing
    end
    return (;
        root=abspath(options.root),
        options.format,
        options.color,
        options.progress,
        options.settings_path,
        options.report_path,
        options.full_report_path)
end

"""Apply one check-command option to mutable parser state."""
function parse_check_option!(options, argument)
    if startswith(argument, "--format=")
        options.format = split(argument, "="; limit=2)[2]
    elseif startswith(argument, "--color=")
        value = parse_display_mode(argument, "color")
        value === nothing && return false
        options.color = value
    elseif startswith(argument, "--progress=")
        value = parse_display_mode(argument, "progress")
        value === nothing && return false
        options.progress = value
    elseif startswith(argument, "--settings=")
        value = split(argument, "="; limit=2)[2]
        isempty(value) && return empty_path_option("settings")
        options.settings_path = value
    elseif startswith(argument, "--report=")
        value = split(argument, "="; limit=2)[2]
        isempty(value) && return empty_path_option("report")
        options.report_path = value
    elseif startswith(argument, "--full-report=")
        value = split(argument, "="; limit=2)[2]
        isempty(value) && return empty_path_option("full-report")
        options.full_report_path = value
    elseif startswith(argument, "-")
        println(stderr, "OdinJuliaAnalysis: unknown option: ", argument)
        return false
    else
        options.root = argument
    end
    return true
end

"""Parse one auto/always/never display mode option."""
function parse_display_mode(argument, label)
    value = split(argument, "="; limit=2)[2]
    if value ∉ ("auto", "always", "never")
        println(stderr, "OdinJuliaAnalysis: unsupported $label mode: ", value)
        return nothing
    end
    return Symbol(value)
end

"""Report an empty analyzer path option."""
function empty_path_option(label)
    println(stderr, "OdinJuliaAnalysis: $label path must not be empty")
    return false
end

"""Return a stderr progress callback for the requested display mode."""
function progress_callback(mode::Symbol)
    enabled = mode == :always || mode == :auto && get(stderr, :color, false)
    enabled || return nothing
    return message -> begin
        println(stderr, "    ", message)
        flush(stderr)
    end
end

"""Report one analysis milestone when progress output is enabled."""
report_progress(progress, message) = progress === nothing || progress(message)

"""Run julia-specific checks on an individual julia file."""
function analyze_julia_source_file!(relative_path, source, configuration, state)
    julia_diagnostics = JuliaEngine.check(
        relative_path, source, configuration)
    append!(state.diagnostics, julia_diagnostics)
    syntax_failed = any(
        item -> item.rule_id == "JULIA-SYNTAX", julia_diagnostics)
    syntax_failed || append!(
        state.functions,
        JuliaEngine.analyze_functions(relative_path, source))
    syntax_failed || append!(
        state.dependencies,
        JuliaEngine.analyze_dependencies(relative_path, source))
    syntax_failed || append!(
        state.declarations,
        JuliaEngine.analyze_declarations(relative_path, source))
    syntax_failed || append!(
        state.import_bindings,
        JuliaEngine.analyze_import_bindings(relative_path, source))
    syntax_failed || append!(
        state.references,
        JuliaEngine.analyze_references(relative_path, source))
    syntax_failed || append!(
        state.call_edges,
        JuliaEngine.analyze_calls(relative_path, source))
    syntax_failed || append!(
        state.clone_candidates,
        JuliaEngine.analyze_clone_candidates(relative_path, source))
    syntax_failed || append!(
        state.interop_signatures,
        JuliaEngine.analyze_interop(relative_path, source))
end

"""Run common and language-specific checks that operate on individual files."""
function analyze_source_files!(
    state,
    root,
    files,
    configuration)
    for path in files
        source = read(path, String)
        relative_path = relpath(path, root)
        append!(state.diagnostics, check_common_rules(
            relative_path, source, configuration))

        if endswith(path, ".jl")
            analyze_julia_source_file!(relative_path, source, configuration, state)
        elseif endswith(path, ".md")
            append!(
                state.diagnostics,
                MarkdownEngine.check(
                    relative_path,
                    source,
                    configuration;
                    filesystem_path=path))
        end
    end
end

"""Run configured JET entry points and record engine completion."""
function run_jet_analysis!(diagnostics, engines, root, configuration, progress)
    entry_count = length(configuration.jet.entry_points)
    entry_label = entry_count == 1 ? "entry point" : "entry points"
    report_progress(progress, "Running JET on $entry_count configured $entry_label")
    try
        append!(diagnostics, JetEngine.analyze(root, configuration))
        push!(engines, EngineStatus("jet", "complete", nothing))
    catch error
        push!(engines, EngineStatus("jet", "failed", sprint(showerror, error)))
    end
end

"""Run native Odin source analysis and merge its diagnostics and metrics."""
function run_odin_analysis!(
    state,
    root,
    files,
    configuration,
    progress)
    odin_files = filter(path -> endswith(path, ".odin"), files)
    report_progress(progress, "Running Odin analysis on $(length(odin_files)) files")
    try
        odin_analysis = OdinEngine.analyze(root, odin_files, configuration)
        append!(state.diagnostics, odin_analysis.diagnostics)
        append!(state.functions, odin_analysis.functions)
        append!(state.dependencies, odin_analysis.dependencies)
        append!(state.declarations, odin_analysis.declarations)
        append!(state.import_bindings, odin_analysis.import_bindings)
        append!(state.references, odin_analysis.references)
        append!(state.call_edges, odin_analysis.call_edges)
        append!(state.clone_candidates, odin_analysis.clone_candidates)
        append!(state.resource_events, odin_analysis.resource_events)
        append!(state.interop_signatures, odin_analysis.interop_signatures)
        merge!(state.struct_counts, odin_analysis.struct_counts)
        push!(state.engines, EngineStatus("odin", "complete", nothing))
    catch error
        push!(state.engines, EngineStatus("odin", "failed", sprint(showerror, error)))
    end
end

"""Run configured dependency architecture policy and record completion."""
function run_architecture_analysis!(state, configuration)
    if isempty(configuration.architecture.layers)
        push!(state.engines, EngineStatus("architecture", "not-applicable", nothing))
        return
    end
    try
        append!(state.diagnostics, analyze_architecture(
            state.dependencies, configuration))
        push!(state.engines, EngineStatus("architecture", "complete", nothing))
    catch error
        push!(state.engines, EngineStatus(
            "architecture", "failed", sprint(showerror, error)))
    end
end

"""Run analytical Odin builds and merge their findings and build records."""
function run_odin_build_analysis!(
    diagnostics,
    odin_builds,
    engines,
    root,
    configuration,
    progress)
    build_count = length(configuration.odin_build.targets)
    build_label = build_count == 1 ? "build" : "builds"
    report_progress(progress, "Running $build_count analytical Odin $build_label")
    try
        build_analysis = OdinBuildEngine.analyze(root, configuration)
        append!(diagnostics, build_analysis.diagnostics)
        append!(odin_builds, build_analysis.builds)
        push!(engines, EngineStatus("odin-build", "complete", nothing))
    catch error
        push!(engines, EngineStatus("odin-build", "failed", sprint(showerror, error)))
    end
end

"""Apply cross-engine policy and construct the canonical analysis report."""
function assemble_analysis_report(
    root,
    files,
    files_by_language,
    diagnostics,
    functions,
    engines,
    odin_builds,
    configuration;
    struct_counts=Dict{String, Int}(),
    dependencies=DependencyEdge[],
    declarations=DeclarationRecord[],
    import_bindings=ImportBinding[],
    references=ReferenceRecord[],
    call_edges=CallEdge[],
    call_roots=CallRoot[],
    clone_groups=CloneGroup[],
    resource_lifetimes=ResourceLifetimeSummary[],
    security_paths=SecurityBoundaryPath[],
    test_coverage=TestCoverageEvidence[],
    test_coverage_statistics=nothing,
    interop_signatures=InteropSignature[],
    interop_pairs=InteropBridgePair[],
    extension_results=ExtensionResult[])
    append!(diagnostics, function_metric_diagnostics(functions, configuration))
    apply_reviewed_complexity!(diagnostics, root, files, configuration)
    apply_constructor_naming_convention!(diagnostics, declarations, configuration)
    apply_reviewed_naming_policies!(diagnostics, root, files, configuration)
    files_analysis = analyze_files(root, files, functions, struct_counts, diagnostics)
    statistics = calculate_repository_statistics(files_analysis, functions)
    run_extension_phase!(extension_results, diagnostics, configuration, root, files,
        AfterRepositoryAnalysis;
        files=files_analysis,
        functions,
        dependencies,
        declarations,
        import_bindings,
        references,
        call_edges,
        call_roots,
        clone_groups,
        resource_lifetimes,
        security_paths,
        test_coverage,
        test_coverage_statistics,
        interop_signatures,
        interop_pairs,
        statistics)
    append!(engines, extension_engine_statuses(
        configuration.extensions, extension_results))
    sort!(diagnostics; by=diagnostic_sort_key)
    ignored = remove_ignored_diagnostics!(diagnostics)
    exit_code = analysis_exit_code(diagnostics, engines, configuration)
    rule_summaries = summarize_rule_runs(configuration, files_by_language, diagnostics,
        ignored.counts, engines, call_roots)
    return canonical_analysis_report((;
        root, files, files_by_language, files_analysis, functions, dependencies,
        declarations, import_bindings, references, call_edges, call_roots, clone_groups,
        resource_lifetimes,
        security_paths,
        test_coverage,
        test_coverage_statistics,
        interop_signatures, interop_pairs, statistics,
        diagnostics, ignored, engines, odin_builds, extension_results,
        rule_summaries, exit_code, configuration))
end

"""Construct the canonical report from fully analyzed repository state."""
function canonical_analysis_report(state)
    return AnalysisReport(
        "3.19.0",
        string(VERSION),
        state.root,
        string(state.configuration.profile),
        state.configuration.thresholds,
        state.configuration.parameter_counts,
        state.configuration.function_metrics,
        length(state.files),
        state.files_by_language,
        state.files_analysis,
        state.functions,
        state.dependencies,
        state.declarations,
        state.import_bindings,
        state.references,
        state.call_edges,
        state.call_roots,
        state.clone_groups,
        state.resource_lifetimes,
        state.security_paths,
        state.test_coverage,
        state.test_coverage_statistics,
        state.interop_signatures,
        state.interop_pairs,
        state.statistics,
        state.diagnostics,
        state.ignored.diagnostics,
        state.ignored.counts,
        state.engines,
        state.odin_builds,
        state.extension_results,
        state.rule_summaries,
        state.exit_code)
end

"""Remove ignored diagnostics and return their records and rule counts."""
function remove_ignored_diagnostics!(diagnostics)
    ignored = filter(diagnostic -> diagnostic.response == Ignore, diagnostics)
    counts = Dict{String, Int}()
    for diagnostic in ignored
        counts[diagnostic.rule_id] = get(counts, diagnostic.rule_id, 0) + 1
    end
    filter!(diagnostic -> diagnostic.response != Ignore, diagnostics)
    return (diagnostics=ignored, counts)
end

"""Return the analyzer exit code for engine and policy outcomes."""
function analysis_exit_code(diagnostics, engines, configuration)
    any(engine -> engine.status in ("failed", "incomplete"), engines) && return 2
    policy_failure = any(
        diagnostic -> meets_threshold(diagnostic, configuration.failure_threshold),
        diagnostics)
    return policy_failure ? 1 : 0
end

"""Create mutable result collections for one repository analysis run."""
function repository_analysis_state()
    return (
        diagnostics=Diagnostic[],
        functions=FunctionAnalysis[],
        dependencies=DependencyEdge[],
        declarations=DeclarationRecord[],
        import_bindings=ImportBinding[],
        references=ReferenceRecord[],
        call_edges=CallEdge[],
        call_roots=CallRoot[],
        clone_candidates=CloneCandidate[],
        clone_groups=CloneGroup[],
        resource_events=Diagnostic[],
        resource_lifetimes=ResourceLifetimeSummary[],
        security_paths=SecurityBoundaryPath[],
        test_coverage=TestCoverageEvidence[],
        test_coverage_statistics=Ref{Union{Nothing, TestCoverageStatistics}}(nothing),
        interop_signatures=InteropSignature[],
        interop_pairs=InteropBridgePair[],
        struct_counts=Dict{String, Int}(),
        extension_results=ExtensionResult[],
        odin_builds=OdinBuildAnalysis[],
        engines=EngineStatus[
            EngineStatus("common", "complete", nothing),
            EngineStatus("julia", "complete", nothing),
            EngineStatus("markdown", "complete", nothing),
        ])
end

"""Run built-in and extension analysis through the language-analysis phase."""
function run_language_analysis!(state, root, files, configuration, progress)
    run_extension_phase!(state.extension_results, state.diagnostics, configuration,
        root, files, AfterDiscovery)
    analyze_source_files!(state, root, files, configuration)
    run_jet_analysis!(state.diagnostics, state.engines, root, configuration, progress)
    run_odin_analysis!(state, root, files, configuration, progress)
    append!(state.diagnostics, analyze_unused_imports(
        state.import_bindings, state.references, configuration))
    append!(state.interop_pairs, pair_interop_signatures(state.interop_signatures))
    JuliaEngine.resolve_dependencies!(state.dependencies, root, files)
    run_architecture_analysis!(state, configuration)
    run_call_graph_analysis!(state, configuration)
    run_duplicate_code_analysis!(state, configuration)
    run_resource_lifetime_analysis!(state, configuration)
    run_security_analysis!(state, configuration)
    run_test_coverage_analysis!(state, root, configuration)
    language_files = analyze_files(
        root, files, state.functions, state.struct_counts, state.diagnostics)
    language_statistics = calculate_repository_statistics(
        language_files, state.functions)
    run_extension_phase!(state.extension_results, state.diagnostics,
        configuration, root, files, AfterLanguageAnalysis;
        files=language_files,
        functions=state.functions,
        dependencies=state.dependencies,
        declarations=state.declarations,
        import_bindings=state.import_bindings,
        references=state.references,
        call_edges=state.call_edges,
        call_roots=state.call_roots,
        clone_groups=state.clone_groups,
        resource_lifetimes=state.resource_lifetimes,
        security_paths=state.security_paths,
        test_coverage=state.test_coverage,
        test_coverage_statistics=state.test_coverage_statistics[],
        interop_signatures=state.interop_signatures,
        interop_pairs=state.interop_pairs,
        statistics=language_statistics)
end

"""Resolve configured call roots and reachability diagnostics."""
function run_call_graph_analysis!(state, configuration)
    append!(state.call_roots, collect_call_roots(
        state.declarations, state.interop_signatures, configuration))
    append!(state.diagnostics, analyze_reachability(
        state.declarations, state.call_edges, state.references,
        state.call_roots, configuration))
    push!(state.engines, EngineStatus(
        "call-graph", isempty(state.call_roots) ? "not-applicable" : "complete", nothing))
end

"""Collect exact clone groups and duplicate-code diagnostics."""
function run_duplicate_code_analysis!(state, configuration)
    clone_groups, clone_diagnostics = analyze_duplicate_code(
        state.clone_candidates, configuration)
    append!(state.clone_groups, clone_groups)
    append!(state.diagnostics, clone_diagnostics)
    push!(state.engines, EngineStatus(
        "duplicate-code", configuration.duplicate_code.enabled ?
            "complete" : "not-applicable", nothing))
end

"""Resolve allocation events against configured lifetime contracts."""
function run_resource_lifetime_analysis!(state, configuration)
    resource_lifetimes, lifetime_status = analyze_resource_lifetimes(
        state.resource_events, configuration)
    append!(state.resource_lifetimes, resource_lifetimes)
    lifetime_message = lifetime_status == "incomplete" ?
        "One or more allocation events lack a unique lifetime contract." : nothing
    push!(state.engines, EngineStatus(
        "resource-lifetime", lifetime_status, lifetime_message))
end

"""Analyze configured source-to-sink security boundaries."""
function run_security_analysis!(state, configuration)
    security_analysis = analyze_security_boundaries(state.call_edges, configuration)
    append!(state.security_paths, security_analysis.paths)
    append!(state.diagnostics, security_analysis.diagnostics)
    security_message = security_analysis.status == "incomplete" ?
        "Dynamic calls prevent complete configured boundary analysis." : nothing
    push!(state.engines, EngineStatus(
        "security", security_analysis.status, security_message))
end

"""Correlate configured runtime coverage with static test reachability."""
function run_test_coverage_analysis!(state, root, configuration)
    if !configuration.coverage.enabled
        push!(state.engines, EngineStatus("test-coverage", "not-applicable", nothing))
        return
    end
    try
        analysis = analyze_test_coverage(
            root,
            state.functions,
            state.call_edges,
            state.call_roots,
            configuration)
        append!(state.test_coverage, analysis.evidence)
        state.test_coverage_statistics[] = analysis.statistics
        push!(state.engines, EngineStatus("test-coverage", "complete", nothing))
    catch error
        push!(state.engines, EngineStatus(
            "test-coverage", "failed", sprint(showerror, error)))
    end
end

"""Analyze a repository and return its canonical analysis report."""
function check_repository(
    root::String;
    configuration::EffectiveSettings=load_settings(),
    progress=nothing)
    report_progress(progress, "Discovering source files")
    excludes = exclusions_for_root(root, configuration.enforcement_excludes)
    files = discover_sources(root, excludes)
    files_by_language = count_files_by_language(files)
    report_progress(progress, "Checking $(length(files)) source files")
    state = repository_analysis_state()
    run_language_analysis!(state, root, files, configuration, progress)
    run_odin_build_analysis!(
        state.diagnostics,
        state.odin_builds,
        state.engines,
        root,
        configuration,
        progress)
    report_progress(progress, "Assembling the canonical report")
    return assemble_analysis_report(
        root,
        files,
        files_by_language,
        state.diagnostics,
        state.functions,
        state.engines,
        state.odin_builds,
        configuration;
        struct_counts=state.struct_counts,
        dependencies=state.dependencies,
        declarations=state.declarations,
        import_bindings=state.import_bindings,
        references=state.references,
        call_edges=state.call_edges,
        call_roots=state.call_roots,
        clone_groups=state.clone_groups,
        resource_lifetimes=state.resource_lifetimes,
        security_paths=state.security_paths,
        test_coverage=state.test_coverage,
        test_coverage_statistics=state.test_coverage_statistics[],
        interop_signatures=state.interop_signatures,
        interop_pairs=state.interop_pairs,
        extension_results=state.extension_results)
end

"""Return line, function, and struct totals for every discovered source file."""
function analyze_files(root, files, functions, struct_counts, diagnostics)
    return map(files) do path
        source = read(path, String)
        lines = split(source, '\n'; keepempty=true)
        physical_lines = isempty(source) ? 0 :
            length(lines) - (isempty(last(lines)) ? 1 : 0)
        content_lines = @view lines[1:physical_lines]
        relative_path = relpath(path, root)
        language = endswith(path, ".jl") ? "julia" :
            endswith(path, ".odin") ? "odin" : "markdown"
        syntax_rule = language == "julia" ? "JULIA-SYNTAX" :
            language == "odin" ? "ODIN-SYNTAX" : nothing
        parsed = syntax_rule === nothing || !any(
            item -> item.path == relative_path && item.rule_id == syntax_rule,
            diagnostics)
        line_counts = file_line_counts(
            path, source, lines, content_lines, physical_lines, language, parsed)
        function_count = count(item -> item.path == relative_path, functions)
        struct_count = language == "julia" && parsed ?
            JuliaEngine.struct_count(source) : get(struct_counts, relative_path, 0)
        FileAnalysis(
            relative_path,
            language,
            physical_lines,
            physical_lines - line_counts.blank,
            line_counts.code,
            line_counts.comment,
            line_counts.blank,
            function_count, struct_count,
            parsed)
    end
end

"""Classify physical source lines as blank, comment, or code."""
function file_line_counts(
    path, source, lines, content_lines, physical_lines, language, parsed)
    blank_lines = count(line -> isempty(strip(line)), content_lines)
    comment_line_numbers = source_comment_lines(path, lines)
    language == "julia" && parsed && union!(
        comment_line_numbers,
        JuliaEngine.documentation_comment_lines(source))
    comment_lines = count(
        line_number -> line_number in comment_line_numbers,
        1:physical_lines)
    return SourceLineCounts(
        blank_lines,
        comment_lines,
        physical_lines - blank_lines - comment_lines)
end

"""Resolve configured exclusions that apply to an analysis root."""
function exclusions_for_root(root::String, configured_excludes::Vector{String})
    absolute_root = abspath(root)
    excludes = String[]
    for excluded in configured_excludes
        parts = splitpath(normpath(excluded))
        tail = parts[2:end]
        relative = !isempty(parts) && first(parts) == basename(absolute_root) ?
            (isempty(tail) ? "." : joinpath(tail...)) : normpath(excluded)
        push!(excludes, relative)
    end
    return excludes
end

"""Count discovered source files by supported language."""
function count_files_by_language(files::Vector{String})
    counts = Dict("julia" => 0, "odin" => 0, "markdown" => 0)
    for path in files
        language = endswith(path, ".jl") ? "julia" :
            endswith(path, ".odin") ? "odin" : "markdown"
        counts[language] += 1
    end
    return counts
end

"""Summarize rule applicability, execution status, and finding counts."""
function summarize_rule_runs(
    configuration,
    files_by_language,
    diagnostics,
    ignored_counts,
    engines,
    call_roots=CallRoot[])
    engine_statuses = Dict(engine.name => engine.status for engine in engines)
    summaries = RuleRunSummary[]
    for rule_id in sort!(collect(keys(configuration.rules)))
        setting = configuration.rules[rule_id]
        definition = configuration.rule_registry[rule_id]
        files_checked = rule_files_checked(
            rule_id, definition, configuration, files_by_language, call_roots)
        owner = get(configuration.extension_rule_owners, rule_id, nothing)
        status = rule_run_status(
            setting, definition, engine_statuses, files_checked, owner)
        visible = count(item -> item.rule_id == rule_id, diagnostics)
        findings = visible + get(ignored_counts, rule_id, 0)
        push!(summaries, RuleRunSummary(
            rule_id,
            setting.response,
            status,
            status == "evaluated" ? files_checked : 0,
            findings))
    end
    return summaries
end

"""Return the number of files or configured targets applicable to one rule."""
function rule_files_checked(
    rule_id, definition, configuration, files_by_language, call_roots)
    startswith(rule_id, "ARCHITECTURE-") &&
        isempty(configuration.architecture.layers) && return 0
    rule_id in ("DUPLICATE-CODE-POLICY-DRIFT", "JULIA-DUPLICATE-CODE",
        "ODIN-DUPLICATE-CODE") && !configuration.duplicate_code.enabled && return 0
    rule_id == "JULIA-UNREACHABLE-FUNCTION" &&
        !any(root -> root.language == "julia", call_roots) && return 0
    rule_id == "ODIN-UNREACHABLE-PROCEDURE" &&
        !any(root -> root.language == "odin", call_roots) && return 0
    rule_id == "ODIN-BUILD-FAILED" && return length(configuration.odin_build.targets)
    startswith(rule_id, "JULIA-JET-") && return length(configuration.jet.entry_points)
    return definition.language == "common" ?
        sum(values(files_by_language)) : files_by_language[definition.language]
end

"""Return the execution status for one configured analysis rule."""
function rule_run_status(
    setting,
    definition,
    engine_statuses,
    files_checked,
    extension_owner=nothing)
    setting.enabled || return "disabled"
    files_checked == 0 && return "not-applicable"
    engine_name = extension_owner !== nothing ? "extension:$extension_owner" :
        startswith(setting.rule_id, "ARCHITECTURE-") ? "architecture" :
        setting.rule_id in ("CALL-GRAPH-UNRESOLVED-EDGE",
            "JULIA-UNREACHABLE-FUNCTION", "ODIN-UNREACHABLE-PROCEDURE") ? "call-graph" :
        setting.rule_id in ("DUPLICATE-CODE-POLICY-DRIFT",
            "JULIA-DUPLICATE-CODE", "ODIN-DUPLICATE-CODE") ? "duplicate-code" :
        setting.rule_id == "ODIN-BUILD-FAILED" ? "odin-build" :
        startswith(setting.rule_id, "JULIA-JET-") ? "jet" :
        definition.language == "common" ? "common" : definition.language
    engine_status = get(engine_statuses, engine_name, "failed")
    engine_status in ("failed", "incomplete") && return "failed"
    engine_status == "not-applicable" && return "not-applicable"
    return "evaluated"
end

end