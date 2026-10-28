"""Return structural rule IDs independent of a consuming project's policy response."""
function sql_findings(source)
    evidence = OdinJuliaAnalysis.SQLEngine.analyze(source)
    @test isempty(evidence.issues)
    @test isempty(evidence.structure.gaps)
    @test evidence.capabilities.query_structure == :complete
    return [rule for (rule, _, _) in
        OdinJuliaAnalysis.SQLEngine.structural_findings(evidence)]
end

"""Decode an evidence span using its owning immutable source snapshot."""
function sql_span_text(evidence, span)
    return String(SubString(evidence.source, span.first_byte,
        prevind(evidence.source, span.after_last_byte)))
end

@testset "SQLite structural parser and conventions" begin
    analyze = OdinJuliaAnalysis.SQLEngine.analyze
    @testset "six configurable rules" begin
        source = "select t.* exposed from things t, others o where t.id = :id"
        @test Set(sql_findings(source)) == Set((
            "SQL-KEYWORD-CASING", "SQL-SEMICOLON", "SQL-NUMBERED-BINDS",
            "SQL-EXPLICIT-AS", "SQL-PROJECTION-WILDCARD", "SQL-COMMA-JOIN"))
        @test isempty(sql_findings(
            "SELECT t.id AS identity FROM things AS t JOIN others AS o " *
            "ON o.id = t.id WHERE t.id = ?5 OR t.id = ?5;"))
        @test isempty(sql_findings(
            "SELECT strict, temp, key, \"select\", t.end AS \"from\" FROM temp AS t;"))
        @test isempty(sql_findings("SELECT true, false, value AS filter FROM records;"))
        @test "SQL-EXPLICIT-AS" in sql_findings("SELECT value filter FROM records;")
        @test count(==("SQL-NUMBERED-BINDS"),
            sql_findings("SELECT ?, :name, @name, \$name, ?0, ?2, ?99, ?2;")) == 5
        @test isempty(sql_findings("SELECT 'select ; ? , *', X'00', \"from\";"))
        @test isempty(sql_findings("-- comment only ;\n/* more */"))
        @test isempty(sql_findings(" ; ;\n"))
        @test "SQL-SEMICOLON" in sql_findings("SELECT 1 /* trailing */")
        @test isempty(sql_findings("SELECT ';'; -- trailing"))
    end
    @testset "wildcard distinctions" begin
        for source in (
            "SELECT COUNT(*), a * b, f(a, b) FROM t;",
            "SELECT EXISTS(SELECT * FROM t);",
            "SELECT EXISTS(SELECT t.* FROM t);",
            "SELECT EXISTS(WITH rows AS (SELECT id FROM t) SELECT * FROM rows);",
            "SELECT EXISTS(SELECT * FROM t UNION ALL SELECT * FROM u);",
            "SELECT 2 * (3 + 4), COUNT(DISTINCT value) FROM t;")
            @test "SQL-PROJECTION-WILDCARD" ∉ sql_findings(source)
        end
        for source in (
            "SELECT * FROM t;", "SELECT t.* FROM t;",
            "SELECT EXISTS(SELECT *, 1 FROM t);",
            "SELECT EXISTS(SELECT * FROM (SELECT * FROM t));",
            "SELECT (SELECT * FROM t);",
            "UPDATE t SET a = 1 RETURNING *;")
            @test "SQL-PROJECTION-WILDCARD" in sql_findings(source)
        end
    end
    @testset "query hierarchy, CTEs and compound operands" begin
        source = """
            WITH RECURSIVE tree(id) AS NOT MATERIALIZED (
                SELECT id FROM nodes
                UNION ALL SELECT n.id FROM nodes AS n JOIN tree AS t ON n.parent = t.id
            ), latest AS (SELECT MAX(id) AS id FROM tree)
            SELECT l.id AS identity, (SELECT COUNT(*) FROM tree) AS size
            FROM latest AS l
            WHERE l.id IN (SELECT id FROM tree WHERE id BETWEEN ?5 AND ?9)
            ORDER BY l.id DESC NULLS LAST LIMIT ?2 OFFSET ?3;
            """
        @test isempty(sql_findings(source))
        evidence = analyze(source)
        structure = evidence.structure
        @test length(structure.statements) == 1
        @test length(structure.ctes) == 2
        @test length(structure.queries) == 6
        @test all(query -> query.statement == 1, structure.queries)
        @test only(structure.statements).kind == :select
        @test all(cte -> cte.parent_query == 4, structure.ctes)
        @test structure.queries[1].parent == 4
        @test structure.queries[3].parent == 4
        @test startswith(sql_span_text(evidence, structure.queries[4].span), "WITH")
        @test any(query -> query.kind == :compound_operand, structure.queries)
        @test Set(binding.slot for binding in structure.binds) == Set((2, 3, 5, 9))
        @test all(!join.comma for join in structure.joins)
        @test [sql_span_text(evidence, cte.name) for cte in structure.ctes] ==
            ["tree", "latest"]
        compound = analyze("SELECT 1 UNION SELECT 2 INTERSECT SELECT 3;")
        @test length(compound.structure.queries) == 3
    end
    @testset "aliases only where SQLite permits them" begin
        @test isempty(sql_findings(
            "WITH x(id) AS (SELECT 1) SELECT CAST(id AS TEXT) AS label FROM x AS rows;"))
        @test count(==("SQL-EXPLICIT-AS"), sql_findings(
            "SELECT (a + b) total, f(x) 'label' FROM table_name alias " *
            "JOIN (SELECT 1 AS value) sub ON sub.value = alias.id;")) == 4
        @test "SQL-EXPLICIT-AS" ∉ sql_findings(
            "CREATE VIEW result(id) AS SELECT id FROM source;")
        @test "SQL-EXPLICIT-AS" ∉ sql_findings(
            "CREATE TABLE result(id INTEGER PRIMARY KEY);")
        @test count(==("SQL-COMMA-JOIN"), sql_findings(
            "SELECT f(a,b), (a,b) FROM (left_table, right_table) AS grouped;")) == 1
        @test "SQL-COMMA-JOIN" ∉ sql_findings(
            "SELECT a, b FROM json_each(?1) AS item JOIN t USING (a, b) LIMIT 1, 2;")
    end
    @testset "schema declarations and opaque virtual modules" begin
        source = """
            CREATE TEMP TABLE IF NOT EXISTS temp.records (
                id INTEGER PRIMARY KEY,
                value TEXT NOT NULL DEFAULT 'literal;--',
                doubled INTEGER GENERATED ALWAYS AS (id * 2) STORED,
                CONSTRAINT positive CHECK (id > 0),
                UNIQUE (value),
                FOREIGN KEY (id) REFERENCES parent(id) ON DELETE CASCADE
                    DEFERRABLE INITIALLY DEFERRED
            ) STRICT, WITHOUT ROWID;
            CREATE UNIQUE INDEX temp.by_value ON records(value COLLATE nocase DESC)
                WHERE id > 1;
            CREATE VIRTUAL TABLE search USING fts5(
                title, body, tokenize='porter unicode61', content='records');
            CREATE VIEW selected(id) AS SELECT id FROM records;
            """
        @test isempty(sql_findings(source))
        evidence = analyze(source)
        declarations = evidence.structure.declarations
        @test [item.kind for item in declarations] ==
            [:table, :index, :virtual_table, :view]
        @test declarations[1].temporary
        @test declarations[1].strict
        @test declarations[1].without_rowid
        @test sql_span_text(evidence, declarations[1].schema) == "temp"
        @test sql_span_text(evidence, declarations[2].partial_predicate) == "id > 1"
        @test sql_span_text(evidence, declarations[3].module_name) == "fts5"
        @test occursin("tokenize='porter unicode61'",
            sql_span_text(evidence, declarations[3].module_arguments))
        spellfix = analyze("CREATE VIRTUAL TABLE words USING spellfix1;")
        @test isempty(spellfix.structure.gaps)
        module_source = "CREATE VIRTUAL TABLE custom USING extension(" *
            "tokenize=plain, option(:value, ?), select, a, b);"
        @test isempty(sql_findings(module_source))
        @test isempty(analyze(module_source).structure.binds)
        @test isempty(sql_findings("CREATE TABLE t AS SELECT 1 AS id;"))
        @test isempty(sql_findings("CREATE TABLE t (key NUMERIC(10, 2), strict TEXT);"))
    end
    @testset "trigger CASE and semicolon boundaries" begin
        source = """
            CREATE TEMP TRIGGER audit_change AFTER UPDATE OF value ON records
            FOR EACH ROW WHEN NEW.value IS NOT OLD.value
            BEGIN
                INSERT INTO log(id, value) VALUES (
                    NEW.id, CASE WHEN NEW.value IS NULL THEN ';' ELSE NEW.value END);
                UPDATE totals SET count = count + 1 WHERE id = NEW.id;
            END;
            SELECT CASE value WHEN 1 THEN CASE WHEN ?1 THEN 'end;' ELSE 'x' END
                ELSE 'other' END AS result FROM records;
            """
        @test isempty(sql_findings(source))
        structure = analyze(source).structure
        @test [statement.kind for statement in structure.statements] ==
            [:create, :insert, :update, :select]
        @test [statement.parent for statement in structure.statements] ==
            [nothing, 1, 1, nothing]
        @test all(statement.terminated for statement in structure.statements)
        @test length(structure.declarations) == 1
        @test only(structure.declarations).kind == :trigger
        unclosed = analyze(replace(source, "END;\nSELECT" => "END\nSELECT"))
        @test !isempty(unclosed.structure.gaps)
        @test isempty(sql_findings(
            "CREATE TRIGGER stop BEFORE INSERT ON t BEGIN " *
            "SELECT RAISE(ABORT, 'no'); SELECT RAISE(IGNORE); END;"))
        lowercase_raise = "CREATE TRIGGER stop BEFORE INSERT ON t BEGIN " *
            "SELECT raise(abort, 'no'); END;"
        @test count(==("SQL-KEYWORD-CASING"), sql_findings(lowercase_raise)) == 2
        @test isempty(sql_findings(
            "SELECT id FROM t WHERE id NOT NULL AND value ISNULL;"))
    end
    @testset "mutations, UPSERT, RETURNING and control" begin
        source = """
            BEGIN IMMEDIATE TRANSACTION;
            SAVEPOINT changes;
            INSERT OR IGNORE INTO t AS target (id, value) VALUES (?5, ?9), (?2, ?9)
                ON CONFLICT (id) WHERE id > 0 DO UPDATE SET
                    value = excluded.value WHERE excluded.value IS NOT NULL
                ON CONFLICT DO NOTHING RETURNING id AS identity, value;
            UPDATE t AS target SET (id, value) = (?2, ?5)
                FROM source AS s WHERE s.id = target.id RETURNING target.id AS identity;
            DELETE FROM t AS target WHERE id = ?5 RETURNING id;
            ROLLBACK TO SAVEPOINT changes;
            RELEASE SAVEPOINT changes;
            COMMIT;
            PRAGMA foreign_keys=ON;
            PRAGMA main.table_info('t');
            DROP VIEW IF EXISTS old;
            """
        @test isempty(sql_findings(source))
        structure = analyze(source).structure
        @test length(structure.statements) == 11
        @test count(query -> query.kind == :returning, structure.queries) == 3
        update_from = analyze(
            "UPDATE t SET id = source.id FROM source, other WHERE source.id = other.id;")
        @test only(update_from.structure.joins).query === nothing
        @test only(update_from.structure.joins).statement == 1
        @test isempty(sql_findings(
            "WITH c AS (SELECT 1 AS id) DELETE FROM t WHERE id IN c;"))
        @test isempty(sql_findings("REPLACE INTO t (id) VALUES (?5);"))
        @test isempty(sql_findings("INSERT INTO t DEFAULT VALUES;"))
        @test isempty(sql_findings("VALUES (1, 2), (3, 4);"))
    end
    @testset "unsupported syntax is incomplete, not clean or a syntax error" begin
        for source in (
            "ALTER TABLE t RENAME TO u;",
            "SELECT SUM(value) OVER (PARTITION BY id) FROM t;",
            "SELECT 1 WINDOW named AS (ORDER BY id);",
            "CREATE TABLE t (id INTEGER) UNKNOWN_OPTION;",
            "SELECT CASE WHEN x THEN y;",
            "EXPLAIN SELECT * FROM t;",
            repeat("WITH c AS (SELECT 1) ", 70) * "SELECT 1;",
            repeat("SELECT (", 70) * "1" * repeat(")", 70) * ";")
            evidence = analyze(source)
            @test evidence.capabilities.lexical_accounting == :complete
            @test evidence.capabilities.query_structure == :incomplete
            @test !isempty(evidence.structure.gaps)
            @test evidence.structure.rules["SQL-EXPLICIT-AS"] == :incomplete
            @test evidence.structure.rules["SQL-NUMBERED-BINDS"] == :evaluated
        end

        partial = analyze("ALTER TABLE t RENAME TO u; SELECT :named;")
        configuration = OdinJuliaAnalysis.load_settings()
        diagnostics = OdinJuliaAnalysis.SQLEngine.check("gap.sql", partial, configuration)
        @test [item.rule_id for item in diagnostics] == ["SQL-NUMBERED-BINDS"]
        @test only(diagnostics).line == 1
        bound = OdinJuliaAnalysis.SQLEngine.MAX_STRUCTURAL_DEPTH
        at_bound = analyze("SELECT " * repeat("NOT ", bound - 3) * "1;")
        @test at_bound.capabilities.query_structure == :complete
        over_bound = analyze("SELECT " * repeat("NOT ", bound - 2) * "1;")
        @test over_bound.capabilities.query_structure == :incomplete
        @test occursin("nesting exceeds", only(over_bound.structure.gaps).message)
        engine = OdinJuliaAnalysis.SQLEngine
        parser = engine.SQLParser(engine.lex("id"))
        @test_throws engine.StructuralGap engine.projection_list!(parser)
    end
