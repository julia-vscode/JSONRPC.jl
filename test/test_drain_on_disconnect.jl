# A peer that reports something and then goes away leaves messages the read task has already
# parsed sitting in the (unbounded) inbound queue. Tearing the endpoint down used to make
# those unreachable, so the last thing a peer said before exiting was lost and the caller saw
# only the disconnect. See `JSONRPC._take_buffered_message`.

@testmodule DisconnectFixture begin
    using JSONRPC

    export queue_then_disconnect

    """
    Give `server` `n` queued-but-unread messages and then take its peer away, which is the
    state a consumer that lags its read task reaches on its own.
    """
    function queue_then_disconnect(server, client, client_socket, n)
        for i in 1:n
            JSONRPC.send_notification(client, "test/ping", Dict("i" => i))
        end

        # Wait for the read task to have parsed all of them, but read none: that is the
        # backlog the disconnect below must not discard.
        for _ in 1:600
            Base.n_avail(server.in_msg_queue) == n && break
            sleep(0.01)
        end

        close(client)
        close(client_socket)

        for _ in 1:600
            server.status === JSONRPC.status_running || break
            sleep(0.01)
        end
        return server
    end
end

@testitem "Messages queued before a disconnect are still delivered" setup=[NamedPipes, DisconnectFixture] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    n = 5
    DisconnectFixture.queue_then_disconnect(server, client, socket2, n)
    @test server.status !== JSONRPC.status_running
    @test Base.n_avail(server.in_msg_queue) == n

    received = Int[]
    for _ in 1:n
        msg = JSONRPC.get_next_message(server)
        @test msg.method == "test/ping"
        push!(received, msg.params["i"])
    end
    @test received == collect(1:n)

    # Only once there is nothing left does it report itself closed.
    @test_throws Exception JSONRPC.get_next_message(server)

    close(server)
    close(socket1)
end

@testitem "Iterating an endpoint drains what the disconnect left behind" setup=[NamedPipes, DisconnectFixture] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    n = 3
    DisconnectFixture.queue_then_disconnect(server, client, socket2, n)
    @test server.status !== JSONRPC.status_running

    received = Int[]
    for msg in server
        push!(received, msg.params["i"])
    end
    @test received == collect(1:n)

    close(server)
    close(socket1)
end

@testitem "A disconnect with nothing queued still reports the endpoint closed" setup=[NamedPipes, DisconnectFixture] begin
    socket1, socket2 = NamedPipes.get_named_pipe()

    server = JSONRPC.JSONRPCEndpoint(socket1, socket1)
    client = JSONRPC.JSONRPCEndpoint(socket2, socket2)

    JSONRPC.start(server)
    JSONRPC.start(client)

    DisconnectFixture.queue_then_disconnect(server, client, socket2, 0)
    @test server.status !== JSONRPC.status_running

    @test_throws Exception JSONRPC.get_next_message(server)
    @test iterate(server) === nothing

    close(server)
    close(socket1)
end
