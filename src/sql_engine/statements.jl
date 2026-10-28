"""Inventory one executable statement, with trigger-body ownership kept explicit."""
function parse_statement!(parser, parent)
    start = parser.position
    previous = parser.statement
    index = length(parser.structure.statements) + 1
    kind = Symbol(lowercase(token_text(parser)))
    push!(parser.structure.statements, SQLStatementRecord(
        kind, token_span(parser), parent, false))
    parser.statement = index
    statement_body!(parser)
    terminated = accept!(parser, ";")
    !terminated && parser.position < parser.limit &&
        gap(parser, "Unsupported trailing statement syntax.")
    parser.structure.statements[index] = SQLStatementRecord(
        parser.structure.statements[index].kind,
        consumed_span(parser, start), parent, terminated)
    parser.statement = previous
end

"""Dispatch only supported statement families; unknown SQLite remains a capability gap."""
function statement_body!(parser)
    enter!(parser)
    if at(parser, "SELECT") || at(parser, "VALUES")
        parse_query!(parser)
    elseif accept!(parser, "WITH")
        with_statement!(parser)
    elseif accept!(parser, "CREATE")
        create_statement!(parser)
    elseif at(parser, "INSERT") || at(parser, "REPLACE")
        insert_statement!(parser)
    elseif accept!(parser, "UPDATE")
        update_statement!(parser)
    elseif accept!(parser, "DELETE")
        delete_statement!(parser)
    elseif accept!(parser, "PRAGMA")
        pragma_statement!(parser)
    elseif accept!(parser, "DROP")
        drop_statement!(parser)
    else
        control_statement!(parser)
    end
    parser.depth -= 1
end

"""Attach statement-level CTEs to their actual main query without inventing statements."""
function with_statement!(parser)
    start = parser.position - 1
    queries_before = length(parser.structure.queries)
    ctes_before = length(parser.structure.ctes)
    with_clause!(parser)
    main_query = length(parser.structure.queries) + 1
    query = at(parser, "SELECT") || at(parser, "VALUES")
    statement = parser.structure.statements[parser.statement]
    parser.structure.statements[parser.statement] = SQLStatementRecord(
        Symbol(lowercase(token_text(parser))), statement.span, statement.parent, false)
    statement_body!(parser)
    query || return
    for index in (queries_before + 1):(main_query - 1)
        item = parser.structure.queries[index]
        item.parent === nothing || continue
        parser.structure.queries[index] = SQLQueryRecord(
            item.kind, item.span, item.statement, main_query)
    end
    for index in (ctes_before + 1):length(parser.structure.ctes)
        item = parser.structure.ctes[index]
        item.parent_query === nothing || continue
        parser.structure.ctes[index] = SQLCTERecord(
            item.name, item.span, item.statement, main_query)
    end
    main = parser.structure.queries[main_query]
    span = SQLSourceSpan(token_span(parser, start).first_byte, main.span.after_last_byte)
    parser.structure.queries[main_query] = SQLQueryRecord(
        main.kind, span, main.statement, main.parent)
end

"""Consume CREATE object options without treating object/column names as keywords."""
function create_statement!(parser)
    temporary = accept!(parser, "TEMP") || accept!(parser, "TEMPORARY")
    unique = accept!(parser, "UNIQUE")
    virtual = accept!(parser, "VIRTUAL")
    kind = uppercase(token_text(parser))
    kind in ("TABLE", "VIEW", "INDEX", "TRIGGER") ||
        gap(parser, "Unsupported CREATE object.")
    expect!(parser, kind)
    unique && kind != "INDEX" && gap(parser, "Unsupported UNIQUE declaration.")
    virtual && kind != "TABLE" && gap(parser, "Unsupported VIRTUAL declaration.")
    if accept!(parser, "IF")
        expect!(parser, "NOT")
        expect!(parser, "EXISTS")
    end
    schema, name = object_name!(parser)
    options = declaration_body!(parser, kind, virtual)
    push!(parser.structure.declarations, SQLDeclarationRecord(
        virtual ? :virtual_table : Symbol(lowercase(kind)), name, schema, temporary,
        options.strict, options.without_rowid, options.module_name,
        options.module_arguments, options.partial_predicate))
end

