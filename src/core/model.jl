struct Diagnostic
    rule_id::String
    response::FindingResponse
    path::String
    line::Int
    column::Int
    message::String
    measured::Union{Nothing, Int}
    allowed::Union{Nothing, Int}
    source::String
    subject::Union{Nothing, String}
    operation::Union{Nothing, String}
    allocator_source::Union{Nothing, String}
    certainty::Union{Nothing, String}
    procedure::Union{Nothing, String}
    allocation_target::Union{Nothing, String}
    reviewed_policy_id::Union{Nothing, String}
    reviewed_policy_reason::Union{Nothing, String}
end

"""Construct a diagnostic from either canonical or extended compatibility fields."""
function Diagnostic(
    rule_id,
    response,
    path,
    line,
    column,
    message,
    measured,
    remaining...)
    length(remaining) in (2, 6) || throw(MethodError(
        Diagnostic,
        (rule_id, response, path, line, column, message, measured, remaining...)))
    allowed, source = remaining[1:2]
    metadata = length(remaining) == 6 ? remaining[3:6] :
        (nothing, nothing, nothing, nothing)
    return Diagnostic(
        rule_id, response, path, line, column, message, measured, allowed, source,
        metadata..., nothing, nothing, nothing, nothing)
end

struct EngineStatus
    name::String
    status::String
    message::Union{Nothing, String}
end

struct OdinBuildAnalysis
    id::String
    input::String
    output::String
    command::Vector{String}
    flags::Vector{String}
    status::String
    exit_code::Int
    stdout::String
    stderr::String
end

struct RuleRunSummary
    rule_id::String
    response::FindingResponse
    status::String
    files_checked::Int
    findings::Int
end

struct DependencyEdge
    source_path::String
    target::String
    target_path::Union{Nothing, String}
    resolution::String
    language::String
    kind::String
    line::Int
    column::Int
end

struct DeclarationRecord
    path::String
    language::String
    name::String
    qualified_name::String
    kind::String
    scope::Union{Nothing, String}
    line::Int
    column::Int
    is_init::Bool
end

"""Construct a declaration without an implicit initialization lifecycle."""
DeclarationRecord(path, language, name, qualified_name, kind, scope, line, column) =
    DeclarationRecord(
        path, language, name, qualified_name, kind, scope, line, column, false)

struct ImportBinding
    path::String
    language::String
    target::String
    name::String
    kind::String
    line::Int
    column::Int
end

struct ReferenceRecord
    path::String
    language::String
    name::String
    scope::Union{Nothing, String}
    line::Int
    column::Int
end

struct CallEdge
    source_path::String
    language::String
    caller::Union{Nothing, String}
    callee::String
    kind::String
    line::Int
    column::Int
end

struct CallRoot
    id::String
    path::String
    language::String
    declaration::String
    category::String
end

struct CloneOccurrence
    path::String
    language::String
    declaration::String
    start_line::Int
    end_line::Int
end

struct CloneCandidate
    occurrence::CloneOccurrence
    canonical_body::String
    token_count::Int
    executable_lines::Int
end

struct CloneGroup
    fingerprint::String
    language::String
    token_count::Int
    executable_lines::Int
    occurrences::Vector{CloneOccurrence}
end

struct ResourceLifetimeSummary
    path::String
    line::Int
    procedure::Union{Nothing, String}
    operation::Union{Nothing, String}
    target::Union{Nothing, String}
    allocator_source::Union{Nothing, String}
    category::String
    contract_id::Union{Nothing, String}
    ownership::String
    lifetime::String
    release_operation::Union{Nothing, String}
    allows_escape::Union{Nothing, Bool}
    certainty::Union{Nothing, String}
    status::String
    explanation::String
end

struct SecurityBoundaryPath
    path::String
    language::String
    declaration::String
    source_contract_id::String
    source_call::String
    source_category::String
    source_line::Int
    sink_contract_id::String
    sink_call::String
    sink_category::String
    sink_line::Int
    sanitizer_contract_ids::Vector{String}
    certainty::String
    explanation::String
end

