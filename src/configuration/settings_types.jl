@enum FindingResponse begin
    Ignore = 0
    Report = 1
    Warn = 2
    Fail = 3
end

@enum AnalysisPhase begin
    AfterDiscovery
    AfterLanguageAnalysis
    AfterRepositoryAnalysis
end

abstract type AnalysisExtension end

struct RuleDefinition
    rule_id::String
    language::String
    standards_reference::String
    capability::String
    confidence::String
    default_activation::String
    immutable_activation::Bool
end

struct RuleSetting
    rule_id::String
    enabled::Bool
    response::FindingResponse
end

struct AnalysisThresholds
    line_warning::Int
    line_discouraged::Int
    line_hard::Int
    executable_lines_review::Int
    executable_lines_maximum::Int
    parameters_maximum::Int
    cyclomatic_warning::Int
    cyclomatic_error::Int
    cognitive_maximum::Int
end

struct ScanProfile
    name::Symbol
    enforcement_excludes::Vector{String}
end

struct ReportSettings
    color::Symbol
    warning_limit::Int
    report_limit::Int
end

struct NamingConvention
    language::Symbol
    kind::Symbol
    casing::Symbol
    allow_leading_underscore::Bool
    allow_trailing_bang::Bool
    allow_constructor_names::Bool
    ignored_names::Vector{String}
    ignored_patterns::Vector{Regex}
end

struct ReviewedNamingPolicy
    id::String
    path::String
    language::Symbol
    kind::Symbol
    name::String
    response::FindingResponse
    minimum_matches::Int
    maximum_matches::Int
    reason::String
end

"""Construct a reviewed naming policy with bounded match defaults."""
function ReviewedNamingPolicy(
    id::String,
    path::String,
    language::Symbol,
    kind::Symbol,
    name::String,
    reason::String;
    response::FindingResponse=Report,
    minimum_matches::Int=1,
    maximum_matches::Int=1)
    return ReviewedNamingPolicy(
        id,
        path,
        language,
        kind,
        name,
        response,
        minimum_matches,
        maximum_matches,
        reason)
end

"""Construct one configurable identifier naming convention."""
function NamingConvention(
    language::Symbol,
    kind::Symbol,
    casing::Symbol;
    allow_leading_underscore::Bool=false,
    allow_trailing_bang::Bool=false,
    allow_constructor_names::Bool=false,
    ignored_names::Vector{String}=String[],
    ignored_patterns::Vector{Regex}=Regex[])
    return NamingConvention(
        language,
        kind,
        casing,
        allow_leading_underscore,
        allow_trailing_bang,
        allow_constructor_names,
        ignored_names,
        ignored_patterns)
end

struct NamingSettings
    conventions::Vector{NamingConvention}
    reviewed_policies::Vector{ReviewedNamingPolicy}
end

struct JetEntryPoint
    id::String
    path::String
    callable::Function
    argument_types::Tuple
end

struct JetSettings
    entry_points::Vector{JetEntryPoint}
end

struct OdinBuildTarget
    id::String
    input::String
    output_name::String
    flags::Vector{String}
end

struct OdinBuildSettings
    targets::Vector{OdinBuildTarget}
end

struct ReturnTupleSettings
    julia_maximum::Int
    odin_maximum::Int
end

"""Return the default maximum of two tuple elements for both languages."""
default_return_tuple_settings() = ReturnTupleSettings(2, 2)

struct ParameterCountSettings
    julia_maximum::Int
    odin_warning::Int
    odin_maximum::Int
end

"""Return the default language-specific parameter count thresholds."""
default_parameter_count_settings() = ParameterCountSettings(8, 5, 8)

struct ResponseThresholds
    report::Int
    warn::Int
    fail::Int
end

struct ReviewedComplexity
    id::String
    path::String
    language::Symbol
    function_name::String
    metric::Symbol
    response::FindingResponse
    minimum_matches::Int
    maximum_matches::Int
    reason::String
end

"""Construct a reviewed function metric policy with bounded match defaults."""
function ReviewedComplexity(
    id::String,
    path::String,
    language::Symbol,
    function_name::String,
    metric::Symbol,
    reason::String;
    response::FindingResponse=Report,
    minimum_matches::Int=1,
    maximum_matches::Int=1)
    return ReviewedComplexity(
        id,
        path,
        language,
        function_name,
        metric,
        response,
        minimum_matches,
        maximum_matches,
        reason)
end

struct FunctionMetricSettings
    julia_lines::ResponseThresholds
    odin_lines::ResponseThresholds
    julia_cyclomatic::ResponseThresholds
    odin_cyclomatic::ResponseThresholds
    reviewed::Vector{ReviewedComplexity}
end

