"""Apply reviewed function metric policies and report stale or ambiguous matches."""
function apply_reviewed_complexity!(
    diagnostics::Vector{Diagnostic},
    root::String,
    files::Vector{String},
    configuration::EffectiveSettings)
    scanned_paths = Set(
        replace(relpath(abspath(path), abspath(root)), '\\' => '/')
        for path in files)
    policies = filter(
        policy -> policy.path in scanned_paths,
        configuration.function_metrics.reviewed)
    isempty(policies) && return diagnostics

    match_counts = zeros(Int, length(policies))
    drift = Diagnostic[]
    for index in eachindex(diagnostics)
        diagnostic = diagnostics[index]
        diagnostic.source in ("function-metrics", "odin-ast") || continue
        policy_indices = findall(
            policy -> reviewed_complexity_matches(policy, diagnostic),
            policies)
        for policy_index in policy_indices
            match_counts[policy_index] += 1
        end
        if length(policy_indices) == 1
            diagnostics[index] = apply_reviewed_complexity(
                diagnostic,
                policies[only(policy_indices)])
        elseif length(policy_indices) > 1
            policy_ids = join((policies[item].id for item in policy_indices), ", ")
            push!(drift, function_metric_policy_drift(
                diagnostic.path,
                diagnostic.line,
                diagnostic.column,
                "Function metric matches multiple reviewed policies: $policy_ids."))
        end
    end

    append_reviewed_complexity_drift!(drift, policies, match_counts)
    append!(diagnostics, drift)
    return diagnostics
end

"""Append drift diagnostics for reviewed function metric match counts."""
function append_reviewed_complexity_drift!(drift, policies, match_counts)
    for (policy, count) in zip(policies, match_counts)
        if count < policy.minimum_matches || count > policy.maximum_matches
            message = "Reviewed complexity $(policy.id) expected " *
                "$(policy.minimum_matches)-$(policy.maximum_matches) matches, " *
                "found $count."
            push!(drift, function_metric_policy_drift(policy.path, 1, 1, message))
        end
    end
end

"""Return whether a function metric diagnostic matches one reviewed selector."""
function reviewed_complexity_matches(policy, diagnostic::Diagnostic)
    return diagnostic.path == policy.path &&
        diagnostic.subject == policy.function_name &&
        diagnostic.operation == string(policy.metric) &&
        startswith(diagnostic.rule_id, uppercase(string(policy.language)) * "-")
end

"""Apply one reviewed response and attach its review evidence."""
function apply_reviewed_complexity(diagnostic::Diagnostic, policy)
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

"""Create a diagnostic describing reviewed function metric policy drift."""
function function_metric_policy_drift(path, line, column, message)
    return Diagnostic(
        "FUNCTION-METRIC-POLICY-DRIFT",
        Fail,
        path,
        line,
        column,
        message,
        nothing,
        nothing,
        "reviewed-complexity")
end
