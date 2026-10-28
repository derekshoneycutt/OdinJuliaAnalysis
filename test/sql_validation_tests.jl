"""Layer runtime-only fixture configuration without imposing a provider on structural tests."""
function sqlite_fixture_configuration(validation)
    base = Base.include(
        Module(gensym(:SQLiteValidationFixture)), OdinJuliaAnalysis.DEFAULT_SETTINGS_PATH)
    settings = AnalysisSettings((
        name == :sqlite_validation ? validation :
        name == :jet ? JetSettings(JetEntryPoint[]) :
        name == :odin_build ? OdinBuildSettings(OdinBuildTarget[]) : getfield(base, name)
        for name in fieldnames(AnalysisSettings))...)
    return OdinJuliaAnalysis.validate_settings(settings)
end

"""Configure an explicit executable/argument vector, including a non-shell argument fixture."""
function sqlite_fixture_runner(mode="normal"; timeout=20.0)
    project = normpath(joinpath(@__DIR__, ".."))
    fixture = joinpath(@__DIR__, "fixtures", "sqlite_protocol_runner.jl")
    return SQLiteRunnerSettings([Base.julia_cmd().exec[1], "--startup-file=no",
        "--project=$project", fixture, mode]; timeout_seconds=timeout)
end

@testset "SQLite snapshot request and lossless values" begin
    engine = OdinJuliaAnalysis
    source = "ALTER TABLE t RENAME TO u; SELECT ?5, :named, ?, ?5;"
    evidence = engine.SQLEngine.analyze(source)
    @test evidence.capabilities.query_structure == :incomplete
    values = SQLiteValue[SQLiteNull(), SQLiteInteger(typemin(Int64)),
        SQLiteInteger(typemax(Int64)), SQLiteReal(1.25), SQLiteText(""),
        SQLiteText("a\0β"), SQLiteBlob(UInt8[]), SQLiteBlob(UInt8[0x00, 0xff])]
    bindings = [SQLiteBind(slot, value) for (slot, value) in enumerate(values)]
    case = SQLiteValidationCase("snapshot"; steps=[
        SQLiteFileStep("native", "query.sql"; bindings),
        SQLiteFixtureStep("setup", "SELECT 1;")])
    request = engine.sqlite_case_request(case, Dict("query.sql" => evidence))
    @test request.steps[1].source == source
    @test request.steps[1].digest == engine.sqlite_source_digest(source)
    @test [token.text for token in request.steps[1].bind_tokens] == ["?5", ":named", "?", "?5"]
    @test request.steps[2].source_id == "fixture:snapshot:setup"
    encoded = JSON.parse(JSON.json(request))
    @test encoded.steps[1].binds[2].value == "-9223372036854775808"
    @test encoded.steps[1].binds[3].value == "9223372036854775807"
    @test encoded.steps[1].binds[4].value == 1.25
    @test encoded.steps[1].binds[5].type == "text"
    @test encoded.steps[1].binds[5].value == ""
    @test encoded.steps[1].binds[6].value == "a\0β"
    @test encoded.steps[1].binds[7].type == "blob"
    @test encoded.steps[1].binds[7].value == ""
    @test encoded.steps[1].binds[8].value == "00ff"
    @test_throws ArgumentError engine.sqlite_case_request(
        case, Dict{String, SQLSourceEvidence}())
    oversized = SQLiteValidationCase("large"; steps=[
        SQLiteFixtureStep("large", repeat(" ", engine.SQLITE_SOURCE_LIMIT + 1))])
    @test_throws ArgumentError engine.sqlite_case_request(
        oversized, Dict{String, SQLSourceEvidence}())
    invalid_source = engine.SQLEngine.lex(String(UInt8[0xff]))
    @test_throws ArgumentError engine.sqlite_case_request(case,
        Dict("query.sql" => invalid_source))
    @test_throws ArgumentError engine.validate_sqlite_bindings([
        SQLiteBind(1, SQLiteText(String(UInt8[0xff])))])
    @test_throws ArgumentError engine.validate_sqlite_validation_settings(
        SQLiteValidationSettings(; runner=SQLiteRunnerSettings(
            ["runner"]; working_directory="bad\0directory")))
    root = abspath("fixture-root")
    command = engine.sqlite_runner_command(root,
        SQLiteRunnerSettings(["tool/runner", "an argument"]; working_directory="work"))
    @test command.exec == [joinpath(root, "tool", "runner"), "an argument"]
    @test command.dir == joinpath(root, "work")
