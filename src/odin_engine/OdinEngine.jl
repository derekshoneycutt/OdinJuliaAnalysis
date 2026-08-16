module OdinEngine

using JSON3

using ..OdinJuliaAnalysis: Diagnostic
using ..OdinJuliaAnalysis: EffectiveSettings
using ..OdinJuliaAnalysis: Fail
using ..OdinJuliaAnalysis: FunctionAnalysis
using ..OdinJuliaAnalysis: Ignore
using ..OdinJuliaAnalysis: configured_diagnostic
using ..OdinJuliaAnalysis: executable_source_lines
using ..OdinJuliaAnalysis: load_settings
using ..OdinJuliaAnalysis: valid_identifier_name

export check_syntax
export analyze

const ANALYSIS_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const ENGINE_SOURCE = joinpath(ANALYSIS_ROOT, "odin_engine")
const ENGINE_BUILD = joinpath(ANALYSIS_ROOT, ".build", "odin-engine")
const SCHEMA_VERSION = "3.5.0"

const OdinFinding = @NamedTuple begin
    rule_id::String
    line::Int
    column::Int
    message::String
    subject::String
    operation::String
    procedure::String
    target::String
    allocator_source::String
    certainty::String
end

const OdinProcedureMetric = @NamedTuple begin
    name::String
    start_line::Int
    end_line::Int
    parameter_count::Int
    return_count::Int
    cyclomatic_complexity::Int
    documented::Bool
    start_offset::Int
    end_offset::Int
end

const OdinDeclarationSymbol = @NamedTuple begin
    name::String
    kind::String
    line::Int
    column::Int
    is_struct::Bool
end

const OdinFileSummary = @NamedTuple begin
    path::String
    parsed::Bool
    syntax_errors::Int
    syntax_warnings::Int
    struct_count::Int
    findings::Vector{OdinFinding}
    procedures::Vector{OdinProcedureMetric}
    symbols::Vector{OdinDeclarationSymbol}
end

const OdinEngineResponse = @NamedTuple begin
    schema_version::String
    engine_version::String
    files::Vector{OdinFileSummary}
end

"""Return syntax diagnostics from parser-backed Odin analysis."""
function check_syntax(
    root::String,
    files::Vector{String},
    configuration::EffectiveSettings=load_settings())
    return analyze(root, files, configuration).diagnostics
end

"""Return Odin diagnostics and parser-backed procedure measurements."""
function analyze(
    root::String,
    files::Vector{String},
    configuration::EffectiveSettings=load_settings())
    isempty(files) && return (
        diagnostics=Diagnostic[],
        functions=FunctionAnalysis[],
        struct_counts=Dict{String, Int}())
    ensure_engine()

    command = Cmd(vcat([ENGINE_BUILD], files))
    response = JSON3.read(read(command, String), OdinEngineResponse)
    response.schema_version == SCHEMA_VERSION || error(
        "Odin engine schema mismatch: expected $SCHEMA_VERSION, " *
        "received $(response.schema_version)")

    diagnostics = Diagnostic[]
    functions = FunctionAnalysis[]
    struct_counts = Dict{String, Int}()
    for summary in response.files
        struct_counts[relpath(String(summary.path), root)] = Int(summary.struct_count)
        append_summary_analysis!(diagnostics, functions, root, summary, configuration)
    end
    apply_reviewed_allocation_policies!(
        diagnostics,
        root,
        files,
        configuration)
    return (; diagnostics, functions, struct_counts)
end

"""Convert one native Odin file summary into configured diagnostics and metrics."""
function append_summary_analysis!(diagnostics, functions, root, summary, configuration)
    if !summary.parsed || summary.syntax_errors != 0
        diagnostic = configured_diagnostic(
            configuration,
            syntax_diagnostic(root, summary))
        diagnostic === nothing || push!(diagnostics, diagnostic)
    end
    for finding in summary.findings
        diagnostic = configured_diagnostic(
            configuration,
            backend_diagnostic(root, summary, finding, configuration))
        diagnostic === nothing || push!(diagnostics, diagnostic)
    end
    append!(diagnostics, naming_diagnostics(root, summary, configuration))
    append!(diagnostics, return_tuple_diagnostics(root, summary, configuration))
    append!(diagnostics, parameter_count_diagnostics(root, summary, configuration))
    append!(diagnostics, declaration_order_diagnostics(root, summary, configuration))
    append!(functions, backend_functions(root, summary))
