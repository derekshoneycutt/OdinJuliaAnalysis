@testset "Verification progress presentation" begin
    @test !Verification.terminal_progress_enabled(nothing)
    @test !Verification.terminal_progress_enabled(IOBuffer())
    @test !Verification.terminal_progress_enabled(IOContext(IOBuffer(), :color => true))
    for (seconds, expected) in ((0, "00:00"), (9, "00:09"),
        (60, "01:00"), (3661, "61:01"))
        @test Verification.progress_elapsed(UInt64(seconds) * 1_000_000_000) == expected
    end
    result = Verification.PhaseResult(
        "Synthetic", "3 checks", UInt64(1_000_000), "PASS", "", Dict{String, Any}())
    for status in ("PASS", "FAIL")
        output = IOBuffer()
        completed = Verification.PhaseResult(
            result.name, result.detail, result.elapsed_ns, status, "", result.metadata)
        operation = () -> begin
            progress = task_local_storage(:verification_phase_progress)
            @test timedwait(() -> progress.frame >= 3, 5.0) == :ok
            progress.started = time_ns() - UInt64(2_000_000_000)
            Verification.draw_progress(progress)
            return completed
        end
        @test Verification.run_progress_phase(
            output, 2, 4, "Synthetic", operation; animate=true) === completed
        text = String(take!(output))
        @test occursin("[2/4] Synthetic", text)
        @test occursin("00:02", text)
        @test endswith(text, "[2/4] Synthetic  $status  3 checks (1 ms)\n")
        @test !haskey(task_local_storage(), :verification_phase_progress)
    end
    output = IOBuffer()
    Verification.run_progress_phase(output, 1, 4, "Synthetic", () -> result)
    text = String(take!(output))
    @test text == "  [1/4] Synthetic\n        PASS  3 checks (1 ms)\n"
    @test !occursin('\r', text)
    @test !occursin('\e', text)
    @test Verification.run_progress_phase(nothing, 1, 4, "Silent", () -> result) === result
end

@testset "Verification spinner cleanup" begin
    for exception in (ErrorException("phase failed"), InterruptException())
        output = IOBuffer()
        state = Ref{Verification.PhaseProgress}()
        operation = () -> begin
            state[] = task_local_storage(:verification_phase_progress)
            throw(exception)
        end
        @test_throws typeof(exception) Verification.run_progress_phase(
            output, 1, 4, "Throwing phase", operation; animate=true)
        @test !state[].active
        @test !haskey(task_local_storage(), :verification_phase_progress)
        before = position(output)
        sleep(0.2)
        @test position(output) == before
        @test endswith(String(take!(output)), "\r\e[2K")
    end
end

@testset "Verification spinner and child diagnostics" begin
    output = IOBuffer()
    response = Ref{Any}()
    operation = () -> begin
        command = Cmd([Base.julia_cmd().exec..., "--startup-file=no", "-e",
            "print(stdout, \"machine output\"); " *
                "println(stderr, \"milestone\"); print(stderr, \"partial diagnostic\"); exit(7)"])
        response[] = Verification.capture_command_streams(command; stream_errors=true)
        return Verification.PhaseResult(
            "Child", "failed child", UInt64(1), "FAIL", "", Dict{String, Any}())
    end
    Verification.run_progress_phase(output, 1, 4, "Child", operation; animate=true)
    text = String(take!(output))
    @test response[].output == "machine output"
    @test response[].errors == ""
    @test response[].exit_code == 7
    @test occursin("\r\e[2Kmilestone\n\r\e[2K", text)
    @test occursin("\r\e[2Kpartial diagnostic\n\r\e[2K", text)
    @test !occursin("machine output", text)
end
