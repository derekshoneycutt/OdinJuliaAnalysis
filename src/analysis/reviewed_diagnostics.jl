"""Apply exact reviewed-diagnostic policies and report stale or ambiguous reviews."""
function apply_reviewed_diagnostic_policies!(
    diagnostics::Vector{Diagnostic},
    root::String,
    files::Vector{String},
    configuration::EffectiveSettings)
    scanned_paths = Set(
        replace(relpath(abspath(path), abspath(root)), '\\' => '/')
        for path in files)
    policies = filter(
        policy -> policy.path in scanned_paths,
        configuration.report.reviewed_diagnostics)
    isempty(policies) && return diagnostics

    match_counts = zeros(Int, length(policies))
    drift = Diagnostic[]
    for index in eachindex(diagnostics)
        diagnostic = diagnostics[index]
        diagnostic.reviewed_policy_id === nothing || continue
        policy_indices = findall(
            policy -> reviewed_diagnostic_matches(policy, diagnostic), policies)
        for policy_index in policy_indices
            match_counts[policy_index] += 1
        end
        if length(policy_indices) == 1
            diagnostics[index] = apply_reviewed_diagnostic_policy(
                diagnostic, policies[only(policy_indices)])
        elseif length(policy_indices) > 1
            policy_ids = join((policies[item].id for item in policy_indices), ", ")
            push!(drift, reviewed_diagnostic_policy_drift(
                diagnostic.path, diagnostic.line, diagnostic.column,
                "Diagnostic matches multiple reviewed policies: $policy_ids."))
        end
    end
    append_reviewed_diagnostic_drift!(drift, policies, match_counts)
    append!(diagnostics, drift)
    return diagnostics
end

"""Return whether one diagnostic matches an exact reviewed selector."""
function reviewed_diagnostic_matches(policy, diagnostic::Diagnostic)
    return diagnostic.rule_id == policy.rule_id &&
        diagnostic.path == policy.path &&
        diagnostic.subject == policy.subject
end

"""Attach one reviewed decision and its evidence to a diagnostic."""
function apply_reviewed_diagnostic_policy(diagnostic::Diagnostic, policy)
    return Diagnostic(
        diagnostic.rule_id, policy.response, diagnostic.path,
        diagnostic.line, diagnostic.column, diagnostic.message,
        diagnostic.measured, diagnostic.allowed, diagnostic.source,
        diagnostic.subject, diagnostic.operation, diagnostic.allocator_source,
        diagnostic.certainty, diagnostic.procedure, diagnostic.allocation_target,
        policy.id, policy.reason)
end

"""Append drift findings for reviewed policies outside their match bounds."""
function append_reviewed_diagnostic_drift!(drift, policies, match_counts)
    for (policy, count) in zip(policies, match_counts)
        if count < policy.minimum_matches || count > policy.maximum_matches
            message = "Reviewed diagnostic $(policy.id) expected " *
                "$(policy.minimum_matches)-$(policy.maximum_matches) matches, " *
                "found $count."
            push!(drift, reviewed_diagnostic_policy_drift(
                policy.path, 1, 1, message))
        end
    end
end

"""Create a fail-level reviewed-diagnostic policy drift finding."""
function reviewed_diagnostic_policy_drift(path, line, column, message)
    return Diagnostic(
        "REVIEWED-DIAGNOSTIC-POLICY-DRIFT", Fail, path, line, column,
        message, nothing, nothing, "reviewed-diagnostic-policy")
end