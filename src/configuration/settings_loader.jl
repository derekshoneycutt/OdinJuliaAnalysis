const DEFAULT_SETTINGS_PATH = normpath(
    joinpath(@__DIR__, "..", "..", "settings.jl"))

const SECURITY_SOURCE_CATEGORIES = Set((
    :command_line, :environment, :file, :network, :interop, :user_input))
const SECURITY_SINK_CATEGORIES = Set((
    :command_execution, :path_access, :dynamic_evaluation, :unsafe_memory,
    :external_write))
const SECURITY_SANITIZER_CATEGORIES = Set((
    :validation, :escaping, :canonicalization, :allowlist))

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

const NAMING_CASES = Set((
    :any,
    :lowercase,
    :snake_case,
    :camel_case,
    :camel_or_screaming,
    :ada_case,
    :screaming_snake_case))

# Greek letters name mathematical quantities rather than words, so they carry no
# word casing and satisfy either case class.
const GREEK_LETTERS = "\u0370-\u03ff\u1f00-\u1fff"
const NAMING_LOWER = "a-z$(GREEK_LETTERS)"
const NAMING_UPPER = "A-Z$(GREEK_LETTERS)"
const NAMING_LETTER = "A-Za-z$(GREEK_LETTERS)"

const NAMING_PATTERNS = Dict(
    :any => r"^.*$",
    :lowercase => Regex("^[$NAMING_LOWER][$(NAMING_LOWER)0-9_]*\$"),
    :snake_case => Regex(
        "^[$NAMING_LOWER][$(NAMING_LOWER)0-9]*(?:_[$(NAMING_LOWER)0-9]+)*\$"),
    :camel_case => Regex("^[$NAMING_UPPER][$(NAMING_LETTER)0-9]*\$"),
    :camel_or_screaming => Regex(
        "^(?:[$NAMING_UPPER][$(NAMING_LETTER)0-9]*" *
        "|[$NAMING_UPPER][$(NAMING_UPPER)0-9]*(?:_[$(NAMING_UPPER)0-9]+)*)\$"),
    :ada_case => Regex(
        "^[$NAMING_UPPER][$(NAMING_LOWER)0-9]*" *
        "(?:_[$NAMING_UPPER][$(NAMING_LOWER)0-9]*)*\$"),
    :screaming_snake_case => Regex(
        "^[$NAMING_UPPER][$(NAMING_UPPER)0-9]*(?:_[$(NAMING_UPPER)0-9]+)*\$"))

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

const RESOURCE_OWNERSHIP_KINDS = Set((:owned, :borrowed, :shared, :external))
const RESOURCE_LIFETIME_KINDS = Set((
    :procedure, :temporary, :arena, :service, :process, :external))

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
    validate_duplicate_code_settings(settings.duplicate_code)
    validate_resource_lifetime_settings(settings.resource_lifetime)
    validate_security_settings(settings.security)
    validate_coverage_settings(settings.coverage)
    validate_documentation_settings(settings.documentation)
    validate_call_root_settings(settings.call_roots)
    validate_allocation_settings(settings.allocations)
    validate_report_settings(settings.report)
    return EffectiveSettings(selected_profile, settings.failure_threshold,
        settings.thresholds,
        copy(profiles[selected_profile].enforcement_excludes),
        rules, settings.naming, settings.jet, settings.odin_build, settings.return_tuples,
        settings.parameter_counts, settings.function_metrics, settings.architecture,
        settings.allocations, settings.report, extensions, rule_registry, rule_owners,
        settings.duplicate_code, settings.resource_lifetime, settings.security,
        settings.coverage, settings.documentation, settings.call_roots)
end

"""Reject unusable or duplicated cross-language call root entry points."""
function validate_call_root_settings(settings::CallRootSettings)
    seen = Set{String}()
    for entry in settings.entry_points
        isempty(strip(entry.id)) && throw(ArgumentError(
            "call root entry point requires an id"))
        entry.id in seen && throw(ArgumentError(
            "duplicate call root entry point: $(entry.id)"))
        push!(seen, entry.id)
        entry.language in (:julia, :odin) || throw(ArgumentError(
            "call root entry point $(entry.id) has unknown language: " *
                "$(entry.language)"))
        isempty(strip(entry.name)) && throw(ArgumentError(
            "call root entry point $(entry.id) requires a callable name"))
        isempty(strip(entry.reason)) && throw(ArgumentError(
            "call root entry point $(entry.id) requires a reason"))
    end
end

"""Reject documentation templates that can match an empty comment."""
function validate_documentation_settings(settings::DocumentationSettings)
    for (language, template) in (
    "Julia" => settings.julia_template,
    "Odin" => settings.odin_template)
    occursin(template, "") && throw(ArgumentError(
        "$language documentation template must require nonempty text"))
    end
end

