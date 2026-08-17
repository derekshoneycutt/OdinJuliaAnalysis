"""Build configured ownership and lifetime summaries from allocation events."""
function analyze_resource_lifetimes(events, configuration)
    settings = configuration.resource_lifetime
    settings.enabled || return ResourceLifetimeSummary[], "not-applicable"
    summaries = ResourceLifetimeSummary[]
    for event in events
        category = allocation_event_category(event)
        matches = filter(
            contract -> resource_contract_matches(contract, category, event),
            settings.contracts)
        push!(summaries, resource_lifetime_summary(event, category, matches))
    end
    sort!(summaries; by=summary -> join((
        summary.path,
        string(summary.line),
        something(summary.procedure, "")), '\0'))
    status = any(summary -> summary.status != "complete", summaries) ?
        "incomplete" : "complete"
    return summaries, status
end

"""Extract the allocation category from one parser-backed event."""
function allocation_event_category(event)
    suffix = replace(event.rule_id, "ODIN-ALLOCATION-" => "")
    return Symbol(lowercase(replace(suffix, '-' => '_')))
end

"""Return whether a configured contract selects one allocation event."""
function resource_contract_matches(contract, category, event)
    return contract.category == category &&
        (contract.operation === nothing || contract.operation == event.operation) &&
        (contract.allocator_source === nothing ||
            contract.allocator_source == event.allocator_source)
end

"""Create a complete, unresolved, or ambiguous lifetime summary."""
function resource_lifetime_summary(event, category, matches)
    if length(matches) == 1
        contract = only(matches)
        return ResourceLifetimeSummary(
            event.path,
            event.line,
            event.procedure,
            event.operation,
            event.allocation_target,
            event.allocator_source,
            string(category),
            contract.id,
            string(contract.ownership),
            string(contract.lifetime),
            contract.release_operation,
            contract.allows_escape,
            event.certainty,
            "complete",
            contract.reason)
    end
    status = isempty(matches) ? "unresolved" : "ambiguous"
    explanation = isempty(matches) ?
        "No configured resource lifetime contract matched this allocation." :
        "Multiple resource lifetime contracts matched: " *
            join((contract.id for contract in matches), ", ") * "."
    return ResourceLifetimeSummary(
        event.path,
        event.line,
        event.procedure,
        event.operation,
        event.allocation_target,
        event.allocator_source,
        string(category),
        nothing,
        "unknown",
        "unknown",
        nothing,
        nothing,
        event.certainty,
        status,
        explanation)
end