end

"""Report package constants and structs declared after a procedure."""
function declaration_order_diagnostics(root, summary, configuration)
    diagnostics = Diagnostic[]
    procedure_section = false
    for symbol in sort(summary.symbols; by=item -> (item.line, item.column))
        kind = String(symbol.kind)
        top_level = kind == "procedure" ? top_level_procedure(symbol, summary) :
            !inside_procedure(symbol, summary)
        top_level || continue
        if kind == "procedure"
            procedure_section = true
        elseif procedure_section && (kind == "constant" || Bool(symbol.is_struct))
            name = String(symbol.name)
            declaration_kind = Bool(symbol.is_struct) ? "struct" : "constant"
            diagnostic = Diagnostic(
                "ODIN-DECLARATION-ORDER",
                Ignore,
                relpath(String(summary.path), root),
                Int(symbol.line),
                Int(symbol.column),
                "Odin $(declaration_kind) declarations must appear before procedures.",
                nothing,
                nothing,
                "odin-ast",
                name,
                "declaration-order",
                nothing,
                "stable")
            configured = configured_diagnostic(configuration, diagnostic)
            configured === nothing || push!(diagnostics, configured)
        end
    end
    return diagnostics
end

"""Return whether a symbol is inside any parser-reported procedure body."""
function inside_procedure(symbol, summary)
    line = Int(symbol.line)
    return any(metric -> Int(metric.start_line) <= line <= Int(metric.end_line),
        summary.procedures)
end

"""Return whether a procedure symbol identifies a package-level procedure."""
function top_level_procedure(symbol, summary)
    name = String(symbol.name)
    line = Int(symbol.line)
    metric = findfirst(item ->
        String(item.name) == name && Int(item.start_line) == line,
        summary.procedures)
    metric === nothing && return false
    return !any(enclosing ->
        Int(enclosing.start_line) < line <= Int(enclosing.end_line),
        summary.procedures)
end

"""Convert neutral Odin parameter counts into one configured severity tier."""
function parameter_count_diagnostics(root, summary, configuration)
    diagnostics = Diagnostic[]
    warning = configuration.parameter_counts.odin_warning
    maximum = configuration.parameter_counts.odin_maximum
    for metric in summary.procedures
        count = Int(metric.parameter_count)
        count <= warning && continue
        rule_id, allowed = count > maximum ?
            ("ODIN-PARAMETERS-FAIL", maximum) :
            ("ODIN-PARAMETERS-WARN", warning)
        name = String(metric.name)
        diagnostic = Diagnostic(
            rule_id,
            Ignore,
            relpath(String(summary.path), root),
            Int(metric.start_line),
            1,
            "Odin procedure `$(name)` has $(count) parameters; " *
                "maximum for this tier is $(allowed).",
            count,
            allowed,
            "odin-ast",
            name,
            "parameters",
            nothing,
            "stable")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    return diagnostics
end

"""Convert neutral Odin result counts into configured tuple-return findings."""
function return_tuple_diagnostics(root, summary, configuration)
    diagnostics = Diagnostic[]
    maximum = configuration.return_tuples.odin_maximum
    for metric in summary.procedures
        count = Int(metric.return_count)
        count <= maximum && continue
        name = String(metric.name)
        diagnostic = Diagnostic(
            "ODIN-RETURN-TUPLE",
            Ignore,
            relpath(String(summary.path), root),
            Int(metric.start_line),
            1,
            "Odin procedure `$(name)` returns $(count) values; maximum is $(maximum).",
            count,
            maximum,
            "odin-ast",
            name,
            "return",
            nothing,
            "stable")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    return diagnostics
end

