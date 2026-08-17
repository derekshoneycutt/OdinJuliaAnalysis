"""Return architecture settings with policy disabled by default."""
default_architecture_settings() = ArchitectureSettings(
    ArchitectureLayer[], ArchitectureDependency[])

"""Run configured architecture policy against resolved repository dependencies."""
function analyze_architecture(dependencies, configuration)
    settings = configuration.architecture
    isempty(settings.layers) && return Diagnostic[]
    diagnostics = unresolved_architecture_diagnostics(dependencies)
    layer_edges = architecture_layer_edges(settings, dependencies)
    append!(diagnostics, forbidden_architecture_diagnostics(settings, layer_edges))
    append!(diagnostics, architecture_cycle_diagnostics(layer_edges))
    configured = Diagnostic[]
    for diagnostic in diagnostics
        item = configured_diagnostic(configuration, diagnostic)
        item === nothing || push!(configured, item)
    end
    return configured
end

"""Reject invalid layer identities, paths, and allowed directions."""
function validate_architecture_settings(settings)
    names = Set{String}()
    owners = Dict{String, String}()
    for layer in settings.layers
        isempty(strip(layer.name)) && throw(ArgumentError(
            "architecture layer name cannot be empty"))
        layer.name in names && throw(ArgumentError(
            "duplicate architecture layer: $(layer.name)"))
        isempty(layer.paths) && throw(ArgumentError(
            "architecture layer $(layer.name) must own at least one path"))
        push!(names, layer.name)
        for path in layer.paths
            normalized = validate_architecture_path(path, layer.name)
            haskey(owners, normalized) && throw(ArgumentError(
                "architecture path $normalized is owned by both " *
                    "$(owners[normalized]) and $(layer.name)"))
            owners[normalized] = layer.name
        end
    end
    for dependency in settings.allowed_dependencies
        dependency.source in names || throw(ArgumentError(
            "unknown architecture source layer: $(dependency.source)"))
        dependency.target in names || throw(ArgumentError(
            "unknown architecture target layer: $(dependency.target)"))
    end
end

"""Normalize and validate one repository-relative architecture path."""
function validate_architecture_path(path, layer_name)
    isempty(strip(path)) && throw(ArgumentError(
        "architecture layer $layer_name contains an empty path"))
    isabspath(path) && throw(ArgumentError(
        "architecture path must be repository-relative: $path"))
    normalized = replace(normpath(path), '\\' => '/')
    parts = split(normalized, '/')
    any(part -> part == "..", parts) && throw(ArgumentError(
        "architecture path must remain inside the repository: $path"))
    return normalized
end

"""Return resolved repository edges whose endpoints both belong to layers."""
function architecture_layer_edges(settings, dependencies)
    edges = NamedTuple[]
    for edge in dependencies
        edge.resolution == "repository" || continue
        edge.target_path === nothing && continue
        source_layer = architecture_layer(settings, edge.source_path)
        target_layer = architecture_layer(settings, edge.target_path)
        source_layer === nothing && continue
        target_layer === nothing && continue
        push!(edges, (; edge, source_layer, target_layer))
    end
    return edges
end

"""Return the most-specific layer owning one normalized repository path."""
function architecture_layer(settings, path)
    matches = Tuple{Int, String}[]
    for layer in settings.layers, configured_path in layer.paths
        prefix = replace(normpath(configured_path), '\\' => '/')
        owned = prefix == "." || path == prefix || startswith(path, prefix * "/")
        owned && push!(matches, (ncodeunits(prefix), layer.name))
    end
    isempty(matches) && return nothing
    sort!(matches; by=first, rev=true)
    return first(matches)[2]
end

"""Report unresolved imports whose syntax explicitly denotes repository ownership."""
function unresolved_architecture_diagnostics(dependencies)
    diagnostics = Diagnostic[]
    for edge in dependencies
        edge.resolution == "unresolved" || continue
        push!(diagnostics, Diagnostic(
            "ARCHITECTURE-UNRESOLVED-INTERNAL-IMPORT",
            Ignore,
            edge.source_path,
            edge.line,
            edge.column,
            "Internal $(edge.language) import `$(edge.target)` could not be resolved.",
            nothing,
            nothing,
            "architecture",
            edge.target,
            "dependency-resolution",
            nothing,
            "stable"))
    end
    return diagnostics
end

"""Report actual layer edges absent from the exact allowed-direction set."""
function forbidden_architecture_diagnostics(settings, layer_edges)
    allowed = Set(
        (dependency.source, dependency.target)
        for dependency in settings.allowed_dependencies)
    diagnostics = Diagnostic[]
    for item in layer_edges
        item.source_layer == item.target_layer && continue
        (item.source_layer, item.target_layer) in allowed && continue
        edge = item.edge
        push!(diagnostics, Diagnostic(
            "ARCHITECTURE-FORBIDDEN-DEPENDENCY",
            Ignore,
            edge.source_path,
            edge.line,
            edge.column,
            "Architecture layer `$(item.source_layer)` may not depend on " *
                "`$(item.target_layer)` through `$(edge.target)`.",
            nothing,
            nothing,
            "architecture",
            "$(item.source_layer)->$(item.target_layer)",
            "dependency",
            nothing,
            "stable"))
    end
    return diagnostics
end

"""Report each strongly connected layer component once."""
function architecture_cycle_diagnostics(layer_edges)
    adjacency = architecture_adjacency(layer_edges)
    diagnostics = Diagnostic[]
    for component in architecture_cycles(adjacency)
        evidence = first(filter(layer_edges) do item
            item.source_layer in component && item.target_layer in component &&
                item.source_layer != item.target_layer
        end)
        edge = evidence.edge
        push!(diagnostics, Diagnostic(
            "ARCHITECTURE-DEPENDENCY-CYCLE",
            Ignore,
            edge.source_path,
            edge.line,
            edge.column,
            "Dependency cycle includes layers: $(join(component, ", ")).",
            length(component),
            nothing,
            "architecture",
            join(component, ","),
            "dependency-cycle",
            nothing,
            "stable"))
    end
    return diagnostics
end

"""Build deterministic layer adjacency from actual repository edges."""
function architecture_adjacency(layer_edges)
    adjacency = Dict{String, Set{String}}()
    for item in layer_edges
        push!(get!(adjacency, item.source_layer, Set{String}()), item.target_layer)
        get!(adjacency, item.target_layer, Set{String}())
    end
    return adjacency
end

"""Return strongly connected layer groups using mutual reachability."""
function architecture_cycles(adjacency)
    cycles = Vector{String}[]
    seen = Set{String}()
    nodes = sort!(collect(keys(adjacency)))
    for node in nodes
        component = sort!(filter(candidate ->
            architecture_reachable(node, candidate, adjacency) &&
                architecture_reachable(candidate, node, adjacency), nodes))
        length(component) > 1 || continue
        identity = join(component, "\0")
        identity in seen && continue
        push!(seen, identity)
        push!(cycles, component)
    end
    return cycles
end

"""Return whether one layer can reach another in the actual dependency graph."""
function architecture_reachable(source, target, adjacency)
    pending = String[source]
    visited = Set{String}()
    while !isempty(pending)
        current = pop!(pending)
        current == target && return true
        current in visited && continue
        push!(visited, current)
        append!(pending, get(adjacency, current, Set{String}()))
    end
    return false
end
