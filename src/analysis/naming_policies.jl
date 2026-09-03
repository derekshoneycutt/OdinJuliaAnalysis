"""Remove Julia constructor naming findings backed by declared repository types."""
function apply_constructor_naming_convention!(
    diagnostics,
    declarations,
    configuration)
    convention = findfirst(
        item -> item.language == :julia && item.kind == :function,
        configuration.naming.conventions)
    convention === nothing && return diagnostics
    configuration.naming.conventions[convention].allow_constructor_names ||
        return diagnostics
    type_names = Set(
        declaration.name
        for declaration in declarations
        if declaration.language == "julia" && declaration.kind == "type")
    filter!(diagnostic ->
        diagnostic.rule_id != "JULIA-NAMING" ||
            diagnostic.operation != "function" ||
            !(diagnostic.subject in type_names),
        diagnostics)
    return diagnostics
end

"""Apply reviewed naming policies and report stale or ambiguous policy matches."""
function apply_reviewed_naming_policies!(
    diagnostics::Vector{Diagnostic},
    root::String,
    files::Vector{String},
    configuration::EffectiveSettings)
    scanned_paths = Set(
        replace(relpath(abspath(path), abspath(root)), '\\' => '/')
        for path in files)
    policies = filter(
        policy -> policy.path in scanned_paths,
        configuration.naming.reviewed_policies)
    isempty(policies) && return diagnostics

    match_counts = zeros(Int, length(policies))
    drift = Diagnostic[]
    for index in eachindex(diagnostics)
        diagnostic = diagnostics[index]
        diagnostic.rule_id in ("JULIA-NAMING", "ODIN-NAMING") || continue
        policy_indices = findall(
            policy -> naming_policy_matches(policy, diagnostic),
            policies)
        for policy_index in policy_indices
            match_counts[policy_index] += 1
        end
        if length(policy_indices) == 1
            diagnostics[index] = apply_reviewed_naming_policy(
                diagnostic,
                policies[only(policy_indices)])
        elseif length(policy_indices) > 1
            policy_ids = join((policies[item].id for item in policy_indices), ", ")
            push!(drift, naming_policy_drift_diagnostic(
                diagnostic.path,
                diagnostic.line,
                diagnostic.column,
                "Naming finding matches multiple reviewed policies: $policy_ids."))
        end
    end

    append_naming_policy_count_drift!(drift, policies, match_counts)
    append!(diagnostics, drift)
    return diagnostics
end

"""Append drift diagnostics for reviewed naming policy match counts."""
function append_naming_policy_count_drift!(drift, policies, match_counts)
    for (policy, count) in zip(policies, match_counts)
        if count < policy.minimum_matches || count > policy.maximum_matches
            message = "Reviewed naming policy $(policy.id) expected " *
                "$(policy.minimum_matches)-$(policy.maximum_matches) matches, " *
                "found $count."
            push!(drift, naming_policy_drift_diagnostic(policy.path, 1, 1, message))
        end
    end
end

"""Return whether a naming diagnostic satisfies one exact reviewed selector."""
function naming_policy_matches(policy, diagnostic::Diagnostic)
    expected_rule = "$(uppercase(string(policy.language)))-NAMING"
    return diagnostic.rule_id == expected_rule &&
        diagnostic.path == policy.path &&
        diagnostic.operation == string(policy.kind) &&
        diagnostic.subject == policy.name
end

"""Attach a reviewed naming decision to one diagnostic."""
function apply_reviewed_naming_policy(diagnostic::Diagnostic, policy)
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

"""Create a diagnostic describing reviewed naming policy drift."""
function naming_policy_drift_diagnostic(path, line, column, message)
    return Diagnostic(
        "NAMING-POLICY-DRIFT",
        Fail,
        path,
        line,
        column,
        message,
        nothing,
        nothing,
        "reviewed-naming-policy")
end