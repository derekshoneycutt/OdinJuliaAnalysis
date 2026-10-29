@testset "Verification tool" begin
    include(joinpath(@__DIR__, "..", "tools", "Verification.jl"))
    using .Verification

    operation = () -> PhaseResult(
        "Synthetic phase",
        "3 checks",
        UInt64(1_500_000),
        "PASS",
        "phase output\n",
        Dict{String, Any}("checks" => 3))
    progress = IOBuffer()
    results = run_phases(
        [("Run synthetic phase", operation)];
        heading="Run synthetic verification",
        progress_io=progress)

    progress_text = String(take!(progress))
    @test occursin("==> Run synthetic verification", progress_text)
    @test occursin("[1/1] Run synthetic phase", progress_text)
    @test occursin("PASS  3 checks (2 ms)", progress_text)

    text_output = IOBuffer()
    write_report(text_output, results; color=:always)
    text = String(take!(text_output))
    @test occursin("VERIFICATION", text)
    @test occursin("Synthetic phase", text)
    @test occursin("\e[1;32mPASS", text)
    @test occursin("Verification: PASS", text)

    structured_failure = PhaseResult(
        "Structured analysis",
        "1 failure",
        UInt64(1),
        "FAIL",
        "{\"large\":\"machine report\"}\n",
        Dict{String, Any}("report" => (diagnostics=Any[],)))
    structured_output = IOBuffer()
    write_report(structured_output, [structured_failure])
    structured_text = String(take!(structured_output))
    @test occursin("Structured analysis", structured_text)
    @test !occursin("machine report", structured_text)
    @test !occursin("FAILURE: Structured analysis", structured_text)

    trace_output = IOBuffer()
    write_report(trace_output, [structured_failure]; verbosity=Trace)
    @test occursin("machine report", String(take!(trace_output)))

    json_output = IOBuffer()
    write_report(json_output, results; format="json")
    report = JSON.parse(String(take!(json_output)))
    @test report.schema_version == "1.0.0"
    @test report.passed
    @test only(report.phases).metadata.checks == 3

    command = Cmd([
        Base.julia_cmd().exec...,
        "--startup-file=no",
        "-e",
        "print(42)",
    ])
    captured = capture_command(command)
    @test captured.exit_code == 0
    @test captured.output == "42"

    mktempdir() do root
        path = joinpath(root, "query.sql")
        write(path, "SELECT ?1 AS value;")
        canonical = OdinJuliaAnalysis.check_repository(
            root; configuration=sql_rule_configuration())
        serialized = JSON.parse(JSON.json(canonical))
        output = IOBuffer()
        Verification.write_code_statistics(output, serialized, false)
        summary = String(take!(output))
        @test occursin("SQLite", summary)
        @test occursin("Procedural total", summary)
        @test !occursin("Shared source:", summary)
        @test !occursin("SQLite inventory:", summary)
        @test occursin("\u2014 (not applicable", summary)
        @test !occursin("CC coverage:", summary)
        @test !occursin("SQLite lexical coverage:", summary)
        @test !occursin("SQLite runtime validation:", summary)
        @test occursin("HLSL: lexical-only", summary)
        @test occursin("HLSL", summary)
        @test Verification.code_statistics_row("SQLite",
            serialized.statistics.code_by_language.sql)[3:4] == ["\u2014", "\u2014"]
        @test Verification.code_statistics_row("HLSL",
            serialized.statistics.code_by_language.hlsl)[3:4] == ["\u2014", "\u2014"]
        write(path, "ALTER TABLE t RENAME TO u;")
        partial = OdinJuliaAnalysis.check_repository(
            root; configuration=sql_rule_configuration())
        output = IOBuffer()
        Verification.write_code_statistics(output, JSON.parse(JSON.json(partial)), false)
        incomplete_summary = String(take!(output))
        @test !occursin("SQLite inventory:", incomplete_summary)
        @test !occursin("SQLite reason:", incomplete_summary)
    end
end
