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

    json_output = IOBuffer()
    write_report(json_output, results; format="json")
    report = JSON3.read(String(take!(json_output)))
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
end
