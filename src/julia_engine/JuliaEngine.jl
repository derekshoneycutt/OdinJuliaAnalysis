module JuliaEngine

using CodeComplexity
using JuliaSyntax

using ..OdinJuliaAnalysis: Diagnostic
using ..OdinJuliaAnalysis: CallEdge
using ..OdinJuliaAnalysis: CloneCandidate
using ..OdinJuliaAnalysis: CloneOccurrence
using ..OdinJuliaAnalysis: DeclarationRecord
using ..OdinJuliaAnalysis: DependencyEdge
using ..OdinJuliaAnalysis: EffectiveSettings
using ..OdinJuliaAnalysis: FunctionAnalysis
using ..OdinJuliaAnalysis: ImportBinding
using ..OdinJuliaAnalysis: InteropSignature
using ..OdinJuliaAnalysis: Ignore
using ..OdinJuliaAnalysis: ReferenceRecord
using ..OdinJuliaAnalysis: configured_diagnostic
using ..OdinJuliaAnalysis: executable_source_lines
using ..OdinJuliaAnalysis: load_settings
using ..OdinJuliaAnalysis: valid_identifier_name

export check_syntax
export check
export analyze_dependencies
export analyze_calls
export analyze_clone_candidates
export analyze_declarations
export analyze_functions
export analyze_import_bindings
export analyze_interop
export analyze_references
export documentation_comment_lines
export struct_count

include("ClosingParentheses.jl")

const CYCLOMATIC = CyclomaticComplexity()
const COGNITIVE = CognitiveComplexity()

const JuliaModuleDefinition = @NamedTuple begin
    name::String
    path::String
    start_line::Int
    end_line::Int
    depth::Int
end

