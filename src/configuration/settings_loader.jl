const DEFAULT_SETTINGS_PATH = normpath(
    joinpath(@__DIR__, "..", "..", "settings.jl"))

"""Load, validate, and resolve analyzer settings from a Julia file."""
function load_settings(
    path::AbstractString=DEFAULT_SETTINGS_PATH;
    profile::Union{Nothing, Symbol}=nothing)
    normalized_path = abspath(path)
    isfile(normalized_path) || throw(ArgumentError(
        "settings file does not exist: $normalized_path"))
    settings_module = Module(gensym(:OdinJuliaAnalysisSettings))
    value = Base.include(settings_module, normalized_path)
    value isa AnalysisSettings || throw(ArgumentError(
        "settings file must return an AnalysisSettings value"))
    return validate_settings(value; profile)
end

"""Validate analyzer settings and return their effective profile."""
function validate_settings(
    settings::AnalysisSettings;
    profile::Union{Nothing, Symbol}=nothing)
    settings.failure_threshold == Ignore && throw(ArgumentError(
        "failure threshold must be Report, Warn, or Fail"))
    validate_thresholds(settings.thresholds)
    profiles = validate_profiles(settings.profiles)
    selected_profile = something(profile, settings.profile)
    haskey(profiles, selected_profile) || throw(ArgumentError(
        "unknown analysis profile: $selected_profile"))
    extensions = validate_extensions(settings.extensions)
    rule_registry, rule_owners = merged_rule_registry(extensions)
    rules = validate_rule_settings(settings.rules, rule_registry)
    validate_naming_settings(settings.naming)
    validate_jet_settings(settings.jet)
    validate_odin_build_settings(settings.odin_build)
    validate_return_tuple_settings(settings.return_tuples)
    validate_parameter_count_settings(settings.parameter_counts)
    validate_function_metric_settings(settings.function_metrics)
    validate_architecture_settings(settings.architecture)
    validate_allocation_settings(settings.allocations)
    validate_report_settings(settings.report)
    return EffectiveSettings(selected_profile, settings.failure_threshold,
        settings.thresholds,
        copy(profiles[selected_profile].enforcement_excludes),
        rules, settings.naming, settings.jet, settings.odin_build, settings.return_tuples,
        settings.parameter_counts, settings.function_metrics, settings.architecture,
        settings.allocations, settings.report, extensions, rule_registry, rule_owners)
end

"""Validate extension contracts and return deterministic dependency order."""
function validate_extensions(extensions)
    extension_by_id = Dict{String, AnalysisExtension}()
    configured_order = Dict{String, Int}()
    for (index, extension) in enumerate(extensions)
        id = invoke_extension_id(extension)
        isempty(strip(id)) && throw(ArgumentError("extension ID cannot be empty"))
        haskey(extension_by_id, id) && throw(ArgumentError(
            "duplicate extension ID: $id"))
        version = invoke_extension_api_version(extension)
        version == EXTENSION_API_VERSION ||
            throw(ArgumentError(
                "extension $id requires API $version; " *
                    "analyzer provides $EXTENSION_API_VERSION"))
        phases = invoke_extension_phases(extension)
        isempty(phases) && throw(ArgumentError(
            "extension $id must declare at least one phase"))
        all(phase -> phase isa AnalysisPhase, phases) || throw(ArgumentError(
            "extension $id declares an unsupported phase"))
        extension_by_id[id] = extension
        configured_order[id] = index
    end
    for extension in extensions
        id = invoke_extension_id(extension)
        for dependency in invoke_extension_dependencies(extension)
            dependency == id && throw(ArgumentError(
                "extension $id cannot depend on itself"))
            haskey(extension_by_id, dependency) || throw(ArgumentError(
                "extension $id has unknown dependency: $dependency"))
        end
    end
    return order_extensions(extension_by_id, configured_order)
end

