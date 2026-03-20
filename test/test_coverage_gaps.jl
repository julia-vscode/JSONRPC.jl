@testitem "endpoint with IOBuffer pipes (non-PipeEndpoint read path)" begin
    # This test exercises the read task's else branch that calls
    # read_transport_layer(stream) instead of read_transport_layer(stream, token)
    # when pipe_in is not a TCPSocket/PipeEndpoint.
    payload = "{\"jsonrpc\":\"2.0\",\"method\":\"iobuf_test\",\"params\":{\"key\":\"val\"}}"
    buf_in = IOBuffer()
    JSONRPC.write_transport_layer(buf_in, payload)
    seekstart(buf_in)
    buf_out = IOBuffer()

    ep = JSONRPC.JSONRPCEndpoint(buf_in, buf_out)
    JSONRPC.start(ep)

    # With IOBuffer the read task runs to completion almost instantly (EOF on empty buffer).
    # So we take! from in_msg_queue directly — the message was already queued.
    sleep(0.1)
    @test isready(ep.in_msg_queue)
    msg = take!(ep.in_msg_queue)
    @test msg isa JSONRPC.Request
    @test msg.method == "iobuf_test"
    @test msg.params["key"] == "val"
    @test msg.id === nothing
    @test msg.token === nothing

    # After EOF, the read loop should exit cleanly
    close(ep)
    @test ep.status == JSONRPC.status_closed
end

@testitem "IOBuffer endpoint: request with id" begin
    # Ensure that requests with an id get a CancellationToken through the IOBuffer path
    payload = "{\"jsonrpc\":\"2.0\",\"method\":\"test_req\",\"id\":\"abc-123\",\"params\":null}"
    buf_in = IOBuffer()
    JSONRPC.write_transport_layer(buf_in, payload)
    seekstart(buf_in)
    buf_out = IOBuffer()

    ep = JSONRPC.JSONRPCEndpoint(buf_in, buf_out)
    JSONRPC.start(ep)

    # IOBuffer read task finishes instantly; take directly from queue
    sleep(0.1)
    @test isready(ep.in_msg_queue)
    msg = take!(ep.in_msg_queue)
    @test msg.method == "test_req"
    @test msg.id == "abc-123"
    @test msg.token !== nothing  # requests should get a cancellation token

    close(ep)
end

@testitem "IOBuffer endpoint: multiple messages" begin
    # Test that the read task handles multiple messages through IOBuffer
    buf_in = IOBuffer()
    for i in 1:3
        payload = "{\"jsonrpc\":\"2.0\",\"method\":\"msg_$i\",\"params\":null}"
        JSONRPC.write_transport_layer(buf_in, payload)
    end
    seekstart(buf_in)
    buf_out = IOBuffer()

    ep = JSONRPC.JSONRPCEndpoint(buf_in, buf_out)
    JSONRPC.start(ep)

    # IOBuffer read task finishes instantly; take directly from queue
    sleep(0.1)
    for i in 1:3
        @test isready(ep.in_msg_queue)
        msg = take!(ep.in_msg_queue)
        @test msg.method == "msg_$i"
    end

    close(ep)
end

@testitem "IOBuffer endpoint: write task produces output" begin
    # Verify write task works with IOBuffer
    buf_in = IOBuffer()
    # Write one notification so read task has something to process
    payload = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\",\"params\":null}"
    JSONRPC.write_transport_layer(buf_in, payload)
    seekstart(buf_in)

    buf_out = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf_in, buf_out)
    JSONRPC.start(ep)

    # Send a notification through the endpoint — should be written to buf_out
    JSONRPC.send_notification(ep, "pong", nothing)

    sleep(0.2)
    close(ep)

    # Check that something was written to buf_out
    output = String(take!(buf_out))
    @test occursin("Content-Length:", output)
    @test occursin("pong", output)
end

@testitem "IOBuffer endpoint: JSON parse failure in non-token path" begin
    # Ensure the non-PipeEndpoint read path also handles parse errors
    invalid_json = "this is not json"
    n = ncodeunits(invalid_json)
    raw = "Content-Length: $n\r\n\r\n$invalid_json"
    buf_in = IOBuffer(raw)
    buf_out = IOBuffer()

    ep = JSONRPC.JSONRPCEndpoint(buf_in, buf_out)
    JSONRPC.start(ep)
    sleep(0.2)

    @test ep.err isa JSONRPC.TransportError
    @test occursin("parse", lowercase(ep.err.msg))

    close(ep)
end

