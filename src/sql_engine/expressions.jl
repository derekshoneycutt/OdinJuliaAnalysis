const BINARY_PRECEDENCE = Dict(
    "OR" => 1, "AND" => 2,
    "=" => 3, "==" => 3, "!=" => 3, "<>" => 3, "<" => 3, ">" => 3,
    "<=" => 3, ">=" => 3, "IS" => 3, "IN" => 3, "LIKE" => 3,
    "GLOB" => 3, "MATCH" => 3, "REGEXP" => 3, "BETWEEN" => 3,
    "|" => 4, "&" => 4, "<<" => 4, ">>" => 4,
    "+" => 5, "-" => 5, "*" => 6, "/" => 6, "%" => 6,
    "||" => 7, "->" => 7, "->>" => 7)
const NEGATABLE_OPERATORS = ("IN", "LIKE", "GLOB", "MATCH", "REGEXP", "BETWEEN")

"""Parse enough SQLite expression structure to locate interfaces and subqueries."""
function expression!(parser, minimum=0)
    enter!(parser)
    primary!(parser)
    while parser.position < parser.limit
        if accept!(parser, "COLLATE")
            identifier!(parser)
            continue
        elseif accept!(parser, "ISNULL") || accept!(parser, "NOTNULL")
            continue
        elseif at(parser, "NOT") && at(parser, "NULL", parser.position + 1)
            expect!(parser, "NOT")
            expect!(parser, "NULL")
            continue
        end
        operator, negated = binary_operator(parser)
        precedence = get(BINARY_PRECEDENCE, operator, -1)
        precedence >= minimum || break
        negated && expect!(parser, "NOT")
        expect!(parser, operator)
        binary_operand!(parser, operator, precedence)
    end
    parser.depth -= 1
end

"""Select binary operators without consuming adjacent aliases or clause names."""
function binary_operator(parser)
    text = uppercase(token_text(parser))
    token_kind(parser) in (:word, :operator) || return "", false
    if text == "NOT"
        following = uppercase(token_text(parser, parser.position + 1))
        following in NEGATABLE_OPERATORS && return String(following), true
    end
    return String(text), false
end

"""Parse special operator operands without mistaking BETWEEN's AND for a clause."""
function binary_operand!(parser, operator, precedence)
    if operator == "BETWEEN"
        expression!(parser, precedence + 1)
        expect!(parser, "AND")
        expression!(parser, precedence + 1)
    elseif operator == "IN"
        in_operand!(parser)
    elseif operator == "IS"
        accept!(parser, "NOT")
        if accept!(parser, "DISTINCT")
            expect!(parser, "FROM")
        end
        expression!(parser, precedence + 1)
    else
        expression!(parser, precedence + 1)
        operator in ("LIKE", "GLOB", "MATCH", "REGEXP") &&
            accept!(parser, "ESCAPE") && expression!(parser, precedence + 1)
    end
end

"""Parse IN lists, subqueries and SQLite table/table-function operands."""
function in_operand!(parser)
    if accept!(parser, "(")
        if query_start(parser)
            parse_query!(parser)
        elseif !at(parser, ")")
            expression_list!(parser)
        end
        expect!(parser, ")")
    else
        object_name!(parser)
        at(parser, "(") && function_arguments!(parser)
    end
end

"""Parse a primary expression without treating arbitrary identifier words as keywords."""
function primary!(parser)
    if accept!(parser, "+") || accept!(parser, "-") || accept!(parser, "~")
        expression!(parser, 8)
    elseif accept!(parser, "NOT")
        expression!(parser, 3)
    elseif accept!(parser, "EXISTS")
        expect!(parser, "(")
        parse_query!(parser; exists_only=true)
        expect!(parser, ")")
    elseif accept!(parser, "CASE")
        case_expression!(parser)
    elseif at(parser, "CAST") && at(parser, "(", parser.position + 1)
        cast_expression!(parser)
    elseif at(parser, "RAISE") && at(parser, "(", parser.position + 1)
        raise_expression!(parser)
    elseif accept!(parser, "(")
        parenthesized_expression!(parser)
    elseif token_kind(parser) in (:number, :string, :blob, :bind)
        parser.position += 1
    else
        named_expression!(parser)
    end
end

"""Recognize trigger RAISE grammar separately from ordinary function-name identifiers."""
function raise_expression!(parser)
    expect!(parser, "RAISE")
    expect!(parser, "(")
    if !accept!(parser, "IGNORE")
        action = uppercase(token_text(parser))
        action in ("ROLLBACK", "ABORT", "FAIL") ||
            gap(parser, "Unsupported RAISE action.")
        expect!(parser, action)
        expect!(parser, ",")
        expression!(parser)
    end
    expect!(parser, ")")
end

"""Consume scalar or row expressions and independently expose nested query blocks."""
function parenthesized_expression!(parser)
    if query_start(parser)
        parse_query!(parser)
    else
        expression_list!(parser)
    end
    expect!(parser, ")")
end

"""Recognize literal keywords in expression positions, not declaration/name positions."""
function named_expression!(parser)
    if token_kind(parser) == :word &&
        uppercase(token_text(parser)) in
            ("NULL", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP")
        expect!(parser, uppercase(token_text(parser)))
        return
    end
    identifier!(parser)
    while accept!(parser, ".")
        accept!(parser, "*") && return
        identifier!(parser)
    end
    function_call = at(parser, "(")
    function_call && function_arguments!(parser)
    if function_call && at(parser, "FILTER") && at(parser, "(", parser.position + 1)
        expect!(parser, "FILTER")
        expect!(parser, "(")
        expect!(parser, "WHERE")
        expression!(parser)
        expect!(parser, ")")
    end
    function_call && at(parser, "OVER") &&
        gap(parser, "Window specifications are not structurally supported.")
end

"""Parse aggregate/function arguments, allowing COUNT(*) without exposed wildcard evidence."""
function function_arguments!(parser)
    expect!(parser, "(")
    accept!(parser, ")") && return
    if !accept!(parser, "*")
        accept!(parser, "DISTINCT")
        expression_list!(parser)
        if accept!(parser, "ORDER")
            expect!(parser, "BY")
            ordering_list!(parser)
        end
    end
    expect!(parser, ")")
end

"""Keep CAST target types separate from result aliases."""
function cast_expression!(parser)
    expect!(parser, "CAST")
    expect!(parser, "(")
    expression!(parser)
    expect!(parser, "AS")
    identifier!(parser)
    while token_kind(parser) in (:word, :quoted_identifier)
        identifier!(parser)
    end
    at(parser, "(") && opaque_group!(parser)
    expect!(parser, ")")
end

"""Match CASE/WHEN/END explicitly so trigger END is never an expression boundary."""
function case_expression!(parser)
    at(parser, "WHEN") || expression!(parser)
    expect!(parser, "WHEN")
    while true
        expression!(parser)
        expect!(parser, "THEN")
        expression!(parser)
        accept!(parser, "WHEN") || break
    end
    accept!(parser, "ELSE") && expression!(parser)
    expect!(parser, "END")
end

"""Consume a comma-separated expression region without including result aliases."""
function expression_list!(parser)
    expression!(parser)
    while accept!(parser, ",")
        expression!(parser)
    end
end

"""Parse ordering terms including explicit SQLite NULL ordering."""
function ordering_list!(parser)
    while true
        expression!(parser)
        accept!(parser, "ASC") || accept!(parser, "DESC")
        if accept!(parser, "NULLS")
            accept!(parser, "FIRST") || expect!(parser, "LAST")
        end
        accept!(parser, ",") || break
    end
end