"""Validate configured LCOV inputs and report presentation limits."""
function validate_coverage_settings(settings::CoverageSettings)
    settings.high_risk_limit > 0 || throw(ArgumentError(
        "coverage high-risk limit must be positive"))
    settings.enabled && isempty(settings.tracefiles) && throw(ArgumentError(
        "enabled coverage analysis requires at least one tracefile"))
    normalized = Set{String}()
    for path in settings.tracefiles
        validate_repository_path(path, "coverage tracefile")
        canonical = replace(normpath(path), '\\' => '/')
        canonical in normalized && throw(ArgumentError(
            "duplicate coverage tracefile: $canonical"))
        push!(normalized, canonical)
    end
end

"""Validate duplicate-code thresholds, exclusions, and reviewed selectors."""
function validate_duplicate_code_settings(settings::DuplicateCodeSettings)
    settings.minimum_tokens > 0 || throw(ArgumentError(
        "duplicate-code minimum tokens must be positive"))
    settings.minimum_executable_lines > 0 || throw(ArgumentError(
        "duplicate-code minimum executable lines must be positive"))
    settings.minimum_occurrences >= 2 || throw(ArgumentError(
        "duplicate-code minimum occurrences must be at least two"))
    for path in settings.excluded_paths
        validate_repository_path(path, "duplicate-code excluded path")
    end
    ids = Set{String}()
    for policy in settings.reviewed_policies
        validate_reviewed_clone_policy(policy, ids)
    end
end

"""Validate one reviewed exact-clone policy and record its ID."""
function validate_reviewed_clone_policy(policy, ids)
    isempty(strip(policy.id)) && throw(ArgumentError(
        "reviewed clone policy ID cannot be empty"))
    policy.id in ids && throw(ArgumentError(
        "duplicate reviewed clone policy ID: $(policy.id)"))
    push!(ids, policy.id)
    policy.language in (:julia, :odin) || throw(ArgumentError(
        "unsupported reviewed clone language: $(policy.language)"))
    length(policy.fingerprint) == 64 &&
        all(character -> isdigit(character) || character in 'a':'f',
            policy.fingerprint) || throw(ArgumentError(
        "reviewed clone fingerprint must be a lowercase SHA-256 value: " * policy.id))
    policy.response == Ignore && throw(ArgumentError(
        "reviewed clone response cannot be Ignore: $(policy.id)"))
    0 <= policy.minimum_matches <= policy.maximum_matches || throw(ArgumentError(
        "invalid reviewed clone match bounds: $(policy.id)"))
    isempty(strip(policy.reason)) && throw(ArgumentError(
        "reviewed clone reason cannot be empty: $(policy.id)"))
end

"""Validate configured ownership and lifetime contracts."""
function validate_resource_lifetime_settings(settings::ResourceLifetimeSettings)
    ids = Set{String}()
    selectors = Set{NamedTuple}()
    for contract in settings.contracts
        validate_resource_lifetime_contract(contract)
        contract.id in ids && throw(ArgumentError(
            "duplicate resource lifetime contract ID: $(contract.id)"))
        push!(ids, contract.id)
        selector = (
            category=contract.category,
            operation=contract.operation,
            allocator_source=contract.allocator_source)
        selector in selectors && throw(ArgumentError(
            "duplicate resource lifetime selector: $(contract.id)"))
        push!(selectors, selector)
    end
end

"""Validate one ownership and lifetime contract."""
function validate_resource_lifetime_contract(contract)
    isempty(strip(contract.id)) && throw(ArgumentError(
        "resource lifetime contract ID cannot be empty"))
    contract.category in ALLOCATION_CATEGORIES || throw(ArgumentError(
        "unknown resource lifetime category: $(contract.category)"))
    contract.ownership in RESOURCE_OWNERSHIP_KINDS || throw(ArgumentError(
        "unknown resource ownership: $(contract.ownership)"))
    contract.lifetime in RESOURCE_LIFETIME_KINDS || throw(ArgumentError(
        "unknown resource lifetime: $(contract.lifetime)"))
    isempty(strip(contract.reason)) && throw(ArgumentError(
        "resource lifetime contract reason cannot be empty: $(contract.id)"))
    for (label, value) in (("operation", contract.operation),
        ("allocator source", contract.allocator_source),
        ("release operation", contract.release_operation))
        value === nothing || !isempty(strip(value)) || throw(ArgumentError(
            "resource lifetime $label cannot be empty: $(contract.id)"))
    end
end