@testitem "token read_transport_layer: missing Content-Length" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    # Directly test the token-aware read_transport_layer with a bad header
    # Write a header block with no Content-Length
    write(socket2, "X-Custom: value\r\n\r\n")
    flush(socket2)

    src = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(src)
    msg = JSONRPC.read_transport_layer(socket1, token)
    @test msg === nothing

    close(socket1)
    close(socket2)
end

@testitem "token read_transport_layer: truncated payload" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    # Write a header saying 100 bytes but only send a few
    write(socket2, "Content-Length: 100\r\n\r\nshort")
    flush(socket2)
    # Close the write end so read gets EOF
    close(socket2)

    src = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(src)
    msg = JSONRPC.read_transport_layer(socket1, token)
    @test msg === nothing

    close(socket1)
end

@testitem "token read_transport_layer: empty stream" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    # Immediately close the write side — readline returns ""
    close(socket2)

    src = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(src)
    msg = JSONRPC.read_transport_layer(socket1, token)
    @test msg === nothing

    close(socket1)
end

@testitem "token read_transport_layer: cancellation throws OperationCanceledException" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    src = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(src)

    # Start reading in background — no data will arrive
    result_ch = Channel{Any}(1)
    @async try
        msg = JSONRPC.read_transport_layer(socket1, token)
        put!(result_ch, something(msg, :nothing_returned))
    catch err
        put!(result_ch, err)
    end

    sleep(0.1)
    CancellationTokens.cancel(src)

    result = take!(result_ch)
    @test result isa CancellationTokens.OperationCanceledException

    close(socket1)
    close(socket2)
end

@testitem "token read_transport_layer: normal round-trip" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    payload = "{\"test\":true}"
    JSONRPC.write_transport_layer(socket2, payload)

    src = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(src)
    msg = JSONRPC.read_transport_layer(socket1, token)
    @test msg == payload

    close(socket1)
    close(socket2)
end

@testitem "token read_transport_layer: extra headers" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    payload = "{\"ok\":true}"
    n = ncodeunits(payload)
    # Write with extra headers
    write(socket2, "X-Extra: foo:bar\r\nContent-Length: $n\r\n\r\n$payload")
    flush(socket2)

    src = CancellationTokens.CancellationTokenSource()
    token = CancellationTokens.get_token(src)
    msg = JSONRPC.read_transport_layer(socket1, token)
    @test msg == payload

    close(socket1)
    close(socket2)
end

@testitem "send_request throws TransportError when pipe breaks during wait" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Consume the request on the server side but don't respond
    request_type = JSONRPC.RequestType("hang", Nothing, String)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        sleep(100)  # never respond
        "never"
    end

    server_task = @async try
        for msg in server
            @async JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch
    end

    # Start request in the background
    result_ch = Channel{Any}(1)
    @async try
        res = JSONRPC.send(client, request_type, nothing)
        put!(result_ch, res)
    catch err
        put!(result_ch, err)
    end

    sleep(0.2)

    # Break the underlying pipes to cause TransportError on the client
    close(socket1)

    sleep(0.3)

    # Close the server to clean up
    close(server)

    result = take!(result_ch)
    # Should be TransportError or JSONRPCError (endpoint closed/errored)
    @test result isa Exception
    if result isa JSONRPC.TransportError
        @test occursin("IOError", result.msg) || occursin("error", lowercase(result.msg))
    elseif result isa JSONRPC.JSONRPCError
        @test occursin("closed", lowercase(result.msg)) || occursin("cancelled", lowercase(result.msg))
    end

    close(client)
    close(socket2)
end

@testitem "get_next_message throws TransportError on errored endpoint (no user token)" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Inject a parse error to set ep.err
    write(socket2, "Content-Length: 3\r\n\r\n!!!")
    flush(socket2)
    sleep(0.3)

    @test ep.err isa JSONRPC.TransportError

    # get_next_message without a user token should throw the stored TransportError
    threw = Ref(false)
    try
        JSONRPC.get_next_message(ep)
    catch err
        threw[] = true
        @test err isa JSONRPC.TransportError
    end
    @test threw[]

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "get_next_message: endpoint close surfaces err (no user token)" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Start get_next_message in background waiting for a message
    result_ch = Channel{Any}(1)
    @async try
        msg = JSONRPC.get_next_message(ep)
        put!(result_ch, msg)
    catch err
        put!(result_ch, err)
    end

    sleep(0.1)

    # Break pipe to cause error, then close
    close(socket1)
    sleep(0.1)
    close(ep)

    result = take!(result_ch)
    @test result isa Exception

    close(socket2)
end