end

@testset "SQLite process isolation and incomplete protocol" begin
    engine = OdinJuliaAnalysis
    mktempdir() do root
        path = joinpath(root, "query.sql")
        write(path, "SELECT ?1 AS value;")
        sources = Dict("query.sql" => engine.SQLEngine.analyze(read(path, String)))
        case = SQLiteValidationCase("case"; steps=[
            SQLiteFileStep("operation", "query.sql"; bindings=[
                SQLiteBind(1, SQLiteInteger(1))])])
        for mode in ("normal", "arguments with spaces;not a shell", "stderr")
            result = engine.run_sqlite_case(
                root, case, sqlite_fixture_runner(mode), sources)
            @test result.status == "passed"
            @test result.completed
            @test result.provider.identity == "protocol-test-fixture"
            @test result.steps[1].processed_bytes == ncodeunits(sources["query.sql"].source)
            @test result.steps[1].executed
            mode == "stderr" && @test result.stderr == "bounded fixture diagnostics"
        end
        for mode in ("crash", "malformed", "truncated", "stdout-limit", "stderr-limit")
            result = engine.run_sqlite_case(
                root, case, sqlite_fixture_runner(mode), sources)
            @test result.status == "incomplete"
            @test !result.completed
            @test isempty(result.steps)
            @test result.message !== nothing
            @test ncodeunits(result.stderr) <= engine.SQLITE_STDERR_LIMIT
        end
        timeout = engine.run_sqlite_case(root, case,
            sqlite_fixture_runner("timeout"; timeout=0.1), sources)
        @test timeout.status == "incomplete"
        @test occursin("timed out", timeout.message)
        tiny_timeout = engine.run_sqlite_case(root, case,
            sqlite_fixture_runner("timeout"; timeout=0.0001), sources)
        @test tiny_timeout.status == "incomplete"
        @test occursin("timed out", tiny_timeout.message)
        missing = engine.run_sqlite_case(root, case,
            SQLiteRunnerSettings(["missing tool"]), sources)
        @test missing.status == "incomplete"
        @test occursin("could not start", missing.message)
        declared = SQLiteValidationSettings(; runner=sqlite_fixture_runner("mixed"),
            require_coverage=true, cases=[
                SQLiteValidationCase("bad-case"; steps=case.steps),
                SQLiteValidationCase("good-case"; steps=case.steps)])
        validation = engine.analyze_sqlite_validation(root, sources, declared)
        @test [item.status for item in validation.cases] == ["incomplete", "passed"]
        @test validation.status == "incomplete"
        @test only(validation.coverage).validated
    end
end

"""Return a reconciliable fixture response for mutation-based consistency tests."""
function sqlite_test_response(request)
    return JSON.parse(JSON.json((
        protocol_version=1, case_id=request.case_id, status="passed", completed=true,
        provider=(identity="fixture", version="1", capabilities=["fixture"]),
        transaction_complete=true, cleanup=(finalized=true, closed=true),
        steps=[(; step.id, step.source_id, step.digest, step.mode, status="passed",
            attempted=true, prepared=true, executed=step.mode == "execute",
            processed_bytes=ncodeunits(step.source),
            statement_count=isempty(step.source) ? 0 : 1, failure=nothing)
            for step in request.steps], failure=nothing)))
end

