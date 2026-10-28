"""Decode token spans only at valid UTF-8 boundaries."""
function sql_token_text(evidence)
    return [String(SubString(evidence.source,
        token.span.first_byte, prevind(evidence.source, token.span.after_last_byte)))
        for token in evidence.tokens]
end

"""Replace SQLite settings without dropping any other current configuration field."""
function settings_with_sqlite(sqlite)
    base = Base.include(
        Module(gensym(:SQLiteFixtureSettings)), OdinJuliaAnalysis.DEFAULT_SETTINGS_PATH)
    return AnalysisSettings((name == :sqlite_validation ? sqlite : getfield(base, name)
        for name in fieldnames(AnalysisSettings))...)
end

@testset "SQLite lexical evidence" begin
    engine = OdinJuliaAnalysis.SQLEngine
    @testset "quotes, contextual words and byte spans" begin
        source = "select strict, temp, \"a\"\"b\", `c``d`, [é], 'it''s;--/*';"
        evidence = engine.lex(source)
        @test evidence.capabilities.lexical_accounting == :complete
        @test isempty(evidence.issues)
        @test sql_token_text(evidence) == [
            "select", "strict", ",", "temp", ",", "\"a\"\"b\"", ",",
            "`c``d`", ",", "[é]", ",", "'it''s;--/*'", ";"]
        @test evidence.tokens[1].kind == :word
        @test evidence.tokens[2].kind == :word
        @test last(evidence.tokens).span.after_last_byte == ncodeunits(source) + 1
        @test all(token -> isvalid(source, token.span.first_byte), evidence.tokens)
        @test evidence.capabilities.statement_inventory == :incomplete
        @test evidence.capabilities.query_structure == :incomplete
        unicode = engine.analyze("SELECT éclair, β FROM données;")
        @test isempty(unicode.issues)
        @test sql_token_text(unicode) ==
            ["SELECT", "éclair", ",", "β", "FROM", "données", ";"]
        @test sql_token_text(engine.analyze("'backslash\\' 'next'")) ==
            ["'backslash\\'", "'next'"]
    end
    @testset "numbers, blobs, operators and parameter spellings" begin
        source = raw"X'00aF' x'' 0xF_F 1_000 1. .5 1e-2 ? ?5 ?5 :name @é $ns::item(tag)"
        evidence = engine.analyze(source)
        @test isempty(evidence.issues)
        @test [token.kind for token in evidence.tokens] ==
            [:blob, :blob, :number, :number, :number, :number, :number,
                :bind, :bind, :bind, :bind, :bind, :bind]
        @test last(sql_token_text(evidence)) == raw"$ns::item(tag)"
        @test isempty(engine.analyze(raw"@ns::item(tag) :name(suffix)").issues)
        @test sql_token_text(engine.analyze("a->>'x'||b != c << 1")) ==
            ["a", "->>", "'x'", "||", "b", "!=", "c", "<<", "1"]
        @test sql_token_text(engine.analyze("1.2.3")) == ["1.2", ".3"]
    end
    @testset "physical lines, CRLF and multiline contents" begin
        source = "-- comment\r\nSELECT 'first\r\n\r\n-- literal\r\nlast'; /* mixed\r\n\r\nend */\r\n\r\n"
        evidence = engine.analyze(source)
        @test evidence.line_kinds ==
            [:comment, :code, :code, :code, :code, :comment, :comment, :blank]
        @test length(evidence.line_starts) == 8
        @test isempty(engine.analyze("").line_kinds)
        @test engine.analyze("\n").line_kinds == [:blank]
        @test engine.analyze("\r\n").line_kinds == [:blank]
        @test engine.analyze("\ufeff\r\n").line_kinds == [:blank]
        @test sql_token_text(engine.analyze("\ufeffSELECT 1;")) == ["SELECT", "1", ";"]
        @test engine.analyze("/* through EOF").line_kinds == [:comment]
        @test isempty(engine.analyze("/* through EOF").issues)
        @test engine.analyze("-- EOF").line_kinds == [:comment]
        @test engine.analyze("SELECT 1; -- mixed").line_kinds == [:code]
    end
    @testset "delimiters and bounded nesting" begin
        evidence = engine.analyze("f((?5), ')', /* ) */ [x(y])")
        @test isempty(evidence.issues)
        links = evidence.delimiter_links
        @test links[2] == length(evidence.tokens)
        @test links[3] == 5
        @test links[5] == 3
        @test evidence.capabilities.delimiter_links == :complete
        at_bound = engine.analyze(repeat("(", engine.MAX_NESTING) *
            repeat(")", engine.MAX_NESTING))
        @test isempty(at_bound.issues)
        @test at_bound.delimiter_links[1] == 2 * engine.MAX_NESTING
        for source in ("(", ")", repeat("(", engine.MAX_NESTING + 1) *
            repeat(")", engine.MAX_NESTING + 1))
            result = engine.analyze(source)
            @test !isempty(result.issues)
            @test result.capabilities.delimiter_links == :incomplete
            @test result.capabilities.lexical_accounting == :complete
        end
    end
    @testset "malformed lexical input is never clean" begin
        for source in ("'unclosed", "\"unclosed", "[unclosed", "`unclosed",
            "X'0'", "X'zz'", "1__0", "0x", "1e+", "12abc", "12é", ":", "!", "\0",
            raw"$::", raw"$name(unclosed", raw"@name(unclosed", "'embedded\0NUL'",
            String(UInt8[0xff]), String(UInt8[0x31, 0xff]))
            evidence = engine.analyze(source)
            @test !isempty(evidence.issues)
            @test evidence.capabilities.lexical_accounting == :incomplete
            @test evidence.line_kinds == [:code]
        end
    end