"""Topologically order extensions with configured order as the stable tie-breaker."""
function order_extensions(extension_by_id, configured_order)
    ordered = AnalysisExtension[]
    remaining = Set(keys(extension_by_id))
    while !isempty(remaining)
        ready = sort!(collect(filter(remaining) do id
            all(dependency -> dependency ∉ remaining,
                invoke_extension_dependencies(extension_by_id[id]))
        end); by=id -> configured_order[id])
        isempty(ready) && throw(ArgumentError(
            "extension dependency cycle: $(join(sort!(collect(remaining)), ", "))"))
        for id in ready
            push!(ordered, extension_by_id[id])
            delete!(remaining, id)
        end
    end
    return ordered
end

"""Merge built-in and extension rules while recording extension ownership."""
function merged_rule_registry(extensions)
    registry = copy(RULE_REGISTRY)
    owners = Dict{String, String}()
    for extension in extensions
        id = invoke_extension_id(extension)
        rules = invoke_extension_rules(extension)
        rules isa Vector{RuleDefinition} || throw(ArgumentError(
            "extension $id rules must be Vector{RuleDefinition}"))
        for definition in rules
            haskey(registry, definition.rule_id) && throw(ArgumentError(
                "duplicate rule ID from extension $id: $(definition.rule_id)"))
            isempty(strip(definition.rule_id)) && throw(ArgumentError(
                "extension $id rule ID cannot be empty"))
            definition.language in ("common", "julia", "odin", "markdown") ||
                throw(ArgumentError(
                    "extension $id rule has unsupported language: " *
                        definition.language))
            registry[definition.rule_id] = definition
            owners[definition.rule_id] = id
        end
    end
    return registry, owners
end

"""Validate every function metric's strictly increasing response thresholds."""
function validate_function_metric_settings(settings::FunctionMetricSettings)
    for (name, thresholds) in (
        "Julia function lines" => settings.julia_lines,
        "Odin procedure lines" => settings.odin_lines,
        "Julia cyclomatic complexity" => settings.julia_cyclomatic,
        "Odin cyclomatic complexity" => settings.odin_cyclomatic)
        0 < thresholds.report < thresholds.warn < thresholds.fail ||
            throw(ArgumentError(
                "$name thresholds must increase from report to warn to fail"))
    end
    validate_reviewed_complexity(settings.reviewed)
end

"""Validate reviewed function metric policies and selector uniqueness."""
function validate_reviewed_complexity(policies)
    policy_ids = Set{String}()
    selectors = Set{Tuple{String, Symbol, String, Symbol}}()
    for policy in policies
        validate_reviewed_complexity_policy(policy)
        policy.id in policy_ids && throw(ArgumentError(
            "duplicate reviewed complexity ID: $(policy.id)"))
        push!(policy_ids, policy.id)
        selector = (
            policy.path,
            policy.language,
            policy.function_name,
            policy.metric)
        selector in selectors && throw(ArgumentError(
            "duplicate reviewed complexity selector: " *
                "$(policy.path):$(policy.function_name):$(policy.metric)"))
        push!(selectors, selector)
    end
end

"""Validate one reviewed function metric policy."""
function validate_reviewed_complexity_policy(policy)
    isempty(strip(policy.id)) && throw(ArgumentError(
        "reviewed complexity ID cannot be empty"))
    validate_repository_path(policy.path, "Reviewed complexity path")
    policy.language in (:julia, :odin) || throw(ArgumentError(
        "reviewed complexity language must be :julia or :odin"))
    isempty(strip(policy.function_name)) && throw(ArgumentError(
        "reviewed complexity function name cannot be empty"))
    policy.metric in (:executable_lines, :cyclomatic_complexity) ||
        throw(ArgumentError(
            "reviewed complexity metric must be :executable_lines or " *
                ":cyclomatic_complexity"))
    policy.response == Ignore && throw(ArgumentError(
        "reviewed complexity response cannot be Ignore"))
    policy.minimum_matches >= 1 || throw(ArgumentError(
        "reviewed complexity minimum matches must be positive"))
    policy.maximum_matches >= policy.minimum_matches || throw(ArgumentError(
        "reviewed complexity maximum matches must not be below minimum"))
    isempty(strip(policy.reason)) && throw(ArgumentError(
        "reviewed complexity reason cannot be empty"))