@testset "SQLite result reconciliation rejects contradictory coverage" begin
    engine = OdinJuliaAnalysis
    case = SQLiteValidationCase("case"; steps=[SQLiteFixtureStep("step", "SELECT 1;")])
    request = engine.sqlite_case_request(case, Dict{String, SQLSourceEvidence}())
    response = sqlite_test_response(request)
    @test engine.sqlite_case_result(response, request, "").status == "passed"
    for (field, value) in (
        ("protocol_version", 2), ("protocol_version", true), ("case_id", "other"),
        ("completed", false), ("status", "unknown"), ("transaction_complete", false),
        ("steps", Any[]), ("provider", nothing), ("failure", Dict()))
        broken = deepcopy(response)
        broken[field] = value
        @test_throws ArgumentError engine.sqlite_case_result(broken, request, "")
    end
    for (field, value) in (
        ("id", "other"), ("source_id", "other"), ("digest", repeat("0", 64)),
        ("mode", "prepare"), ("prepared", false), ("executed", false),
        ("attempted", false), ("processed_bytes", 0), ("processed_bytes", 100),
        ("statement_count", -1), ("status", "skipped"), ("status", "failed"))
        broken = deepcopy(response)
        broken.steps[1][field] = value
        @test_throws ArgumentError engine.sqlite_case_result(broken, request, "")
    end
    for field in ("case_id", "failure", "steps", "cleanup", "provider", "completed")
        broken = deepcopy(response)
        delete!(broken, field)
        @test_throws ArgumentError engine.sqlite_case_result(broken, request, "")
    end
    broken = deepcopy(response)
    broken.cleanup["closed"] = false
    @test_throws ArgumentError engine.sqlite_case_result(broken, request, "")
    required = merge(request, (requirements=["unavailable"],))
    @test_throws ArgumentError engine.sqlite_case_result(response, required, "")
end

