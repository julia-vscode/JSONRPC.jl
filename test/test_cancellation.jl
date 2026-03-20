@testitem "outstanding_requests cleanup" setup=[NamedPipes] begin
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
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    # Send several requests
    for _ in 1:5
        res = JSONRPC.send(client, request_type, nothing)
        @test res == "hello"
    end

    # All outstanding_requests entries should have been cleaned up
    @test isempty(client.outstanding_requests)

    close(client)
    close(socket2)
    close(server)
    close(socket1)
    fetch(server_task)
end

@testitem "cancel sources on endpoint close" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("slow", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    token_was_cancelled = Channel{Bool}(1)
    handler_started = Channel{Bool}(1)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        put!(handler_started, true)
        # Wait for cancellation (endpoint close should trigger it)
        try
            wait(token)
        catch
        end
        put!(token_was_cancelled, is_cancellation_requested(token))
        "done"
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            @async JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    # Send a request but don't wait for a response — close the server instead
    client_task = @async try
        result = JSONRPC.send(client, request_type, nothing)
        result
    catch err
        err
    end

    wait(handler_started)

    # Close the server endpoint — should cancel all in-progress request tokens
    close(server)
    close(socket1)

    result = take!(token_was_cancelled)
    @test result == true

    close(client)
    close(socket2)
end

@testitem "send_request throws on endpoint close" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("hang", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    handler_started = Channel{Bool}(1)
    handler_blocked = Channel{Nothing}(1)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        put!(handler_started, true)
        # Never respond — just block
        wait(handler_blocked)
        "never"
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            @async JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    # Start a request in the background
    result_channel = Channel{Any}(1)
    client_task = @async try
        res = JSONRPC.send(client, request_type, nothing)
        put!(result_channel, res)
    catch err
        put!(result_channel, err)
    end

    wait(handler_started)

    # Close the client endpoint while the request is pending
    close(client)
    close(socket2)

    result = take!(result_channel)
    @test result isa JSONRPC.TransportError
    @test occursin("Endpoint closed", result.msg)

    close(server)
    close(socket1)
end

@testitem "dual-token: server_token sends cancelRequest" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("cancellable", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    cancel_received = Channel{Bool}(1)
    handler_started = Channel{Bool}(1)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        put!(handler_started, true)
        # Wait for the cancellation token (from $/cancelRequest)
        wait(token)
        put!(cancel_received, true)
        "cancelled"
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            @async JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    # Create a server token and cancel it after a short delay
    server_src = CancellationTokenSource()
    server_token = get_token(server_src)

    client_task = @async try
        JSONRPC.send(client, request_type, nothing; server_token=server_token)
    catch err
        err
    end

    wait(handler_started)

    # Cancel the server token — should auto-send $/cancelRequest
    cancel(server_src)

    # The server handler should receive the cancellation
    got_cancel = take!(cancel_received)
    @test got_cancel == true

    # Wait for client to get the response
    result = fetch(client_task)
    @test result == "cancelled"

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "dual-token: client_token gives up locally" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("slow", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    server_got_cancel_request = Channel{Bool}(1)
    handler_started = Channel{Bool}(1)
    handler_may_proceed = Channel{Bool}(1)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        put!(handler_started, true)
        # Wait until test signals, then check if $/cancelRequest arrived
        wait(handler_may_proceed)
        put!(server_got_cancel_request, is_cancellation_requested(token))
        "done"
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task_err = Channel{Any}(1)
    server_task = @async try
        for msg in server
            @async JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch err
        put!(server_task_err, err)
    end

    # Create a client token and cancel it after a short delay
    client_src = CancellationTokenSource()
    client_token = get_token(client_src)

    client_task_err = Channel{Any}(1)
    client_task = @async try
        JSONRPC.send(client, request_type, nothing; client_token=client_token)
    catch err
        put!(client_task_err, err)
    end

    wait(handler_started)

    # Cancel the client token — should give up locally without sending $/cancelRequest
    cancel(client_src)

    # Let the handler proceed to check cancellation status
    put!(handler_may_proceed, true)

    result = fetch(client_task)
    @test result isa CancellationTokens.OperationCanceledException

    # The server should NOT have received a $/cancelRequest
    server_cancel_status = take!(server_got_cancel_request)
    @test server_cancel_status == false

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "dual-token: both tokens" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("both", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    server_token_cancelled = Channel{Bool}(1)
    handler_started = Channel{Bool}(1)
    handler_may_respond = Channel{Bool}(1)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        put!(handler_started, true)
        # Wait for the server cancellation
        wait(token)
        put!(server_token_cancelled, true)
        wait(handler_may_respond)  # Delay response so client_token can fire first
        "done"
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            @async JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    server_src = CancellationTokenSource()
    client_src = CancellationTokenSource()

    client_task = @async try
        JSONRPC.send(client, request_type, nothing;
            server_token=get_token(server_src),
            client_token=get_token(client_src))
    catch err
        err
    end

    wait(handler_started)

    # Cancel server token first — sends $/cancelRequest, client keeps waiting
    cancel(server_src)

    # Wait for server to confirm it received cancellation
    @test take!(server_token_cancelled) == true

    # Now cancel client token — client should give up immediately
    cancel(client_src)

    # Let the handler respond
    put!(handler_may_respond, true)

    result = fetch(client_task)
    @test result isa CancellationTokens.OperationCanceledException

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "client cancellation: endpoint recovers" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("echo", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    call_count = Ref(0)
    handler_started = Channel{Bool}(1)
    handler_may_respond = Channel{Bool}(1)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        call_count[] += 1
        if call_count[] == 1
            put!(handler_started, true)
            # Block until test signals — client cancellation fires before response
            wait(handler_may_respond)
        end
        "hello"
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            @async JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    # First request: cancel via client_token
    client_src = CancellationTokenSource()
    client_task = @async try
        JSONRPC.send(client, request_type, nothing; client_token=get_token(client_src))
    catch err
        err
    end

    wait(handler_started)
    cancel(client_src)

    result = fetch(client_task)
    @test result isa CancellationTokens.OperationCanceledException

    # Let the server handler finish — its late response should be absorbed by the tombstone
    put!(handler_may_respond, true)

    # Endpoint should still be healthy — the tombstone absorbed the late response
    @test client.status == JSONRPC.status_running

    # Second request should work fine
    res = JSONRPC.send(client, request_type, nothing)
    @test res == "hello"

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "server -32800 response becomes OperationCanceledException" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("cancellable", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        JSONRPC.JSONRPCError(JSONRPC.REQUEST_CANCELLED, "Request cancelled", nothing)
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch
    end

    server_src = CancellationTokenSource()
    server_token = get_token(server_src)

    threw = Ref(false)
    try
        JSONRPC.send(client, request_type, nothing; server_token=server_token)
    catch err
        threw[] = true
        @test err isa CancellationTokens.OperationCanceledException
    end
    @test threw[]

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "server -32800 without server_token stays JSONRPCError" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("cancellable", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        JSONRPC.JSONRPCError(JSONRPC.REQUEST_CANCELLED, "Request cancelled", nothing)
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch
    end

    # No server_token provided — should stay as JSONRPCError
    threw = Ref(false)
    try
        JSONRPC.send(client, request_type, nothing)
    catch err
        threw[] = true
        @test err isa JSONRPC.JSONRPCError
        @test err.code == JSONRPC.REQUEST_CANCELLED
    end
    @test threw[]

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "dispatch_msg: handler OperationCanceledException sends -32800" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    request_type = JSONRPC.RequestType("cancel_me", Nothing, String)

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        src = CancellationTokenSource()
        cancel(src)
        throw(CancellationTokens.OperationCanceledException(get_token(src)))
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            @async JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch
    end

    threw = Ref(false)
    try
        JSONRPC.send(client, request_type, nothing)
    catch err
        threw[] = true
        @test err isa JSONRPC.JSONRPCError
        @test err.code == JSONRPC.REQUEST_CANCELLED
        @test occursin("cancelled", lowercase(err.msg))
    end
    @test threw[]

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end