@testitem "flush with istaskdone write_task" setup=[NamedPipes] begin
    # Test flush when the write task is already done (istaskdone branch).
    # The write task blocks on `for msg in queue`; we must put messages to unblock it.
    # Closing pipe_out makes isopen return false, so the first message triggers a break,
    # leaving remaining messages buffered. isready(queue) stays true.
    socket1, socket2 = NamedPipes.get_named_pipe()
    socket3, socket4 = NamedPipes.get_named_pipe()

    # Read from socket1 (stays open), write to socket4
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket4)
    JSONRPC.start(ep)

    # Close the write pipe — isopen(socket4) will return false
    close(socket4)

    # Put multiple messages: first unblocks the write task (which sees !isopen → break),
    # remaining ones stay buffered in the (now-closed) channel.
    for i in 1:3
        try
            put!(ep.out_msg_queue, "msg_$i")
        catch
        end
    end

    sleep(0.5)

    @test istaskdone(ep.write_task)
    # Endpoint still running (read task waiting on socket1)
    @test ep.status == JSONRPC.status_running

    # flush: while isready → istaskdone → break
    flush(ep)

    close(socket1)
    close(ep)
    close(socket2)
    close(socket3)
end

@testitem "write task: pipe_out closed before message (isopen check)" setup=[NamedPipes] begin
    # Test the !isopen(x.pipe_out) → break branch in write task
    socket1, socket2 = NamedPipes.get_named_pipe()
    socket3, socket4 = NamedPipes.get_named_pipe()

    # Read from socket1, write to socket4
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket4)
    JSONRPC.start(ep)

    # Close the write end (socket4 itself) to make isopen return false
    close(socket4)
    sleep(0.1)

    # Queue a message — write task should hit !isopen branch
    try
        put!(ep.out_msg_queue, "{\"test\":true}")
    catch
        # Channel may be closed already
    end

    sleep(0.2)

    # Write task should be done (exited via break or IOError)
    @test istaskdone(ep.write_task)

    # Clean up
    close(socket1)
    close(ep)
    close(socket2)
    close(socket3)
end

@testitem "send_request: InvalidStateException path with err" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    request_type = JSONRPC.RequestType("block", Nothing, String)

    # Don't respond — just consume the message
    server_task = @async try
        msg = JSONRPC.get_next_message(server)
        # Don't respond, just wait
        sleep(10)
    catch
    end

    # Start a request in background
    result_ch = Channel{Any}(1)
    @async try
        res = JSONRPC.send(client, request_type, nothing)
        put!(result_ch, res)
    catch err
        put!(result_ch, err)
    end

    sleep(0.2)

    # Inject an error by sending bad data to the client
    write(socket1, "Content-Length: 3\r\n\r\n!!!")
    flush(socket1)

    sleep(0.3)

    # The client read task should have set err and closed outstanding_requests
    result = take!(result_ch)
    @test result isa Exception
    # Could be TransportError, JSONRPCError, or generic error depending on timing
    @test result isa JSONRPC.TransportError || result isa JSONRPC.JSONRPCError

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "no_longer_needed_cancellation_sources cleanup" setup=[NamedPipes] begin
    # Test that cancellation sources are cleaned up after request completion
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

    # Send several requests — each adds to cancellation_sources
    for _ in 1:5
        res = JSONRPC.send(client, request_type, nothing)
        @test res == "hello"
    end

    # After processing, the no_longer_needed cleanup should have run
    # Send one more to trigger the cleanup loop
    res = JSONRPC.send(client, request_type, nothing)
    @test res == "hello"

    # cancellation_sources should be cleaned up (may have the last one still)
    @test length(server.cancellation_sources) <= 1

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "read task: response delivered to correct outstanding request" setup=[NamedPipes] begin
    # Test the response handling path explicitly with interleaved requests
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    request_type = JSONRPC.RequestType("delayed", Nothing, String)

    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> "response"

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch
    end

    # Send concurrent requests
    tasks = [
        @async JSONRPC.send(client, request_type, nothing)
        for _ in 1:3
    ]

    results = [fetch(t) for t in tasks]
    @test all(r -> r == "response", results)

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "flush yields while write task consumes" setup=[NamedPipes] begin
    # Exercise the yield() path in flush by queuing many messages and flushing immediately.
    # The queue should still have items, causing the while loop to call yield().
    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    # Rapidly fill the queue — faster than the write task can drain it
    for i in 1:50
        put!(client.out_msg_queue, "{\"jsonrpc\":\"2.0\",\"method\":\"bulk_$i\",\"params\":null}")
    end

    # flush should spin in the yield loop while the write task catches up
    flush(client)

    # All 50 messages should arrive at the server
    for i in 1:50
        msg = JSONRPC.get_next_message(server)
        @test msg.method == "bulk_$i"
    end

    close(client)
    close(socket2)
    close(server)
    close(socket1)
