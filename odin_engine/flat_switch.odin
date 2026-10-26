package main

import "core:odin/ast"

Flat_Switch_Expression_State :: struct {
    valid: bool,
}

// Reject expression-local decisions without descending into separate procedure scopes.
visit_flat_switch_expression :: proc(
    visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
    if node == nil {
        return visitor
    }
    state := (^Flat_Switch_Expression_State)(visitor.data)
    #partial switch expression in node.derived {
    case ^ast.Proc_Lit:
        return nil
    case ^ast.Bad_Expr, ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr,
         ^ast.Or_Else_Expr, ^ast.Or_Return_Expr, ^ast.Or_Branch_Expr,
         ^ast.Inline_Asm_Expr:
        state.valid = false
        return nil
    case ^ast.Binary_Expr:
        if expression.op.kind == .Cmp_And || expression.op.kind == .Cmp_Or {
            state.valid = false
            return nil
        }
    case ^ast.Assign_Stmt:
        if expression.op.kind == .Cmp_And_Eq || expression.op.kind == .Cmp_Or_Eq {
            state.valid = false
            return nil
        }
    }
    return visitor
}

// Check expression decisions in one already-admitted statement or switch header.
flat_switch_expression_safe :: proc(node: ^ast.Node) -> bool {
    if node == nil {
        return true
    }
    state: Flat_Switch_Expression_State = {valid = true}
    visitor: ast.Visitor = {visit = visit_flat_switch_expression, data = &state}
    ast.walk(&visitor, node)
    return state.valid
}

// Admit only simple executable statements; control and unknown forms fail closed.
flat_switch_simple_statement :: proc(statement: ^ast.Stmt) -> bool {
    #partial switch value in statement.derived {
    case ^ast.Return_Stmt, ^ast.Assign_Stmt, ^ast.Value_Decl:
        return flat_switch_expression_safe(statement)
    case ^ast.Expr_Stmt:
        _, call := ast.unparen_expr(value.expr).derived.(^ast.Call_Expr)
        return call && flat_switch_expression_safe(statement)
    }
    return false
}

// Count actual case statements through transparent blocks, rejecting hidden logic.
flat_switch_case_count :: proc(statements: []^ast.Stmt) -> (int, bool) {
    count := 0
    for statement in statements {
        if statement == nil {
            continue
        }
        #partial switch value in statement.derived {
        case ^ast.Empty_Stmt:
            continue
        case ^ast.Block_Stmt:
            nested, valid := flat_switch_case_count(value.stmts)
            if !valid || value.label != nil || value.uses_do {
                return 0, false
            }
            count += nested
            continue
        }
        if !flat_switch_simple_statement(statement) {
            return 0, false
        }
        count += 1
    }
    return count, count <= 1
}

// Validate switch labels and all cases without treating them as extra decisions.
flat_switch_cases_safe :: proc(body: ^ast.Stmt) -> bool {
    if body == nil {
        return false
    }
    block, ok := body.derived.(^ast.Block_Stmt)
    if !ok {
        return false
    }
    for statement in block.stmts {
        clause, is_case := statement.derived.(^ast.Case_Clause)
        if !is_case {
            return false
        }
        for label in clause.list {
            if !flat_switch_expression_safe(label) {
                return false
            }
        }
        _, valid := flat_switch_case_count(clause.body)
        if !valid {
            return false
        }
    }
    return true
}

// Validate ordinary and type-switch headers independently of their case bodies.
flat_switch_statement_safe :: proc(statement: ^ast.Stmt) -> bool {
    #partial switch value in statement.derived {
    case ^ast.Switch_Stmt:
        return value.label == nil &&
            (value.init == nil || flat_switch_simple_statement(value.init)) &&
            flat_switch_expression_safe(value.cond) && flat_switch_cases_safe(value.body)
    case ^ast.Type_Switch_Stmt:
        return value.label == nil &&
            (value.tag == nil || flat_switch_simple_statement(value.tag)) &&
            flat_switch_expression_safe(value.expr) && flat_switch_cases_safe(value.body)
    }
    return false
}

// Retain unique code-bearing outside lines, excluding comments and brace-only lines.
flat_switch_append_lines :: proc(
    data: ^Analysis_Visitor_Data,
    statement: ^ast.Stmt,
    lines: ^[dynamic]int) {
    start := token_index_at_or_after(data.tokens, statement.pos.offset)
    for index := start; index < len(data.tokens) &&
        data.tokens[index].pos.offset < statement.end.offset; index += 1 {
        token := data.tokens[index]
        if !initializer_code_token(token) ||
            token.kind == .Open_Brace || token.kind == .Close_Brace ||
            token.kind == .Semicolon {
            continue
        }
        line := token.pos.line
        if len(lines^) == 0 || lines^[len(lines^) - 1] != line {
            append(lines, line)
        }
        for byte in token.text {
            if byte == '\n' {
                line += 1
                if lines^[len(lines^) - 1] != line {
                    append(lines, line)
                }
            }
        }
    }
}

// Collect policy-neutral flat-switch shape and outside-line evidence for one body.
flat_switch_evidence :: proc(
    data: ^Analysis_Visitor_Data,
    procedure: ^ast.Proc_Lit) -> (bool, [dynamic]int) {
    lines := make([dynamic]int, 0, data.allocator)
    if procedure.body == nil {
        return false, lines
    }
    body, ok := procedure.body.derived.(^ast.Block_Stmt)
    if !ok {
        return false, lines
    }
    switches := 0
    for statement in body.stmts {
        #partial switch _ in statement.derived {
        case ^ast.Empty_Stmt:
            continue
        case ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
            switches += 1
            if !flat_switch_statement_safe(statement) {
                return false, lines
            }
        case:
            if !flat_switch_simple_statement(statement) {
                return false, lines
            }
            flat_switch_append_lines(data, statement, &lines)
        }
    }
    return switches == 1, lines
}
