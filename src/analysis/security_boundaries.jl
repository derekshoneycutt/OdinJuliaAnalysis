struct SecurityBoundaryAnalysis
    paths::Vector{SecurityBoundaryPath}
    diagnostics::Vector{Diagnostic}
    status::String
end

"""Find configured source-before-sink call paths within one declaration."""
function analyze_security_boundaries(call_edges, configuration)
    settings = configuration.security
    settings.enabled || return SecurityBoundaryAnalysis(
        SecurityBoundaryPath[], Diagnostic[], "not-applicable")
    paths = SecurityBoundaryPath[]
    for language in ("julia", "odin")
        language_edges = filter(edge -> edge.language == language, call_edges)
        caller_names = [terminal_call_name(edge.caller) for edge in language_edges]
        callers = sort!(unique(filter(!isempty, caller_names)))
        for caller in callers
            caller_edges = filter(
                edge -> terminal_call_name(edge.caller) == caller,
                language_edges)
            append!(paths, security_paths_for_caller(
                caller, caller_edges, settings))
        end
    end
    unique!(security_path_key, paths)
    sort!(paths; by=security_path_key)
    diagnostics = security_boundary_diagnostics(paths, configuration)
    incomplete = any(edge -> edge.kind == "dynamic", call_edges)
    return SecurityBoundaryAnalysis(
        paths, diagnostics, incomplete ? "incomplete" : "complete")
end

"""Build all ordered configured boundary paths for one declaration."""
function security_paths_for_caller(caller, edges, settings)
    paths = SecurityBoundaryPath[]
    sources = security_contract_calls(edges, settings.sources)
    sinks = security_contract_calls(edges, settings.sinks)
    sanitizers = security_contract_calls(edges, settings.sanitizers)
    for (source_edge, source_contract) in sources
        for (sink_edge, sink_contract) in sinks
            call_position(source_edge) < call_position(sink_edge) || continue
            observed = sort!([contract.id for (edge, contract) in sanitizers
                if call_position(source_edge) < call_position(edge) <
                    call_position(sink_edge)])
            push!(paths, SecurityBoundaryPath(
                source_edge.source_path,
                source_edge.language,
                caller,
                source_contract.id,
                source_edge.callee,
                string(source_contract.category),
                source_edge.line,
                sink_contract.id,
                sink_edge.callee,
                string(sink_contract.category),
                sink_edge.line,
                observed,
                "potential",
                security_path_explanation(source_contract, sink_contract, observed)))
        end
    end
    return paths
end

"""Pair call edges with every exact configured contract they satisfy."""
function security_contract_calls(edges, contracts)
    return [(edge, contract) for edge in edges for contract in contracts
        if contract.language == Symbol(edge.language) &&
            security_call_matches(edge.callee, contract.declaration)]
end

"""Match qualified declarations exactly and unqualified declarations by terminal name."""
function security_call_matches(call, declaration)
    occursin('.', declaration) && return call == declaration
    return terminal_call_name(call) == declaration
end

"""Return a stable source position for ordering calls."""
call_position(edge) = (line=edge.line, column=edge.column)

"""Explain the evidence and limitations of one configured path."""
function security_path_explanation(source, sink, sanitizers)
    observed = isempty(sanitizers) ? "No configured sanitizer call was observed." :
        "Observed sanitizer calls: $(join(sanitizers, ", "))."
    return "Configured source $(source.id) precedes sink $(sink.id) in one " *
        "declaration. $observed Argument flow is not yet proven."
end

"""Create configured potential findings for boundary paths."""
function security_boundary_diagnostics(paths, configuration)
    diagnostics = Diagnostic[]
    for path in paths
        diagnostic = Diagnostic(
            "SECURITY-UNSAFE-BOUNDARY",
            Ignore,
            path.path,
            path.sink_line,
            1,
            path.explanation,
            nothing,
            nothing,
            "security-boundary",
            path.declaration,
            path.sink_category,
            nothing,
            path.certainty)
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    return diagnostics
end

"""Return the deterministic identity of one configured security path."""
security_path_key(path) = join((
    path.language,
    path.path,
    path.declaration,
    path.source_contract_id,
    string(path.source_line),
    path.sink_contract_id,
    string(path.sink_line)), '\0')