@testitem "start on non-idle endpoint errors" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Double-start should throw
    @test_throws ErrorException("Endpoint is not idle.") JSONRPC.start(ep)

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "start after close errors" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)
    close(ep)

    # Start on a closed endpoint should throw
    @test_throws ErrorException("Endpoint is not idle.") JSONRPC.start(ep)

    close(socket1)
    close(socket2)
end

@testitem "close on idle endpoint" begin
    # close() on a never-started endpoint should work without error
    buf_in = IOBuffer()
    buf_out = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf_in, buf_out)
    @test ep.status == JSONRPC.status_idle
    close(ep)
    @test ep.status == JSONRPC.status_closed
end

@testitem "close is idempotent" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Close the underlying socket to unblock the read task, then close the endpoint
    close(socket1)
    close(ep)
    @test ep.status == JSONRPC.status_closed

    # Second close should be a no-op
    close(ep)
    @test ep.status == JSONRPC.status_closed

    close(socket2)
end

@testitem "close on errored endpoint sets closed" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Force an error by closing the underlying socket
    close(socket1)
    sleep(0.2)

    # Endpoint may be errored now; close should bring it to closed
    close(ep)
    @test ep.status == JSONRPC.status_closed

    close(socket2)
end

@testitem "isopen reflects running status" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)

    # Not open before start
    @test !isopen(ep)

    JSONRPC.start(ep)
    @test isopen(ep)

    close(socket1)
    close(ep)
    @test !isopen(ep)

    close(socket2)
end

@testitem "flush on running endpoint" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Send a notification and flush
    JSONRPC.send_notification(client, "ping", nothing)
    flush(client)  # should not throw

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "send_notification on idle endpoint errors" begin
    buf = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf, buf)
    threw = Ref(false)
    try
        JSONRPC.send_notification(ep, "test", nothing)
    catch err
        threw[] = true
        @test err isa ErrorException || err isa JSONRPC.TransportError
    end
    @test threw[]
end

@testitem "send_request on idle endpoint errors" begin
    buf = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf, buf)
    threw = Ref(false)
    try
        JSONRPC.send_request(ep, "test", nothing)
    catch err
        threw[] = true
        @test err isa ErrorException || err isa JSONRPC.TransportError
    end
    @test threw[]
end

@testitem "get_next_message on idle endpoint errors" begin
    buf = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf, buf)
    threw = Ref(false)
    try
        JSONRPC.get_next_message(ep)
    catch err
        threw[] = true
        @test err isa ErrorException || err isa JSONRPC.TransportError
    end
    @test threw[]
end

@testitem "iterate on idle endpoint errors" begin
    buf = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf, buf)
    threw = Ref(false)
    try
        iterate(ep)
    catch err
        threw[] = true
        @test err isa ErrorException || err isa JSONRPC.TransportError
    end
    @test threw[]
end

@testitem "flush on idle endpoint errors" begin
    buf = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf, buf)
    threw = Ref(false)
    try
        flush(ep)
    catch err
        threw[] = true
        @test err isa ErrorException || err isa JSONRPC.TransportError
    end
    @test threw[]
end

@testitem "send_success_response on notification errors" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Send a notification (no id)
    JSONRPC.send_notification(client, "ping", nothing)
    msg = JSONRPC.get_next_message(server)
    @test msg.id === nothing

    # Attempting to respond to a notification should error
    @test_throws ErrorException("Cannot send a response to a notification.") JSONRPC.send_success_response(server, msg, "pong")

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "send_error_response on notification errors" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    JSONRPC.send_notification(client, "ping", nothing)
    msg = JSONRPC.get_next_message(server)
    @test msg.id === nothing

    @test_throws ErrorException("Cannot send a response to a notification.") JSONRPC.send_error_response(server, msg, -32603, "err", nothing)

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end