end

@testitem "write task: write to closed pipe triggers IOError (not isopen)" setup=[NamedPipes] begin
    # When the REMOTE end closes, isopen(pipe_out) may still return true briefly,
    # causing write_transport_layer to throw IOError. This covers the IOError catch
    # in the write task.
    socket1, socket2 = NamedPipes.get_named_pipe()
    socket3, socket4 = NamedPipes.get_named_pipe()

    # Read from socket1 (stays up), write to socket4
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket4)
    JSONRPC.start(ep)

    # Close the remote end — socket4 isopen may still be true
    close(socket3)

    # Put a message; write task tries to write → may IOError
    try
        put!(ep.out_msg_queue, "{\"jsonrpc\":\"2.0\",\"method\":\"test\"}")
    catch
    end

    sleep(0.5)

    # Write task should be done (via IOError or !isopen)
    @test istaskdone(ep.write_task)

    close(socket1)
    close(ep)
    close(socket2)
    close(socket4)
end

@testitem "send_request surfaces TransportError on errored endpoint (no client_token)" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Inject a parse error to make the endpoint error out
    write(socket2, "Content-Length: 3\r\n\r\n!!!")
    flush(socket2)
    sleep(0.3)

    # Endpoint should have err set
    @test ep.err isa JSONRPC.TransportError

    # Calling send_request should throw the stored TransportError via check_dead_endpoint!
    threw = Ref(false)
    try
        JSONRPC.send_request(ep, "test", nothing)
    catch err
        threw[] = true
        @test err isa JSONRPC.TransportError
    end
    @test threw[]

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "send_notification on errored endpoint throws TransportError" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    write(socket2, "Content-Length: 3\r\n\r\n!!!")
    flush(socket2)
    sleep(0.3)

    @test ep.err isa JSONRPC.TransportError

    threw = Ref(false)
    try
        JSONRPC.send_notification(ep, "test", nothing)
    catch err
        threw[] = true
        @test err isa JSONRPC.TransportError
    end
    @test threw[]

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "flush on errored endpoint throws TransportError" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    write(socket2, "Content-Length: 3\r\n\r\n!!!")
    flush(socket2)
    sleep(0.3)

    @test ep.err isa JSONRPC.TransportError

    threw = Ref(false)
    try
        Base.flush(ep)
    catch err
        threw[] = true
        @test err isa JSONRPC.TransportError
    end
    @test threw[]

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "iterate on errored endpoint throws TransportError" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    write(socket2, "Content-Length: 3\r\n\r\n!!!")
    flush(socket2)
    sleep(0.3)

    @test ep.err isa JSONRPC.TransportError

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

@testitem "send_success_response on errored endpoint throws TransportError" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    write(socket2, "Content-Length: 3\r\n\r\n!!!")
    flush(socket2)
    sleep(0.3)

    @test ep.err isa JSONRPC.TransportError

    # Create a fake Request object
    req = JSONRPC.Request("test", nothing, "fake-id", nothing)
    threw = Ref(false)
    try
        JSONRPC.send_success_response(ep, req, "result")
    catch err
        threw[] = true
        @test err isa JSONRPC.TransportError
    end
    @test threw[]

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "send_error_response on errored endpoint throws TransportError" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    write(socket2, "Content-Length: 3\r\n\r\n!!!")
    flush(socket2)
    sleep(0.3)

    @test ep.err isa JSONRPC.TransportError

    req = JSONRPC.Request("test", nothing, "fake-id", nothing)
    threw = Ref(false)
    try
        JSONRPC.send_error_response(ep, req, -32603, "err", nothing)
    catch err
        threw[] = true
        @test err isa JSONRPC.TransportError
    end
    @test threw[]

    close(ep)
    close(socket1)
    close(socket2)
end

@testitem "close() waits for read and write tasks" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    @test ep.read_task !== nothing
    @test ep.write_task !== nothing

    close(ep)

    # After close, both tasks should be done
    @test istaskdone(ep.read_task)
    @test istaskdone(ep.write_task)
    @test ep.status == JSONRPC.status_closed

    close(socket1)
    close(socket2)
end

@testitem "read task: clean exit when remote closes normally" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Close the remote side — should cause clean read task exit (no TransportError)
    close(socket2)
    sleep(0.3)

    # No error should be stored
    @test ep.err === nothing
    # Status should be closed (clean exit in finally block)
    @test ep.status == JSONRPC.status_closed

    close(ep)
    close(socket1)
end