"""Collect explicit parser-backed Julia declarations."""
function analyze_declarations(path::String, source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    declarations = DeclarationRecord[]
    collect_declarations!(declarations, tree, path, offsets, String[])
    return declarations
end

"""Collect canonical whole-body candidates for exact Julia clone grouping."""
function analyze_clone_candidates(path::String, source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    lines = split(source, '\n'; keepempty=true)
    offsets = line_start_offsets(lines)
    candidates = CloneCandidate[]
    collect_clone_candidates!(candidates, tree, path, lines, offsets)
    return candidates
end

"""Visit named Julia functions and retain parser-structural body forms."""
function collect_clone_candidates!(candidates, node, path, lines, offsets)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :function && length(children) >= 2
        name_node = declaration_identifier_node(node)
        if name_node !== nothing
            body = last(children)
            start_line = metric_line_for_offset(offsets, JuliaSyntax.first_byte(body))
            end_line = metric_line_for_offset(offsets, JuliaSyntax.last_byte(body))
            canonical, token_count = canonical_syntax(body)
            push!(candidates, CloneCandidate(
                CloneOccurrence(
                    path,
                    "julia",
                    strip(String(JuliaSyntax.sourcetext(name_node))),
                    start_line,
                    end_line),
                canonical,
                token_count,
                body_executable_lines(body, path, lines, offsets)))
        end
    end
    for child in children
        collect_clone_candidates!(candidates, child, path, lines, offsets)
    end
end

"""Return a trivia-free parser-structural representation and leaf-token count."""
function canonical_syntax(node)
    children = something(JuliaSyntax.children(node), ())
    kind = string(Symbol(JuliaSyntax.kind(node)))
    if isempty(children)
        text = strip(String(JuliaSyntax.sourcetext(node)))
        return "$kind:$text", 1
    end
    parts = String[]
    token_count = 0
    for child in children
        canonical, child_tokens = canonical_syntax(child)
        push!(parts, canonical)
        token_count += child_tokens
    end
    return "$kind($(join(parts, ',')))", token_count
end

"""Visit explicit module, function, struct, and constant declarations."""
function collect_declarations!(declarations, node, path, offsets, scope)
    kind = Symbol(JuliaSyntax.kind(node))
    declaration_kind = if kind == :module
        "module"
    elseif kind == :function
        "function"
    elseif kind == :struct
        "type"
    elseif kind == :const
        "constant"
    end
    nested_scope = scope
    if declaration_kind !== nothing
        name_node = declaration_identifier_node(node)
        if name_node !== nothing
            name = strip(String(JuliaSyntax.sourcetext(name_node)))
            byte_offset = JuliaSyntax.first_byte(name_node)
            line = metric_line_for_offset(offsets, byte_offset)
            scope_name = isempty(scope) ? nothing : join(scope, ".")
            push!(declarations, DeclarationRecord(
                path,
                "julia",
                name,
                join([scope; name], "."),
                declaration_kind,
                scope_name,
                line,
                byte_offset - offsets[line] + 1))
            kind in (:module, :function, :struct) && (nested_scope = [scope; name])
        end
    end
    for child in something(JuliaSyntax.children(node), ())
        collect_declarations!(declarations, child, path, offsets, nested_scope)
    end
end

"""Return the identifier node naming one explicit declaration."""
function declaration_identifier_node(node)
    children = something(JuliaSyntax.children(node), ())
    isempty(children) && return nothing
    candidate = first(children)
    while true
        kind = Symbol(JuliaSyntax.kind(candidate))
        kind == :Identifier && return candidate
        kind in (:where, :(::), :curly, :(=), :call) || return nothing
        nested = something(JuliaSyntax.children(candidate), ())
        isempty(nested) && return nothing
        candidate = first(nested)
    end
end

"""Collect explicit Julia import bindings that can be checked for references."""
function analyze_import_bindings(path::String, source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    bindings = ImportBinding[]
    collect_import_bindings!(bindings, tree, path, offsets)
    return bindings
end

"""Visit import statements and append their explicit namespace or name bindings."""
function collect_import_bindings!(bindings, node, path, offsets)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind in (:using, :import)
        append_julia_import_bindings!(bindings, node, path, offsets, String(kind))
        return
    end
    for child in children
        collect_import_bindings!(bindings, child, path, offsets)
    end
end

"""Append analyzable bindings from one Julia using or import statement."""
function append_julia_import_bindings!(bindings, node, path, offsets, kind)
    children = something(JuliaSyntax.children(node), ())
    isempty(children) && return
    clause = first(children)
    clause_kind = Symbol(JuliaSyntax.kind(clause))
    if clause_kind == :importpath
        kind == "import" || return
        append_julia_import_binding!(bindings, clause, clause, path, offsets, kind)
        return
    end
    clause_kind == :(:) || return
    paths = something(JuliaSyntax.children(clause), ())
    length(paths) >= 2 || return
    target = strip(String(JuliaSyntax.sourcetext(first(paths))))
    for binding_node in paths[2:end]
        append_julia_import_binding!(
            bindings, first(paths), binding_node, path, offsets, kind; target)
    end
end

"""Append one Julia import binding with its local alias and source location."""
function append_julia_import_binding!(
    bindings, target_node, binding_node, path, offsets, kind; target=nothing)
    local_node = binding_node
    if Symbol(JuliaSyntax.kind(binding_node)) == :as
        alias_children = something(JuliaSyntax.children(binding_node), ())
        isempty(alias_children) && return
        local_node = last(alias_children)
    end
    name = strip(String(JuliaSyntax.sourcetext(local_node)))
    raw_target = target === nothing ?
        strip(String(JuliaSyntax.sourcetext(target_node))) : target
    byte_offset = JuliaSyntax.first_byte(local_node)
    line = metric_line_for_offset(offsets, byte_offset)
    push!(bindings, ImportBinding(
        path, "julia", raw_target, name, kind, line,
        byte_offset - offsets[line] + 1))
end

"""Collect parser-visible Julia identifier references outside import statements."""
function analyze_references(path::String, source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    references = ReferenceRecord[]
    collect_references!(references, tree, path, offsets, String[], false)
    return references
end

"""Visit identifier nodes while retaining lexical module and function scope."""
function collect_references!(references, node, path, offsets, scope, excluded)
    kind = Symbol(JuliaSyntax.kind(node))
    kind in (:using, :import) && return
    declaration = kind in (:module, :function, :struct, :const) ?
        declaration_identifier_node(node) : nothing
    nested_scope = scope
    if declaration !== nothing && kind in (:module, :function, :struct)
        nested_scope = [scope; strip(String(JuliaSyntax.sourcetext(declaration)))]
    end
    if kind == :Identifier && !excluded
        byte_offset = JuliaSyntax.first_byte(node)
        line = metric_line_for_offset(offsets, byte_offset)
        push!(references, ReferenceRecord(
            path,
            "julia",
            String(JuliaSyntax.sourcetext(node)),
            isempty(scope) ? nothing : join(scope, "."),
            line,
            byte_offset - offsets[line] + 1))
        return
    end
    for child in something(JuliaSyntax.children(node), ())
        collect_references!(
            references, child, path, offsets, nested_scope,
            excluded || child === declaration)
    end
end

"""Collect explicit parser-backed Julia call edges."""
function analyze_calls(path::String, source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    calls = CallEdge[]
    collect_calls!(calls, tree, path, offsets, String[], false)
    return calls
end

"""Return the callee node of a call expression, or `nothing` when it has none.

Infix and postfix operator calls place the operand first, so the callee is the
operator child rather than the first child. Parametric constructor calls name the
type through a `curly` wrapper, so the underlying type name is the callee."""
function call_callee_node(node, children)
    isempty(children) && return nothing
    callee = JuliaSyntax.is_infix_op_call(node) || JuliaSyntax.is_postfix_op_call(node) ?
        (length(children) >= 2 ? children[2] : nothing) : first(children)
    while callee !== nothing && Symbol(JuliaSyntax.kind(callee)) == :curly
        parameters = something(JuliaSyntax.children(callee), ())
        callee = isempty(parameters) ? nothing : first(parameters)
    end
    return callee
end

"""Visit call expressions while retaining lexical module and function scope."""
function collect_calls!(calls, node, path, offsets, scope, declaration_header)
    kind = Symbol(JuliaSyntax.kind(node))
    # Quoted expressions are macro templates; their $-interpolation placeholders are
    # not concrete call sites, so they produce no call-graph edges.
    kind == :quote && return
    declaration = call_scope_declaration(node, kind)
    nested_scope = declaration === nothing ? scope :
        [scope; strip(String(JuliaSyntax.sourcetext(declaration)))]
    children = something(JuliaSyntax.children(node), ())
    callee_node = eligible_call_callee(node, kind, children, declaration_header)
    if callee_node !== nothing
        push!(calls, call_edge(callee_node, path, offsets, scope))
    end
    for child in children
        child_is_header = declaration !== nothing && child === first(children)
        collect_calls!(
            calls, child, path, offsets, nested_scope,
            declaration_header || child_is_header)
    end
end

"""Return a declaration that introduces lexical call scope."""
function call_scope_declaration(node, kind)
    return kind in (:module, :function, :struct) ?
        declaration_identifier_node(node) : nothing
end

"""Return the callee for an eligible call expression."""
function eligible_call_callee(node, kind, children, declaration_header)
    return kind in (:call, :dotcall) && !declaration_header ?
        call_callee_node(node, children) : nothing
end

"""Build one canonical Julia call edge from its callee syntax node."""
function call_edge(callee_node, path, offsets, scope)
    callee_kind = Symbol(JuliaSyntax.kind(callee_node))
    byte_offset = JuliaSyntax.first_byte(callee_node)
    line = metric_line_for_offset(offsets, byte_offset)
    call_kind = callee_kind == :Identifier ? "direct" :
        callee_kind == :. ? "qualified" : "dynamic"
    return CallEdge(
        path,
        "julia",
        isempty(scope) ? nothing : join(scope, "."),
        strip(String(JuliaSyntax.sourcetext(callee_node))),
        call_kind,
        line,
        byte_offset - offsets[line] + 1)
end

"""Collect supported Julia C interop signatures from surface syntax."""
function analyze_interop(path::String, source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    signatures = InteropSignature[]
    collect_interop!(signatures, tree, path, offsets)
    return signatures
end

"""Visit @ccall, ccall, and @cfunction syntax forms."""
function collect_interop!(signatures, node, path, offsets)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    signature = if kind == :macrocall && !isempty(children)
        macro_name = String(JuliaSyntax.sourcetext(first(children)))
        macro_name == "ccall" ? julia_macro_ccall(node, path, offsets) :
            macro_name == "cfunction" ? julia_cfunction(node, path, offsets) : nothing
    elseif kind == :call && !isempty(children) &&
        String(JuliaSyntax.sourcetext(first(children))) == "ccall"
        julia_ccall(node, path, offsets)
    end
    signature === nothing || push!(signatures, signature)
    for child in children
        collect_interop!(signatures, child, path, offsets)
    end
end

"""Normalize one Julia @ccall signature."""
function julia_macro_ccall(node, path, offsets)
    children = something(JuliaSyntax.children(node), ())
    length(children) >= 2 || return nothing
    typed_call = children[2]
    typed_children = something(JuliaSyntax.children(typed_call), ())
    length(typed_children) == 2 || return nothing
    call, return_type = typed_children
    call_children = something(JuliaSyntax.children(call), ())
    isempty(call_children) && return nothing
    library, symbol = julia_interop_callee(first(call_children))
    parameter_types = String[]
    for argument in call_children[2:end]
        argument_children = something(JuliaSyntax.children(argument), ())
        Symbol(JuliaSyntax.kind(argument)) == :(::) && length(argument_children) == 2 ||
            return nothing
        push!(parameter_types, normalize_abi_type(last(argument_children)))
    end
    return julia_interop_signature(
        node, path, offsets, symbol, "import", library, parameter_types,
        abi_return_types(return_type))
end

"""Normalize one Julia ccall signature."""
function julia_ccall(node, path, offsets)
    children = something(JuliaSyntax.children(node), ())
    length(children) >= 4 || return nothing
    library, symbol = julia_ccall_target(children[2])
    parameter_nodes = something(JuliaSyntax.children(children[4]), ())
    return julia_interop_signature(
        node, path, offsets, symbol, "import", library,
        [normalize_abi_type(item) for item in parameter_nodes],
        abi_return_types(children[3]))
end

"""Normalize one Julia @cfunction callback signature."""
function julia_cfunction(node, path, offsets)
    children = something(JuliaSyntax.children(node), ())
    length(children) == 4 || return nothing
    symbol = strip(String(JuliaSyntax.sourcetext(children[2])), '$')
    parameter_nodes = something(JuliaSyntax.children(children[4]), ())
    return julia_interop_signature(
        node, path, offsets, symbol, "export", nothing,
        [normalize_abi_type(item) for item in parameter_nodes],
        abi_return_types(children[3]))
end

"""Return library and symbol names from an @ccall callee."""
function julia_interop_callee(node)
    if Symbol(JuliaSyntax.kind(node)) == :Identifier
        return nothing, String(JuliaSyntax.sourcetext(node))
    end
    children = something(JuliaSyntax.children(node), ())
    length(children) == 2 || return nothing, String(JuliaSyntax.sourcetext(node))
    return String(JuliaSyntax.sourcetext(first(children))),
        String(JuliaSyntax.sourcetext(last(children)))
end

"""Return library and symbol names from a ccall target tuple or symbol."""
function julia_ccall_target(node)
    children = something(JuliaSyntax.children(node), ())
    if Symbol(JuliaSyntax.kind(node)) == :tuple && length(children) >= 2
        symbol = strip(String(JuliaSyntax.sourcetext(first(children))), ':')
        return String(JuliaSyntax.sourcetext(children[2])), symbol
    end
    return nothing, strip(String(JuliaSyntax.sourcetext(node)), ':')
end

"""Construct one normalized Julia interop signature at its source location."""
function julia_interop_signature(
    node, path, offsets, symbol, direction, library, parameters, returns)
    byte_offset = JuliaSyntax.first_byte(node)
    line = metric_line_for_offset(offsets, byte_offset)
    return InteropSignature(
        path, "julia", symbol, direction, library, "c", parameters, returns,
        line, byte_offset - offsets[line] + 1)
end

"""Normalize a supported ABI type spelling across Julia and Odin."""
function normalize_abi_type(node)
    text = replace(strip(String(JuliaSyntax.sourcetext(node))), " " => "")
    mappings = Dict(
        "Cchar" => "i8", "Cuchar" => "u8", "Cshort" => "i16",
        "Cushort" => "u16", "Cint" => "i32", "Cuint" => "u32",
        "Clonglong" => "i64", "Culonglong" => "u64", "Cfloat" => "f32",
        "Cdouble" => "f64", "Cvoid" => "void", "Cstring" => "cstring")
    haskey(mappings, text) && return mappings[text]
    startswith(text, "Ptr{") && endswith(text, "}") &&
        return "^" * get(mappings, text[5:(end - 1)], text[5:(end - 1)])
    return text
end

"""Represent a void result as an empty ABI return list."""
function abi_return_types(node)
    normalized = normalize_abi_type(node)
    return normalized == "void" ? String[] : [normalized]
end

"""Collect parser-backed Julia using and import edges."""
function analyze_dependencies(path::String, source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    dependencies = DependencyEdge[]
    collect_dependencies!(dependencies, tree, path, offsets)
    return dependencies
end

"""Visit Julia syntax and append each directly imported module path."""
function collect_dependencies!(dependencies, node, path, offsets)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind in (:using, :import)
        for child in children
            import_path = dependency_import_path(child)
            import_path === nothing && continue
            byte_offset = JuliaSyntax.first_byte(import_path)
            line = metric_line_for_offset(offsets, byte_offset)
            raw_target = String(JuliaSyntax.sourcetext(import_path))
            leading_bytes = ncodeunits(raw_target) - ncodeunits(lstrip(raw_target))
            push!(dependencies, DependencyEdge(
                path,
                strip(raw_target),
                nothing,
                "unresolved",
                "julia",
                String(kind),
                line,
                byte_offset - offsets[line] + leading_bytes + 1))
        end
        return
    end
    for child in children
        collect_dependencies!(dependencies, child, path, offsets)
    end
end

"""Resolve Julia imports against parser-derived repository module declarations."""
function resolve_dependencies!(dependencies, root, files)
    definitions = JuliaModuleDefinition[]
    for file in files
        endswith(file, ".jl") || continue
        source = read(file, String)
        append!(definitions, analyze_modules(relpath(file, root), source))
    end
    for index in eachindex(dependencies)
        edge = dependencies[index]
        edge.language == "julia" || continue
        target_path, resolution = resolve_julia_target(edge, definitions)
        dependencies[index] = DependencyEdge(
            edge.source_path,
            edge.target,
            target_path,
            resolution,
            edge.language,
            edge.kind,
            edge.line,
            edge.column)
    end
end

"""Collect qualified module declarations and their lexical source ranges."""
function analyze_modules(path, source)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    definitions = JuliaModuleDefinition[]
    collect_modules!(definitions, tree, path, offsets, String[])
    return definitions
end

"""Visit nested Julia modules while retaining their qualified identities."""
function collect_modules!(definitions, node, path, offsets, parents)
    children = something(JuliaSyntax.children(node), ())
    if Symbol(JuliaSyntax.kind(node)) == :module && length(children) >= 2
        module_name = strip(String(JuliaSyntax.sourcetext(first(children))))
        qualified_parts = [parents; module_name]
        start_line = metric_line_for_offset(offsets, JuliaSyntax.first_byte(node))
        end_line = metric_line_for_offset(offsets, JuliaSyntax.last_byte(node))
        push!(definitions, (
            name=join(qualified_parts, "."),
            path=path,
            start_line,
            end_line,
            depth=length(qualified_parts)))
        collect_modules!(definitions, last(children), path, offsets, qualified_parts)
        return
    end
    for child in children
        collect_modules!(definitions, child, path, offsets, parents)
    end
end

"""Classify one Julia import as repository-owned, external, or unresolved."""
function resolve_julia_target(edge, definitions)
    relative_depth = count_leading_dots(edge.target)
    target_name = lstrip(edge.target, '.')
    candidate = target_name
    if relative_depth > 0
        source_module = innermost_source_module(edge, definitions)
        source_module === nothing && return nothing, "unresolved"
        source_parts = split(source_module.name, '.')
        parent_depth = relative_depth - 1
        parent_depth < length(source_parts) || return nothing, "unresolved"
        base_parts = source_parts[1:(length(source_parts) - parent_depth)]
        candidate = join([base_parts; split(target_name, '.')], ".")
    end
    matches = filter(definitions) do definition
        candidate == definition.name ||
            relative_depth == 0 && startswith(candidate, definition.name * ".")
    end
    if isempty(matches)
        return nothing, relative_depth > 0 ? "unresolved" : "external"
    end
    target = first(sort!(matches; by=definition -> definition.depth, rev=true))
    return target.path, "repository"
end

"""Return the lexical module containing one Julia import edge."""
function innermost_source_module(edge, definitions)
    matches = filter(definition ->
        definition.path == edge.source_path &&
            definition.start_line <= edge.line <= definition.end_line,
        definitions)
    isempty(matches) && return nothing
    return first(sort!(matches; by=definition -> definition.depth, rev=true))
end

"""Count the relative-module prefix on one Julia import target."""
function count_leading_dots(target)
    count = 0
    for character in target
        character == '.' || break
        count += 1
    end
    return count
end

"""Return the module path from one direct using or import child."""
function dependency_import_path(node)
    kind = Symbol(JuliaSyntax.kind(node))
    kind == :importpath && return node
    kind == :(:) || return nothing
    children = something(JuliaSyntax.children(node), ())
    return isempty(children) ? nothing : first(children)
end

"""Run configured syntax, layout, and documentation checks on Julia source."""
function check(
    path::String,
    source::String,
    configuration::EffectiveSettings=load_settings())
    diagnostics = check_syntax(path, source, configuration)
    isempty(diagnostics) || return diagnostics
    append!(diagnostics, check_closing_parentheses(path, source, configuration))
    append!(diagnostics, check_documentation(path, source, configuration))
    append!(diagnostics, check_naming(path, source, configuration))
    append!(diagnostics, check_nonconst_globals(path, source, configuration))
    append!(diagnostics, check_const_mutable_refs(path, source, configuration))
    append!(diagnostics, check_return_tuples(path, source, configuration))
    append!(diagnostics, check_parameter_counts(path, source, configuration))
    append!(diagnostics, check_declaration_order(path, source, configuration))
    append!(diagnostics, check_behavior(path, source, configuration))
    return diagnostics
end

"""Report high-confidence catch, argument-mutation, and global-write behavior."""
function check_behavior(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    diagnostics = Diagnostic[]
    collect_behavior!(
        diagnostics, tree, path, offsets, configuration, nothing, Set{String}())
    return diagnostics
end

"""Visit behavior-sensitive syntax while retaining function name and parameters."""
function collect_behavior!(
    diagnostics, node, path, offsets, configuration, function_name, parameters)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :function
        collect_function_behavior!(
            diagnostics, node, children, path, offsets, configuration)
        return
    end
    append_behavior_node_diagnostics!(
        diagnostics, node, path, offsets, configuration, function_name, parameters)
    for child in children
        collect_behavior!(
            diagnostics, child, path, offsets, configuration,
            function_name, parameters)
    end
end

"""Append behavior diagnostics produced directly by one syntax node."""
function append_behavior_node_diagnostics!(
    diagnostics, node, path, offsets, configuration, function_name, parameters)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :catch
        append_catch_diagnostics!(diagnostics, node, path, offsets, configuration)
    elseif kind == :global && function_name !== nothing
        append_behavior_diagnostic!(
            diagnostics, "JULIA-GLOBAL-WRITE", node, path, offsets, configuration,
            "Function `$function_name` writes global state.";
            subject=function_name, operation="global-write", certainty="definite")
    elseif kind == :(=) && function_name !== nothing &&
        !endswith(function_name, "!") && !isempty(children)
        target = mutated_parameter(first(children), parameters)
        target === nothing || append_behavior_diagnostic!(
            diagnostics,
            "JULIA-UNSIGNALED-ARGUMENT-MUTATION",
            first(children),
            path, offsets, configuration,
            "Function `$function_name` mutates argument `$target` " *
            "without a trailing `!`.";
            subject=target, operation="argument-mutation", certainty="definite")
    end
end

"""Visit a function body with its declaration context."""
function collect_function_behavior!(
    diagnostics, node, children, path, offsets, configuration)
    name_node = declaration_identifier_node(node)
    name = name_node === nothing ? nothing :
        strip(String(JuliaSyntax.sourcetext(name_node)))
    header = isempty(children) ? nothing : first(children)
    parameters = header === nothing ? Set{String}() :
        function_parameter_names(header, name_node)
    for child in children
        child === header && continue
        collect_behavior!(
            diagnostics, child, path, offsets, configuration, name, parameters)
    end
end

"""Return explicit parameter identifiers from one function declaration header."""
function function_parameter_names(header, name_node)
    names = Set{String}()
    for child in something(JuliaSyntax.children(header), ())
        child === name_node && continue
        parameter = declaration_identifier_node(child)
        parameter === nothing && Symbol(JuliaSyntax.kind(child)) == :Identifier &&
            (parameter = child)
        parameter === nothing ||
            push!(names, String(JuliaSyntax.sourcetext(parameter)))
    end
    return names
end

"""Return a mutated explicit argument for indexed or property assignment."""
function mutated_parameter(target, parameters)
    kind = Symbol(JuliaSyntax.kind(target))
    kind in (:ref, :.) || return nothing
    children = something(JuliaSyntax.children(target), ())
    isempty(children) && return nothing
    owner = first(children)
    Symbol(JuliaSyntax.kind(owner)) == :Identifier || return nothing
    name = String(JuliaSyntax.sourcetext(owner))
    return name in parameters ? name : nothing
end

"""Report empty catches and broad catches that do not bind or use an exception."""
function append_catch_diagnostics!(diagnostics, node, path, offsets, configuration)
    children = something(JuliaSyntax.children(node), ())
    has_binding = !isempty(children) &&
        Symbol(JuliaSyntax.kind(first(children))) == :Identifier
    binding = has_binding ? first(children) : nothing
    body = isempty(children) ? nothing : last(children)
    body === nothing && return append_behavior_diagnostic!(
        diagnostics, "JULIA-EMPTY-CATCH", node, path, offsets, configuration,
        "Catch block is empty."; operation="catch", certainty="definite")
    body_children = something(JuliaSyntax.children(body), ())
    if isempty(body_children)
        append_behavior_diagnostic!(
            diagnostics, "JULIA-EMPTY-CATCH", node, path, offsets, configuration,
            "Catch block is empty."; operation="catch", certainty="definite")
        return
    end
    binding_name = binding === nothing ? nothing : String(JuliaSyntax.sourcetext(binding))
    binding_used = binding_name === nothing ? false : any(
        child -> Symbol(JuliaSyntax.kind(child)) == :Identifier &&
            String(JuliaSyntax.sourcetext(child)) == binding_name,
        syntax_descendants(body))
    binding_used === true && return
    append_behavior_diagnostic!(
        diagnostics, "JULIA-BROAD-CATCH", node, path, offsets, configuration,
        "Catch block handles all exceptions without using the exception value.";
        subject=binding_name, operation="catch", certainty="probable")
end

"""Return all recursive syntax descendants of one node."""
function syntax_descendants(node)
    descendants = Any[]
    for child in something(JuliaSyntax.children(node), ())
        push!(descendants, child)
        append!(descendants, syntax_descendants(child))
    end
    return descendants
end

"""Create and configure one parser-backed Julia behavior diagnostic."""
function append_behavior_diagnostic!(
    diagnostics, rule_id, node, path, offsets, configuration, message;
    subject=nothing, operation, certainty)
    byte_offset = JuliaSyntax.first_byte(node)
    line = metric_line_for_offset(offsets, byte_offset)
    diagnostic = Diagnostic(
        rule_id, Ignore, path, line, byte_offset - offsets[line] + 1, message,
        nothing, nothing, "julia-syntax", subject, operation, nothing, certainty)
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end

"""Report top-level constants and structs declared after ordinary functions."""
function check_declaration_order(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    diagnostics = Diagnostic[]
    collect_declaration_order!(diagnostics, tree, path, offsets, configuration)
    return diagnostics
end

"""Check each top-level or module statement list independently."""
function collect_declaration_order!(diagnostics, node, path, offsets, configuration)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :toplevel
        check_statement_order!(diagnostics, children, path, offsets, configuration)
    elseif kind == :module && length(children) >= 2
        body = children[end]
        statements = something(JuliaSyntax.children(body), ())
        check_statement_order!(diagnostics, statements, path, offsets, configuration)
    end
    for child in children
        collect_declaration_order!(diagnostics, child, path, offsets, configuration)
    end
end

"""Enforce the declaration section before the ordinary-function section."""
function check_statement_order!(diagnostics, statements, path, offsets, configuration)
    struct_names = Set{String}()
    function_section = false
    for statement in statements
        kind = Symbol(JuliaSyntax.kind(statement))
        if kind == :struct
            append_declaration_order_diagnostic!(
                diagnostics,
                statement,
                function_section,
                "struct",
                path,
                offsets,
                configuration)
            name = declaration_name(statement)
            isempty(name) || push!(struct_names, name)
        elseif kind == :const
            append_declaration_order_diagnostic!(
                diagnostics,
                statement,
                function_section,
                "constant",
                path,
                offsets,
                configuration)
        elseif kind == :function
            name = declaration_name(statement)
            name in struct_names || (function_section = true)
        end
    end
end

"""Return the declared struct or function name represented by a syntax node."""
function declaration_name(node)
    children = something(JuliaSyntax.children(node), ())
    isempty(children) && return ""
    signature = children[1]
    while true
        kind = Symbol(JuliaSyntax.kind(signature))
        kind == :Identifier && return String(JuliaSyntax.sourcetext(signature))
        kind in (:where, :(::), :curly, :(=), :call) || return ""
        nested = something(JuliaSyntax.children(signature), ())
        isempty(nested) && return ""
        signature = nested[1]
    end
end

"""Append one configured Julia declaration-order finding."""
function append_declaration_order_diagnostic!(
    diagnostics,
    node,
    misplaced,
    declaration_kind,
    path,
    offsets,
    configuration)
    misplaced || return
    byte_offset = JuliaSyntax.first_byte(node)
    line = metric_line_for_offset(offsets, byte_offset)
    diagnostic = Diagnostic(
        "JULIA-DECLARATION-ORDER",
        Ignore,
        path,
        line,
        byte_offset - offsets[line] + 1,
        "Julia $(declaration_kind) declarations must appear before ordinary functions.",
        nothing,
        nothing,
        "julia-syntax",
        declaration_name(node),
        "declaration-order",
        nothing,
        "stable")
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end

"""Report Julia functions above the configured positional parameter maximum."""
function check_parameter_counts(path, source, configuration)
    diagnostics = Diagnostic[]
    maximum = configuration.parameter_counts.julia_maximum
    for item in analyze_functions(path, source)
        item.parameter_count <= maximum && continue
        diagnostic = Diagnostic(
            "JULIA-PARAMETERS-FAIL",
            Ignore,
            path,
            item.start_line,
            1,
            "Julia function `$(item.name)` has $(item.parameter_count) " *
                "non-keyword parameters; maximum is $(maximum).",
            item.parameter_count,
            maximum,
            "julia-syntax",
            item.name,
            "parameters",
            nothing,
            "stable")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    return diagnostics
end

"""Report Julia function return tuples above the configured maximum."""
function check_return_tuples(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    diagnostics = Diagnostic[]
    collect_function_return_tuples!(
        diagnostics, tree, path, offsets, configuration)
    return diagnostics
end

"""Find return sites only within each function's own lexical body."""
function collect_function_return_tuples!(diagnostics, node, path, offsets, configuration)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind in (:function, :macro, :(->)) && !isempty(children)
        name = first_measure(
            CYCLOMATIC, String(JuliaSyntax.sourcetext(node))).name
        body = children[end]
        collect_explicit_return_tuples!(
            diagnostics, body, path, offsets, configuration, name)
        append_return_tuple_diagnostic!(
            diagnostics, terminal_expression(body), path, offsets, configuration, name)
        for child in children
            collect_function_return_tuples!(
                diagnostics, child, path, offsets, configuration)
        end
    else
        for child in children
            collect_function_return_tuples!(
                diagnostics, child, path, offsets, configuration)
        end
    end
end

"""Collect explicit tuple returns while excluding nested function bodies."""
function collect_explicit_return_tuples!(
    diagnostics, node, path, offsets, configuration, name)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind in (:function, :macro, :(->))
        return
    elseif kind == :return
        isempty(children) || append_return_tuple_diagnostic!(
            diagnostics, children[end], path, offsets, configuration, name)
        return
    end
    for child in children
        collect_explicit_return_tuples!(
            diagnostics, child, path, offsets, configuration, name)
    end
end

"""Return the final expression that determines an implicit function result."""
function terminal_expression(node)
    Symbol(JuliaSyntax.kind(node)) == :block || return node
    children = something(JuliaSyntax.children(node), ())
    return isempty(children) ? node : children[end]
end

"""Append one configured oversized-return diagnostic for a tuple expression."""
function append_return_tuple_diagnostic!(
    diagnostics, node, path, offsets, configuration, name)
    Symbol(JuliaSyntax.kind(node)) == :tuple || return
    children = something(JuliaSyntax.children(node), ())
    any(child -> Symbol(JuliaSyntax.kind(child)) in (:(=), :kw), children) && return
    arity = length(children)
    maximum = configuration.return_tuples.julia_maximum
    arity <= maximum && return
    byte_offset = JuliaSyntax.first_byte(node)
    line = metric_line_for_offset(offsets, byte_offset)
    column = byte_offset - offsets[line] + 1
    diagnostic = Diagnostic(
        "JULIA-RETURN-TUPLE",
        Ignore,
        path,
        line,
        column,
        "Julia function `$(name)` returns $(arity) tuple elements; " *
            "maximum is $(maximum).",
        arity,
        maximum,
        "julia-syntax",
        name,
        "return",
        nothing,
        "stable")
    configured = configured_diagnostic(configuration, diagnostic)
    configured === nothing || push!(diagnostics, configured)
end

"""Report mutable Julia bindings declared in module or explicit global scope."""
function check_nonconst_globals(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    diagnostics = Diagnostic[]
    collect_nonconst_globals!(diagnostics, tree, path, offsets, :module)
    configured = Diagnostic[]
    for diagnostic in diagnostics
        item = configured_diagnostic(configuration, diagnostic)
        item === nothing || push!(configured, item)
    end
    return configured
end

"""Collect non-const bindings while respecting Julia lexical scopes."""
function collect_nonconst_globals!(diagnostics, node, path, offsets, scope)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :module && length(children) >= 2
        collect_nonconst_globals!(diagnostics, children[end], path, offsets, :module)
        return
    elseif kind == :global
        collect_explicit_global_bindings!(diagnostics, children, path, offsets)
        return
    elseif kind in (:const, :local, :struct, :quote, :call, :macrocall)
        return
    elseif kind in (
        :function, :macro, :(->), :let, :for, :while, :generator,
        :comprehension, :do)
        collect_nonconst_children!(diagnostics, children, path, offsets, :local)
        return
    elseif kind == :(=) && scope == :module && !isempty(children)
        collect_module_assignment!(diagnostics, children, path, offsets)
        return
    end
    collect_nonconst_children!(diagnostics, children, path, offsets, scope)
end

"""Visit child nodes while retaining the selected binding scope."""
function collect_nonconst_children!(diagnostics, children, path, offsets, scope)
    for child in children
        collect_nonconst_globals!(diagnostics, child, path, offsets, scope)
    end
end

"""Collect every binding named by an explicit global statement."""
function collect_explicit_global_bindings!(diagnostics, children, path, offsets)
    for child in children
        collect_global_bindings!(diagnostics, child, path, offsets)
    end
end

"""Collect a module assignment or descend into a short-form function body."""
function collect_module_assignment!(diagnostics, children, path, offsets)
    if is_call_signature(children[1])
        length(children) >= 2 && collect_nonconst_globals!(
            diagnostics, children[end], path, offsets, :local)
        return
    end
    collect_global_bindings!(diagnostics, children[1], path, offsets)
end

"""Append diagnostics for identifiers in one global binding pattern."""
function collect_global_bindings!(diagnostics, node, path, offsets)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :Identifier
        name = String(JuliaSyntax.sourcetext(node))
        name == "_" && return
        byte_offset = JuliaSyntax.first_byte(node)
        line = metric_line_for_offset(offsets, byte_offset)
        column = byte_offset - offsets[line] + 1
        push!(diagnostics, Diagnostic(
            "JULIA-NONCONST-GLOBAL",
            Ignore,
            path,
            line,
            column,
            "Julia global `$(name)` is mutable; declare it `const` or keep it local.",
            nothing,
            nothing,
            "julia-syntax",
            name,
            "global",
            nothing,
            "stable"))
    elseif kind == :(=) && !isempty(children)
        collect_global_bindings!(diagnostics, children[1], path, offsets)
    elseif kind in (:(::), :kw, :(...)) && !isempty(children)
        collect_global_bindings!(diagnostics, children[1], path, offsets)
    elseif kind in (:tuple, :parameters)
        for child in children
            collect_global_bindings!(diagnostics, child, path, offsets)
        end
    end
end

"""Report module-scope constants backed by mutable reference storage."""
function check_const_mutable_refs(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    diagnostics = Diagnostic[]
    collect_const_mutable_refs!(diagnostics, tree, path, offsets, :module)
    configured = Diagnostic[]
    for diagnostic in diagnostics
        item = configured_diagnostic(configuration, diagnostic)
        item === nothing || push!(configured, item)
    end
    return configured
end

"""Collect const reference bindings while respecting Julia lexical scopes."""
function collect_const_mutable_refs!(diagnostics, node, path, offsets, scope)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :module && length(children) >= 2
        collect_const_mutable_refs!(diagnostics, children[end], path, offsets, :module)
        return
    elseif kind == :const && scope == :module
        isempty(children) || collect_const_ref_assignment!(
            diagnostics, first(children), path, offsets)
        return
    elseif kind in (:local, :struct, :quote, :call, :macrocall)
        return
    elseif kind in (
        :function, :macro, :(->), :let, :for, :while, :generator,
        :comprehension, :do)
        for child in children
            collect_const_mutable_refs!(diagnostics, child, path, offsets, :local)
        end
        return
    end
    for child in children
        collect_const_mutable_refs!(diagnostics, child, path, offsets, scope)
    end
end

"""Report one const assignment when its value constructs mutable Ref storage."""
function collect_const_ref_assignment!(diagnostics, node, path, offsets)
    Symbol(JuliaSyntax.kind(node)) == :(=) || return
    children = something(JuliaSyntax.children(node), ())
    length(children) >= 2 || return
    is_mutable_ref_constructor(children[2]) || return
    append_const_ref_binding!(diagnostics, children[1], path, offsets)
end

"""Return whether an expression constructs a standard Julia reference cell."""
function is_mutable_ref_constructor(node)
    Symbol(JuliaSyntax.kind(node)) == :call || return false
    children = something(JuliaSyntax.children(node), ())
    isempty(children) && return false
    callee = first(children)
    if Symbol(JuliaSyntax.kind(callee)) == :curly
        parameters = something(JuliaSyntax.children(callee), ())
        isempty(parameters) && return false
        callee = first(parameters)
    end
    name = replace(strip(String(JuliaSyntax.sourcetext(callee))), " " => "")
    return name in ("Ref", "Core.Ref", "Base.Ref", "Base.RefValue")
end

"""Append one mutable-reference diagnostic for a const binding pattern."""
function append_const_ref_binding!(diagnostics, node, path, offsets)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :Identifier
        name = String(JuliaSyntax.sourcetext(node))
        name == "_" && return
        byte_offset = JuliaSyntax.first_byte(node)
        line = metric_line_for_offset(offsets, byte_offset)
        column = byte_offset - offsets[line] + 1
        push!(diagnostics, Diagnostic(
            "JULIA-CONST-MUTABLE-REF",
            Ignore,
            path,
            line,
            column,
            "Julia global `$(name)` is a const binding to mutable Ref storage; " *
                "keep mutable state local or pass it explicitly.",
            nothing,
            nothing,
            "julia-syntax",
            name,
            "const-ref-global",
            nothing,
            "probable"))
    elseif kind in (:(::), :kw) && !isempty(children)
        append_const_ref_binding!(diagnostics, first(children), path, offsets)
    end
end

"""Report Julia declarations that violate configured naming conventions."""
function check_naming(path, source, configuration)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    conventions = Dict(
        convention.kind => convention
        for convention in configuration.naming.conventions
        if convention.language == :julia)
    diagnostics = Diagnostic[]
    offsets = line_start_offsets(split(source, '\n'; keepempty=true))
    collect_naming!(diagnostics, tree, path, offsets, conventions, :top_level)
    function_convention = get(conventions, :function, nothing)
    if function_convention !== nothing && function_convention.allow_constructor_names
        type_names = Set(
            declaration.name
            for declaration in analyze_declarations(path, source)
            if declaration.kind == "type")
        filter!(diagnostic ->
            diagnostic.operation != "function" ||
                !(diagnostic.subject in type_names),
            diagnostics)
    end
    configured = Diagnostic[]
    for diagnostic in diagnostics
        item = configured_diagnostic(configuration, diagnostic)
        item === nothing || push!(configured, item)
    end
    return configured
end

"""Collect names only from syntax positions that declare identifiers."""
function collect_naming!(diagnostics, node, path, offsets, conventions, scope)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if kind == :module && length(children) >= 2
        check_name!(diagnostics, children[1], :module, path, offsets, conventions)
        collect_naming!(diagnostics, children[end], path, offsets, conventions, :module)
        return
    elseif kind in (:struct, :abstract, :primitive) && !isempty(children)
        collect_type_names!(diagnostics, kind, children, path, offsets, conventions)
        kind == :struct && return
    elseif kind in (:function, :macro) && length(children) >= 2
        collect_signature_names!(diagnostics, children[1], path, offsets, conventions)
        collect_naming!(diagnostics, children[end], path, offsets, conventions, :function)
        return
    elseif kind == :const && !isempty(children)
        collect_binding_names!(
            diagnostics, children[1], :constant, path, offsets, conventions)
        return
    elseif kind == :(=) && !isempty(children)
        collect_assignment_names!(
            diagnostics, children, path, offsets, conventions, scope) && return
    end
    for child in children
        collect_naming!(diagnostics, child, path, offsets, conventions, scope)
    end
end

"""Collect a declared type name and any struct fields."""
function collect_type_names!(diagnostics, kind, children, path, offsets, conventions)
    check_name!(diagnostics, children[1], :type, path, offsets, conventions)
    kind == :struct && length(children) >= 2 && collect_struct_fields!(
        diagnostics, children[end], path, offsets, conventions)
end

"""Collect names introduced by long-form and short-form assignments."""
function collect_assignment_names!(
    diagnostics,
    children,
    path,
    offsets,
    conventions,
    scope)
    if is_call_signature(children[1])
        collect_signature_names!(diagnostics, children[1], path, offsets, conventions)
        length(children) >= 2 && collect_naming!(
            diagnostics, children[end], path, offsets, conventions, :function)
        return true
    end
    scope == :function && collect_binding_names!(
        diagnostics, children[1], :variable, path, offsets, conventions)
    return false
end

"""Collect struct field declarations without inspecting referenced type names."""
function collect_struct_fields!(diagnostics, block, path, offsets, conventions)
    for field in something(JuliaSyntax.children(block), ())
        field_kind = Symbol(JuliaSyntax.kind(field))
        children = something(JuliaSyntax.children(field), ())
        if field_kind in (:(::), :(=)) && !isempty(children)
            collect_binding_names!(
                diagnostics, children[1], :field, path, offsets, conventions)
        elseif field_kind == :Identifier
            check_name!(diagnostics, field, :field, path, offsets, conventions)
        elseif field_kind in (:function, :macro)
            collect_naming!(
                diagnostics, field, path, offsets, conventions, :function)
        end
    end
end

"""Collect a function name and its declared parameters from a signature."""
function collect_signature_names!(diagnostics, signature, path, offsets, conventions)
    kind = Symbol(JuliaSyntax.kind(signature))
    children = something(JuliaSyntax.children(signature), ())
    if kind in (:where, :(::)) && !isempty(children)
        collect_signature_names!(diagnostics, children[1], path, offsets, conventions)
    elseif kind == :call && !isempty(children)
        check_name!(diagnostics, children[1], :function, path, offsets, conventions)
        for parameter in Iterators.drop(children, 1)
            collect_binding_names!(
                diagnostics, parameter, :parameter, path, offsets, conventions)
        end
    elseif kind == :Identifier
        check_name!(diagnostics, signature, :function, path, offsets, conventions)
    end
end

"""Return whether a syntax node is a call-shaped method signature."""
function is_call_signature(node)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    return kind == :call ||
        (kind in (:where, :(::)) && !isempty(children) && is_call_signature(children[1]))
end

"""Collect identifiers from a binding pattern while ignoring type expressions."""
function collect_binding_names!(diagnostics, node, kind, path, offsets, conventions)
    node_kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    if node_kind == :Identifier
        check_name!(diagnostics, node, kind, path, offsets, conventions)
    elseif node_kind in (:(::), :kw, :(...), :(=)) && !isempty(children)
        collect_binding_names!(diagnostics, children[1], kind, path, offsets, conventions)
    elseif node_kind in (:tuple, :parameters)
        for child in children
            collect_binding_names!(diagnostics, child, kind, path, offsets, conventions)
        end
    end
end

"""Append one configured naming diagnostic when a declaration name is invalid."""
function check_name!(diagnostics, node, kind, path, offsets, conventions)
    convention = get(conventions, kind, nothing)
    convention === nothing && return
    Symbol(JuliaSyntax.kind(node)) == :Identifier || return
    name = String(JuliaSyntax.sourcetext(node))
    valid_identifier_name(name, convention) && return
    byte_offset = JuliaSyntax.first_byte(node)
    line = metric_line_for_offset(offsets, byte_offset)
    column = byte_offset - offsets[line] + 1
    kind_name = replace(string(kind), '_' => ' ')
    diagnostic = Diagnostic(
        "JULIA-NAMING",
        Ignore,
        path,
        line,
        column,
        "Julia $(kind_name) `$(name)` must use $(convention.casing).",
        nothing,
        nothing,
        "julia-syntax",
        name,
        string(kind),
        nothing,
        "stable")
    push!(diagnostics, diagnostic)
end

"""Report same-name Julia function families without any attached docstring."""
function check_documentation(path, source, configuration)
    diagnostics = Diagnostic[]
    functions = analyze_functions(path, source)
    documentation = function_documentation(source)
    documented_names = Set(name for (name, texts) in documentation
        if any(
            text -> occursin(configuration.documentation.julia_template, text),
            texts))
    reported_names = Set{String}()
    for item in functions
        # Docstrings attach to the bare macro name; normalize the `@`-prefixed
        # family name CodeComplexity reports for macro definitions before matching.
        family = startswith(item.name, "@") ? item.name[2:end] : item.name
        (item.name == "<anonymous>" || family in documented_names ||
            item.name in documented_names || item.name in reported_names) && continue
        push!(reported_names, item.name)
        diagnostic = Diagnostic(
            "JULIA-DOC-MISSING",
            Ignore,
            path,
            item.start_line,
            1,
            "Julia function family `$(item.name)` requires at least one " *
                "docstring matching the configured template.",
            nothing,
            nothing,
            "julia-syntax",
            item.name,
            "documentation",
            nothing,
            "stable")
        configured = configured_diagnostic(configuration, diagnostic)
        configured === nothing || push!(diagnostics, configured)
    end
    return diagnostics
end

"""Return parser-attached docstring text grouped by Julia function family."""
function function_documentation(source)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source)
    documentation = Dict{String, Vector{String}}()
    collect_function_documentation!(documentation, tree)
    return documentation
end

"""Collect doc node text for directly attached named function declarations."""
function collect_function_documentation!(documentation, node)
    children = something(JuliaSyntax.children(node), ())
    if Symbol(JuliaSyntax.kind(node)) == :doc && length(children) >= 2
        declaration = unwrap_documented_function(last(children))
        if declaration !== nothing
            name = function_family_name(declaration)
            text = documentation_text(first(children))
            push!(get!(documentation, name, String[]), text)
        end
        collect_function_documentation!(documentation, last(children))
        return
    end
    for child in children
        collect_function_documentation!(documentation, child)
    end
end

"""Unwrap attribute macros and where clauses to reach a function-like node."""
function unwrap_documented_function(node)
    kind = Symbol(JuliaSyntax.kind(node))
    children = something(JuliaSyntax.children(node), ())
    kind in (:function, :macro) && return node
    if kind in (:macrocall, :where) && !isempty(children)
        for child in children
            unwrapped = unwrap_documented_function(child)
            unwrapped !== nothing && return unwrapped
        end
    end
    return nothing
end

"""Return content text from a JuliaSyntax string node."""
function documentation_text(node)
    children = something(JuliaSyntax.children(node), ())
    if Symbol(JuliaSyntax.kind(node)) == :string
        return join(String(JuliaSyntax.sourcetext(child)) for child in children)
    end
    for child in children
        text = documentation_text(child)
        isempty(text) || return text
    end
    return ""
end

"""Return a configured diagnostic when Julia source cannot be parsed."""
function check_syntax(
    path::String,
    source::String,
    configuration::EffectiveSettings=load_settings())
    try
        JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
        return Diagnostic[]
    catch error
        error isa JuliaSyntax.ParseError || rethrow()
        diagnostic = Diagnostic(
            "JULIA-SYNTAX",
            Ignore,
            path,
            1,
            1,
            sprint(showerror, error),
            nothing,
            nothing,
            "julia-syntax")
        configured = configured_diagnostic(configuration, diagnostic)
        return configured === nothing ? Diagnostic[] : [configured]
    end
end

"""Return parser-backed measurements for every Julia function-like definition."""
function analyze_functions(path::String, source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source; filename=path)
    lines = split(source, '\n'; keepempty=true)
    offsets = line_start_offsets(lines)
    functions = FunctionAnalysis[]
    collect_functions!(functions, tree, path, source, lines, offsets, false)
    return functions
end

"""Return nonblank source lines occupied only by attached Julia docstrings."""
function documentation_comment_lines(source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source)
    lines = split(source, '\n'; keepempty=true)
    offsets = line_start_offsets(lines)
    comment_lines = Set{Int}()
    collect_documentation_comment_lines!(comment_lines, tree, lines, offsets)
    return comment_lines
end

"""Return the number of parser-backed Julia struct declarations."""
function struct_count(source::String)
    tree = JuliaSyntax.parseall(JuliaSyntax.SyntaxNode, source)
    return count_structs(tree)
end

"""Count struct nodes recursively, including mutable struct declarations."""
function count_structs(node)
    count = Symbol(JuliaSyntax.kind(node)) == :struct ? 1 : 0
    for child in something(JuliaSyntax.children(node), ())
        count += count_structs(child)
    end
    return count
end

"""Collect line spans for doc expressions without consuming their declarations."""
function collect_documentation_comment_lines!(results, node, lines, offsets)
    children = something(JuliaSyntax.children(node), ())
    if Symbol(JuliaSyntax.kind(node)) == :doc && length(children) >= 2
        documentation = first(children)
        declaration = last(children)
        first_line = metric_line_for_offset(
            offsets, JuliaSyntax.first_byte(documentation))
        last_line = metric_line_for_offset(
            offsets, JuliaSyntax.last_byte(documentation))
        declaration_line = metric_line_for_offset(
            offsets, JuliaSyntax.first_byte(declaration))
        for line_number in first_line:last_line
            line_number == declaration_line && continue
            isempty(strip(lines[line_number])) || push!(results, line_number)
        end
        collect_documentation_comment_lines!(results, declaration, lines, offsets)
        return
    end
    for child in children
        collect_documentation_comment_lines!(results, child, lines, offsets)
    end
end

"""Return one-based byte offsets for the beginning of each source line."""
function line_start_offsets(lines)
    offsets = Int[]
    offset = 1
    for line in lines
        push!(offsets, offset)
        offset += ncodeunits(line) + 1
    end
    return offsets
end

"""Return the metric source line containing a one-based byte offset."""
function metric_line_for_offset(offsets, byte_offset)
    return searchsortedlast(offsets, byte_offset)
end

"""Collect named function metrics while preserving docstring attachment state."""
function collect_functions!(results, node, path, source, lines, offsets, documented)
    node_kind = Symbol(JuliaSyntax.kind(node))
    node_children = JuliaSyntax.children(node)
    children = something(node_children, ())
    if node_kind == :doc
        length(children) >= 2 && collect_functions!(
            results, children[end], path, source, lines, offsets, true)
        return
    elseif node_kind in (:function, :macro, :(->)) && node_children !== nothing
        push!(results, function_analysis(
            node, path, source, lines, offsets, documented))
    end
    for child in children
        collect_functions!(results, child, path, source, lines, offsets, false)
    end
end

"""Build one metric record using CodeComplexity as the scoring authority."""
function function_analysis(node, path, source, lines, offsets, documented)
    children = JuliaSyntax.children(node)
    body = last(children)
    start_line = metric_line_for_offset(offsets, JuliaSyntax.first_byte(node))
    end_line = metric_line_for_offset(offsets, JuliaSyntax.last_byte(node))
    definition_source = String(JuliaSyntax.sourcetext(node))
    cyclomatic = first_measure(CYCLOMATIC, definition_source)
    cognitive = first_measure(COGNITIVE, definition_source)
    parameter_count = positional_parameter_count(node)
    executable = body_executable_lines(body, path, lines, offsets)
    return FunctionAnalysis(
        path,
        "julia",
        cyclomatic.name;
        start_line,
        end_line,
        executable_lines=executable,
        parameter_count,
        cyclomatic_complexity=cyclomatic.value,
        cognitive_complexity=cognitive.value,
        documented)
end

"""Count a Julia function's positional parameters, excluding all keywords."""
function positional_parameter_count(node)
    children = something(JuliaSyntax.children(node), ())
    isempty(children) && return 0
    signature = children[1]
    if Symbol(JuliaSyntax.kind(node)) == :(->)
        signature_children = something(JuliaSyntax.children(signature), ())
        return Symbol(JuliaSyntax.kind(signature)) == :tuple ?
            count(
                child -> Symbol(JuliaSyntax.kind(child)) != :parameters,
                signature_children) : 1
    end
    return named_signature_parameter_count(signature)
end

"""Count positional entries in a named Julia method signature."""
function named_signature_parameter_count(signature)
    kind = Symbol(JuliaSyntax.kind(signature))
    children = something(JuliaSyntax.children(signature), ())
    if kind in (:where, :(::)) && !isempty(children)
        return named_signature_parameter_count(children[1])
    elseif kind != :call || isempty(children)
        return 0
    end
    return count(
        child -> Symbol(JuliaSyntax.kind(child)) != :parameters,
        Iterators.drop(children, 1))
end

"""Return the outer definition measurement from a function-like source span."""
function first_measure(metric, source)
    measurements = measure_report(metric, source)
    isempty(measurements) && error(
        "CodeComplexity did not recognize a Julia function-like definition")
    return first(measurements)
end

"""Return the normalized family name for one function-like definition span.

CodeComplexity reports macro definitions with a leading `@`, but docstrings attach to
the bare identifier, so the `@` is stripped to align the family name with its docs."""
function function_family_name(node)
    raw = first_measure(CYCLOMATIC, String(JuliaSyntax.sourcetext(node))).name
    return startswith(raw, "@") ? raw[2:end] : raw
end

"""Count nonblank, non-comment-only lines covered by a function body."""
function body_executable_lines(body, path, lines, offsets)
    start_line = metric_line_for_offset(offsets, JuliaSyntax.first_byte(body))
    end_line = metric_line_for_offset(offsets, JuliaSyntax.last_byte(body))
    Symbol(JuliaSyntax.kind(body)) == :block && (start_line += 1)
    start_line > end_line && return 0
    return executable_source_lines(path, lines, start_line, end_line)
end

end