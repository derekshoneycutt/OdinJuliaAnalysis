using SHA

const CloneCandidate = @NamedTuple begin
    occurrence::CloneOccurrence
    canonical_body::String
    token_count::Int
    executable_lines::Int
end

"""Group exact same-language canonical function bodies deterministically."""
function exact_clone_groups(candidates; minimum_occurrences=2)
    buckets = Dict{Tuple{String, String}, Vector{CloneCandidate}}()
    for candidate in candidates
        fingerprint = bytes2hex(sha256(candidate.canonical_body))
        key = (candidate.occurrence.language, fingerprint)
        push!(get!(buckets, key, CloneCandidate[]), candidate)
    end
    groups = CloneGroup[]
    for ((language, fingerprint), bucket) in buckets
        length(bucket) >= minimum_occurrences || continue
        bodies = Set(candidate.canonical_body for candidate in bucket)
        length(bodies) == 1 || continue
        sort!(bucket; by=candidate -> join((
            candidate.occurrence.path,
            string(candidate.occurrence.start_line),
            candidate.occurrence.declaration), '\0'))
        push!(groups, CloneGroup(
            fingerprint,
            language,
            first(bucket).token_count,
            first(bucket).executable_lines,
            [candidate.occurrence for candidate in bucket]))
    end
    sort!(groups; by=group -> (group.language, group.fingerprint))
    return groups
end

"""Filter configured candidates, group exact bodies, and create group findings."""
function analyze_duplicate_code(candidates, configuration)
    settings = configuration.duplicate_code
    settings.enabled || return CloneGroup[], Diagnostic[]
    eligible = filter(candidates) do candidate
        candidate.token_count >= settings.minimum_tokens &&
            candidate.executable_lines >= settings.minimum_executable_lines &&
            !any(prefix -> candidate.occurrence.path == prefix ||
                startswith(candidate.occurrence.path, prefix * "/"),
                settings.excluded_paths)
    end
    groups = exact_clone_groups(
        eligible; minimum_occurrences=settings.minimum_occurrences)
    diagnostics = Diagnostic[]
    for group in groups
        occurrence = first(group.occurrences)
        rule_id = group.language == "julia" ?
            "JULIA-DUPLICATE-CODE" : "ODIN-DUPLICATE-CODE"
        diagnostic = Diagnostic(
            rule_id, Ignore, occurrence.path, occurrence.start_line, 1,
            "Exact implementation clone appears $(length(group.occurrences)) times.",
            group.token_count, settings.minimum_tokens, "duplicate-code",
            group.fingerprint, "exact-clone", nothing, "definite")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    apply_reviewed_clone_policies!(diagnostics, settings.reviewed_policies)
    return groups, diagnostics
end

"""Apply reviewed clone responses and report stale or ambiguous policies."""
function apply_reviewed_clone_policies!(diagnostics, policies)
    isempty(policies) && return diagnostics
    match_counts = zeros(Int, length(policies))
    drift = Diagnostic[]
    for index in eachindex(diagnostics)
        diagnostic = diagnostics[index]
        diagnostic.source == "duplicate-code" || continue
        policy_indices = findall(
            policy -> reviewed_clone_matches(policy, diagnostic),
            policies)
        for policy_index in policy_indices
            match_counts[policy_index] += 1
        end
        if length(policy_indices) == 1
            diagnostics[index] = apply_reviewed_clone_policy(
                diagnostic, policies[only(policy_indices)])
        elseif length(policy_indices) > 1
            policy_ids = join((policies[item].id for item in policy_indices), ", ")
            push!(drift, duplicate_code_policy_drift(
                diagnostic.path,
                diagnostic.line,
                "Exact clone matches multiple reviewed policies: $policy_ids."))
        end
    end
    append_reviewed_clone_drift!(drift, policies, match_counts)
    append!(diagnostics, drift)
    return diagnostics
end

"""Return whether an exact-clone finding satisfies one reviewed selector."""
function reviewed_clone_matches(policy, diagnostic)
    expected_rule = "$(uppercase(string(policy.language)))-DUPLICATE-CODE"
    return diagnostic.rule_id == expected_rule &&
        diagnostic.subject == policy.fingerprint
end

"""Attach a reviewed clone decision to one diagnostic."""
function apply_reviewed_clone_policy(diagnostic, policy)
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

"""Append drift diagnostics for reviewed exact-clone match counts."""
function append_reviewed_clone_drift!(drift, policies, match_counts)
    for (policy, count) in zip(policies, match_counts)
        if count < policy.minimum_matches || count > policy.maximum_matches
            message = "Reviewed clone policy $(policy.id) expected " *
                "$(policy.minimum_matches)-$(policy.maximum_matches) matches, " *
                "found $count."
            push!(drift, duplicate_code_policy_drift(".", 1, message))
        end
    end
end

"""Create a diagnostic describing reviewed exact-clone policy drift."""
function duplicate_code_policy_drift(path, line, message)
    return Diagnostic(
        "DUPLICATE-CODE-POLICY-DRIFT",
        Fail,
        path,
        line,
        1,
        message,
        nothing,
        nothing,
        "reviewed-clone-policy")
end