"""Parse object-specific bodies and preserve virtual module arguments as opaque syntax."""
function declaration_body!(parser, kind, virtual)
    strict = false
    without_rowid = false
    module_name = nothing
    arguments = nothing
    predicate = nothing
    if virtual
        expect!(parser, "USING")
        module_name = identifier!(parser)
        at(parser, "(") && (arguments = opaque_group!(parser))
    elseif kind == "TABLE"
        strict, without_rowid = table_body!(parser)
    elseif kind == "VIEW"
        at(parser, "(") && identifier_list!(parser)
        expect!(parser, "AS")
        parse_query!(parser)
    elseif kind == "INDEX"
        predicate = index_body!(parser)
    else
        trigger_body!(parser)
    end
    return (; strict, without_rowid, module_name, module_arguments=arguments,
        partial_predicate=predicate)
end

"""Parse columns and table constraints, recording STRICT/WITHOUT ROWID deliberately."""
function table_body!(parser)
    if accept!(parser, "AS")
        parse_query!(parser)
        return false, false
    end
    expect!(parser, "(")
    while true
        table_element!(parser)
        accept!(parser, ",") || break
    end
    expect!(parser, ")")
    strict = false
    without_rowid = false
    while at(parser, "STRICT") || at(parser, "WITHOUT")
        if accept!(parser, "STRICT")
            strict = true
        else
            expect!(parser, "WITHOUT")
            expect!(parser, "ROWID")
            without_rowid = true
        end
        accept!(parser, ",") || break
    end
    return strict, without_rowid
end

const COLUMN_CONSTRAINTS = Set((
    "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT",
    "COLLATE", "REFERENCES", "GENERATED", "AS"))

"""Separate declaration identifiers/types from grammar-defined column constraints."""
function table_element!(parser)
    accept!(parser, "CONSTRAINT") && identifier!(parser)
    if at(parser, "PRIMARY") || at(parser, "UNIQUE") || at(parser, "CHECK") ||
        at(parser, "FOREIGN")
        table_constraint!(parser)
        return
    end
    identifier!(parser)
    while token_kind(parser) in (:word, :quoted_identifier) &&
        uppercase(token_text(parser)) ∉ COLUMN_CONSTRAINTS
        identifier!(parser)
    end
    at(parser, "(") && opaque_group!(parser)
    while token_kind(parser) == :word &&
        uppercase(token_text(parser)) in COLUMN_CONSTRAINTS
        column_constraint!(parser)
    end
end

"""Parse table-wide constraints; expression commas stay within their groups."""
function table_constraint!(parser)
    if accept!(parser, "PRIMARY")
        expect!(parser, "KEY")
        indexed_columns!(parser)
        conflict_clause!(parser)
    elseif accept!(parser, "UNIQUE")
        indexed_columns!(parser)
        conflict_clause!(parser)
    elseif accept!(parser, "FOREIGN")
        expect!(parser, "KEY")
        identifier_list!(parser)
        expect!(parser, "REFERENCES")
        references_clause!(parser)
    else
        expect!(parser, "CHECK")
        grouped_expression!(parser)
    end
end

"""Consume one column constraint and its optional conflict/foreign-key policy."""
function column_constraint!(parser)
    if accept!(parser, "CONSTRAINT")
        identifier!(parser)
    elseif accept!(parser, "PRIMARY")
        expect!(parser, "KEY")
        accept!(parser, "ASC") || accept!(parser, "DESC")
        conflict_clause!(parser)
        accept!(parser, "AUTOINCREMENT")
    elseif accept!(parser, "NOT")
        expect!(parser, "NULL")
        conflict_clause!(parser)
    elseif accept!(parser, "NULL") || accept!(parser, "UNIQUE")
        conflict_clause!(parser)
    elseif accept!(parser, "CHECK")
        grouped_expression!(parser)
    elseif accept!(parser, "DEFAULT")
        expression!(parser, 8)
    elseif accept!(parser, "COLLATE")
        identifier!(parser)
    elseif accept!(parser, "REFERENCES")
        references_clause!(parser)
    else
        generated_constraint!(parser)
    end
end

"""Recognize generated expressions without interpreting VIRTUAL module arguments."""
function generated_constraint!(parser)
    if accept!(parser, "GENERATED")
        accept!(parser, "ALWAYS")
    end
    expect!(parser, "AS")
    grouped_expression!(parser)
    accept!(parser, "STORED") || accept!(parser, "VIRTUAL")