"""Construct function metric settings without reviewed policies."""
FunctionMetricSettings(julia_lines, odin_lines, julia_cyclomatic, odin_cyclomatic) =
    FunctionMetricSettings(
        julia_lines,
        odin_lines,
        julia_cyclomatic,
        odin_cyclomatic,
        ReviewedComplexity[])

"""Return conservative function metric tiers with established review triggers."""
function default_function_metric_settings()
    return FunctionMetricSettings(
        ResponseThresholds(20, 35, 65),
        ResponseThresholds(20, 35, 65),
        ResponseThresholds(10, 13, 16),
        ResponseThresholds(10, 15, 18))
end

"""Return no analytical Odin builds for compatibility with unconfigured consumers."""
default_odin_build_settings() = OdinBuildSettings(OdinBuildTarget[])

"""Return the analyzer CLI as the package's default JET call root."""
function default_jet_settings()
    return JetSettings([
        JetEntryPoint(
            "analyzer-cli",
            "src/OdinJuliaAnalysis.jl",
            main,
            (Vector{String},)),
    ])
end

"""Construct naming settings without reviewed policy exceptions."""
NamingSettings(conventions::Vector{NamingConvention}) =
    NamingSettings(conventions, ReviewedNamingPolicy[])

"""Return the package's default Julia and Odin naming conventions."""
function default_naming_settings()
    return NamingSettings([
        NamingConvention(:julia, :module, :camel_case),
        NamingConvention(:julia, :type, :camel_case),
        NamingConvention(
            :julia,
            :function,
            :snake_case;
            allow_leading_underscore=true,
            allow_trailing_bang=true),
        NamingConvention(:julia, :constant, :camel_or_screaming),
        NamingConvention(
            :julia,
            :parameter,
            :snake_case;
            allow_leading_underscore=true),
        NamingConvention(
            :julia,
            :variable,
            :snake_case;
            allow_leading_underscore=true),
        NamingConvention(
            :julia,
            :field,
            :snake_case;
            allow_leading_underscore=true),
        NamingConvention(:odin, :import, :snake_case),
        NamingConvention(:odin, :type, :ada_case),
        NamingConvention(:odin, :enum_value, :ada_case),
        NamingConvention(:odin, :procedure, :snake_case),
        NamingConvention(:odin, :constant, :screaming_snake_case),
        NamingConvention(:odin, :parameter, :snake_case),
        NamingConvention(:odin, :variable, :snake_case),
        NamingConvention(:odin, :field, :snake_case),
    ])
end

struct KnownAllocatingProcedure
    subject::String
    operation::String
    certainty::Symbol
end

struct AllocatorSourcePattern
    source::String
    category::Symbol
end

struct ReviewedAllocationPolicy
    id::String
    path::String
    procedure::String
    category::Symbol
    operation::Union{Nothing, String}
    target::Union{Nothing, String}
    allocator_source::Union{Nothing, String}
    certainty::Union{Nothing, Symbol}
    response::FindingResponse
    minimum_matches::Int
    maximum_matches::Int
    reason::String
end

"""Construct a reviewed allocation policy with bounded match defaults."""
function ReviewedAllocationPolicy(
    id::String,
    path::String,
    procedure::String,
    category::Symbol,
    reason::String;
    operation::Union{Nothing, String}=nothing,
    target::Union{Nothing, String}=nothing,
    allocator_source::Union{Nothing, String}=nothing,
    certainty::Union{Nothing, Symbol}=nothing,
    response::FindingResponse=Report,
    minimum_matches::Int=1,
    maximum_matches::Int=1)
    return ReviewedAllocationPolicy(
        id,
        path,
        procedure,
        category,
        operation,
        target,
        allocator_source,
        certainty,
        response,
        minimum_matches,
        maximum_matches,
        reason)
end

struct AllocationSettings
    known_procedures::Vector{KnownAllocatingProcedure}
    source_patterns::Vector{AllocatorSourcePattern}
    reviewed_policies::Vector{ReviewedAllocationPolicy}
end

struct ArchitectureLayer
    name::String
    paths::Vector{String}
end

struct ArchitectureDependency
    source::String
    target::String
end

struct ArchitectureSettings
    layers::Vector{ArchitectureLayer}
    allowed_dependencies::Vector{ArchitectureDependency}
end

struct ReviewedClonePolicy
    id::String
    language::Symbol
    fingerprint::String
    response::FindingResponse
    minimum_matches::Int
    maximum_matches::Int
    reason::String
end

"""Construct an exact-clone review policy with bounded match defaults."""
function ReviewedClonePolicy(
    id::String,
    language::Symbol,
    fingerprint::String,
    reason::String;
    response::FindingResponse=Report,
    minimum_matches::Int=1,
    maximum_matches::Int=1)
    return ReviewedClonePolicy(
        id,
        language,
        fingerprint,
        response,
        minimum_matches,
        maximum_matches,
        reason)