struct TestCoverageEvidence
    path::String
    language::String
    declaration::String
    start_line::Int
    end_line::Int
    executable_lines::Int
    cyclomatic_complexity::Int
    static_test_reachable::Union{Nothing, Bool}
    runtime_instrumented_lines::Int
    runtime_covered_lines::Int
    runtime_covered::Union{Nothing, Bool}
    evidence_class::String
    boundary_categories::Vector{String}
    risk_score::Int
    explanation::String
end

struct TestCoverageCounts
    declarations::Int
    static_reachable::Int
    runtime_available::Int
    runtime_covered::Int
    corroborated::Int
    static_only::Int
    runtime_only::Int
    uncovered::Int
    runtime_unavailable::Int
    static_unavailable::Int
    unavailable::Int
    gaps::Int
end

struct TestCoverageStatistics
    overall::TestCoverageCounts
    by_language::Dict{String, TestCoverageCounts}
    unresolved_dynamic_edges::Int
    high_risk_limit::Int
end

struct InteropSignature
    path::String
    language::String
    symbol::String
    direction::String
    library::Union{Nothing, String}
    calling_convention::String
    parameter_types::Vector{String}
    return_types::Vector{String}
    line::Int
    column::Int
end

struct InteropBridgePair
    symbol::String
    status::String
    julia_path::Union{Nothing, String}
    odin_path::Union{Nothing, String}
    mismatch::Union{Nothing, String}
end

struct FunctionAnalysis
    path::String
    language::String
    name::String
    start_line::Int
    end_line::Int
    executable_lines::Int
    parameter_count::Int
    cyclomatic_complexity::Int
    cognitive_complexity::Union{Nothing, Int}
    documented::Bool
    declarations::Vector{DeclarationRecord}
    import_bindings::Vector{ImportBinding}
    references::Vector{ReferenceRecord}
    call_edges::Vector{CallEdge}
    clone_candidates::Vector{CloneCandidate}
    clone_groups::Vector{CloneGroup}
    resource_lifetimes::Vector{ResourceLifetimeSummary}
    security_paths::Vector{SecurityBoundaryPath}
    test_coverage::Vector{TestCoverageEvidence}
    interop_signatures::Vector{InteropSignature}
    interop_pairs::Vector{InteropBridgePair}
end

"""Construct function metrics before nested evidence has been assigned."""
function FunctionAnalysis(
    path,
    language,
    name;
    start_line,
    end_line,
    executable_lines,
    parameter_count,
    cyclomatic_complexity,
    cognitive_complexity,
    documented)
    return FunctionAnalysis(
        path,
        language,
        name,
        start_line,
        end_line,
        executable_lines,
        parameter_count,
        cyclomatic_complexity,
        cognitive_complexity,
        documented,
        DeclarationRecord[],
        ImportBinding[],
        ReferenceRecord[],
        CallEdge[],
        CloneCandidate[],
        CloneGroup[],
        ResourceLifetimeSummary[],
        SecurityBoundaryPath[],
        TestCoverageEvidence[],
        InteropSignature[],
        InteropBridgePair[])
end

struct FileAnalysis
    path::String
    language::String
    physical_lines::Int
    source_lines::Int
    code_lines::Int
    comment_lines::Int
    blank_lines::Int
    struct_count::Int
    parsed::Bool
    functions::Vector{FunctionAnalysis}
    declarations::Vector{DeclarationRecord}
    import_bindings::Vector{ImportBinding}
    references::Vector{ReferenceRecord}
    call_edges::Vector{CallEdge}
    clone_candidates::Vector{CloneCandidate}
    clone_groups::Vector{CloneGroup}
    resource_lifetimes::Vector{ResourceLifetimeSummary}
    security_paths::Vector{SecurityBoundaryPath}
    test_coverage::Vector{TestCoverageEvidence}
    interop_signatures::Vector{InteropSignature}
    interop_pairs::Vector{InteropBridgePair}
end

