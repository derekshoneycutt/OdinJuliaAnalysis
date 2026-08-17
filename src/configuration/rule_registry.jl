const RULE_REGISTRY = Dict(
    "CALL-GRAPH-UNRESOLVED-EDGE" => RuleDefinition(
        "CALL-GRAPH-UNRESOLVED-EDGE", "common",
        "Call-Graph Reachability > Unresolved Edges",
        "experimental", "potential", "report", false),
    "ARCHITECTURE-FORBIDDEN-DEPENDENCY" => RuleDefinition(
        "ARCHITECTURE-FORBIDDEN-DEPENDENCY", "common",
        "Dependency Architecture > Allowed Directions",
        "experimental", "stable", "report", false),
    "ARCHITECTURE-DEPENDENCY-CYCLE" => RuleDefinition(
        "ARCHITECTURE-DEPENDENCY-CYCLE", "common",
        "Dependency Architecture > Cycles",
        "experimental", "stable", "report", false),
    "ARCHITECTURE-UNRESOLVED-INTERNAL-IMPORT" => RuleDefinition(
        "ARCHITECTURE-UNRESOLVED-INTERNAL-IMPORT", "common",
        "Dependency Architecture > Resolution",
        "experimental", "stable", "report", false),
    "COMMON-LINE-90" => RuleDefinition(
        "COMMON-LINE-90", "common", "Global Rules > Line Length",
        "mature", "stable", "warning", false),
    "COMMON-LINE-100" => RuleDefinition(
        "COMMON-LINE-100", "common", "Global Rules > Line Length",
        "mature", "stable", "warning", false),
    "COMMON-LINE-120" => RuleDefinition(
        "COMMON-LINE-120", "common", "Global Rules > Line Length",
        "mature", "stable", "error", false),
    "COMMON-NO-TABS" => RuleDefinition(
        "COMMON-NO-TABS", "common", "Odin Rules > Formatting",
        "mature", "stable", "error", false),
    "JULIA-SYNTAX" => RuleDefinition(
        "JULIA-SYNTAX", "julia", "Julia Rules (Required)",
        "mature", "stable", "error", true),
    "JULIA-CLOSING-PAREN-PLACEMENT" => RuleDefinition(
        "JULIA-CLOSING-PAREN-PLACEMENT", "julia",
        "Global Rules > Closing Parenthesis Placement (Absolute)",
        "mature", "stable", "error", false),
    "JULIA-JET-POSSIBLE-ERROR" => RuleDefinition(
        "JULIA-JET-POSSIBLE-ERROR", "julia",
        "Julia Rules > Static Inference Analysis",
        "experimental", "potential", "report", false),
    "JULIA-EMPTY-CATCH" => RuleDefinition(
        "JULIA-EMPTY-CATCH", "julia", "Error Handling > Empty Catch",
        "experimental", "definite", "report", false),
    "JULIA-BROAD-CATCH" => RuleDefinition(
        "JULIA-BROAD-CATCH", "julia", "Error Handling > Broad Catch",
        "experimental", "probable", "report", false),
    "JULIA-UNSIGNALED-ARGUMENT-MUTATION" => RuleDefinition(
        "JULIA-UNSIGNALED-ARGUMENT-MUTATION", "julia",
        "Mutation And Side Effects > Argument Mutation",
        "experimental", "definite", "report", false),
    "JULIA-GLOBAL-WRITE" => RuleDefinition(
        "JULIA-GLOBAL-WRITE", "julia",
        "Mutation And Side Effects > Global Writes",
        "experimental", "definite", "report", false),
    "JULIA-UNREACHABLE-FUNCTION" => RuleDefinition(
        "JULIA-UNREACHABLE-FUNCTION", "julia",
        "Call-Graph Reachability > Julia Functions",
        "experimental", "probable", "report", false),
    "JULIA-NAMING" => RuleDefinition(
        "JULIA-NAMING", "julia", "Julia Rules > Naming and API Semantics",
        "mature", "stable", "report", false),
    "JULIA-NONCONST-GLOBAL" => RuleDefinition(
        "JULIA-NONCONST-GLOBAL", "julia", "Global Rules > Mutable Globals",
        "mature", "stable", "warning", false),
    "JULIA-UNUSED-IMPORT" => RuleDefinition(
        "JULIA-UNUSED-IMPORT", "julia", "Julia Rules > Unused Imports",
        "experimental", "definite", "report", false),
    "JULIA-DECLARATION-ORDER" => RuleDefinition(
        "JULIA-DECLARATION-ORDER", "julia",
        "Global Rules > Declaration Order",
        "mature", "stable", "warning", false),
    "JULIA-RETURN-TUPLE" => RuleDefinition(
        "JULIA-RETURN-TUPLE", "julia", "Global Rules > Return Tuples",
        "mature", "stable", "error", false),
    "JULIA-PARAMETERS-FAIL" => RuleDefinition(
        "JULIA-PARAMETERS-FAIL", "julia", "Global Rules > Parameter Counts",
        "mature", "stable", "error", false),
    "JULIA-FUNCTION-LINES-REPORT" => RuleDefinition(
        "JULIA-FUNCTION-LINES-REPORT", "julia",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "report", false),
    "JULIA-FUNCTION-LINES-WARN" => RuleDefinition(
        "JULIA-FUNCTION-LINES-WARN", "julia",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "warning", false),
    "JULIA-FUNCTION-LINES-FAIL" => RuleDefinition(
        "JULIA-FUNCTION-LINES-FAIL", "julia",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "error", false),
    "JULIA-CYCLOMATIC-REPORT" => RuleDefinition(
        "JULIA-CYCLOMATIC-REPORT", "julia",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "report", false),
    "JULIA-CYCLOMATIC-WARN" => RuleDefinition(
        "JULIA-CYCLOMATIC-WARN", "julia",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "warning", false),
    "JULIA-CYCLOMATIC-FAIL" => RuleDefinition(
        "JULIA-CYCLOMATIC-FAIL", "julia",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "error", false),
    "ODIN-SYNTAX" => RuleDefinition(
        "ODIN-SYNTAX", "odin", "Odin Rules > Compiler Cleanliness",
        "mature", "stable", "error", true),
    "ODIN-BUILD-FAILED" => RuleDefinition(
        "ODIN-BUILD-FAILED", "odin", "Odin Rules > Analytical Build",
        "mature", "stable", "error", false),
    "ODIN-CLOSING-PAREN-PLACEMENT" => RuleDefinition(
        "ODIN-CLOSING-PAREN-PLACEMENT", "odin",
        "Global Rules > Closing Parenthesis Placement (Absolute)",
        "mature", "stable", "error", false),
    "ODIN-NAMING" => RuleDefinition(
        "ODIN-NAMING", "odin", "Odin Rules > Naming",
        "mature", "stable", "report", false),
    "ODIN-NONCONST-GLOBAL" => RuleDefinition(
        "ODIN-NONCONST-GLOBAL", "odin", "Global Rules > Mutable Globals",
        "mature", "stable", "warning", false),
    "ODIN-UNUSED-IMPORT" => RuleDefinition(
        "ODIN-UNUSED-IMPORT", "odin", "Odin Rules > Unused Imports",
        "experimental", "definite", "report", false),
    "ODIN-UNREACHABLE-PROCEDURE" => RuleDefinition(
        "ODIN-UNREACHABLE-PROCEDURE", "odin",
        "Call-Graph Reachability > Odin Procedures",
        "experimental", "probable", "report", false),
    "ODIN-DECLARATION-ORDER" => RuleDefinition(
        "ODIN-DECLARATION-ORDER", "odin",
        "Global Rules > Declaration Order",
        "mature", "stable", "warning", false),
    "ODIN-RETURN-TUPLE" => RuleDefinition(
        "ODIN-RETURN-TUPLE", "odin", "Global Rules > Return Tuples",
        "mature", "stable", "error", false),
    "ODIN-PARAMETERS-WARN" => RuleDefinition(
        "ODIN-PARAMETERS-WARN", "odin", "Global Rules > Parameter Counts",
        "mature", "stable", "warning", false),
    "ODIN-PARAMETERS-FAIL" => RuleDefinition(
        "ODIN-PARAMETERS-FAIL", "odin", "Global Rules > Parameter Counts",
        "mature", "stable", "error", false),
    "ODIN-FUNCTION-LINES-REPORT" => RuleDefinition(
        "ODIN-FUNCTION-LINES-REPORT", "odin",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "report", false),
    "ODIN-FUNCTION-LINES-WARN" => RuleDefinition(
        "ODIN-FUNCTION-LINES-WARN", "odin",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "warning", false),
    "ODIN-FUNCTION-LINES-FAIL" => RuleDefinition(
        "ODIN-FUNCTION-LINES-FAIL", "odin",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "error", false),
    "ODIN-CYCLOMATIC-REPORT" => RuleDefinition(
        "ODIN-CYCLOMATIC-REPORT", "odin",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "report", false),
    "ODIN-CYCLOMATIC-WARN" => RuleDefinition(
        "ODIN-CYCLOMATIC-WARN", "odin",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "warning", false),
    "ODIN-CYCLOMATIC-FAIL" => RuleDefinition(
        "ODIN-CYCLOMATIC-FAIL", "odin",
        "Global Rules > Function Size and Complexity",
        "mature", "stable", "error", false),
    "FUNCTION-METRIC-POLICY-DRIFT" => RuleDefinition(
        "FUNCTION-METRIC-POLICY-DRIFT", "common",
        "Verification Gate > Function Metric Policies",
        "mature", "stable", "error", true),
    "NAMING-POLICY-DRIFT" => RuleDefinition(
        "NAMING-POLICY-DRIFT", "common", "Verification Gate > Naming Policies",
        "mature", "stable", "error", true),
    "ODIN-ALLOCATION-IMPLICIT" => RuleDefinition(
        "ODIN-ALLOCATION-IMPLICIT", "odin", "Odin Rules > Memory and Allocation",
        "experimental", "stable", "warning", false),
    "ODIN-ALLOCATION-UNKNOWN" => RuleDefinition(
        "ODIN-ALLOCATION-UNKNOWN", "odin", "Odin Rules > Memory and Allocation",
        "experimental", "stable", "error", false),
    "ODIN-ALLOCATION-CONTEXT" => RuleDefinition(
        "ODIN-ALLOCATION-CONTEXT", "odin", "Odin Rules > Memory and Allocation",
        "experimental", "stable", "warning", false),
    "ODIN-ALLOCATION-HEAP" => RuleDefinition(
        "ODIN-ALLOCATION-HEAP", "odin", "Odin Rules > Memory and Allocation",
        "experimental", "stable", "warning", false),
    "ODIN-ALLOCATION-TEMPORARY" => RuleDefinition(
        "ODIN-ALLOCATION-TEMPORARY", "odin", "Odin Rules > Memory and Allocation",
        "experimental", "stable", "report", false),
    "ODIN-ALLOCATION-CUSTOM" => RuleDefinition(
        "ODIN-ALLOCATION-CUSTOM", "odin", "Odin Rules > Memory and Allocation",
        "experimental", "stable", "report", false),
    "ODIN-ALLOCATION-DYNAMIC-GROWTH" => RuleDefinition(
        "ODIN-ALLOCATION-DYNAMIC-GROWTH", "odin",
        "Odin Rules > Memory and Allocation",
        "experimental", "potential", "report", false),
    "ODIN-ALLOCATION-ARENA" => RuleDefinition(
        "ODIN-ALLOCATION-ARENA", "odin", "Odin Rules > Memory and Allocation",
        "experimental", "stable", "warning", false),
    "ODIN-ALLOCATION-HIDDEN" => RuleDefinition(
        "ODIN-ALLOCATION-HIDDEN", "odin", "Odin Rules > Memory and Allocation",
        "experimental", "potential", "warning", false),
    "ODIN-ALLOCATION-POLICY-DRIFT" => RuleDefinition(
        "ODIN-ALLOCATION-POLICY-DRIFT", "odin",
        "Odin Rules > Memory and Allocation",
        "experimental", "stable", "error", true),
    "JULIA-DOC-MISSING" => RuleDefinition(
        "JULIA-DOC-MISSING", "julia", "Julia Rules > Docstrings",
        "mature", "stable", "error", false),
    "ODIN-DOC-MISSING" => RuleDefinition(
        "ODIN-DOC-MISSING", "odin",
        "Odin Rules > Comments and Function Placement",
        "mature", "stable", "error", false),
    "MARKDOWN-SINGLE-H1" => RuleDefinition(
        "MARKDOWN-SINGLE-H1", "markdown",
        "Documentation Rules > Markdown Structure",
        "mature", "stable", "warning", false),
    "MARKDOWN-HEADING-LEVELS" => RuleDefinition(
        "MARKDOWN-HEADING-LEVELS", "markdown",
        "Documentation Rules > Markdown Structure",
        "mature", "stable", "warning", false),
    "MARKDOWN-CODE-FENCE-LANGUAGE" => RuleDefinition(
        "MARKDOWN-CODE-FENCE-LANGUAGE", "markdown",
        "Documentation Rules > Markdown Structure",
        "mature", "stable", "warning", false),
    "MARKDOWN-RELATIVE-LINK" => RuleDefinition(
        "MARKDOWN-RELATIVE-LINK", "markdown",
        "Documentation Rules > Markdown Links",
        "mature", "stable", "warning", false),
    "MARKDOWN-IMAGE-ALT-TEXT" => RuleDefinition(
        "MARKDOWN-IMAGE-ALT-TEXT", "markdown",
        "Documentation Rules > Markdown Accessibility",
        "mature", "stable", "warning", false))