end

@testset "SQLite discovery and file hierarchy" begin
    mktempdir() do root
        for relative in ("schema.sql", "nested/query.sql", "skip/ignored.sql",
            ".build/generated.sql", "bin/generated.sql", ".git/generated.sql")
            path = joinpath(root, relative)
            mkpath(dirname(path))
            write(path, "-- schema\nSELECT 'é\n\n-- literal'; /* comment */\n")
        end
        paths = OdinJuliaAnalysis.discover_sources(root, ["skip"])
        @test relpath.(paths, root) == ["nested/query.sql", "schema.sql"]
        @test OdinJuliaAnalysis.count_files_by_language(paths)["sql"] == 2
        files = OdinJuliaAnalysis.analyze_files(
            root, paths, Dict{String, Int}(), Diagnostic[])
        nested = OdinJuliaAnalysis.nest_analysis_files(
            files, OdinJuliaAnalysis.FunctionAnalysis[])
        @test all(file -> file.language == "sql" && file.parsed, nested)
        @test all(file -> file.sql !== nothing, nested)
        @test all(file -> isempty(file.functions) && file.struct_count === nothing, nested)
        @test all(file -> file.code_lines == 3 && file.comment_lines == 1, nested)
        @test all(index -> nested[index].sql === files[index].sql, eachindex(nested))
        @test all(file -> file.physical_lines ==
            file.code_lines + file.comment_lines + file.blank_lines, nested)
    end
end

@testset "SQLite repository capability reporting" begin
    settings = settings_with_sqlite(default_sqlite_validation_settings())
    settings = AnalysisSettings((
        name == :jet ? JetSettings(JetEntryPoint[]) :
        name == :odin_build ? OdinBuildSettings(OdinBuildTarget[]) :
        getfield(settings, name) for name in fieldnames(AnalysisSettings))...)
    configuration = OdinJuliaAnalysis.validate_settings(settings)
    mktempdir() do root
        path = joinpath(root, "query.sql")
        write(path, "-- query\nSELECT ?5;\n")
        report = OdinJuliaAnalysis.check_repository(root; configuration)
        @test report.exit_code == 0
        @test report.files_by_language["sql"] == 1
        @test only(report.files).sql.source == "-- query\nSELECT ?5;\n"
        @test isempty(only(report.files).functions)
        @test any(engine -> engine.name == "sql-lexer" &&
            engine.status == "complete", report.engines)
        @test any(engine -> engine.name == "sql" &&
            engine.status == "complete", report.engines)
        @test any(engine -> engine.name == "sqlite-validation" &&
            engine.status == "not-applicable", report.engines)
        encoded = JSON.parse(JSON.json(report))
        @test only(encoded["files"])["sql"]["capabilities"]["query_structure"] ==
            "complete"
        @test only(encoded["files"])["sql"]["tokens"][1]["kind"] == "comment"
        write(path, "SELECT 'unclosed")
        malformed = OdinJuliaAnalysis.check_repository(root; configuration)
        @test malformed.exit_code == 2
        @test any(engine -> engine.name == "sql-lexer" &&
            engine.status == "incomplete" && occursin("query.sql", engine.message),
            malformed.engines)
        configured = SQLiteValidationSettings(
            runner=SQLiteRunnerSettings(["nonexistent-sqlite-runner"]))
        enabled = AnalysisSettings((name == :sqlite_validation ? configured :
            getfield(settings, name) for name in fieldnames(AnalysisSettings))...)
        runtime = OdinJuliaAnalysis.check_repository(root;
            configuration=OdinJuliaAnalysis.validate_settings(enabled))
        @test any(engine -> engine.name == "sqlite-validation" &&
            engine.status == "incomplete", runtime.engines)
    end
