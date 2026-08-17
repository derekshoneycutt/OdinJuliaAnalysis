module OdinEngine

using JSON3

using ..OdinJuliaAnalysis: Diagnostic
using ..OdinJuliaAnalysis: CallEdge
using ..OdinJuliaAnalysis: CloneCandidate
using ..OdinJuliaAnalysis: CloneOccurrence
using ..OdinJuliaAnalysis: DeclarationRecord
using ..OdinJuliaAnalysis: DependencyEdge
using ..OdinJuliaAnalysis: EffectiveSettings
using ..OdinJuliaAnalysis: Fail
using ..OdinJuliaAnalysis: FunctionAnalysis
using ..OdinJuliaAnalysis: Ignore
using ..OdinJuliaAnalysis: ImportBinding
using ..OdinJuliaAnalysis: InteropSignature
using ..OdinJuliaAnalysis: ReferenceRecord
using ..OdinJuliaAnalysis: configured_diagnostic
using ..OdinJuliaAnalysis: executable_source_lines
using ..OdinJuliaAnalysis: load_settings
using ..OdinJuliaAnalysis: valid_identifier_name

export check_syntax
export analyze

const ANALYSIS_ROOT = normpath(joinpath(@__DIR__, "..", ".."))
const ENGINE_SOURCE = joinpath(ANALYSIS_ROOT, "odin_engine")
const ENGINE_BUILD = joinpath(ANALYSIS_ROOT, ".build", "odin-engine")
const SCHEMA_VERSION = "3.9.0"

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

const OdinImport = @NamedTuple begin
    target::String
    binding::String
    is_using::Bool
    line::Int
    column::Int
end

const OdinReference = @NamedTuple begin
    name::String
    scope::String
    line::Int
    column::Int
end

const OdinCallEdge = @NamedTuple begin
    caller::String
    callee::String
    kind::String
    line::Int
    column::Int
end

const OdinProcedureBody = @NamedTuple begin
    name::String
    tokens::Vector{String}
    start_line::Int
    end_line::Int
end

const OdinInteropSignature = @NamedTuple begin
    symbol::String
    direction::String
    library::String
    calling_convention::String
    parameter_types::Vector{String}
    return_types::Vector{String}
    line::Int
    column::Int
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
    imports::Vector{OdinImport}
    references::Vector{OdinReference}
    call_edges::Vector{OdinCallEdge}
    procedure_bodies::Vector{OdinProcedureBody}
    interop_signatures::Vector{OdinInteropSignature}
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
    isempty(files) && return empty_analysis()
    ensure_engine()

    command = Cmd(vcat([ENGINE_BUILD], files))
    response = JSON3.read(read(command, String), OdinEngineResponse)
    response.schema_version == SCHEMA_VERSION || error(
        "Odin engine schema mismatch: expected $SCHEMA_VERSION, " *
        "received $(response.schema_version)")
    analysis = empty_analysis()
    for summary in response.files
        append_file_summary!(analysis, root, summary, configuration)
    end
    apply_reviewed_allocation_policies!(
        analysis.diagnostics,
        root,
        files,
        configuration)
    return analysis
end

"""Create mutable collections for one native Odin analysis response."""
function empty_analysis()
    return (
        diagnostics=Diagnostic[],
        functions=FunctionAnalysis[],
        dependencies=DependencyEdge[],
        declarations=DeclarationRecord[],
        import_bindings=ImportBinding[],
        references=ReferenceRecord[],
        call_edges=CallEdge[],
        clone_candidates=CloneCandidate[],
        resource_events=Diagnostic[],
        interop_signatures=InteropSignature[],
        struct_counts=Dict{String, Int}())
end

"""Append all canonical facts from one native Odin file summary."""
function append_file_summary!(analysis, root, summary, configuration)
    source_path = relpath(String(summary.path), root)
    analysis.struct_counts[source_path] = Int(summary.struct_count)
    append_summary_analysis!(
        analysis.diagnostics,
        analysis.resource_events,
        analysis.functions,
        root,
        summary,
        configuration)
    append!(analysis.declarations, declaration_records(source_path, summary))
    append_import_records!(analysis, root, source_path, summary.imports)
    append!(analysis.references, reference_records(source_path, summary.references))
    append!(analysis.call_edges, call_edge_records(source_path, summary.call_edges))
    append!(analysis.clone_candidates, clone_candidate_records(
        source_path, summary.procedure_bodies))
    append!(analysis.interop_signatures,
        interop_records(source_path, summary.interop_signatures))
end

