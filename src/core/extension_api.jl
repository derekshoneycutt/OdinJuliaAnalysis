const EXTENSION_API_VERSION = v"1.7.0"
const EXTENSION_RESULT_STATUSES = Set((
    "complete",
    "incomplete",
    "failed",
    "not-applicable"))

"""Return the globally unique stable identity of one extension."""
function extension_id(_extension::AnalysisExtension)
    throw(MethodError(extension_id, (_extension,)))
end

"""Return the extension API version implemented by one extension."""
extension_api_version(_extension::AnalysisExtension) = EXTENSION_API_VERSION

"""Return rule definitions owned by one extension."""
extension_rules(_extension::AnalysisExtension) = RuleDefinition[]

"""Return lifecycle phases implemented by one extension."""
extension_phases(_extension::AnalysisExtension) = Set((AfterRepositoryAnalysis,))

"""Return extension IDs whose same-phase results may be consumed."""
extension_dependencies(_extension::AnalysisExtension) = String[]

"""Analyze one lifecycle phase using immutable canonical context."""
function analyze_extension(extension::AnalysisExtension, context, prior_results)
    throw(MethodError(analyze_extension, (extension, context, prior_results)))
end

"""Invoke a potentially settings-loaded extension identity method."""
invoke_extension_id(extension) = Base.invokelatest(extension_id, extension)

"""Invoke a potentially settings-loaded extension API version method."""
invoke_extension_api_version(extension) =
    Base.invokelatest(extension_api_version, extension)

"""Invoke a potentially settings-loaded extension rule method."""
invoke_extension_rules(extension) = Base.invokelatest(extension_rules, extension)

"""Invoke a potentially settings-loaded extension phase method."""
invoke_extension_phases(extension) = Base.invokelatest(extension_phases, extension)

"""Invoke a potentially settings-loaded extension dependency method."""
invoke_extension_dependencies(extension) =
    Base.invokelatest(extension_dependencies, extension)

"""Invoke a potentially settings-loaded extension analysis method."""
invoke_extension_analysis(extension, context, prior_results) =
    Base.invokelatest(analyze_extension, extension, context, prior_results)

"""Construct one successful extension result without findings or artifacts."""
function ExtensionResult(
    extension_id::String,
    phase::AnalysisPhase;
    status::String="complete",
    diagnostics::Vector{Diagnostic}=Diagnostic[],
    artifacts::Dict{String, Any}=Dict{String, Any}(),
    message::Union{Nothing, String}=nothing)
    return ExtensionResult(
        extension_id, phase, status, diagnostics, artifacts, message)
end

"""Run configured extensions for one lifecycle phase in dependency order."""
function run_extension_phase!(
    results,
    diagnostics,
    configuration,
    root,
    paths,
    phase;
    files=FileAnalysis[],
    functions=FunctionAnalysis[],
    dependencies=DependencyEdge[],
    declarations=DeclarationRecord[],
    import_bindings=ImportBinding[],
    references=ReferenceRecord[],
    call_edges=CallEdge[],
    call_roots=CallRoot[],
    clone_groups=CloneGroup[],
    resource_lifetimes=ResourceLifetimeSummary[],
    security_paths=SecurityBoundaryPath[],
    interop_signatures=InteropSignature[],
    interop_pairs=InteropBridgePair[],
    statistics=nothing)
    context = AnalysisContext(
        root,
        configuration.profile,
        phase,
        Tuple(relpath(path, root) for path in paths),
        Tuple(files),
        Tuple(functions),
        Tuple(dependencies),
        Tuple(declarations),
        Tuple(import_bindings),
        Tuple(references),
        Tuple(call_edges),
        Tuple(call_roots),
        Tuple(clone_groups),
        Tuple(resource_lifetimes),
        Tuple(security_paths),
        Tuple(interop_signatures),
        Tuple(interop_pairs),
        statistics)
    for extension in configuration.extensions
        phase in invoke_extension_phases(extension) || continue
        id = invoke_extension_id(extension)
        prior = dependency_results(extension, results)
        result = try
            raw_result = invoke_extension_analysis(extension, context, prior)
            validate_extension_result(raw_result, extension, phase, configuration)
        catch error
            ExtensionResult(
                id,
                phase;
                status="failed",
                message=sprint(showerror, error))
        end
        append!(diagnostics, result.diagnostics)
        push!(results, result)
    end
end

"""Return the latest result for each declared extension dependency."""
function dependency_results(extension, results)
    prior = Dict{String, ExtensionResult}()
    for dependency in invoke_extension_dependencies(extension)
        index = findlast(result -> result.extension_id == dependency, results)
        index === nothing || (prior[dependency] = results[index])
    end
    return prior
end

"""Validate one result and apply configured rule responses to its findings."""
function validate_extension_result(result, extension, phase, configuration)
    id = invoke_extension_id(extension)
    result isa ExtensionResult || throw(ArgumentError(
        "extension $id must return ExtensionResult"))
    result.extension_id == id || throw(ArgumentError(
        "extension $id returned result for $(result.extension_id)"))
    result.phase == phase || throw(ArgumentError(
        "extension $id returned result for the wrong phase"))
    result.status in EXTENSION_RESULT_STATUSES || throw(ArgumentError(
        "extension $id returned unsupported status: $(result.status)"))
    JSON3.write(result.artifacts)
    configured = Diagnostic[]
    for diagnostic in result.diagnostics
        owner = get(configuration.extension_rule_owners, diagnostic.rule_id, nothing)
        owner == id || throw(ArgumentError(
            "extension $id emitted unowned rule: $(diagnostic.rule_id)"))
        item = configured_diagnostic(configuration, diagnostic)
        item === nothing || push!(configured, item)
    end
    return ExtensionResult(
        id,
        phase,
        result.status,
        configured,
        result.artifacts,
        result.message)
end

"""Create one aggregate engine status for every configured extension."""
function extension_engine_statuses(extensions, results)
    return map(extensions) do extension
        id = invoke_extension_id(extension)
        extension_results = filter(result -> result.extension_id == id, results)
        statuses = Set(result.status for result in extension_results)
        status = "failed" in statuses ? "failed" :
            "incomplete" in statuses ? "incomplete" :
            isempty(statuses) || statuses == Set(("not-applicable",)) ?
                "not-applicable" : "complete"
        messages = String[
            result.message for result in extension_results
            if result.message !== nothing]
        message = isempty(messages) ? nothing : join(messages, "; ")
        EngineStatus("extension:$id", status, message)
    end
end