end

"""Validate language-specific parameter count thresholds."""
function validate_parameter_count_settings(settings::ParameterCountSettings)
    settings.julia_maximum > 0 || throw(ArgumentError(
        "Julia parameter maximum must be positive"))
    0 < settings.odin_warning < settings.odin_maximum || throw(ArgumentError(
        "Odin parameter thresholds must increase from warning to maximum"))
end

"""Validate independently configured Julia and Odin return tuple maxima."""
function validate_return_tuple_settings(settings::ReturnTupleSettings)
    settings.julia_maximum >= 1 || throw(ArgumentError(
        "Julia return tuple maximum must be positive"))
    settings.odin_maximum >= 1 || throw(ArgumentError(
        "Odin return tuple maximum must be positive"))
end

"""Validate analytical Odin build identities, paths, outputs, and compiler flags."""
function validate_odin_build_settings(settings::OdinBuildSettings)
    target_ids = Set{String}()
    output_names = Set{String}()
    for target in settings.targets
        isempty(strip(target.id)) && throw(ArgumentError(
            "Odin build target ID cannot be empty"))
        target.id in target_ids && throw(ArgumentError(
            "duplicate Odin build target ID: $(target.id)"))
        push!(target_ids, target.id)
        validate_repository_path(target.input, "Odin build input")
        invalid_output = isempty(strip(target.output_name)) ||
            basename(target.output_name) != target.output_name ||
            target.output_name in (".", "..")
        invalid_output && throw(ArgumentError(
            "Odin build output name must be a filename"))
        target.output_name in output_names && throw(ArgumentError(
            "duplicate Odin build output name: $(target.output_name)"))
        push!(output_names, target.output_name)
        isempty(target.flags) && throw(ArgumentError(
            "Odin build target must configure at least one compiler flag: $(target.id)"))
        for flag in target.flags
            startswith(flag, "-") || throw(ArgumentError(
                "Odin build flags must begin with '-': $flag"))
            startswith(flag, "-out:") && throw(ArgumentError(
                "Odin build output is controlled by output_name: $(target.id)"))
        end
    end
end

"""Validate one normalized repository-relative settings path."""
function validate_repository_path(path::String, label::String)
    invalid = isempty(strip(path)) || isabspath(path) ||
        normpath(path) != path || startswith(path, "..")
    invalid && throw(ArgumentError(
        "$label must be normalized and repository-relative"))
end

"""Validate configured JET call roots and representative argument types."""
function validate_jet_settings(settings::JetSettings)
    entry_ids = Set{String}()
    for entry in settings.entry_points
        isempty(strip(entry.id)) && throw(ArgumentError(
            "JET entry point ID cannot be empty"))
        entry.id in entry_ids && throw(ArgumentError(
            "duplicate JET entry point ID: $(entry.id)"))
        push!(entry_ids, entry.id)
        invalid_path = isempty(strip(entry.path)) || isabspath(entry.path) ||
            normpath(entry.path) != entry.path || startswith(entry.path, "..")
        invalid_path && throw(ArgumentError(
            "JET entry point path must be normalized and repository-relative"))
        all(argument_type -> argument_type isa Type, entry.argument_types) === true ||
            throw(ArgumentError(
                "JET entry point argument types must contain only types: $(entry.id)"))
    end
end

const NAMING_CASES = Set((
    :any,
    :lowercase,
    :snake_case,
    :camel_case,
    :camel_or_screaming,
    :ada_case,
    :screaming_snake_case))

const NAMING_KINDS = Dict(
    :julia => Set((:module, :type, :function, :constant, :parameter, :variable, :field)),
    :odin => Set((
        :import,
        :type,
        :enum_value,
        :procedure,
        :constant,
        :parameter,
        :variable,
        :field)))

