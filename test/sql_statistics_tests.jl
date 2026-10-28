@testset "SQLite targeted source statistics" begin
    mktempdir() do root
        path = joinpath(root, "query.sql")
        source = "-- comment\n\nSELECT 'first\n\n-- literal' AS text, ?1;\n"
        write(path, source)
        report = analyze_source_statistics(path)
        @test report.schema_version == "2.0.0"
        @test report.file.physical_lines == 5
        @test report.file.code_lines == 3
        @test report.file.comment_lines == 1
        @test report.file.blank_lines == 1
        @test report.file.function_count === nothing
        @test report.file.struct_count === nothing
        @test report.file.total_cyclomatic_complexity === nothing
        @test report.file.complexity_per_code_line === nothing
        @test isempty(report.functions)
        @test report.sql.structural_status == "complete"
        @test report.sql.triggers == 0
        @test report.sql.statements == 1
        @test report.sql.binds == 1
        @test only(report.statements).start_line == 3
        @test report.metric_scope.status == "not-applicable"
        @test_throws ArgumentError analyze_source_statistics(path; function_name="query")
        @test_throws ArgumentError analyze_source_statistics(path; line=0)
        @test_throws ArgumentError analyze_source_statistics(path; line=2)
        @test_throws ArgumentError analyze_source_statistics(path; line=6)
        @test only(analyze_source_statistics(path; line=4).statements).kind == "select"
        encoded = JSON.parse(JSON.json(report))
        @test encoded.file.function_count === nothing
        @test encoded.sql.triggers == 0
        output = IOBuffer()
        OdinJuliaAnalysis.write_statistics_report(output, report, "text")
        text = String(take!(output))
        @test occursin("\u2014", text)
        @test occursin("SQLITE STATEMENTS", text)
        @test occursin("not-applicable", text)
        @test !occursin("FUNCTIONS", text)
        @test OdinJuliaAnalysis.main(["stats", path, "--format=json"]) == 0
        @test OdinJuliaAnalysis.main(["stats", path, "--function=query"]) == 2
    end
end

@testset "SQLite innermost executable statement selection" begin
    mktempdir() do root
        path = joinpath(root, "trigger.sql")
        write(path, """
            CREATE TRIGGER notify AFTER INSERT ON t BEGIN
                INSERT INTO log (id) VALUES (NEW.id);
                UPDATE log SET id = id + 1;
            END;
            WITH c AS (
                SELECT 1 AS value
            ) SELECT value FROM c;
            """)
        report = analyze_source_statistics(path)
        @test report.sql.statements == 4
        @test report.sql.top_level_statements == 2
        @test report.sql.triggers == 1
        @test report.sql.ctes == 1
        @test report.sql.query_blocks == 2
        @test length(report.statements) == 4
        insert = analyze_source_statistics(path; line=2)
        @test only(insert.statements).kind == "insert"
        @test only(insert.statements).parent == 1
        @test insert.selection.kind == "statement-line"
        @test only(analyze_source_statistics(path; line=1).statements).kind == "create"
        @test only(analyze_source_statistics(path; line=6).statements).start_line == 5
        @test only(analyze_source_statistics(path; line=6).statements).parent === nothing
    end
end

@testset "SQLite empty, unavailable and incomplete measurements" begin
    mktempdir() do root
        path = joinpath(root, "scope.sql")
        for source in ("", "-- only a comment\n", "/* comment\n\ninterior */\n")
            write(path, source)
            report = analyze_source_statistics(path)
            @test report.sql.lexical_status == "complete"
            @test report.sql.structural_status == "complete"
            @test report.sql.statements == 0
            @test report.sql.triggers == 0
            @test report.sql.binds == 0
            @test report.file.code_lines == 0
            @test report.file.function_count === nothing
        end
        write(path, "ALTER TABLE t RENAME TO u; SELECT ?1;")
        partial = analyze_source_statistics(path)
        @test partial.sql.lexical_status == "complete"
        @test partial.sql.structural_status == "incomplete"
        @test partial.sql.statements === nothing
        @test partial.sql.triggers === nothing
        @test partial.sql.binds == 1
        @test occursin(":1:1:", partial.sql.reason)
        @test isempty(partial.statements)
        @test partial.file.code_lines == 1
        @test_throws ArgumentError analyze_source_statistics(path; line=1)
        @test OdinJuliaAnalysis.main(["stats", path]) == 2
        write(path, "SELECT 'unclosed\n-- still string")
        malformed = analyze_source_statistics(path)
        @test malformed.sql.lexical_status == "incomplete"
        @test malformed.sql.structural_status == "incomplete"
        @test malformed.sql.binds === nothing
        @test malformed.sql.triggers === nothing
        @test malformed.sql.reason !== nothing
        @test malformed.file.code_lines == 2
        missing = OdinJuliaAnalysis.FileAnalysis("missing.sql", "sql";
            physical_lines=0, source_lines=0, code_lines=0, comment_lines=0,
            blank_lines=0, struct_count=nothing, parsed=false)
        unavailable = OdinJuliaAnalysis.sql_statistics([missing])
        @test unavailable.structural_status == "incomplete"
        @test unavailable.triggers === nothing
        @test occursin("unavailable", unavailable.reason)
    end
end