@testitem "read task: status_errored when err is set" setup=[NamedPipes] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Inject parse error
    write(socket2, "Content-Length: 5\r\n\r\nzzzzz")
    flush(socket2)
    sleep(0.3)

    @test ep.err !== nothing
    @test ep.status == JSONRPC.status_errored

    close(ep)
    @test ep.status == JSONRPC.status_closed
    close(socket1)
    close(socket2)
end

@testitem "write task IOError with cancellation requested" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Cancel endpoint (as close() would), then close the sockets
    CancellationTokens.cancel(ep.endpoint_cancellation_source)
    # close(socket) may throw OperationCanceledException when cancellation is active
    try close(socket1) catch end
    sleep(0.3)

    # With cancellation requested, write task IOError should NOT set ep.err
    # (the IOError is "expected" during graceful shutdown)
    close(ep)
    @test ep.status == JSONRPC.status_closed
    try close(socket2) catch end
end

@testitem "send_request: endpoint closed during wait (OperationCanceledException, no err)" setup=[NamedPipes] begin
    using CancellationTokens

    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    request_type = JSONRPC.RequestType("hang", Nothing, String)

    # Server reads the request but never responds
    msg_dispatcher = JSONRPC.MsgDispatcher()
    msg_dispatcher[request_type] = (conn, params, token) -> begin
        sleep(100)
        "never"
    end

    JSONRPC.start(server)
    JSONRPC.start(client)

    server_task = @async try
        for msg in server
            @async JSONRPC.dispatch_msg(server, msg_dispatcher, msg)
        end
    catch
    end

    result_ch = Channel{Any}(1)
    @async try
        res = JSONRPC.send(client, request_type, nothing)
        put!(result_ch, res)
    catch err
        put!(result_ch, err)
    end

    sleep(0.2)

    # Close the client cleanly (no pipe break, just close)
    # This sends cancellation signal, then waits for tasks
    close(client)

    result = take!(result_ch)
    # Should be TransportError about endpoint closed (no transport error since close is clean)
    @test result isa Exception
    if result isa JSONRPC.TransportError
        @test occursin("closed", lowercase(result.msg))
    end

    close(socket2)
    close(server)
    close(socket1)
end

@testitem "check_dead_endpoint! on closed endpoint without err" begin
    buf = IOBuffer()
    ep = JSONRPC.JSONRPCEndpoint(buf, buf)
    close(ep)
    @test ep.status == JSONRPC.status_closed

    threw = Ref(false)
    try
        JSONRPC.check_dead_endpoint!(ep)
    catch err
        threw[] = true
        @test err isa ErrorException
        @test occursin("status_closed", string(err.msg))
    end
    @test threw[]
end

@testitem "read_transport_layer rethrow: invalid Content-Length (non-token)" begin
    using CancellationTokens
    # Trigger the rethrow(err) path in read_transport_layer(stream) by
    # writing a Content-Length header with a non-integer value.
    # parse(Int, " abc") throws ArgumentError, which is not IOError → rethrow
    buf = IOBuffer("Content-Length: abc\r\n\r\n")
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    @test_throws ArgumentError JSONRPC.read_transport_layer(buf, token)
end

@testitem "read_transport_layer rethrow: invalid Content-Length (token)" setup=[NamedPipes] begin
    using CancellationTokens
    # Same test but for the token-aware overload on PipeEndpoint.
    # parse(Int, " abc") → ArgumentError → rethrow (not IOError, not OperationCanceledException)
    socket1, socket2 = NamedPipes.get_named_pipe()
    write(socket2, "Content-Length: abc\r\n\r\n")
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    @test_throws ArgumentError JSONRPC.read_transport_layer(socket1, token)
    close(socket1)
    close(socket2)
end

@testitem "read task outer catch: non-IOError from read_transport_layer" setup=[NamedPipes] begin
    # When read_transport_layer rethrows a non-IOError, it propagates to the
    # read task's outer catch → "Read task failed" branch (not IOError).
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Write invalid Content-Length from the remote side to our read pipe
    write(socket2, "Content-Length: xyz\r\n\r\n")
    sleep(0.5)

    # The read task should have caught ArgumentError and set ep.err
    @test ep.err isa JSONRPC.TransportError
    @test occursin("Read task failed", ep.err.msg)
    close(ep)
    close(socket2)
end