end

struct DuplicateCodeSettings
    enabled::Bool
    minimum_tokens::Int
    minimum_executable_lines::Int
    minimum_occurrences::Int
    excluded_paths::Vector{String}
    reviewed_policies::Vector{ReviewedClonePolicy}
end

"""Return duplicate-code analysis disabled for compatibility and opt-in rollout."""
default_duplicate_code_settings() = DuplicateCodeSettings(
    false, 40, 6, 2, String[], ReviewedClonePolicy[])

struct ResourceLifetimeContract
    id::String
    category::Symbol
    operation::Union{Nothing, String}
    allocator_source::Union{Nothing, String}
    ownership::Symbol
    lifetime::Symbol
    release_operation::Union{Nothing, String}
    allows_escape::Bool
    reason::String
end

"""Construct a configured ownership and lifetime contract."""
function ResourceLifetimeContract(
    id::String,
    category::Symbol,
    ownership::Symbol,
    lifetime::Symbol,
    reason::String;
    operation::Union{Nothing, String}=nothing,
    allocator_source::Union{Nothing, String}=nothing,
    release_operation::Union{Nothing, String}=nothing,
    allows_escape::Bool=false)
    return ResourceLifetimeContract(
        id,
        category,
        operation,
        allocator_source,
        ownership,
        lifetime,
        release_operation,
        allows_escape,
        reason)
end

struct ResourceLifetimeSettings
    enabled::Bool
    contracts::Vector{ResourceLifetimeContract}
end

"""Return resource lifetime analysis disabled for opt-in rollout."""
default_resource_lifetime_settings() = ResourceLifetimeSettings(
    false, ResourceLifetimeContract[])

struct SecurityCallContract
    id::String
    language::Symbol
    declaration::String
    category::Symbol
    reason::String
end

struct SecuritySettings
    enabled::Bool
    sources::Vector{SecurityCallContract}
    sinks::Vector{SecurityCallContract}
    sanitizers::Vector{SecurityCallContract}
end

"""Return conservative security boundary analysis disabled by default."""
default_security_settings() = SecuritySettings(
    false,
    SecurityCallContract[],
    SecurityCallContract[],
    SecurityCallContract[])

struct AnalysisSettings
    profile::Symbol
    failure_threshold::FindingResponse
    thresholds::AnalysisThresholds
    profiles::Vector{ScanProfile}
    rules::Vector{RuleSetting}
    naming::NamingSettings
    jet::JetSettings
    odin_build::OdinBuildSettings
    return_tuples::ReturnTupleSettings
    parameter_counts::ParameterCountSettings
    function_metrics::FunctionMetricSettings
    architecture::ArchitectureSettings
    allocations::AllocationSettings
    report::ReportSettings
    extensions::Vector{AnalysisExtension}
    duplicate_code::DuplicateCodeSettings
    resource_lifetime::ResourceLifetimeSettings
    security::SecuritySettings
end

struct EffectiveSettings
    profile::Symbol
    failure_threshold::FindingResponse
    thresholds::AnalysisThresholds
    enforcement_excludes::Vector{String}
    rules::Dict{String, RuleSetting}
    naming::NamingSettings
    jet::JetSettings
    odin_build::OdinBuildSettings
    return_tuples::ReturnTupleSettings
    parameter_counts::ParameterCountSettings
    function_metrics::FunctionMetricSettings
    architecture::ArchitectureSettings
    allocations::AllocationSettings
    report::ReportSettings
    extensions::Vector{AnalysisExtension}
    rule_registry::Dict{String, RuleDefinition}
    extension_rule_owners::Dict{String, String}
    duplicate_code::DuplicateCodeSettings
    resource_lifetime::ResourceLifetimeSettings
    security::SecuritySettings
end

"""Construct settings from the pre-naming API using package naming defaults."""
function AnalysisSettings(
    profile,
    failure_threshold,
    thresholds,
    profiles,
    rules,
    allocations,
    report)
    return AnalysisSettings(
        profile,
        failure_threshold,
        thresholds,
        profiles,
        rules,
        default_naming_settings(),
        default_jet_settings(),
        default_odin_build_settings(),
        default_return_tuple_settings(),
        default_parameter_count_settings(),
        default_function_metric_settings(),
        default_architecture_settings(),
        allocations,
        report,
        AnalysisExtension[],
        default_duplicate_code_settings(),
        default_resource_lifetime_settings(),
        default_security_settings())
end

    """Construct settings from the pre-entry-point API using default JET settings."""
    function AnalysisSettings(
        profile,
        failure_threshold,
        thresholds,
        profiles,
        rules,
        naming,
        allocations,
        report)
        return AnalysisSettings(
        profile,
        failure_threshold,
        thresholds,
        profiles,
        rules,
        naming,
        default_jet_settings(),
            default_odin_build_settings(),
            default_return_tuple_settings(),
            default_parameter_count_settings(),
            default_function_metric_settings(),
            default_architecture_settings(),
        allocations,
        report,
        AnalysisExtension[],
        default_duplicate_code_settings(),
        default_resource_lifetime_settings(),
        default_security_settings())
    end