"""Validate typed security source, sink, and sanitizer contracts."""
function validate_security_settings(settings::SecuritySettings)
    ids = Set{String}()
    selectors = Set{Tuple{Symbol, String, Symbol}}()
    groups = (
        ("source", settings.sources, SECURITY_SOURCE_CATEGORIES),
        ("sink", settings.sinks, SECURITY_SINK_CATEGORIES),
        ("sanitizer", settings.sanitizers, SECURITY_SANITIZER_CATEGORIES))
    for (kind, contracts, categories) in groups
        for contract in contracts
            isempty(strip(contract.id)) && throw(ArgumentError(
                "security $kind contract ID cannot be empty"))
            contract.id in ids && throw(ArgumentError(
                "duplicate security contract ID: $(contract.id)"))
            push!(ids, contract.id)
            contract.language in (:julia, :odin) || throw(ArgumentError(
                "unsupported security contract language: $(contract.language)"))
            isempty(strip(contract.declaration)) && throw(ArgumentError(
                "security $kind declaration cannot be empty: $(contract.id)"))
            contract.category in categories || throw(ArgumentError(
                "unsupported security $kind category: $(contract.category)"))
            isempty(strip(contract.reason)) && throw(ArgumentError(
                "security $kind reason cannot be empty: $(contract.id)"))
            selector = (contract.language, contract.declaration, contract.category)
            selector in selectors && throw(ArgumentError(
                "duplicate security contract selector: $(contract.id)"))
            push!(selectors, selector)
        end
    end
end

"""Validate extension contracts and return deterministic dependency order."""
function validate_extensions(extensions)
    extension_by_id = Dict{String, AnalysisExtension}()
    configured_order = Dict{String, Int}()
    for (index, extension) in enumerate(extensions)
        id = invoke_extension_id(extension)
        validate_extension_contract(extension, id)
        haskey(extension_by_id, id) && throw(ArgumentError(
            "duplicate extension ID: $id"))
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

"""Validate one extension's identity, API version, and lifecycle phases."""
function validate_extension_contract(extension, id)
    isempty(strip(id)) && throw(ArgumentError("extension ID cannot be empty"))
    version = invoke_extension_api_version(extension)
    version == EXTENSION_API_VERSION || throw(ArgumentError(
        "extension $id requires API $version; " *
            "analyzer provides $EXTENSION_API_VERSION"))
    phases = invoke_extension_phases(extension)
    isempty(phases) && throw(ArgumentError(
        "extension $id must declare at least one phase"))
    all(phase -> phase isa AnalysisPhase, phases) || throw(ArgumentError(
        "extension $id declares an unsupported phase"))
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
    policy.minimum_matches >= 0 || throw(ArgumentError(
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
        validate_odin_build_target(target)
        target.id in target_ids && throw(ArgumentError(
            "duplicate Odin build target ID: $(target.id)"))
        push!(target_ids, target.id)
        target.output_name in output_names && throw(ArgumentError(
            "duplicate Odin build output name: $(target.output_name)"))
        push!(output_names, target.output_name)
    end
end

"""Validate one analytical Odin build target."""
function validate_odin_build_target(target)
    isempty(strip(target.id)) && throw(ArgumentError(
        "Odin build target ID cannot be empty"))
    validate_repository_path(target.input, "Odin build input")
    invalid_output = isempty(strip(target.output_name)) ||
        basename(target.output_name) != target.output_name ||
        target.output_name in (".", "..")
    invalid_output && throw(ArgumentError(
        "Odin build output name must be a filename"))
    isempty(target.flags) && throw(ArgumentError(
        "Odin build target must configure at least one compiler flag: $(target.id)"))
    for flag in target.flags
        startswith(flag, "-") || throw(ArgumentError(
            "Odin build flags must begin with '-': $flag"))
        startswith(flag, "-out:") && throw(ArgumentError(
            "Odin build output is controlled by output_name: $(target.id)"))
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
    policy.minimum_matches >= 0 || throw(ArgumentError(
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
    return occursin(NAMING_PATTERNS[convention.casing], candidate)
end

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
    policy.certainty === nothing || policy.certainty in (:definite, :potential) ||
        throw(ArgumentError("reviewed allocation certainty is invalid"))
    policy.minimum_matches >= 0 || throw(ArgumentError(
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
    response = staging_response(settings.report, diagnostic.path, rule.response)
    return diagnostic_with_response(diagnostic, response)
end

"""Copy a diagnostic while replacing only its response."""
function diagnostic_with_response(
    diagnostic::Diagnostic,
    response::FindingResponse)
    return Diagnostic(
        diagnostic.rule_id,
        response,
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

"""Apply the staging response ceiling to a collection of diagnostics."""
function cap_staging_responses!(
    diagnostics::Vector{Diagnostic},
    settings::ReportSettings)
    for index in eachindex(diagnostics)
        diagnostic = diagnostics[index]
        response = staging_response(settings, diagnostic.path, diagnostic.response)
        if response != diagnostic.response
            diagnostics[index] = diagnostic_with_response(diagnostic, response)
        end
    end
    return diagnostics
end

"""Cap one response when its path belongs to staging content."""
function staging_response(
    settings::ReportSettings,
    path::String,
    response::FindingResponse)
    is_staging_path(path) || return response
    return FindingResponse(min(
        Int(response), Int(settings.staging_maximum_response)))
end

"""Return whether a file is named or nested beneath a `staging_` path component."""
function is_staging_path(path::String)
    return any(component -> startswith(component, "staging_"), splitpath(path))
end