"""Convert neutral Odin declaration symbols into configured naming findings."""
function naming_diagnostics(root, summary, configuration)
    conventions = Dict(
        convention.kind => convention
        for convention in configuration.naming.conventions
        if convention.language == :odin)
    diagnostics = Diagnostic[]
    for symbol in summary.symbols
        kind = Symbol(String(symbol.kind))
        convention = get(conventions, kind, nothing)
        convention === nothing && continue
        name = String(symbol.name)
        valid_identifier_name(name, convention) && continue
        kind_name = replace(string(kind), '_' => ' ')
        diagnostic = Diagnostic(
            "ODIN-NAMING",
            Ignore,
            relpath(String(summary.path), root),
            Int(symbol.line),
            Int(symbol.column),
            "Odin $(kind_name) `$(name)` must use $(convention.casing).",
            nothing,
            nothing,
            "odin-ast",
            name,
            string(kind),
            nothing,
            "stable")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    return diagnostics
end

"""Convert backend procedure measurements into canonical function records."""
function backend_functions(root, summary)
    path = relpath(String(summary.path), root)
    lines = split(read(String(summary.path), String), '\n'; keepempty=true)
    return [FunctionAnalysis(
        path,
        "odin",
        String(metric.name),
        Int(metric.start_line),
        Int(metric.end_line),
        procedure_executable_lines(
            path, lines, Int(metric.start_line), Int(metric.end_line)),
        Int(metric.parameter_count),
        Int(metric.cyclomatic_complexity),
        nothing,
        Bool(metric.documented)) for metric in summary.procedures]
end

"""Count executable lines inside an Odin procedure body."""
function procedure_executable_lines(path, lines, start_line, end_line)
    start_line == end_line && return 1
    start_line += 1
    end_line -= 1
    start_line > end_line && return 0
    return executable_source_lines(path, lines, start_line, end_line)
end

"""Convert an Odin backend finding into a configured diagnostic."""
function backend_diagnostic(root, summary, finding, configuration)
    allocator_source = optional_string(finding, :allocator_source)
    rule_id = configured_allocation_rule(
        String(finding.rule_id),
        allocator_source,
        configuration)
    return Diagnostic(
        rule_id,
        Ignore,
        relpath(String(summary.path), root),
        Int(finding.line),
        Int(finding.column),
        String(finding.message),
        nothing,
        nothing,
        "odin-ast",
        optional_string(finding, :subject),
        optional_string(finding, :operation),
        allocator_source,
        optional_string(finding, :certainty),
        optional_string(finding, :procedure),
        optional_string(finding, :target),
        nothing,
        nothing)
end

"""Apply reviewed allocation policies and report policy drift."""
function apply_reviewed_allocation_policies!(
    diagnostics::Vector{Diagnostic},
    root::String,
    files::Vector{String},
    configuration::EffectiveSettings)
    scanned_paths = Set(repository_path(path, root) for path in files)
    policies = filter(
        policy -> policy.path in scanned_paths,
        configuration.allocations.reviewed_policies)
    isempty(policies) && return diagnostics

    match_counts = zeros(Int, length(policies))
    drift = Diagnostic[]
    for index in eachindex(diagnostics)
        diagnostic = diagnostics[index]
        startswith(diagnostic.rule_id, "ODIN-ALLOCATION-") || continue
        diagnostic.rule_id == "ODIN-ALLOCATION-POLICY-DRIFT" && continue
        policy_indices = findall(
            policy -> policy_matches(policy, diagnostic, root),
            policies)
        for policy_index in policy_indices
            match_counts[policy_index] += 1
        end
        if length(policy_indices) == 1
            diagnostics[index] = apply_policy(
                diagnostic,
                policies[only(policy_indices)])
        elseif length(policy_indices) > 1
            policy_ids = join((policies[item].id for item in policy_indices), ", ")
            push!(drift, policy_drift_diagnostic(
                diagnostic.path,
                diagnostic.line,
                diagnostic.column,
                "Allocation matches multiple reviewed policies: $policy_ids."))
        end
    end

    append_allocation_policy_count_drift!(drift, policies, match_counts)
    append!(diagnostics, drift)
    return diagnostics
end

