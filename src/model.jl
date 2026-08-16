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

struct FileAnalysis
    path::String
    language::String
    physical_lines::Int
    source_lines::Int
    code_lines::Int
    comment_lines::Int
    blank_lines::Int
    function_count::Int
    struct_count::Int
    parsed::Bool
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
    functions::Tuple
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
    functions::Vector{FunctionAnalysis}
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