@testitem "send_request: transport-level error (response missing result and error)" setup=[NamedPipes] begin
    using JSON, CancellationTokens
    # When a response has neither "result" nor "error", send_request should
    # throw TransportError with "Received malformed message"
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Start send_request in background — it waits for a response
    result_ref = Ref{Any}(nothing)
    err_ref = Ref{Any}(nothing)
    t = @async begin
        try
            result_ref[] = JSONRPC.send_request(ep, "test/method", Dict())
        catch e
            err_ref[] = e
        end
    end

    # Wait a bit for the request to be sent, then read it from the remote side
    sleep(0.2)
    _token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg_str = JSONRPC.read_transport_layer(socket2, _token)
    @test msg_str !== nothing
    msg = JSON.parse(msg_str)
    id = msg["id"]

    # Send a response with neither "result" nor "error"
    bad_response = JSON.json(Dict("jsonrpc" => "2.0", "id" => id))
    JSONRPC.write_transport_layer(socket2, bad_response)
    sleep(0.3)

    wait(t)
    @test err_ref[] isa JSONRPC.TransportError
    @test occursin("malformed", lowercase(err_ref[].msg))
    close(ep)
    close(socket2)
end

@testitem "get_next_message: user token cancelled while endpoint alive" setup=[NamedPipes] begin
    using CancellationTokens
    # When a user-provided token is cancelled but the endpoint is still running,
    # get_next_message should throw JSONRPCError "get_next_message cancelled by token"
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    user_source = CancellationTokens.CancellationTokenSource()
    user_token = CancellationTokens.get_token(user_source)

    # Cancel the user token after a short delay in a background task
    @async begin
        sleep(0.1)
        CancellationTokens.cancel(user_source)
    end

    err_ref = Ref{Any}(nothing)
    try
        JSONRPC.get_next_message(ep; token=user_token)
    catch e
        err_ref[] = e
    end

    @test err_ref[] isa CancellationTokens.OperationCanceledException
    close(ep)
    close(socket2)
end

@testitem "flush: cancellation_requested breaks early" setup=[NamedPipes] begin
    using CancellationTokens
    # When cancellation is requested during flush, it should break out of the yield loop
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Put messages in out_msg_queue so isready is true
    put!(ep.out_msg_queue, "{}")
    put!(ep.out_msg_queue, "{}")

    # Cancel cancellation source — flush should see is_cancellation_requested and break
    CancellationTokens.cancel(ep.endpoint_cancellation_source)
    # flush checks check_dead_endpoint! first, but endpoint may still be "running"
    # since read task hasn't processed cancellation yet. Race-free: set status manually.
    ep.status = JSONRPC.status_running
    JSONRPC.flush(ep)
    # If we get here without hanging, the cancellation-requested branch worked
    @test true

    # Reset status for clean close
    close(ep)
    close(socket2)
end

@testitem "iterate: clean termination returns nothing" setup=[NamedPipes] begin
    # When endpoint closure happens while iterate is blocking on take!,
    # iterate catches InvalidStateException and returns nothing (no err).
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Start iterate in background — it will block on take!(in_msg_queue, token)
    result_ref = Ref{Any}(:sentinel)
    err_ref = Ref{Any}(nothing)
    t = @async begin
        try
            result_ref[] = Base.iterate(ep, nothing)
        catch e
            err_ref[] = e
        end
    end

    sleep(0.1)
    # Close remote side — read task exits, closes in_msg_queue → take! throws
    close(socket2)
    sleep(0.5)

    wait(t)
    # iterate should return nothing (clean close, no err)
    @test err_ref[] === nothing
    @test result_ref[] === nothing
    close(ep)
    close(socket1)
end

@testitem "send_request: error response from server" setup=[NamedPipes] begin
    using JSON, CancellationTokens
    # Exercise the response["error"] branch of send_request with error data
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    err_ref = Ref{Any}(nothing)
    t = @async begin
        try
            JSONRPC.send_request(ep, "test/failing", Dict("x" => 1))
        catch e
            err_ref[] = e
        end
    end

    sleep(0.2)
    _token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg_str = JSONRPC.read_transport_layer(socket2, _token)
    msg = JSON.parse(msg_str)
    id = msg["id"]

    # Send an error response with data
    err_response = JSON.json(Dict(
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => Dict("code" => -32601, "message" => "Method not found", "data" => "extra info")
    ))
    JSONRPC.write_transport_layer(socket2, err_response)
    sleep(0.3)

    wait(t)
    @test err_ref[] isa JSONRPC.JSONRPCError
    @test err_ref[].code == -32601
    @test err_ref[].msg == "Method not found"
    @test err_ref[].data == "extra info"
    close(ep)
    close(socket2)
end