@testset "SQLite repository inventories and output consistency" begin
    mktempdir() do root
        write(joinpath(root, "schema.sql"), """
            CREATE TABLE t (id INTEGER);
            CREATE VIEW v AS SELECT id FROM t;
            CREATE INDEX idx ON t (id);
            CREATE VIRTUAL TABLE docs USING fts5(body);
            SELECT id AS value FROM t WHERE id = ?1;
            """)
        configuration = sql_rule_configuration()
        report = OdinJuliaAnalysis.check_repository(root; configuration)
        sql = report.statistics.sql
        @test report.exit_code == 0
        @test report.statistics.sources.files == 1
        @test report.statistics.sources.code_lines == 5
        @test report.statistics.code.complexity === nothing
        @test report.statistics.cocomo === nothing
        @test report.statistics.locomo === nothing
        @test sql.tables == sql.views == sql.indexes == sql.virtual_tables == 1
        @test sql.triggers == 0
        @test sql.statements == sql.top_level_statements == 5
        @test sql.query_blocks == sql.projections == 2
        @test sql.binds == 1
        @test report.statistics.code_by_language["sql"].functions === nothing
        @test report.statistics.code_by_language["sql"].structs === nothing
        @test report.statistics.metric_scope.status == "not-applicable"
        @test only(report.files).sql.source == read(joinpath(root, "schema.sql"), String)
        encoded = JSON.parse(JSON.json(report))
        @test encoded.statistics.cocomo === nothing
        @test encoded.statistics.code_by_language.sql.complexity === nothing
        @test encoded.files[1].struct_count === nothing
        for comprehensive in (false, true)
            output = IOBuffer()
            OdinJuliaAnalysis.write_markdown_report(output, report; comprehensive)
            text = String(take!(output))
            @test occursin("Shared Source Totals", text)
            @test occursin("SQLite Inventory", text)
            @test occursin("| triggers | 0 |", text)
            @test occursin("SQL and Markdown excluded", text)
            @test occursin("\u2014 (not applicable", text)
            @test occursin("SQLite Source Inventories", text) == comprehensive
        end
        output = IOBuffer()
        OdinJuliaAnalysis.write_report(output, report, "text"; color=:never)
        @test occursin("SQLITE INVENTORY", String(take!(output)))
        empty_stats = OdinJuliaAnalysis.calculate_repository_statistics(
            OdinJuliaAnalysis.FileAnalysis[], OdinJuliaAnalysis.FunctionAnalysis[])
        @test empty_stats.sql.structural_status == "not-applicable"
        @test empty_stats.sql.triggers === nothing
        write(joinpath(root, "schema.sql"), "ALTER TABLE t RENAME TO u; SELECT ?1;")
        incomplete = OdinJuliaAnalysis.check_repository(root; configuration)
        for comprehensive in (false, true)
            output = IOBuffer()
            OdinJuliaAnalysis.write_markdown_report(output, incomplete; comprehensive)
            text = String(take!(output))
            @test occursin("structural: incomplete", text)
            @test occursin("| triggers | \u2014 |", text)
            @test occursin("| binds | 1 |", text)
            @test occursin("schema.sql:1:1:", text)
        end
    end
end

@testset "SQL cannot dilute procedural complexity or estimates" begin
    mktempdir() do root
        write(joinpath(root, "one.jl"), "\"\"\"Choose a positive value.\"\"\"\nf(x) = x > 0 ? x : 0\n")
        configuration = sql_rule_configuration()
        baseline = OdinJuliaAnalysis.check_repository(root; configuration).statistics
        write(joinpath(root, "many.sql"), repeat("SELECT ?1 AS value;\n", 100))
        write(joinpath(root, "notes.md"), "# Notes\n\nText.\n")
        mixed = OdinJuliaAnalysis.check_repository(root; configuration).statistics
        @test mixed.code == baseline.code
        @test mixed.cocomo == baseline.cocomo
        @test mixed.locomo == baseline.locomo
        @test mixed.metric_scope.complexity_code_lines ==
            baseline.metric_scope.complexity_code_lines
        @test mixed.sources.files == 3
        @test mixed.sources.code_lines == baseline.code.code_lines + 102
        @test mixed.sql.statements == 100
        for field in fieldnames(SourceTotals)
            @test getfield(mixed.sources, field) ==
                sum(totals -> getfield(totals, field), values(mixed.sources_by_language))
        end
        broken = OdinJuliaAnalysis.FileAnalysis("broken.jl", "julia";
            physical_lines=100, source_lines=100, code_lines=100, comment_lines=0,
            blank_lines=0, struct_count=0, parsed=false)
        parsed = OdinJuliaAnalysis.FileAnalysis("ok.jl", "julia";
            physical_lines=4, source_lines=4, code_lines=4, comment_lines=0,
            blank_lines=0, struct_count=0, parsed=true)
        fun = OdinJuliaAnalysis.FunctionAnalysis("ok.jl", "julia", "f"; start_line=1, end_line=4,
            executable_lines=3, parameter_count=0, cyclomatic_complexity=2,
            cognitive_complexity=0, documented=true)
        partial = OdinJuliaAnalysis.calculate_repository_statistics([parsed, broken], [fun])
        @test partial.code.complexity_per_code_line == 0.5
        @test partial.metric_scope.status == "incomplete"
        @test partial.metric_scope.complexity_code_lines == 4
        @test partial.metric_scope.estimate_code_lines == 104
        @test partial.cocomo == OdinJuliaAnalysis.calculate_cocomo(104)
        @test partial.locomo == OdinJuliaAnalysis.calculate_locomo(104, 2)
    end
end