@testset "SQLite coverage states and structural independence" begin
    engine = OdinJuliaAnalysis
    mktempdir() do root
        write(joinpath(root, "query.sql"), "ALTER TABLE t RENAME TO u;")
        cases = [SQLiteValidationCase("native"; steps=[
            SQLiteFileStep("operation", "query.sql"; mode=:prepare)])]
        validation = SQLiteValidationSettings(;
            runner=sqlite_fixture_runner(), cases, require_coverage=true)
        report = engine.check_repository(root;
            configuration=sqlite_fixture_configuration(validation))
        @test report.exit_code == 2
        @test report.sqlite_validation.status == "complete"
        @test only(report.sqlite_validation.coverage).prepared
        @test !only(report.sqlite_validation.coverage).executed
        @test only(report.sqlite_validation.coverage).validated
        @test report.files[1].sql.capabilities.query_structure == :incomplete
        @test any(item -> item.name == "sql" && item.status == "incomplete", report.engines)
        @test any(item -> item.name == "sqlite-validation" && item.status == "complete",
            report.engines)
        encoded = JSON.parse(JSON.json(report))
        @test encoded.sqlite_validation.cases[1].provider.identity == "protocol-test-fixture"
        @test only(encoded.sqlite_validation.coverage).validated
        for comprehensive in (false, true)
            output = IOBuffer()
            engine.write_markdown_report(output, report; comprehensive)
            text = String(take!(output))
            @test occursin("SQLite Runtime Validation", text)
            @test occursin("protocol-test-fixture", text)
            @test occursin("| query.sql | true | true | true | false | true |", text)
        end
        empty_cases = SQLiteValidationSettings(;
            runner=sqlite_fixture_runner(), require_coverage=true)
        uncovered = engine.check_repository(root;
            configuration=sqlite_fixture_configuration(empty_cases))
        @test uncovered.sqlite_validation.status == "failed"
        @test !only(uncovered.sqlite_validation.coverage).declared
        @test !only(uncovered.sqlite_validation.coverage).validated
        disabled = engine.check_repository(root;
            configuration=sqlite_fixture_configuration(SQLiteValidationSettings()))
        @test disabled.sqlite_validation.status == "not-applicable"
        @test isempty(disabled.sqlite_validation.cases)
        sources = Dict("query.sql" => report.files[1].sql)
        fixture_only = SQLiteValidationSettings(; runner=sqlite_fixture_runner(),
            require_coverage=true, cases=[SQLiteValidationCase("fixture"; steps=[
                SQLiteFixtureStep("setup", "SELECT 1;")])])
        evidence = engine.analyze_sqlite_validation(root, sources, fixture_only)
        @test evidence.status == "failed"
        @test !only(evidence.coverage).declared
        @test !only(evidence.coverage).attempted
    end

    """Build a native-style diagnostic independently of any consumer's SQLite bindings."""
    function sqlite_test_failure(phase; offset=nothing, code=1)
        return Dict{String, Any}("phase" => phase, "primary_code" => code,
            "extended_code" => code, "offset" => offset, "message" => "fixture $phase failure")
    end

    @testset "SQLite failed steps, dependencies and cleanup reconciliation" begin
        engine = OdinJuliaAnalysis
        case = SQLiteValidationCase("case"; steps=[
            SQLiteFixtureStep("setup", "CREATE TABLE t (id);"),
            SQLiteFixtureStep("fixture", "INSERT INTO t VALUES (1);"),
            SQLiteFileStep("query", "query.sql")])
        sources = Dict("query.sql" => engine.SQLEngine.analyze("SELECT id FROM t;"))
        request = engine.sqlite_case_request(case, sources)
        response = sqlite_test_response(request)
        response["status"] = "failed"
        response.steps[1]["status"] = "failed"
        response.steps[1]["prepared"] = false
        response.steps[1]["executed"] = false
        response.steps[1]["failure"] = sqlite_test_failure("prepare"; offset=2)
        for step in response.steps[2:end]
            step["status"] = "skipped"
            step["attempted"] = false
            step["prepared"] = false
            step["executed"] = false
            step["statement_count"] = 0
            step["processed_bytes"] = 0
        end
        result = engine.sqlite_case_result(response, request, "copied stderr")
        @test result.status == "failed"
        @test result.steps[1].failure.phase == "prepare"
        @test result.steps[2].status == result.steps[3].status == "skipped"
        @test result.stderr == "copied stderr"
        failed_evidence = SQLiteValidationEvidence(
            "failed", false, [result], SQLiteSourceCoverage[], nothing)
        output = IOBuffer()
        engine.write_sqlite_validation(output, failed_evidence)
        text = String(take!(output))
        @test occursin("Failure [prepare] SQLite 1/1 at byte 2", text)
        @test occursin("copied stderr", text)
        output = IOBuffer()
        engine.write_markdown_sqlite_validation(output, failed_evidence)
        markdown = String(take!(output))
        @test occursin("Failure **prepare**: SQLite 1/1, byte 2", markdown)
        @test occursin("copied stderr", markdown)
        settings = SQLiteValidationSettings(; runner=sqlite_fixture_runner(),
            cases=[case], require_coverage=true)
        coverage = only(engine.sqlite_source_coverage(sources, settings, [result]))
        @test coverage.declared
        @test !coverage.attempted
        @test !coverage.validated
        contradictory = deepcopy(response)
        contradictory.steps[2] = sqlite_test_response(request).steps[2]
        @test_throws ArgumentError engine.sqlite_case_result(contradictory, request, "")
        for (field, value) in (("primary_code", 2), ("offset", 100), ("phase", "unknown"))
            contradictory = deepcopy(response)
            contradictory.steps[1].failure[field] = value
            @test_throws ArgumentError engine.sqlite_case_result(contradictory, request, "")
        end
        transaction = sqlite_test_response(request)
        transaction["status"] = "failed"
        transaction["transaction_complete"] = false
        transaction["failure"] = sqlite_test_failure("transaction"; code=0)
        @test engine.sqlite_case_result(transaction, request, "").status == "failed"
        uncommitted = engine.sqlite_case_result(transaction, request, "")
        uncommitted_coverage = only(engine.sqlite_source_coverage(
            sources, settings, [uncommitted]))
        @test uncommitted_coverage.executed
        @test !uncommitted_coverage.validated
        cleanup = deepcopy(response)
        cleanup.cleanup["closed"] = false
        @test_throws ArgumentError engine.sqlite_case_result(cleanup, request, "")
        cleanup["failure"] = sqlite_test_failure("close"; code=5)
        @test !engine.sqlite_case_result(cleanup, request, "").closed
        capabilities = deepcopy(response)
        capabilities["failure"] = sqlite_test_failure("capability"; code=0)
        for step in capabilities.steps
            step["status"] = "skipped"
            step["attempted"] = step["prepared"] = step["executed"] = false
            step["statement_count"] = step["processed_bytes"] = 0
            step["failure"] = nothing
        end
        missing = merge(request, (requirements=["unavailable"],))
        @test engine.sqlite_case_result(capabilities, missing, "").status == "failed"
        unavailable = engine.sqlite_decode_result(
            (stdout=JSON.json(capabilities), stderr=""), missing)
        @test unavailable.status == "incomplete"
        @test unavailable.failure.phase == "capability"
        @test unavailable.provider.identity == "fixture"
        for stdout in ("null", "true", "[]", "{}", "{\"protocol_version\":1}")
            decoded = engine.sqlite_decode_result((; stdout, stderr="fixture"), request)
            @test decoded.status == "incomplete"
            @test isempty(decoded.steps)
        end
    end
end