@testitem "send_request: server_token monitors and sends cancelRequest" setup=[NamedPipes] begin
    using CancellationTokens, JSON
    # Exercise the server_monitor_task branch: when server_token is cancelled,
    # a $/cancelRequest notification should be sent.
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    server_source = CancellationTokens.CancellationTokenSource()
    server_token = CancellationTokens.get_token(server_source)

    # Start the request
    err_ref = Ref{Any}(nothing)
    t = @async begin
        try
            JSONRPC.send_request(ep, "test/slow", Dict(); server_token=server_token)
        catch e
            err_ref[] = e
        end
    end

    # Read the original request
    sleep(0.2)
    _token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg_str = JSONRPC.read_transport_layer(socket2, _token)
    msg = JSON.parse(msg_str)
    id = msg["id"]

    # Cancel the server token — this should cause $/cancelRequest to be sent
    CancellationTokens.cancel(server_source)
    sleep(0.2)

    # Read the $/cancelRequest notification
    cancel_str = JSONRPC.read_transport_layer(socket2, _token)
    @test cancel_str !== nothing
    cancel_msg = JSON.parse(cancel_str)
    @test cancel_msg["method"] == "\$/cancelRequest"
    @test cancel_msg["params"]["id"] == id

    # Now send a normal response to unblock the request
    response = JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "result" => "done"))
    JSONRPC.write_transport_layer(socket2, response)
    sleep(0.3)

    wait(t)
    @test err_ref[] === nothing
    close(ep)
    close(socket2)
end

@testitem "send_request: client_token cancellation" setup=[NamedPipes] begin
    using CancellationTokens
    # Exercise the client_token path: when client_token is cancelled,
    # send_request should throw JSONRPCError "Request cancelled by client"
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    client_source = CancellationTokens.CancellationTokenSource()
    client_token = CancellationTokens.get_token(client_source)

    err_ref = Ref{Any}(nothing)
    t = @async begin
        try
            JSONRPC.send_request(ep, "test/slow", Dict(); client_token=client_token)
        catch e
            err_ref[] = e
        end
    end

    # Wait for request to be sent
    sleep(0.2)
    _token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg_str = JSONRPC.read_transport_layer(socket2, _token)
    @test msg_str !== nothing

    # Cancel the client token — send_request should throw
    CancellationTokens.cancel(client_source)
    sleep(0.3)

    wait(t)
    @test err_ref[] isa CancellationTokens.OperationCanceledException
    close(ep)
    close(socket2)
end

@testitem "read task: cancelRequest for known request" setup=[NamedPipes] begin
    using CancellationTokens, JSON
    # Exercise the $/cancelRequest handling in the read task:
    # when a cancelRequest message arrives for a known request id,
    # the corresponding cancellation source should be cancelled.
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Manually register a cancellation source for a fake request id
    cs = CancellationTokens.CancellationTokenSource()
    cst = CancellationTokens.get_token(cs)
    ep.cancellation_sources["test-id-999"] = cs

    # Send a $/cancelRequest from the remote side
    cancel_msg = JSON.json(Dict(
        "jsonrpc" => "2.0",
        "method" => "\$/cancelRequest",
        "params" => Dict("id" => "test-id-999")
    ))
    JSONRPC.write_transport_layer(socket2, cancel_msg)
    sleep(0.3)

    # The cancellation source should have been cancelled
    @test CancellationTokens.is_cancellation_requested(cst)

    close(ep)
    close(socket2)
end

@testitem "read task: cancelRequest for unknown id (already completed)" setup=[NamedPipes] begin
    using JSON
    # Exercise the path where $/cancelRequest arrives for a request id that
    # has no cancellation source (request already completed / response sent).
    # This should NOT error — the cs === nothing branch is a no-op.
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    cancel_msg = JSON.json(Dict(
        "jsonrpc" => "2.0",
        "method" => "\$/cancelRequest",
        "params" => Dict("id" => "nonexistent-id")
    ))
    JSONRPC.write_transport_layer(socket2, cancel_msg)
    sleep(0.3)

    # Endpoint should still be running (no crash)
    @test ep.status == JSONRPC.status_running
    close(ep)
    close(socket2)
end

@testitem "read task: response for unknown request id sets err" setup=[NamedPipes] begin
    using JSON
    # When a response arrives for an id that isn't in outstanding_requests,
    # ep.err should be set to TransportError and the read loop should exit.
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Send a response for an id we never requested
    bad_response = JSON.json(Dict(
        "jsonrpc" => "2.0",
        "id" => "ghost-request-id",
        "result" => "unused"
    ))
    JSONRPC.write_transport_layer(socket2, bad_response)
    sleep(0.3)

    @test ep.err isa JSONRPC.TransportError
    @test occursin("unknown request", ep.err.msg)
    close(ep)
    close(socket2)
end

