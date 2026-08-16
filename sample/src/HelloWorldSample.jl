module HelloWorldSample

export greeting, main

const GREETING = "Hello from Julia!"

"""Return the sample's Julia greeting."""
greeting() = GREETING

"""Print the Julia greeting to an output stream."""
function main(io::IO=stdout)
    println(io, greeting())
end

end