"""Validate naming convention languages, kinds, casing, and uniqueness."""
function validate_naming_conventions(conventions)
    selectors = Set{Tuple{Symbol, Symbol}}()
    for convention in conventions
        haskey(NAMING_KINDS, convention.language) || throw(ArgumentError(
            "unsupported naming language: $(convention.language)"))
        convention.kind in NAMING_KINDS[convention.language] || throw(ArgumentError(
            "unsupported $(convention.language) naming kind: $(convention.kind)"))
        convention.casing in NAMING_CASES || throw(ArgumentError(
            "unsupported naming case: $(convention.casing)"))
        convention.allow_constructor_names &&
            (convention.language != :julia || convention.kind != :function) &&
            throw(ArgumentError(
                "constructor names are supported only for Julia functions"))
        selector = (convention.language, convention.kind)
        selector in selectors && throw(ArgumentError(
            "duplicate naming convention: $(convention.language).$(convention.kind)"))
        push!(selectors, selector)
    end
end

"""Validate one reviewed policy path as normalized and repository-relative."""
function validate_reviewed_policy_path(path, policy_kind)
    invalid_path = isempty(strip(path)) || isabspath(path) ||
        normpath(path) != path || startswith(path, "..")
    invalid_path && throw(ArgumentError(
        "reviewed $policy_kind policy path must be normalized and repository-relative"))
end

"""Validate fields and match bounds for one reviewed naming policy."""
function validate_reviewed_naming_policy(policy)
    isempty(strip(policy.id)) && throw(ArgumentError(
        "reviewed naming policy ID cannot be empty"))
    haskey(NAMING_KINDS, policy.language) || throw(ArgumentError(
        "unsupported reviewed naming language: $(policy.language)"))
    policy.kind in NAMING_KINDS[policy.language] || throw(ArgumentError(
        "unsupported reviewed $(policy.language) naming kind: $(policy.kind)"))
    validate_reviewed_policy_path(policy.path, "naming")
    isempty(strip(policy.name)) && throw(ArgumentError(
        "reviewed naming name cannot be empty"))
    isempty(strip(policy.reason)) && throw(ArgumentError(
        "reviewed naming reason cannot be empty"))
    policy.response == Ignore && throw(ArgumentError(
        "reviewed naming response cannot be Ignore"))
    policy.minimum_matches >= 1 || throw(ArgumentError(
        "reviewed naming minimum matches must be positive"))
    policy.maximum_matches >= policy.minimum_matches || throw(ArgumentError(
        "reviewed naming maximum matches must not be below minimum"))
end

"""Validate reviewed naming policies and collection-wide uniqueness."""
function validate_reviewed_naming_policies(policies)
    policy_ids = Set{String}()
    policy_selectors = Set{Tuple{String, Symbol, Symbol, String}}()
    for policy in policies
        validate_reviewed_naming_policy(policy)
        policy.id in policy_ids && throw(ArgumentError(
            "duplicate reviewed naming policy ID: $(policy.id)"))
        push!(policy_ids, policy.id)
        selector = (policy.path, policy.language, policy.kind, policy.name)
        selector in policy_selectors && throw(ArgumentError(
            "duplicate reviewed naming selector: $(policy.path):$(policy.name)"))
        push!(policy_selectors, selector)
    end
end

"""Validate naming conventions and reviewed naming policies."""
function validate_naming_settings(settings::NamingSettings)
    validate_naming_conventions(settings.conventions)
    validate_reviewed_naming_policies(settings.reviewed_policies)
end