struct CompatibilitySettingsTail
    odin_build
    return_tuples
    parameter_counts
    function_metrics
    architecture
    allocations
    report
    extensions
    duplicate_code
    resource_lifetime
    security
end

"""Decode settings fields added across compatibility constructor versions."""
function compatibility_settings_tail(trailing)
    odin_build = length(trailing) >= 3 ? trailing[1] : default_odin_build_settings()
    return_tuples = length(trailing) >= 4 ? trailing[2] :
        default_return_tuple_settings()
    parameter_counts = length(trailing) >= 5 ? trailing[3] :
        default_parameter_count_settings()
    function_metrics = length(trailing) >= 6 ? trailing[4] :
        default_function_metric_settings()
    has_architecture = length(trailing) >= 7 && trailing[5] isa ArchitectureSettings
    architecture = has_architecture ? trailing[5] : default_architecture_settings()
    duplicate_code_index = has_architecture ? 9 : 8
    duplicate_code = length(trailing) >= duplicate_code_index ?
        trailing[duplicate_code_index] : default_duplicate_code_settings()
    lifetime_index = duplicate_code_index + 1
    resource_lifetime = length(trailing) >= lifetime_index ?
        trailing[lifetime_index] : default_resource_lifetime_settings()
    security_index = lifetime_index + 1
    security = length(trailing) >= security_index ?
        trailing[security_index] : default_security_settings()
    extensions = has_architecture && length(trailing) >= 8 ? trailing[8] :
        !has_architecture && length(trailing) >= 7 ? trailing[7] : AnalysisExtension[]
    policy_end = has_architecture ? 7 : min(length(trailing), 6)
    allocations, report = trailing[(policy_end - 1):policy_end]
    return CompatibilitySettingsTail(
        odin_build,
        return_tuples,
        parameter_counts,
        function_metrics,
        architecture,
        allocations,
        report,
        extensions,
        duplicate_code,
        resource_lifetime,
        security)
end

"""Construct settings from APIs predating build, tuple, or parameter policies."""
    function AnalysisSettings(
        profile,
        failure_threshold,
        thresholds,
        profiles,
        rules,
        naming,
        jet,
        trailing...)
        length(trailing) in 2:11 || throw(MethodError(
            AnalysisSettings,
            (profile, failure_threshold, thresholds, profiles, rules, naming, jet,
                trailing...)))
        tail = compatibility_settings_tail(trailing)
        return AnalysisSettings(
        profile,
        failure_threshold,
        thresholds,
        profiles,
        rules,
        naming,
        jet,
        tail.odin_build,
        tail.return_tuples,
        tail.parameter_counts,
        tail.function_metrics,
        tail.architecture,
        tail.allocations,
        tail.report,
        tail.extensions,
        tail.duplicate_code,
        tail.resource_lifetime,
        tail.security)
    end

    """Construct effective settings from APIs predating tuple or parameter policies."""
    function EffectiveSettings(
        profile,
        failure_threshold,
        thresholds,
        enforcement_excludes,
        rules,
        naming,
        jet,
        trailing...)
        length(trailing) in 3:6 || length(trailing) == 10 || throw(MethodError(
            EffectiveSettings,
            (profile, failure_threshold, thresholds, enforcement_excludes, rules,
                naming, jet, trailing...)))
        if length(trailing) == 10
            return EffectiveSettings(
                profile,
                failure_threshold,
                thresholds,
                enforcement_excludes,
                rules,
                naming,
                jet,
                trailing...,
                default_duplicate_code_settings(),
                default_resource_lifetime_settings(),
                default_security_settings())
        end
        odin_build = trailing[1]
        return_tuples = length(trailing) in (4, 6) ? trailing[2] :
            default_return_tuple_settings()
        parameter_counts = length(trailing) in (5, 6) ? trailing[3] :
            default_parameter_count_settings()
        function_metrics = length(trailing) == 6 ? trailing[4] :
            default_function_metric_settings()
        allocations, report = trailing[end - 1:end]
        return EffectiveSettings(
        profile,
        failure_threshold,
        thresholds,
        enforcement_excludes,
        rules,
        naming,
        jet,
        odin_build,
        return_tuples,
        parameter_counts,
        function_metrics,
        default_architecture_settings(),
        allocations,
        report,
        AnalysisExtension[],
        copy(RULE_REGISTRY),
        Dict{String, String}(),
        default_duplicate_code_settings(),
        default_resource_lifetime_settings(),
        default_security_settings())
    end
