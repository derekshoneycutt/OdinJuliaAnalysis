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
    is_rodata::Bool
end

"""Construct a declaration without Odin lifecycle or storage metadata."""
DeclarationRecord(path, language, name, qualified_name, kind, scope, line, column) =
    DeclarationRecord(
        path, language, name, qualified_name, kind, scope, line, column, false, false)

struct ImportBinding
    path::String
    language::String
    target::String
    name::String
    kind::String
    line::Int
    column::Int
end

struct IncludeEdge
    source_path::String
    target_path::String
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
    exact_path::Bool
end

"""Construct a conventional call root whose declaration name is repository-wide."""
function CallRoot(
    id::String, path::String, language::String, declaration::String,
    category::String)
    return CallRoot(id, path, language, declaration, category, false)
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
    initializer_reduced_lines::Int
    flat_switch_candidate::Bool
    flat_switch_outside_lines::Int
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
    documented,
    initializer_reduced_lines=executable_lines,
    flat_switch_candidate=false,
    flat_switch_outside_lines=0)
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
        InteropBridgePair[],
        initializer_reduced_lines,
        flat_switch_candidate,
        flat_switch_outside_lines)
end

"""Preserve positional construction before initializer reduction was introduced."""
function FunctionAnalysis(
    path, language, name, start_line, end_line, executable_lines, remaining...)
    length(remaining) in (15, 16) || throw(MethodError(
        FunctionAnalysis,
        (path, language, name, start_line, end_line, executable_lines, remaining...)))
    return FunctionAnalysis(
        path, language, name, start_line, end_line, executable_lines,
        remaining...,
        (length(remaining) == 15 ? (executable_lines, false, 0) : (false, 0))...)
end

struct FileAnalysis
    path::String
    language::String
    physical_lines::Int
    source_lines::Int
    code_lines::Int
    comment_lines::Int
    blank_lines::Int
    struct_count::Union{Nothing, Int}
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
    sql::Union{Nothing, SQLSourceEvidence}
end

"""Preserve file constructors from before dedicated SQL evidence was available."""
function FileAnalysis(
    path, language, metrics...)
    length(metrics) == 19 || throw(MethodError(FileAnalysis, (path, language, metrics...)))
    return FileAnalysis(path, language, metrics..., nothing)
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
    parsed,
    sql::Union{Nothing, SQLSourceEvidence}=nothing)
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
        InteropBridgePair[],
        sql)
end

struct CodeStatistics
    files::Int
    functions::Union{Nothing, Int}
    structs::Union{Nothing, Int}
    lines::Int
    blank_lines::Int
    comment_lines::Int
    code_lines::Int
    complexity::Union{Nothing, Int}
    complexity_per_code_line::Union{Nothing, Float64}
end

struct SourceTotals
    files::Int
    physical_lines::Int
    source_lines::Int
    code_lines::Int
    comment_lines::Int
    blank_lines::Int
end

"""Procedural metrics and estimates disclose languages without structural measurements."""
struct MetricScope
    status::String
    languages::Vector{String}
    excluded_languages::Vector{String}
    complexity_files::Int
    complexity_code_lines::Int
    estimate_code_lines::Int
    reason::Union{Nothing, String}
end

"""SQL measurements distinguish a real zero from absent or incomplete evidence."""
struct SQLStatistics
    files::Int
    lexical_status::String
    structural_status::String
    reason::Union{Nothing, String}
    statements::Union{Nothing, Int}
    top_level_statements::Union{Nothing, Int}
    tables::Union{Nothing, Int}
    views::Union{Nothing, Int}
    indexes::Union{Nothing, Int}
    triggers::Union{Nothing, Int}
    virtual_tables::Union{Nothing, Int}
    query_blocks::Union{Nothing, Int}
    ctes::Union{Nothing, Int}
    binds::Union{Nothing, Int}
    projections::Union{Nothing, Int}
end

struct SQLStatementStatistics
    kind::String
    first_byte::Int
    after_last_byte::Int
    start_line::Int
    end_line::Int
    parent::Union{Nothing, Int}
    terminated::Bool
end

struct FunctionStatistics
    name::String
    start_line::Int
    end_line::Int
    physical_lines::Int
    executable_lines::Int
    parameter_count::Int
    cyclomatic_complexity::Int
    cognitive_complexity::Union{Nothing, Int}
    documented::Bool
    complexity_per_executable_line::Float64
end

struct FileStatistics
    parsed::Bool
    physical_lines::Int
    source_lines::Int
    code_lines::Int
    comment_lines::Int
    blank_lines::Int
    function_count::Union{Nothing, Int}
    struct_count::Union{Nothing, Int}
    total_cyclomatic_complexity::Union{Nothing, Int}
    complexity_per_code_line::Union{Nothing, Float64}
    average_function_complexity::Union{Nothing, Float64}
    maximum_function_complexity::Union{Nothing, Int}
    average_executable_lines::Union{Nothing, Float64}
    maximum_executable_lines::Union{Nothing, Int}
end

struct StatisticsSelection
    kind::String
    value::String
    matches::Int
end

struct SourceStatisticsReport
    schema_version::String
    tool_version::String
    path::String
    language::String
    file::FileStatistics
    functions::Vector{FunctionStatistics}
    selection::Union{Nothing, StatisticsSelection}
    sql::Union{Nothing, SQLStatistics}
    statements::Vector{SQLStatementStatistics}
    metric_scope::MetricScope
end

"""Preserve construction of procedural targeted reports with explicit scope defaults."""
function SourceStatisticsReport(
    schema, version, path, language, file, functions, selection)
    scope = MetricScope("applicable", ["julia", "odin"], ["sql", "markdown", "hlsl"],
        1, file.code_lines, file.code_lines, nothing)
    return SourceStatisticsReport(schema, version, path, language, file,
        functions, selection, nothing, SQLStatementStatistics[], scope)
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
    cocomo::Union{Nothing, CocomoEstimate}
    locomo::Union{Nothing, LocomoEstimate}
    sources::SourceTotals
    sources_by_language::Dict{String, SourceTotals}
    sql::SQLStatistics
    metric_scope::MetricScope
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
    sqlite_validation::SQLiteValidationEvidence
end

"""Retain historical report construction with runtime validation explicitly not applicable."""
function AnalysisReport(arguments...)
    length(arguments) == fieldcount(AnalysisReport) - 1 ||
        throw(MethodError(AnalysisReport, arguments))
    return AnalysisReport(arguments..., empty_sqlite_validation())
end

"""Expose active structural exemptions alongside policy-neutral function evidence."""
function JSON.lower(report::AnalysisReport)
    fields = NamedTuple{fieldnames(AnalysisReport)}(
        Tuple(getfield(report, name) for name in fieldnames(AnalysisReport)))
    return merge(fields, (; function_metric_exemptions=flat_switch_exemptions(report)))
end

"""Lower a diagnostic into its stable serialized representation."""
JSON.lower(diagnostic::Diagnostic) = (
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
JSON.lower(summary::RuleRunSummary) = (
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