end

"""Consume a single parenthesized expression, including nested scalar queries."""
function grouped_expression!(parser)
    expect!(parser, "(")
    expression!(parser)
    expect!(parser, ")")
end

"""Parse ON CONFLICT algorithms only at grammar positions where they are keywords."""
function conflict_clause!(parser)
    accept!(parser, "ON") || return
    expect!(parser, "CONFLICT")
    algorithm = uppercase(token_text(parser))
    algorithm in ("ROLLBACK", "ABORT", "FAIL", "IGNORE", "REPLACE") ||
        gap(parser, "Unsupported conflict algorithm.")
    expect!(parser, algorithm)
end

"""Parse REFERENCES actions and deferrability without assigning declaration aliases."""
function references_clause!(parser)
    identifier!(parser)
    at(parser, "(") && identifier_list!(parser)
    while at(parser, "ON") || at(parser, "MATCH")
        if accept!(parser, "MATCH")
            identifier!(parser)
        else
            expect!(parser, "ON")
            accept!(parser, "DELETE") || expect!(parser, "UPDATE")
            reference_action!(parser)
        end
    end
    if accept!(parser, "NOT")
        expect!(parser, "DEFERRABLE")
    else
        accept!(parser, "DEFERRABLE")
    end
    if accept!(parser, "INITIALLY")
        accept!(parser, "DEFERRED") || expect!(parser, "IMMEDIATE")
    end
end

"""Consume one foreign-key action, preserving column defaults as separate syntax."""
function reference_action!(parser)
    if accept!(parser, "SET")
        accept!(parser, "NULL") || expect!(parser, "DEFAULT")
    elseif accept!(parser, "NO")
        expect!(parser, "ACTION")
    else
        accept!(parser, "CASCADE") || expect!(parser, "RESTRICT")
    end
end

"""Parse index terms and an optional partial-index predicate."""
function index_body!(parser)
    expect!(parser, "ON")
    object_name!(parser)
    indexed_columns!(parser)
    accept!(parser, "WHERE") || return nothing
    start = parser.position
    expression!(parser)
    return consumed_span(parser, start)
end

"""Parse indexed columns/expressions and sort direction without exposing projections."""
function indexed_columns!(parser)
    expect!(parser, "(")
    ordering_list!(parser)
    expect!(parser, ")")
end

"""Parse trigger boundaries explicitly; body statements keep parent identities."""
function trigger_body!(parser)
    if accept!(parser, "INSTEAD")
        expect!(parser, "OF")
    else
        accept!(parser, "BEFORE") || accept!(parser, "AFTER")
    end
    if accept!(parser, "UPDATE")
        if accept!(parser, "OF")
            identifier!(parser)
            while accept!(parser, ",")
                identifier!(parser)
            end
        end
    else
        accept!(parser, "INSERT") || expect!(parser, "DELETE")
    end
    expect!(parser, "ON")
    object_name!(parser)
    if accept!(parser, "FOR")
        expect!(parser, "EACH")
        expect!(parser, "ROW")
    end
    accept!(parser, "WHEN") && expression!(parser)
    expect!(parser, "BEGIN")
    while !at(parser, "END")
        parser.position < parser.limit || gap(parser, "Unclosed trigger body.")
        parse_statement!(parser, parser.statement)
        last(parser.structure.statements).terminated ||
            gap(parser, "Trigger body statement has no terminator.")
    end
    expect!(parser, "END")
end

"""Parse INSERT/REPLACE and UPSERT/RETURNING without changing bind or projection order."""
function insert_statement!(parser)
    if accept!(parser, "INSERT")
        mutation_conflict!(parser)
    else
        expect!(parser, "REPLACE")
    end
    expect!(parser, "INTO")
    object_name!(parser)
    alias!(parser, :target)
    at(parser, "(") && identifier_list!(parser)
    if accept!(parser, "DEFAULT")
        expect!(parser, "VALUES")
    elseif accept!(parser, "VALUES")
        values_rows!(parser)
    else
        parse_query!(parser)
    end
    while accept!(parser, "ON")
        expect!(parser, "CONFLICT")
        upsert_clause!(parser)
    end
    returning_clause!(parser)
