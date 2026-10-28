using JSON

"""Return a protocol fixture step without making any claim of native SQLite execution."""
function fixture_step(request)
    return Dict{String, Any}(
        "id" => request.id, "source_id" => request.source_id,
        "digest" => request.digest, "mode" => request.mode, "status" => "passed",
        "attempted" => true, "prepared" => true, "executed" => request.mode == "execute",
        "processed_bytes" => ncodeunits(request.source),
        "statement_count" => isempty(request.source) ? 0 : 1, "failure" => nothing)
end

"""Echo identities for generic orchestration tests without a SQLite dependency."""
function fixture_result(request)
    return Dict{String, Any}(
        "protocol_version" => 1, "case_id" => request.case_id, "status" => "passed",
        "provider" => Dict("identity" => "protocol-test-fixture", "version" => "1",
            "capabilities" => ["fixture"]),
        "completed" => true, "transaction_complete" => true,
        "cleanup" => Dict("finalized" => true, "closed" => true),
        "steps" => fixture_step.(request.steps), "failure" => nothing)
end

"""Exercise process boundaries, never substitute this fixture for provider acceptance."""
function fixture_main()
    request = JSON.parse(read(stdin, String))
    mode = only(ARGS)
    mode == "timeout" && sleep(10)
    mode == "crash" && exit(7)
    mode == "malformed" && return print("{")
    mode == "truncated" && return print("{\"protocol_version\":1")
    mode == "stdout-limit" && return print(repeat("x", 3 * 1024 * 1024))
    mode == "stderr-limit" && print(stderr, repeat("x", 128 * 1024))
    mode == "stderr" && print(stderr, "bounded fixture diagnostics")
    mode == "arguments with spaces;not a shell" || mode in (
        "normal", "stderr", "stderr-limit", "mixed") ||
        error("unknown fixture mode: $mode")
    result = fixture_result(request)
    if mode == "mixed" && startswith(request.case_id, "bad")
        result["steps"][1]["digest"] = repeat("0", 64)
    end
    JSON.print(stdout, result)
end

fixture_main()
