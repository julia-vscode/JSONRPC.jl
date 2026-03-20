@testitem "incoming request has cancellation token" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Send a request (has id → should get a cancellation token)
    request_type = JSONRPC.RequestType("echo", Nothing, String)
    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        @test token isa CancellationTokens.CancellationToken
        "ok"
    end

    client_task = @async JSONRPC.send(client, request_type, nothing)

    msg = JSONRPC.get_next_message(server)
    @test msg.token !== nothing
    @test msg.token isa CancellationTokens.CancellationToken

    JSONRPC.dispatch_msg(server, msg_dispatcher, msg)

    result = fetch(client_task)
    @test result == "ok"

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "incoming notification has no cancellation token" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Send a notification (no id → token should be nothing)
    notify_type = JSONRPC.NotificationType("ping", Nothing)
    JSONRPC.send(client, notify_type, nothing)

    msg = JSONRPC.get_next_message(server)
    @test msg.id === nothing
    @test msg.token === nothing

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "cancelRequest cancels in-flight request token" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    request_type = JSONRPC.RequestType("slow_op", Nothing, String)
    token_was_cancelled = Channel{Bool}(1)
    handler_started = Channel{Bool}(1)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        put!(handler_started, true)
        # Wait for cancellation
        try
            wait(token)
        catch
        end
        put!(token_was_cancelled, is_cancellation_requested(token))
        "done"
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

    # Send the request
    client_task = @async try
        JSONRPC.send(client, request_type, nothing)
    catch err
        @error "handler" ex=(err, catch_backtrace())
    end

    wait(handler_started)

    # Send a $/cancelRequest from client to server for the in-flight request.
    # We need to find the request id. It's in server.cancellation_sources.
    @test !isempty(server.cancellation_sources)
    req_id = first(keys(server.cancellation_sources))

    JSONRPC.send_notification(client, "\$/cancelRequest", Dict("id" => req_id))

    # Server handler should see the token cancelled
    was_cancelled = take!(token_was_cancelled)
    @test was_cancelled == true

    # Clean up - wait for the response to come back
    fetch(client_task)

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "cancelRequest for already-completed request is harmless" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    request_type = JSONRPC.RequestType("fast", Nothing, String)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> "instant"

    server_task = @async try
        for msg in server
            JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch
    end

    # Send and receive a request immediately
    result = JSONRPC.send(client, request_type, nothing)
    @test result == "instant"

    # Now send a $/cancelRequest for some made-up id — should be silently ignored
    JSONRPC.send_notification(client, "\$/cancelRequest", Dict("id" => "fake-id"))

    # The server should still be functional
    result2 = JSONRPC.send(client, request_type, nothing)
    @test result2 == "instant"

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "multiple messages in sequence" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Send multiple notifications rapidly
    for i in 1:10
        JSONRPC.send_notification(client, "msg_$i", Dict("index" => i))
    end

    # Read them all back
    for i in 1:10
        msg = JSONRPC.get_next_message(server)
        @test msg.method == "msg_$i"
        @test msg.params["index"] == i
    end

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "endpoint constructor default serialization" begin
    using JSON
    buf = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf, buf)
    @test ep.serialization isa JSON.Serializations.StandardSerialization
    @test ep.status == JSONRPC.status_idle
    @test ep.err === nothing
    @test ep.read_task === nothing
    @test ep.write_task === nothing
end

@testitem "generate_pipe_name returns valid name" begin
    name = JSONRPC.generate_pipe_name()
    @test name isa String
    @test length(name) > 0
    if Sys.iswindows()
        @test startswith(name, "\\\\.\\pipe\\jl-")
    else
        @test startswith(name, "/")
    end

    # Each call returns a unique name
    name2 = JSONRPC.generate_pipe_name()
    @test name != name2
end

@testitem "RPCErrorStrings constant" begin
    @test JSONRPC.RPCErrorStrings[JSONRPC.PARSE_ERROR] == "ParseError"
    @test JSONRPC.RPCErrorStrings[JSONRPC.INVALID_REQUEST] == "InvalidRequest"
    @test JSONRPC.RPCErrorStrings[JSONRPC.METHOD_NOT_FOUND] == "MethodNotFound"
    @test JSONRPC.RPCErrorStrings[JSONRPC.INVALID_PARAMS] == "InvalidParams"
    @test JSONRPC.RPCErrorStrings[JSONRPC.INTERNAL_ERROR] == "InternalError"
    @test JSONRPC.RPCErrorStrings[-32002] == "ServerNotInitialized"
    @test JSONRPC.RPCErrorStrings[-32001] == "UnknownErrorCode"
end