end

"""Consume a mutation's optional OR conflict policy."""
function mutation_conflict!(parser)
    accept!(parser, "OR") || return
    algorithm = uppercase(token_text(parser))
    algorithm in ("ROLLBACK", "ABORT", "FAIL", "IGNORE", "REPLACE") ||
        gap(parser, "Unsupported mutation conflict policy.")
    expect!(parser, algorithm)
end

"""Separate UPSERT targets, action assignments and RETURNING interfaces."""
function upsert_clause!(parser)
    if at(parser, "(")
        indexed_columns!(parser)
        accept!(parser, "WHERE") && expression!(parser)
    end
    expect!(parser, "DO")
    accept!(parser, "NOTHING") && return
    expect!(parser, "UPDATE")
    expect!(parser, "SET")
    assignments!(parser)
    accept!(parser, "WHERE") && expression!(parser)
end

"""Parse UPDATE FROM plus its separate result interface."""
function update_statement!(parser)
    mutation_conflict!(parser)
    object_name!(parser)
    alias!(parser, :target)
    expect!(parser, "SET")
    assignments!(parser)
    accept!(parser, "FROM") && from_clause!(parser)
    accept!(parser, "WHERE") && expression!(parser)
    returning_clause!(parser)
    query_tail!(parser)
end

"""Parse DELETE without imposing a blanket WHERE or ORDER BY policy."""
function delete_statement!(parser)
    expect!(parser, "FROM")
    object_name!(parser)
    alias!(parser, :target)
    accept!(parser, "WHERE") && expression!(parser)
    returning_clause!(parser)
    query_tail!(parser)
end

"""Parse assignment targets separately from expressions and result aliases."""
function assignments!(parser)
    while true
        at(parser, "(") ? identifier_list!(parser) : object_name!(parser)
        expect!(parser, "=")
        expression!(parser)
        accept!(parser, ",") || break
    end
end

"""Represent RETURNING projections as their own query-interface region."""
function returning_clause!(parser)
    accept!(parser, "RETURNING") || return
    start = parser.position
    previous = parser.query
    index = length(parser.structure.queries) + 1
    push!(parser.structure.queries, SQLQueryRecord(
        :returning, token_span(parser), parser.statement, previous))
    parser.query = index
    projection_list!(parser)
    parser.structure.queries[index] = SQLQueryRecord(
        :returning, consumed_span(parser, start), parser.statement, previous)
    parser.query = previous
end

"""Recognize PRAGMA context without treating pragma names or values as SQL keywords."""
function pragma_statement!(parser)
    object_name!(parser)
    if accept!(parser, "=")
        expression!(parser)
    elseif accept!(parser, "(")
        expression!(parser)
        expect!(parser, ")")
    end
end

"""Consume supported DROP declarations without adding source declaration counts."""
function drop_statement!(parser)
    kind = uppercase(token_text(parser))
    kind in ("TABLE", "VIEW", "INDEX", "TRIGGER") || gap(parser, "Unsupported DROP object.")
    expect!(parser, kind)
    if accept!(parser, "IF")
        expect!(parser, "EXISTS")
    end
    object_name!(parser)
end

"""Recognize transaction/control statements without imposing a rollback wrapper."""
function control_statement!(parser)
    if accept!(parser, "BEGIN")
        accept!(parser, "DEFERRED") || accept!(parser, "IMMEDIATE") ||
            accept!(parser, "EXCLUSIVE")
        accept!(parser, "TRANSACTION")
    elseif accept!(parser, "COMMIT") || accept!(parser, "END")
        accept!(parser, "TRANSACTION")
    elseif accept!(parser, "ROLLBACK")
        accept!(parser, "TRANSACTION")
        if accept!(parser, "TO")
            accept!(parser, "SAVEPOINT")
            identifier!(parser)
        end
    elseif accept!(parser, "SAVEPOINT") || accept!(parser, "RELEASE")
        accept!(parser, "SAVEPOINT")
        identifier!(parser)
    elseif accept!(parser, "ANALYZE") || accept!(parser, "REINDEX")
        token_kind(parser) in (:word, :quoted_identifier) && object_name!(parser)
    else
        gap(parser, "Unsupported SQLite statement family.")
    end
end
