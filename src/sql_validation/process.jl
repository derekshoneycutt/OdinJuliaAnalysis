"""Retain a bounded prefix while draining pipes so child diagnostics cannot deadlock."""
mutable struct SQLitePipeCapture
    bytes::Vector{UInt8}
    overflow::Bool
end

"""Drain until EOF; excess output marks the whole protocol incomplete."""
function sqlite_drain_pipe(pipe, limit, capture)
    buffer = Vector{UInt8}(undef, 8192)
    try
        while !eof(pipe)
            count = readbytes!(pipe, buffer, length(buffer))
            available = max(0, limit - length(capture.bytes))
            append!(capture.bytes, @view buffer[1:min(count, available)])
            capture.overflow |= count > available
        end
    catch error
        error isa Base.IOError || error isa EOFError || rethrow()
        capture.overflow = true
    end
end

"""Stop only the owned child; always reap it before releasing case resources."""
function sqlite_stop_process(process)
    process_exited(process) || kill(process, Base.SIGKILL)
    wait(process)
end

"""Execute a case with bounded input/output and a deadline covering pipe completion."""
function sqlite_process(command, request, timeout)
    return mktemp() do _, input
        write(input, JSON.json(request))
        seekstart(input)
        sqlite_process_io(command, input, timeout)
    end
end

"""Capture process completion, output limits and timeouts without shell interpolation."""
function sqlite_process_io(command, input, timeout)
    output, errors = Pipe(), Pipe()
    process = try
        run(pipeline(ignorestatus(command); stdin=input, stdout=output, stderr=errors);
            wait=false)
    catch error
        close(output)
        close(errors)
        error isa Union{Base.IOError, SystemError, ArgumentError} || rethrow()
        return (; status="incomplete", stdout="", stderr="",
            message="SQLite runner could not start: $(sprint(showerror, error))")
    end
    close(output.in)
    close(errors.in)
    return sqlite_capture_process(process, output, errors, timeout)
end

"""Supervise readers and the owned process under the same case deadline."""
function sqlite_capture_process(process, output, errors, timeout)
    out = SQLitePipeCapture(UInt8[], false)
    err = SQLitePipeCapture(UInt8[], false)
    out_task = @async sqlite_drain_pipe(output, SQLITE_STDOUT_LIMIT, out)
    err_task = @async sqlite_drain_pipe(errors, SQLITE_STDERR_LIMIT, err)
    done = timedwait(() -> (process_exited(process) &&
        istaskdone(out_task) && istaskdone(err_task)) || out.overflow || err.overflow,
        timeout; pollint=0.01)
    timed_out = done == :timed_out
    if timed_out || out.overflow || err.overflow
        sqlite_stop_process(process)
        close(output)
        close(errors)
    else
        wait(process)
    end
    wait(out_task)
    wait(err_task)
    close(output)
    close(errors)
    message = timed_out ? "SQLite runner timed out after $timeout seconds." :
        out.overflow || err.overflow ? "SQLite runner exceeded captured output limits." :
        process.exitcode != 0 ? "SQLite runner exited with code $(process.exitcode)." : nothing
    return (; status=message === nothing ? "complete" : "incomplete",
        stdout=String(out.bytes), stderr=String(err.bytes), message)
end
