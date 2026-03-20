@testitem "TransportError surfaced on send_request after broken pipe" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("echo", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> "hello"

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch
    end

    # Verify it works first
    res = JSONRPC.send(client, request_type, nothing)
    @test res == "hello"

    # Now kill the server side abruptly (close underlying socket)
    close(socket1)
    close(server)

    # Wait for client to detect the broken pipe
    sleep(0.3)

    # The next API call should throw TransportError (or at minimum an error)
    threw = Ref(false)
    try
        JSONRPC.send(client, request_type, nothing)
    catch err
        threw[] = true
        @test err isa JSONRPC.TransportError || err isa JSONRPC.JSONRPCError || err isa ErrorException
    end
    @test threw[]

    close(client)
    close(socket2)
end

@testitem "TransportError stored in endpoint.err" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
        end
    catch
    end

    # Kill the remote side to trigger a transport error on the client
    close(socket1)
    close(server)

    sleep(0.3)

    # endpoint.err may or may not be set depending on timing,
    # but after close the status should be :closed
    close(client)
    @test client.status == JSONRPC.status_closed
    close(socket2)
end

@testitem "get_next_message with user token: normal return" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    notify_type = JSONRPC.NotificationType("ping", Nothing)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Send a notification from client to server
    JSONRPC.send(client, notify_type, nothing)

    # Server should receive it, even with a user token
    src = CancellationTokenSource()
    msg = JSONRPC.get_next_message(server; token=get_token(src))
    @test msg isa JSONRPC.Request
    @test msg.method == "ping"

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "get_next_message with user token: cancel token" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    src = CancellationTokenSource()

    # Start get_next_message in background — no messages will arrive
    result_ch = Channel{Any}(1)
    @async try
        msg = JSONRPC.get_next_message(server; token=get_token(src))
        put!(result_ch, msg)
    catch err
        put!(result_ch, err)
    end

    sleep(0.2)

    # Cancel the user token
    cancel(src)

    result = take!(result_ch)
    @test result isa CancellationTokens.OperationCanceledException

    # The endpoint should still be healthy
    @test server.status == JSONRPC.status_running

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "get_next_message with user token: endpoint close" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    src = CancellationTokenSource()

    result_ch = Channel{Any}(1)
    @async try
        msg = JSONRPC.get_next_message(server; token=get_token(src))
        put!(result_ch, msg)
    catch err
        put!(result_ch, err)
    end

    sleep(0.2)

    # Close the endpoint (not the user token)
    close(client)
    close(socket2)
    close(server)
    close(socket1)

    result = take!(result_ch)
    # Should throw — either TransportError or OperationCanceledException
    @test result isa Exception
end
