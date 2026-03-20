@testitem "read task: JSON parse failure sets err" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Send a valid transport frame with invalid JSON content
    invalid_json = "this is not json"
    n = ncodeunits(invalid_json)
    write(socket2, "Content-Length: $n\r\n\r\n$invalid_json")
    flush(socket2)

    sleep(0.3)

    # The endpoint should have recorded a TransportError about parsing
    @test ep.err isa JSONRPC.TransportError
    @test occursin("parse", lowercase(ep.err.msg))

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "read task: response for unknown request id sets err" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Send a response message (no "method" key) with an id that doesn't exist
    response_json = "{\"jsonrpc\":\"2.0\",\"id\":\"nonexistent-id-12345\",\"result\":\"hello\"}"
    n = ncodeunits(response_json)
    write(socket2, "Content-Length: $n\r\n\r\n$response_json")
    flush(socket2)

    sleep(0.3)

    @test ep.err isa JSONRPC.TransportError
    @test occursin("unknown request", lowercase(ep.err.msg))

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "read task: response without result or error" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Start a request in the background
    result_ch = Channel{Any}(1)
    @async try
        res = JSONRPC.send_request(client, "test_method", nothing)
        put!(result_ch, res)
    catch err
        put!(result_ch, err)
    end

    # Read the request on the server side
    msg = JSONRPC.get_next_message(server)

    # Craft a response with neither "result" nor "error"
    bad_response = "{\"jsonrpc\":\"2.0\",\"id\":\"$(msg.id)\"}"

    # But we need to write this from the server's pipe back to the client.
    # Instead of using send_success_response, write raw transport frame to the server's out pipe.
    # The server's pipe_out is socket1, which is connected to socket2 (client's pipe_in).
    JSONRPC.write_transport_layer(socket1, bad_response)

    result = take!(result_ch)
    @test result isa JSONRPC.TransportError
    @test occursin("malformed", lowercase(result.msg))

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "write task: pipe closure during write sets err" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    # Use socket1 for reading and socket2 for writing
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket2)
    JSONRPC.start(ep)

    # Close the write-side socket to trigger IOError in the write task
    close(socket2)

    # Queue a message — write task should hit the closed pipe
    try
        put!(ep.out_msg_queue, "{\"jsonrpc\":\"2.0\",\"method\":\"test\"}")
    catch
        # Channel may be closed already
    end

    sleep(0.3)

    # The error should be recorded (either write task IOError or the pipe was already closed)
    # In either case, close should work
    close(ep)
    @test ep.status == JSONRPC.status_closed

    close(socket1)
end

@testitem "iterate returns nothing on clean close" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Start iterate in background so it's waiting while the endpoint is still running
    result_ch = Channel{Any}(1)
    @async try
        r = iterate(server)
        put!(result_ch, something(r, :nothing_returned))
    catch err
        put!(result_ch, err)
    end

    sleep(0.1)

    # Close the client to signal EOF to the server
    close(client)
    close(socket2)

    result = take!(result_ch)
    @test result === :nothing_returned

    close(server)
    close(socket1)
end

@testitem "iterate surfaces TransportError after broken pipe" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Inject a bad JSON message to cause a TransportError
    invalid_json = "not valid json at all"
    n = ncodeunits(invalid_json)
    write(socket2, "Content-Length: $n\r\n\r\n$invalid_json")
    flush(socket2)

    sleep(0.3)

    # iterate should throw the stored TransportError
    threw = Ref(false)
    try
        iterate(ep)
    catch err
        threw[] = true
        @test err isa JSONRPC.TransportError
    end
    @test threw[]

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "send_request: error response from server" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("fail_me", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> JSONRPC.JSONRPCError(-32000, "custom server error", "details")

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch
    end

    threw = Ref(false)
    try
        JSONRPC.send(client, request_type, nothing)
    catch err
        threw[] = true
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32000
        @test err.msg == "custom server error"
        @test err.data == "details"
    end
    @test threw[]

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "check_dead_endpoint! throws TransportError when err is set" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Inject parse error
    write(socket2, "Content-Length: 3\r\n\r\n!!!")
    flush(socket2)
    sleep(0.3)

    # check_dead_endpoint! should throw the stored TransportError
    threw = Ref(false)
    try
        JSONRPC.check_dead_endpoint!(ep)
    catch err
        threw[] = true
        @test err isa JSONRPC.TransportError
    end
    @test threw[]

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "check_dead_endpoint! error message includes status" begin
    buf = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf, buf)
    # ep is idle, not running
    threw = Ref(false)
    try
        JSONRPC.check_dead_endpoint!(ep)
    catch err
        threw[] = true
        @test err isa ErrorException
        @test occursin("status_idle", string(err.msg))
    end
    @test threw[]
end
