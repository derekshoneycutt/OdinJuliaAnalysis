module JetEngine

using JET

using ..OdinJuliaAnalysis: Diagnostic
using ..OdinJuliaAnalysis: EffectiveSettings
using ..OdinJuliaAnalysis: Ignore
using ..OdinJuliaAnalysis: configured_diagnostic

export analyze

const RULE_ID = "JULIA-JET-POSSIBLE-ERROR"

"""Analyze configured Julia call roots with JET and deduplicate diagnostics."""
function analyze(root::String, configuration::EffectiveSettings)
    JET.JET_AVAILABLE || error("JET is unavailable for this Julia version")
    diagnostics = Diagnostic[]
    Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
        redirect_stderr(devnull) do
            for entry in configuration.jet.entry_points
                result = JET.report_call(
                    entry.callable,
                    entry.argument_types;
                    target_modules=(parentmodule(entry.callable),))
                for report in JET.get_reports(result)
                    diagnostic = configured_diagnostic(
                        configuration,
                        jet_diagnostic(root, entry.path, report))
                    diagnostic === nothing || push!(diagnostics, diagnostic)
                end
            end
        end
    end
    unique!(diagnostic_identity, diagnostics)
    return diagnostics
end

"""Convert one structured JET report to the canonical diagnostic model."""
function jet_diagnostic(root, analyzed_path, report)
    file, line = report_location(report)
    path = repository_path(root, analyzed_path, file)
    message = report_message(report)
    message = replace(
        message,
        r"(?:Main\.)?var\"##JETVirtualModule#\d+\"\." => "")
    return Diagnostic(
        RULE_ID,
        Ignore,
        path,
        max(line, 1),
        1,
        message,
        nothing,
        nothing,
        "jet")
end

"""Render an inference or top-level JET report with its supported interface."""
function report_message(report)
    if report isa JET.InferenceErrorReport
        return sprint(io -> JET.print_report_message(io, report))
    end
    return sprint(io -> JET.print_report(io, report))
end

"""Return the source location associated with a JET report."""
function report_location(report)
    if report isa JET.InferenceErrorReport
        frame = last(report.vst)
        return String(frame.file), frame.line
    end
    return String(report.file), report.line
end

"""Return a repository-relative report path, falling back to the entry path."""
function repository_path(root, entry_path, reported_file)
    candidate = isabspath(reported_file) ? reported_file : abspath(reported_file)
    relative = relpath(candidate, root)
    startswith(relative, "..") && return entry_path
    return relative
end

"""Return the stable identity used to deduplicate JET diagnostics."""
function diagnostic_identity(diagnostic)
    return (
    path=diagnostic.path,
    line=diagnostic.line,
    column=diagnostic.column,
    message=diagnostic.message)
end

end
