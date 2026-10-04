@testitem "id-keyed containers accept Int64 ids" begin
    # The JSON parser returns integer ids as Int64. On 32-bit Julia `Int === Int32`, so any
    # slot typed with `Int` throws a MethodError on `convert` for the very first request.
    ep = JSONRPC.JSONRPCEndpoint(IOBuffer(), IOBuffer())

    @test Int64 <: fieldtype(JSONRPC.Request, :id)
    @test Int64 <: keytype(ep.cancellation_sources)
    @test Int64 <: eltype(ep.no_longer_needed_cancellation_sources)

    id = Int64(typemax(Int32)) + 1
    @test JSONRPC._parse_json("""{"id":$id}""")["id"] isa Int64

    request = JSONRPC.Request("m", nothing, id, nothing)
    @test request.id === id

    ep.cancellation_sources[id] = JSONRPC.CancellationTokens.CancellationTokenSource()
    @test collect(keys(ep.cancellation_sources)) == [id]
    @test first(keys(ep.cancellation_sources)) === id

    put!(ep.no_longer_needed_cancellation_sources, id)
    @test take!(ep.no_longer_needed_cancellation_sources) === id
end

@testitem "request with an id outside the Int32 range" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(server)

    request_type = JSONRPC.RequestType("slow_op", Nothing, String)
    handler_started = Channel{Bool}(1)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        put!(handler_started, true)
        try
            wait(token)
        catch
        end
        is_cancellation_requested(token) ? "cancelled" : "done"
    end

    server_task = @async try
        for msg in server
            @async try
                JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
            catch err
                @error "handler" ex=(err, catch_backtrace())
            end
        end
    catch err
        @error "handler" ex=(err, catch_backtrace())
    end

    # The peer side is driven by hand, because a JSONRPCEndpoint always sends string ids
    send_raw(msg) = (JSONRPC.write_transport_layer(socket2, JSONRPC._serialize_json(JSONRPC.DefaultJSONSerialization(), msg)); flush(socket2))
    read_raw() = JSONRPC._parse_json(JSONRPC.read_transport_layer(socket2, CancellationTokens.get_token(CancellationTokenSource(10.0))))

    id = Int64(typemax(Int32)) + 5

    send_raw(Dict("jsonrpc" => "2.0", "id" => id, "method" => "slow_op", "params" => nothing))
    # Without Int64 ids the read task dies on this request and the handler never runs
    @test timedwait(() -> isready(handler_started), 10.0) === :ok
    @test server.err === nothing
    @test haskey(server.cancellation_sources, id)

    send_raw(Dict("jsonrpc" => "2.0", "method" => "\$/cancelRequest", "params" => Dict("id" => id)))
    response = read_raw()
    @test response["id"] === id
    @test response["result"] == "cancelled"

    # The next incoming message makes the read task drop the finished request's cancellation source
    send_raw(Dict("jsonrpc" => "2.0", "method" => "\$/cancelRequest", "params" => Dict("id" => "unknown")))
    timedwait(() -> !haskey(server.cancellation_sources, id), 5.0)
    @test !haskey(server.cancellation_sources, id)
    @test server.status == JSONRPC.status_running

    close(socket2)
    close(server)
    close(socket1)
    fetch(server_task)
end