"""Append drift diagnostics for reviewed allocation policy match counts."""
function append_allocation_policy_count_drift!(drift, policies, match_counts)
    for (policy, count) in zip(policies, match_counts)
        if count < policy.minimum_matches || count > policy.maximum_matches
            message = "Reviewed allocation policy $(policy.id) expected " *
                "$(policy.minimum_matches)-$(policy.maximum_matches) matches, " *
                "found $count."
            push!(drift, policy_drift_diagnostic(policy.path, 1, 1, message))
        end
    end
end

"""Return a path relative to the repository being analyzed."""
repository_path(path::String, root::String) = relpath(abspath(path), abspath(root))

"""Return whether a diagnostic satisfies every policy constraint."""
function policy_matches(policy, diagnostic::Diagnostic, root::String)
    repository_path(joinpath(root, diagnostic.path), root) == policy.path || return false
    diagnostic.procedure == policy.procedure || return false
    allocation_category(diagnostic.rule_id) == policy.category || return false
    optional_match(policy.operation, diagnostic.operation) || return false
    optional_match(policy.target, diagnostic.allocation_target) || return false
    optional_match(policy.allocator_source, diagnostic.allocator_source) || return false
    policy.certainty === nothing ||
        diagnostic.certainty == string(policy.certainty) || return false
    return true
end

"""Match an optional expected value against an actual value."""
optional_match(expected, actual) = expected === nothing || expected == actual

"""Extract the allocation category from an allocation rule identifier."""
function allocation_category(rule_id::String)
    suffix = replace(rule_id, "ODIN-ALLOCATION-" => "")
    return Symbol(lowercase(replace(suffix, '-' => '_')))
end

"""Attach a reviewed allocation policy decision to a diagnostic."""
function apply_policy(diagnostic::Diagnostic, policy)
    return Diagnostic(
        diagnostic.rule_id,
        policy.response,
        diagnostic.path,
        diagnostic.line,
        diagnostic.column,
        diagnostic.message,
        diagnostic.measured,
        diagnostic.allowed,
        diagnostic.source,
        diagnostic.subject,
        diagnostic.operation,
        diagnostic.allocator_source,
        diagnostic.certainty,
        diagnostic.procedure,
        diagnostic.allocation_target,
        policy.id,
        policy.reason)
end

"""Create a diagnostic describing reviewed allocation policy drift."""
function policy_drift_diagnostic(path, line, column, message)
    return Diagnostic(
        "ODIN-ALLOCATION-POLICY-DRIFT",
        Fail,
        path,
        line,
        column,
        message,
        nothing,
        nothing,
        "reviewed-allocation-policy")
end

"""Return a nonempty string property or `nothing`."""
function optional_string(object, property::Symbol)
    hasproperty(object, property) || return nothing
    value = String(getproperty(object, property))
    return isempty(value) ? nothing : value
end

"""Resolve an allocation finding to its configured category rule."""
function configured_allocation_rule(
    rule_id::String,
    allocator_source,
    configuration)
    rule_id == "ODIN-ALLOCATION-UNKNOWN" || return rule_id
    allocator_source === nothing && return rule_id
    pattern = findfirst(
        item -> item.source == allocator_source,
        configuration.allocations.source_patterns)
    pattern === nothing && return rule_id
    category = configuration.allocations.source_patterns[pattern].category
    return "ODIN-ALLOCATION-$(uppercase(replace(string(category), '_' => '-')))"
end

"""Build the Odin analyzer backend when its binary is absent or stale."""
function ensure_engine()
    source_files = filter(
        path -> endswith(path, ".odin"),
        readdir(ENGINE_SOURCE; join=true))
    newest_source = maximum(mtime, source_files)
    if isfile(ENGINE_BUILD) && mtime(ENGINE_BUILD) >= newest_source
        return
    end

    mkpath(dirname(ENGINE_BUILD))
    run(`odin build $ENGINE_SOURCE -out:$ENGINE_BUILD`)
end

"""Convert Odin parser failure output into a syntax diagnostic."""
function syntax_diagnostic(root, summary)
    return Diagnostic(
        "ODIN-SYNTAX",
        Ignore,
        relpath(String(summary.path), root),
        1,
        1,
        "Odin parser reported $(summary.syntax_errors) syntax error(s).",
        Int(summary.syntax_errors),
        0,
        "odin-ast")
end

end