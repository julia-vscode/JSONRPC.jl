@testitem "A dead write task marks the endpoint errored" begin
    # The write half can die on its own — the read half never learns about it. Before this
    # was fixed the endpoint went on reporting `status_running`, so callers that guard their
    # sends on `isopen` kept writing into a connection that could no longer deliver, and the
    # `TransportError` describing the real failure was never raised.
    pipe_in = Base.BufferStream()
    pipe_out = IOBuffer()
    close(pipe_out)  # every write from now on throws

    endpoint = JSONRPC.JSONRPCEndpoint(pipe_in, pipe_out)
    JSONRPC.start(endpoint)
    @test endpoint.status == JSONRPC.status_running

    JSONRPC.send_notification(endpoint, "somemethod", nothing)
    wait(endpoint.write_task)  # the task catches, so this returns rather than throwing

    @test endpoint.status == JSONRPC.status_errored
    @test !isopen(endpoint)
    @test endpoint.err isa JSONRPC.TransportError

    # And the next send reports *that*, rather than the `InvalidStateException` from the
    # queue the dying write task closed behind it.
    err = try
        JSONRPC.send_notification(endpoint, "somemethod", nothing)
        nothing
    catch ex
        ex
    end
    @test err isa JSONRPC.TransportError

    close(pipe_in)
    close(endpoint)
end

@testitem "outbound_backlog reports undelivered messages" begin
    # The outbound queue is unbounded, so a peer that stops reading never makes a send fail.
    # This is the only signal that anything is wrong.
    endpoint = JSONRPC.JSONRPCEndpoint(Base.BufferStream(), Base.BufferStream())

    backlog = JSONRPC.outbound_backlog(endpoint)
    @test backlog.queued == 0
    @test backlog.blocked_seconds == 0.0

    # Not started, so nothing drains the queue — the same shape a blocked write task leaves.
    put!(endpoint.out_msg_queue, "one")
    put!(endpoint.out_msg_queue, "two")

    backlog = JSONRPC.outbound_backlog(endpoint)
    @test backlog.queued == 2
    @test backlog.blocked_seconds == 0.0
end

@testitem "get_next_message does not leak registrations onto its tokens" begin
    using CancellationTokens

    caller_source = CancellationTokens.CancellationTokenSource()
    caller_token = CancellationTokens.get_token(caller_source)

    endpoint = JSONRPC.JSONRPCEndpoint(Base.BufferStream(), Base.BufferStream())
    JSONRPC.start(endpoint)

    # Reaching into CancellationTokens to count registrations is the only way to observe
    # this; skip rather than fail if the field is ever renamed.
    if isdefined(caller_source, :_callbacks)
        baseline_caller = length(caller_source._callbacks)
        baseline_endpoint = length(endpoint.endpoint_cancellation_source._callbacks)

        for i in 1:50
            put!(endpoint.in_msg_queue, JSONRPC.Request("somemethod", nothing, nothing, nothing))
            msg = JSONRPC.get_next_message(endpoint, token=caller_token)
            @test msg.method == "somemethod"
        end

        # One linked source per message used to leave a callback on each parent behind.
        @test length(caller_source._callbacks) == baseline_caller
        @test length(endpoint.endpoint_cancellation_source._callbacks) == baseline_endpoint
    end

    close(endpoint.pipe_in)
    close(endpoint)
end

@testitem "get_next_message still honours both of its tokens" begin
    using CancellationTokens

    # The hand-rolled linking has to behave exactly like the combined source it replaced.
    for cancel_the_caller in (true, false)
        caller_source = CancellationTokens.CancellationTokenSource()
        caller_token = CancellationTokens.get_token(caller_source)

        endpoint = JSONRPC.JSONRPCEndpoint(Base.BufferStream(), Base.BufferStream())
        JSONRPC.start(endpoint)

        waiter = @async try
            JSONRPC.get_next_message(endpoint, token=caller_token)
            nothing
        catch err
            err
        end

        sleep(0.2)
        if cancel_the_caller
            CancellationTokens.cancel(caller_source)
        else
            CancellationTokens.cancel(endpoint.endpoint_cancellation_source)
        end

        err = fetch(waiter)
        if cancel_the_caller
            @test err isa CancellationTokens.OperationCanceledException
        else
            @test err isa JSONRPC.TransportError
        end

        close(endpoint.pipe_in)
        close(endpoint)
    end
end