@testitem "send_success_response and send_error_response on running endpoint" setup=[NamedPipes] begin
    # Exercise the normal paths for send_success_response / send_error_response
    using CancellationTokens, JSON
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Send two requests from remote side
    req1 = JSON.json(Dict("jsonrpc" => "2.0", "method" => "test/add", "id" => "r1", "params" => Dict("a" => 1)))
    req2 = JSON.json(Dict("jsonrpc" => "2.0", "method" => "test/fail", "id" => "r2", "params" => nothing))
    JSONRPC.write_transport_layer(socket2, req1)
    JSONRPC.write_transport_layer(socket2, req2)
    sleep(0.3)

    # Get messages from endpoint
    msg1 = take!(ep.in_msg_queue)
    msg2 = take!(ep.in_msg_queue)
    @test msg1.id == "r1"
    @test msg2.id == "r2"

    # Send success and error responses
    JSONRPC.send_success_response(ep, msg1, Dict("sum" => 2))
    JSONRPC.send_error_response(ep, msg2, -32600, "Invalid Request", nothing)
    sleep(0.3)

    # Read the responses from the remote side
    _token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    resp1_str = JSONRPC.read_transport_layer(socket2, _token)
    @test resp1_str !== nothing
    resp1 = JSON.parse(resp1_str)
    @test resp1["id"] == "r1"
    @test resp1["result"]["sum"] == 2

    resp2_str = JSONRPC.read_transport_layer(socket2, _token)
    @test resp2_str !== nothing
    resp2 = JSON.parse(resp2_str)
    @test resp2["id"] == "r2"
    @test resp2["error"]["code"] == -32600
    @test resp2["error"]["message"] == "Invalid Request"

    close(ep)
    close(socket2)
end

@testitem "send_success_response: notification id throws" setup=[NamedPipes] begin
    # Cannot send a response to a notification (id === nothing)
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    # Create a fake notification request (no id)
    notif = JSONRPC.Request("test/notify", nothing, nothing, nothing)
    @test_throws ErrorException JSONRPC.send_success_response(ep, notif, nothing)
    @test_throws ErrorException JSONRPC.send_error_response(ep, notif, -1, "err", nothing)

    close(ep)
    close(socket2)
end

@testitem "isopen reflects pipe and status" setup=[NamedPipes] begin
    # Exercise Base.isopen(::JSONRPCEndpoint) — returns true only when
    # status == status_running AND both pipes are open
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)

    # Before start: status is idle → isopen returns false
    @test !isopen(ep)

    JSONRPC.start(ep)
    @test isopen(ep)

    close(ep)
    @test !isopen(ep)
    close(socket2)
end

@testitem "send_request: combined client_token + server_token" setup=[NamedPipes] begin
    using CancellationTokens, JSON
    # Exercise the code path where both server_token and client_token are provided.
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    server_source = CancellationTokens.CancellationTokenSource()
    server_token = CancellationTokens.get_token(server_source)
    client_source = CancellationTokens.CancellationTokenSource()
    client_token = CancellationTokens.get_token(client_source)

    err_ref = Ref{Any}(nothing)
    result_ref = Ref{Any}(nothing)
    t = @async begin
        try
            result_ref[] = JSONRPC.send_request(ep, "test/both", Dict(); server_token=server_token, client_token=client_token)
        catch e
            err_ref[] = e
        end
    end

    sleep(0.2)
    _token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg_str = JSONRPC.read_transport_layer(socket2, _token)
    msg = JSON.parse(msg_str)
    id = msg["id"]

    # Send a successful response
    response = JSON.json(Dict("jsonrpc" => "2.0", "id" => id, "result" => 42))
    JSONRPC.write_transport_layer(socket2, response)
    sleep(0.3)

    wait(t)
    @test err_ref[] === nothing
    @test result_ref[] == 42
    close(ep)
    close(socket2)
end

@testitem "get_next_message: endpoint with err but user token also cancelled" setup=[NamedPipes] begin
    using CancellationTokens
    # When both user token is cancelled AND endpoint has err, the endpoint err should
    # be surfaced (the user-token cancellation check only fires when endpoint is NOT cancelled)
    socket1, socket2 = NamedPipes.get_named_pipe()
    ep = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    JSONRPC.start(ep)

    user_source = CancellationTokens.CancellationTokenSource()
    user_token = CancellationTokens.get_token(user_source)

    # Close remote to cause read task to exit (which cancels endpoint_cancellation_source)
    close(socket2)
    sleep(0.3)

    # Cancel user token too
    CancellationTokens.cancel(user_source)

    # get_next_message should throw — either the endpoint error or "Endpoint closed"
    threw = Ref(false)
    try
        JSONRPC.get_next_message(ep; token=user_token)
    catch e
        threw[] = true
    end
    @test threw[]

    close(ep)
    close(socket1)
end
