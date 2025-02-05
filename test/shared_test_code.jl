@testmodule TestStructs begin
    using JSONRPC: @dict_readable, Outbound

    export Foo, Foo2

    @dict_readable struct Foo <: Outbound
        fieldA::Int
        fieldB::String
        fieldC::Union{Missing,String}
        fieldD::Union{String,Missing}
    end

    @dict_readable struct Foo2 <: Outbound
        fieldA::Union{Nothing,Int}
        fieldB::Vector{Int}
    end

    Base.:(==)(a::Foo2,b::Foo2) = a.fieldA == b.fieldA && a.fieldB == b.fieldB

end

@testmodule NamedPipes begin
    using Sockets, JSONRPC

    export get_named_pipe

    function get_named_pipe()
        socket_name = JSONRPC.generate_pipe_name()

        server_is_up = Channel(1)

        socket1_channel = Channel(1)

        @async try
            server = listen(socket_name)
            put!(server_is_up, true)
            socket1 = accept(server)

            put!(socket1_channel, socket1)
        catch err
            Base.display_error(err, catch_backtrace())
        end

        wait(server_is_up)

        socket2 = connect(socket_name)

        socket1 = take!(socket1_channel)
        
        return socket1, socket2
    end
end