end

@testset "SQLite typed settings compatibility" begin
    validate = OdinJuliaAnalysis.validate_settings
    disabled = validate(settings_with_sqlite(default_sqlite_validation_settings()))
    @test disabled.sqlite_validation.runner === nothing
    @test !disabled.sqlite_validation.require_coverage
    runner = SQLiteRunnerSettings(["tool with spaces", "--flag"]; working_directory=".")
    case = SQLiteValidationCase("history"; steps=SQLiteValidationStep[
        SQLiteFileStep("schema", "schema.sql"; role=:setup),
        SQLiteFixtureStep("fixture", "SELECT ?5";
            bindings=[SQLiteBind(5, SQLiteInteger(typemax(Int64)))]),
        SQLiteFileStep("query", "query.sql"; mode=:prepare, bindings=[
            SQLiteBind(1, SQLiteNull()), SQLiteBind(2, SQLiteReal(1.25)),
            SQLiteBind(5, SQLiteText("")), SQLiteBind(9, SQLiteBlob(UInt8[]))])])
    configured = SQLiteValidationSettings(; runner, cases=[case], require_coverage=true)
    loaded = validate(settings_with_sqlite(configured))
    @test loaded.sqlite_validation === configured
    @test loaded.sqlite_validation.runner.command == ["tool with spaces", "--flag"]
    old_settings = AnalysisSettings((getfield(settings_with_sqlite(configured), name)
        for name in fieldnames(AnalysisSettings) if name != :sqlite_validation)...)
    @test validate(old_settings).sqlite_validation.runner === nothing
    old_effective = OdinJuliaAnalysis.EffectiveSettings((getfield(loaded, name)
        for name in fieldnames(OdinJuliaAnalysis.EffectiveSettings)
        if name != :sqlite_validation)...)
    @test old_effective.sqlite_validation.runner === nothing
    for invalid in (
        SQLiteValidationSettings(require_coverage=true),
        SQLiteValidationSettings(cases=[case]),
        SQLiteValidationSettings(runner=SQLiteRunnerSettings(String[])),
        SQLiteValidationSettings(runner=SQLiteRunnerSettings(["tool"]; protocol_version=2)),
        SQLiteValidationSettings(runner=SQLiteRunnerSettings(["tool"]; timeout_seconds=Inf)),
        SQLiteValidationSettings(runner=SQLiteRunnerSettings(["tool"]; timeout_seconds=0)),
        SQLiteValidationSettings(; runner, cases=[case, case]),
        SQLiteValidationSettings(; runner, cases=[SQLiteValidationCase("bad";
            steps=SQLiteValidationStep[SQLiteFileStep("bad", "../outside.sql")])]),
        SQLiteValidationSettings(; runner, cases=[SQLiteValidationCase("bad";
            steps=SQLiteValidationStep[SQLiteFileStep("bad", "query.sql";
                bindings=[SQLiteBind(1, SQLiteReal(NaN))])])]),
        SQLiteValidationSettings(; runner, cases=[SQLiteValidationCase("bad";
            steps=SQLiteValidationStep[SQLiteFileStep("same", "query.sql"),
                SQLiteFileStep("same", "other.sql")])]),
        SQLiteValidationSettings(; runner, cases=[SQLiteValidationCase("bad";
            steps=SQLiteValidationStep[SQLiteFileStep("bad", "query.sql"; mode=:unknown)])]),
        SQLiteValidationSettings(; runner, cases=[SQLiteValidationCase("bad";
            steps=SQLiteValidationStep[SQLiteFileStep("bad", "query.sql";
                bindings=[SQLiteBind(0, SQLiteNull())])])]),
        SQLiteValidationSettings(; runner, cases=[SQLiteValidationCase("bad";
            steps=SQLiteValidationStep[SQLiteFileStep("bad", "query.sql";
                bindings=[SQLiteBind(5, SQLiteNull()), SQLiteBind(5, SQLiteText(""))])])]))
        @test_throws ArgumentError validate(settings_with_sqlite(invalid))
    end
end