"""Convert native parser-tokenized procedure bodies into clone candidates."""
function clone_candidate_records(source_path, bodies)
    return [CloneCandidate((
        occurrence=CloneOccurrence(
            source_path, "odin", String(body.name),
            Int(body.start_line), Int(body.end_line)),
        canonical_body=join(String.(body.tokens), '\x1f'),
        token_count=length(body.tokens),
        executable_lines=max(Int(body.end_line) - Int(body.start_line) - 1, 0)))
        for body in bodies]
end

"""Convert native explicit calls into canonical call graph edges."""
function call_edge_records(source_path, edges)
    return [CallEdge(
        source_path, "odin", isempty(item.caller) ? nothing : String(item.caller),
        String(item.callee), String(item.kind), Int(item.line), Int(item.column))
        for item in edges]
end

"""Append canonical dependency and binding records from native imports."""
function append_import_records!(analysis, root, source_path, imports)
    for item in imports
        target = String(item.target)
        binding = isempty(item.binding) ? splitpath(target)[end] : String(item.binding)
        Bool(item.is_using) || push!(analysis.import_bindings, ImportBinding(
            source_path, "odin", target, binding, "import",
            Int(item.line), Int(item.column)))
        target_path, resolution = resolve_odin_target(root, source_path, target)
        push!(analysis.dependencies, DependencyEdge(
            source_path, target, target_path, resolution, "odin", "import",
            Int(item.line), Int(item.column)))
    end
end

"""Convert native identifier references into canonical records."""
function reference_records(source_path, references)
    return [ReferenceRecord(
        source_path, "odin", String(item.name),
        isempty(item.scope) ? nothing : String(item.scope),
        Int(item.line), Int(item.column)) for item in references]
end

"""Convert native ABI signatures into canonical normalized records."""
function interop_records(source_path, signatures)
    return [InteropSignature(
        source_path, "odin", String(item.symbol), String(item.direction),
        isempty(item.library) ? nothing : String(item.library),
        String(item.calling_convention),
        normalize_odin_abi_types(item.parameter_types),
        normalize_odin_abi_types(item.return_types),
        Int(item.line), Int(item.column)) for item in signatures]
end

"""Normalize a native ABI type list."""
normalize_odin_abi_types(types) = [normalize_odin_abi_type(item) for item in types]

"""Normalize source-level Odin ABI type spelling."""
function normalize_odin_abi_type(type_name)
    text = replace(strip(String(type_name)), " " => "")
    mappings = Dict("rawptr" => "^void", "cstring" => "cstring")
    return get(mappings, text, text)
end

"""Promote native parser symbols into canonical declaration records."""
function declaration_records(source_path, summary)
    declarations = DeclarationRecord[]
    for symbol in summary.symbols
        name = String(symbol.name)
        scope = declaration_scope(symbol, summary)
        qualified_name = scope === nothing ? name : "$scope.$name"
        push!(declarations, DeclarationRecord(
            source_path,
            "odin",
            name,
            qualified_name,
            String(symbol.kind),
            scope,
            Int(symbol.line),
            Int(symbol.column)))
    end
    return declarations
end

"""Return the narrowest parser-measured procedure containing a declaration."""
function declaration_scope(symbol, summary)
    top_level_procedure(symbol, summary) && return nothing
    line = Int(symbol.line)
    enclosing = filter(
        metric -> Int(metric.start_line) <= line <= Int(metric.end_line),
        summary.procedures)
    isempty(enclosing) && return nothing
    metric = first(sort!(enclosing; by=item ->
        Int(item.end_line) - Int(item.start_line)))
    return String(metric.name)
end

"""Classify one parser-backed Odin package import against repository directories."""
function resolve_odin_target(root, source_path, target)
    occursin(':', target) && return nothing, "external"
    candidate = normpath(joinpath(root, dirname(source_path), target))
    relative_path = relpath(candidate, root)
    parts = splitpath(relative_path)
    repository_owned = isdir(candidate) && !isabspath(relative_path) &&
        !isempty(parts) && first(parts) != ".."
    return repository_owned ? (relative_path, "repository") : (nothing, "unresolved")
end

"""Convert one native Odin file summary into configured diagnostics and metrics."""
function append_summary_analysis!(
    diagnostics,
    resource_events,
    functions,
    root,
    summary,
    configuration)
    if !summary.parsed || summary.syntax_errors != 0
        diagnostic = configured_diagnostic(
            configuration,
            syntax_diagnostic(root, summary))
        diagnostic === nothing || push!(diagnostics, diagnostic)
    end
    for finding in summary.findings
        raw_diagnostic = backend_diagnostic(root, summary, finding, configuration)
        startswith(raw_diagnostic.rule_id, "ODIN-ALLOCATION-") &&
            push!(resource_events, raw_diagnostic)
        diagnostic = configured_diagnostic(configuration, raw_diagnostic)
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