"""Construct file metrics before nested evidence has been assigned."""
function FileAnalysis(
    path,
    language;
    physical_lines,
    source_lines,
    code_lines,
    comment_lines,
    blank_lines,
    struct_count,
    parsed)
    return FileAnalysis(
        path,
        language,
        physical_lines,
        source_lines,
        code_lines,
        comment_lines,
        blank_lines,
        struct_count,
        parsed,
        FunctionAnalysis[],
        DeclarationRecord[],
        ImportBinding[],
        ReferenceRecord[],
        CallEdge[],
        CloneCandidate[],
        CloneGroup[],
        ResourceLifetimeSummary[],
        SecurityBoundaryPath[],
        TestCoverageEvidence[],
        InteropSignature[],
        InteropBridgePair[])
end

struct CodeStatistics
    files::Int
    functions::Int
    structs::Int
    lines::Int
    blank_lines::Int
    comment_lines::Int
    code_lines::Int
    complexity::Int
    complexity_per_code_line::Float64
end

struct CocomoEstimate
    model::String
    effort_person_months::Float64
    schedule_months::Float64
    people::Float64
    estimated_cost::Float64
    average_annual_wage::Int
    overhead_multiplier::Float64
end

struct LocomoEstimate
    preset::String
    input_tokens::Float64
    output_tokens::Float64
    estimated_cycles::Float64
    estimated_cost::Float64
    generation_seconds::Float64
    review_hours::Float64
end

struct RepositoryStatistics
    code::CodeStatistics
    code_by_language::Dict{String, CodeStatistics}
    cocomo::CocomoEstimate
    locomo::LocomoEstimate
end

struct AnalysisContext
    root::String
    profile::Symbol
    phase::AnalysisPhase
    paths::Tuple
    files::Tuple
    dependencies::Tuple
    call_roots::Tuple
    test_coverage_statistics::Union{Nothing, TestCoverageStatistics}
    statistics::Union{Nothing, RepositoryStatistics}
end

struct ExtensionResult
    extension_id::String
    phase::AnalysisPhase
    status::String
    diagnostics::Vector{Diagnostic}
    artifacts::Dict{String, Any}
    message::Union{Nothing, String}
end

struct AnalysisReport
    schema_version::String
    tool_version::String
    root::String
    profile::String
    thresholds::AnalysisThresholds
    parameter_counts::ParameterCountSettings
    function_metrics::FunctionMetricSettings
    files_analyzed::Int
    files_by_language::Dict{String, Int}
    files::Vector{FileAnalysis}
    dependencies::Vector{DependencyEdge}
    call_roots::Vector{CallRoot}
    test_coverage_statistics::Union{Nothing, TestCoverageStatistics}
    statistics::RepositoryStatistics
    diagnostics::Vector{Diagnostic}
    ignored_diagnostics::Vector{Diagnostic}
    ignored_counts::Dict{String, Int}
    engines::Vector{EngineStatus}
    odin_builds::Vector{OdinBuildAnalysis}
    extensions::Vector{ExtensionResult}
    rules::Vector{RuleRunSummary}
    exit_code::Int
end