end

"""Apply SQL rule policy while disabling unrelated provider/build prerequisites."""
function sql_rule_configuration(replacements=Dict{String, RuleSetting}())
    base = Base.include(
        Module(gensym(:SQLRuleFixtureSettings)), OdinJuliaAnalysis.DEFAULT_SETTINGS_PATH)
    rules = [get(replacements, setting.rule_id, setting) for setting in base.rules]
    settings = AnalysisSettings((
        name == :rules ? rules :
        name == :jet ? JetSettings(JetEntryPoint[]) :
        name == :odin_build ? OdinBuildSettings(OdinBuildTarget[]) : getfield(base, name)
        for name in fieldnames(AnalysisSettings))...)
    return OdinJuliaAnalysis.validate_settings(settings)
end

@testset "SQLite rule policy and capability integration" begin
    @testset "every rule supports Fail and disabled policy" begin
        examples = Dict(
            "SQL-KEYWORD-CASING" => "select id FROM t;",
            "SQL-SEMICOLON" => "SELECT id FROM t",
            "SQL-NUMBERED-BINDS" => "SELECT :named;",
            "SQL-EXPLICIT-AS" => "SELECT id label FROM t;",
            "SQL-PROJECTION-WILDCARD" => "SELECT * FROM t;",
            "SQL-COMMA-JOIN" => "SELECT a.id FROM a, b;")
        mktempdir() do root
            for (rule, source) in examples
                write(joinpath(root, "query.sql"), source)
                enabled = sql_rule_configuration(
                    Dict(rule => RuleSetting(rule, true, Fail)))
                report = OdinJuliaAnalysis.check_repository(root; configuration=enabled)
                @test report.exit_code == 1
                @test count(item -> item.rule_id == rule, report.diagnostics) == 1
                @test only(filter(item -> item.rule_id == rule, report.rules)).status ==
                    "evaluated"
                disabled = sql_rule_configuration(
                    Dict(rule => RuleSetting(rule, false, Fail)))
                skipped = OdinJuliaAnalysis.check_repository(root; configuration=disabled)
                @test skipped.exit_code == 0
                @test all(item -> item.rule_id != rule, skipped.diagnostics)
                @test only(filter(item -> item.rule_id == rule, skipped.rules)).status ==
                    "disabled"
            end
        end
    end
    @testset "ignore and gap reporting remain independent" begin
        mktempdir() do root
            rule = "SQL-PROJECTION-WILDCARD"
            write(joinpath(root, "query.sql"), "SELECT * FROM t;")
            ignored = sql_rule_configuration(
                Dict(rule => RuleSetting(rule, true, Ignore)))
            report = OdinJuliaAnalysis.check_repository(root; configuration=ignored)
            @test report.exit_code == 0
            @test report.ignored_counts[rule] == 1
            @test only(filter(item -> item.rule_id == rule, report.rules)).findings == 1
            write(joinpath(root, "query.sql"),
                "SELECT :named; ALTER TABLE t RENAME TO u;")
            partial = OdinJuliaAnalysis.check_repository(root;
                configuration=sql_rule_configuration())
            @test partial.exit_code == 2
            rules = Dict(item.rule_id => item for item in partial.rules)
            @test rules["SQL-NUMBERED-BINDS"].status == "evaluated"
            @test rules["SQL-NUMBERED-BINDS"].files_checked == 1
            @test rules["SQL-EXPLICIT-AS"].status == "failed"
            @test rules["SQL-EXPLICIT-AS"].files_checked == 0
            @test rules["SQL-NUMBERED-BINDS"].findings == 1
            @test !only(partial.files).parsed
            @test any(engine -> engine.name == "sql" &&
                occursin("Unsupported SQLite statement", engine.message), partial.engines)
            @test all(item -> !occursin("SYNTAX", item.rule_id), partial.diagnostics)
            output = IOBuffer()
            OdinJuliaAnalysis.write_report(output, partial, "text"; color=:never)
            text = String(take!(output))
            @test occursin("INCOMPLETE ANALYSIS", text)
            @test occursin("query.sql:1:", text)
            @test occursin("Unsupported SQLite statement", text)
            markdown = IOBuffer()
            OdinJuliaAnalysis.write_markdown_report(markdown, partial)
            @test occursin("Unsupported SQLite statement", String(take!(markdown)))
        end
    end
    @testset "byte spans produce Unicode character columns" begin
        source = "SELECT é, foo alias\r\nFROM tab t;"
        evidence = OdinJuliaAnalysis.SQLEngine.analyze(source)
        diagnostics = OdinJuliaAnalysis.SQLEngine.check(
            "unicode.sql", evidence, sql_rule_configuration())
        aliases = filter(item -> item.rule_id == "SQL-EXPLICIT-AS", diagnostics)
        @test [(item.line, item.column) for item in aliases] == [(1, 15), (2, 10)]
        alias_names = [sql_span_text(evidence, alias.span)
            for alias in evidence.structure.aliases]
        @test alias_names == ["alias", "t"]
        encoded = JSON.parse(JSON.json(evidence))
        @test encoded["structure"]["rules"]["SQL-EXPLICIT-AS"] == "evaluated"
        @test length(encoded["structure"]["projections"]) == 2
    end
end