"""Return whether an identifier complies with one naming convention."""
function valid_identifier_name(name::AbstractString, convention::NamingConvention)
    name in convention.ignored_names && return true
    any(pattern -> occursin(pattern, name), convention.ignored_patterns) && return true
    candidate = String(name)
    if convention.allow_trailing_bang && endswith(candidate, '!')
        candidate = chop(candidate)
    end
    if convention.allow_leading_underscore
        candidate = lstrip(candidate, '_')
    end
    isempty(candidate) && return name == "_"
    patterns = Dict(
        :any => r"^.*$",
        :lowercase => r"^[a-z][a-z0-9_]*$",
        :snake_case => r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$",
        :camel_case => r"^[A-Z][A-Za-z0-9]*$",
        :camel_or_screaming => r"^(?:[A-Z][A-Za-z0-9]*|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*)$",
        :ada_case => r"^[A-Z][a-z0-9]*(?:_[A-Z][a-z0-9]*)*$",
        :screaming_snake_case => r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*$")
    return occursin(patterns[convention.casing], candidate)
end

const ALLOCATION_CATEGORIES = Set((
    :implicit,
    :unknown,
    :context,
    :heap,
    :temporary,
    :custom,
    :dynamic_growth,
    :arena,
    :hidden))

"""Validate known allocating procedure identities and certainty values."""
function validate_known_allocating_procedures(procedures)
    procedure_subjects = Set{String}()
    for procedure in procedures
        isempty(strip(procedure.subject)) && throw(ArgumentError(
            "known allocating procedure subject cannot be empty"))
        procedure.certainty in (:definite, :potential) || throw(ArgumentError(
            "allocation certainty must be :definite or :potential"))
        procedure.subject in procedure_subjects && throw(ArgumentError(
            "duplicate known allocating procedure: $(procedure.subject)"))
        push!(procedure_subjects, procedure.subject)
    end
end

"""Validate allocator source pattern categories and uniqueness."""
function validate_allocator_source_patterns(patterns)
    pattern_sources = Set{String}()
    for pattern in patterns
        pattern.category in ALLOCATION_CATEGORIES || throw(ArgumentError(
            "unknown allocator source category: $(pattern.category)"))
        pattern.category in (:context, :heap, :temporary, :custom) ||
            throw(ArgumentError(
                "allocator source patterns require an explicit-source category"))
        isempty(strip(pattern.source)) && throw(ArgumentError(
            "allocator source pattern cannot be empty"))
        pattern.source in pattern_sources && throw(ArgumentError(
            "duplicate allocator source pattern: $(pattern.source)"))
        push!(pattern_sources, pattern.source)
    end
end

"""Validate the fields and match bounds of one reviewed allocation policy."""
function validate_reviewed_allocation_policy(policy)
    isempty(strip(policy.id)) && throw(ArgumentError(
        "reviewed allocation policy ID cannot be empty"))
    policy.category in ALLOCATION_CATEGORIES || throw(ArgumentError(
        "unknown reviewed allocation category: $(policy.category)"))
    validate_reviewed_policy_path(policy.path, "allocation")
    isempty(strip(policy.procedure)) && throw(ArgumentError(
        "reviewed allocation procedure cannot be empty"))
    isempty(strip(policy.reason)) && throw(ArgumentError(
        "reviewed allocation reason cannot be empty"))
    policy.response == Ignore && throw(ArgumentError(
        "reviewed allocation response cannot be Ignore"))
    policy.certainty === nothing || policy.certainty in (:definite, :potential) ||
        throw(ArgumentError("reviewed allocation certainty is invalid"))
    policy.minimum_matches >= 1 || throw(ArgumentError(
        "reviewed allocation minimum matches must be positive"))
    policy.maximum_matches >= policy.minimum_matches || throw(ArgumentError(
        "reviewed allocation maximum matches must not be below minimum"))
    validate_allocation_selector_values(policy)
end

"""Validate optional string fields used to select reviewed allocations."""
function validate_allocation_selector_values(policy)
    for (label, value) in (("operation", policy.operation),
        ("target", policy.target), ("allocator source", policy.allocator_source))
        value === nothing || !isempty(strip(value)) || throw(ArgumentError(
            "reviewed allocation $label cannot be empty"))
    end
end

"""Return the fields that uniquely identify a reviewed allocation selector."""
allocation_policy_selector(policy) = (
    path=policy.path,
    procedure=policy.procedure,
    category=policy.category,
    operation=policy.operation,
    target=policy.target,
    allocator_source=policy.allocator_source,
    certainty=policy.certainty)

"""Validate reviewed allocation policies and collection-wide uniqueness."""
function validate_reviewed_allocation_policies(policies)
    policy_ids = Set{String}()
    policy_selectors = Set{NamedTuple}()
    for policy in policies
        validate_reviewed_allocation_policy(policy)
        policy.id in policy_ids && throw(ArgumentError(
            "duplicate reviewed allocation policy ID: $(policy.id)"))
        push!(policy_ids, policy.id)
        selector = allocation_policy_selector(policy)
        selector in policy_selectors && throw(ArgumentError(
            "duplicate reviewed allocation selector: $(policy.path):$(policy.procedure)"))
        push!(policy_selectors, selector)
    end
end

"""Validate allocation procedures, source patterns, and reviewed policies."""
function validate_allocation_settings(settings::AllocationSettings)
    validate_known_allocating_procedures(settings.known_procedures)
    validate_allocator_source_patterns(settings.source_patterns)
    validate_reviewed_allocation_policies(settings.reviewed_policies)
end

"""Validate ordering and bounds for configured analysis thresholds."""
function validate_thresholds(thresholds::AnalysisThresholds)
    thresholds.line_warning < thresholds.line_discouraged < thresholds.line_hard ||
        throw(ArgumentError("line thresholds must increase from warning to hard"))
    thresholds.executable_lines_review < thresholds.executable_lines_maximum ||
        throw(ArgumentError("executable-line review threshold must be below maximum"))
    thresholds.cyclomatic_warning < thresholds.cyclomatic_error ||
        throw(ArgumentError("cyclomatic warning threshold must be below error"))
    thresholds.cognitive_maximum > 0 ||
        throw(ArgumentError("cognitive maximum must be positive"))
    thresholds.parameters_maximum > 0 ||
        throw(ArgumentError("parameter maximum must be positive"))
end

"""Validate scan profiles and return a name-indexed profile map."""
function validate_profiles(profile_settings::Vector{ScanProfile})
    profiles = Dict{Symbol, ScanProfile}()
    for profile in profile_settings
        haskey(profiles, profile.name) && throw(ArgumentError(
            "duplicate analysis profile: $(profile.name)"))
        profiles[profile.name] = profile
    end
    return profiles
end

"""Validate rule settings and return a rule-id-indexed map."""
function validate_rule_settings(
    rule_settings::Vector{RuleSetting},
    registry=RULE_REGISTRY)
    rules = Dict{String, RuleSetting}()
    for setting in rule_settings
        haskey(registry, setting.rule_id) || throw(ArgumentError(
            "unknown rule ID: $(setting.rule_id)"))
        haskey(rules, setting.rule_id) && throw(ArgumentError(
            "duplicate rule setting: $(setting.rule_id)"))
        definition = registry[setting.rule_id]
        invalid_immutable = definition.immutable_activation &&
            (!setting.enabled || setting.response != Fail)
        if invalid_immutable
            throw(ArgumentError("$(setting.rule_id) must remain enabled at Fail"))
        end
        if definition.capability == "unavailable" && setting.enabled
            throw(ArgumentError(
                "$(setting.rule_id) is not implemented and cannot be enabled"))
        end
        rules[setting.rule_id] = setting
    end
    missing = sort!(collect(setdiff(keys(registry), keys(rules))))
    isempty(missing) || throw(ArgumentError(
        "settings file is missing rule IDs: $(join(missing, ", "))"))
    return rules
end

"""Validate report color mode and finding display limits."""
function validate_report_settings(settings::ReportSettings)
    settings.color in (:auto, :always, :never) || throw(ArgumentError(
        "report color must be :auto, :always, or :never"))
    settings.warning_limit >= 0 ||
        throw(ArgumentError("warning limit cannot be negative"))
    settings.report_limit >= 0 ||
        throw(ArgumentError("report limit cannot be negative"))
end

"""Return the lowercase serialized name of a finding response."""
function response_name(response::FindingResponse)
    return lowercase(string(response))
end

"""Apply rule enablement and response configuration to a diagnostic."""
function configured_diagnostic(settings::EffectiveSettings, diagnostic::Diagnostic)
    rule = settings.rules[diagnostic.rule_id]
    rule.enabled || return nothing
    return Diagnostic(
        diagnostic.rule_id,
        rule.response,
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
        diagnostic.reviewed_policy_id,
        diagnostic.reviewed_policy_reason)
end