"""Declare custom StructTypes serialization for diagnostics."""
StructTypes.StructType(::Type{Diagnostic}) = StructTypes.CustomStruct()
"""Declare structural serialization for engine status records."""
StructTypes.StructType(::Type{EngineStatus}) = StructTypes.Struct()
"""Declare structural serialization for analytical Odin build results."""
StructTypes.StructType(::Type{OdinBuildAnalysis}) = StructTypes.Struct()
"""Declare custom StructTypes serialization for rule summaries."""
StructTypes.StructType(::Type{RuleRunSummary}) = StructTypes.CustomStruct()
"""Declare structural serialization for analysis thresholds."""
StructTypes.StructType(::Type{AnalysisThresholds}) = StructTypes.Struct()
"""Declare structural serialization for file analysis records."""
StructTypes.StructType(::Type{FileAnalysis}) = StructTypes.Struct()
"""Declare structural serialization for function analysis records."""
StructTypes.StructType(::Type{FunctionAnalysis}) = StructTypes.Struct()
"""Declare structural serialization for dependency graph edges."""
StructTypes.StructType(::Type{DependencyEdge}) = StructTypes.Struct()
"""Declare structural serialization for declaration inventory records."""
StructTypes.StructType(::Type{DeclarationRecord}) = StructTypes.Struct()
"""Declare structural serialization for import binding records."""
StructTypes.StructType(::Type{ImportBinding}) = StructTypes.Struct()
"""Declare structural serialization for identifier reference records."""
StructTypes.StructType(::Type{ReferenceRecord}) = StructTypes.Struct()
"""Declare structural serialization for explicit call graph edges."""
StructTypes.StructType(::Type{CallEdge}) = StructTypes.Struct()
"""Declare structural serialization for configured and inferred call roots."""
StructTypes.StructType(::Type{CallRoot}) = StructTypes.Struct()
"""Declare structural serialization for one duplicate-code occurrence."""
StructTypes.StructType(::Type{CloneOccurrence}) = StructTypes.Struct()
"""Declare structural serialization for one exact duplicate-code group."""
StructTypes.StructType(::Type{CloneGroup}) = StructTypes.Struct()
"""Declare structural serialization for configured resource lifetime summaries."""
StructTypes.StructType(::Type{ResourceLifetimeSummary}) = StructTypes.Struct()
"""Declare structural serialization for configured security boundary paths."""
StructTypes.StructType(::Type{SecurityBoundaryPath}) = StructTypes.Struct()
"""Declare structural serialization for declaration-level coverage evidence."""
StructTypes.StructType(::Type{TestCoverageEvidence}) = StructTypes.Struct()
"""Declare structural serialization for coverage evidence counts."""
StructTypes.StructType(::Type{TestCoverageCounts}) = StructTypes.Struct()
"""Declare structural serialization for repository coverage statistics."""
StructTypes.StructType(::Type{TestCoverageStatistics}) = StructTypes.Struct()
"""Declare structural serialization for normalized interop signatures."""
StructTypes.StructType(::Type{InteropSignature}) = StructTypes.Struct()
"""Declare structural serialization for interop bridge pairs."""
StructTypes.StructType(::Type{InteropBridgePair}) = StructTypes.Struct()
"""Declare structural serialization for code statistics."""
StructTypes.StructType(::Type{CodeStatistics}) = StructTypes.Struct()
"""Declare structural serialization for COCOMO estimates."""
StructTypes.StructType(::Type{CocomoEstimate}) = StructTypes.Struct()
"""Declare structural serialization for LOCOMO estimates."""
StructTypes.StructType(::Type{LocomoEstimate}) = StructTypes.Struct()
"""Declare structural serialization for repository statistics."""
StructTypes.StructType(::Type{RepositoryStatistics}) = StructTypes.Struct()
"""Declare structural serialization for extension results."""
StructTypes.StructType(::Type{ExtensionResult}) = StructTypes.Struct()
"""Declare structural serialization for complete analysis reports."""
StructTypes.StructType(::Type{AnalysisReport}) = StructTypes.Struct()
"""Lower a diagnostic into its stable serialized representation."""
StructTypes.lower(diagnostic::Diagnostic) = (
    rule_id=diagnostic.rule_id,
    response=response_name(diagnostic.response),
    path=diagnostic.path,
    line=diagnostic.line,
    column=diagnostic.column,
    message=diagnostic.message,
    measured=diagnostic.measured,
    allowed=diagnostic.allowed,
    source=diagnostic.source,
    subject=diagnostic.subject,
    operation=diagnostic.operation,
    allocator_source=diagnostic.allocator_source,
    certainty=diagnostic.certainty,
    procedure=diagnostic.procedure,
    allocation_target=diagnostic.allocation_target,
    reviewed_policy_id=diagnostic.reviewed_policy_id,
    reviewed_policy_reason=diagnostic.reviewed_policy_reason)
"""Lower a rule summary into its stable serialized representation."""
StructTypes.lower(summary::RuleRunSummary) = (
    rule_id=summary.rule_id,
    response=response_name(summary.response),
    status=summary.status,
    files_checked=summary.files_checked,
    findings=summary.findings)

"""Return whether a diagnostic meets the configured failure threshold."""
meets_threshold(diagnostic::Diagnostic, threshold::FindingResponse) =
    Int(diagnostic.response) >= Int(threshold)

"""Return the stable ordering key for a diagnostic."""
function diagnostic_sort_key(diagnostic::Diagnostic)
    return (
    path=diagnostic.path,
    line=diagnostic.line,
    column=diagnostic.column,
    rule_id=diagnostic.rule_id)
end