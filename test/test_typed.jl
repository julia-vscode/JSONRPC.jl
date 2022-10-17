function socket_path(id)
    if Sys.iswindows()
        return "\\\\.\\pipe\\jsonrpc-testrun$id"
    elseif Sys.isunix()
        return joinpath(mktempdir(), "jsonrpc-testrun$id")
    else
        error("Unknown operating system.")
    end
end

@testset "Message dispatcher" begin

    global_socket_name1 = socket_path(1)

    request1_type = JSONRPC.RequestType("request1", Foo, String)
    request2_type = JSONRPC.RequestType("request2", Nothing, String)
    notify1_type = JSONRPC.NotificationType("notify1", String)

    global g_var = ""

    server_is_up1 = Base.Condition()

    server_task = @async try
        server = listen(global_socket_name1)
        notify(server_is_up1)
        yield() # don't want to deadlock
        sock = accept(server)
        global conn = JSONRPC.JSONRPCEndpoint(sock, sock)
        msg_dispatcher = JSONRPC.MsgDispatcher()

        msg_dispatcher[request1_type] = (conn, params) -> begin
            @test JSONRPC.is_currently_handling_msg(msg_dispatcher)
            params.fieldA == 1 ? "YES" : "NO"
        end
        msg_dispatcher[request2_type] = (conn, params) -> JSONRPC.JSONRPCError(-32600, "Our message", nothing)
        msg_dispatcher[notify1_type] = (conn, params) -> g_var = params

        run(conn)

        for msg in conn
            JSONRPC.dispatch_msg(conn, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    wait(server_is_up1)

    sock2 = connect(global_socket_name1)
    conn2 = JSONRPCEndpoint(sock2, sock2)

    run(conn2)

    JSONRPC.send(conn2, notify1_type, "TEST")

    res = JSONRPC.send(conn2, request1_type, Foo(fieldA=1, fieldB="FOO"))

    @test res == "YES"
    @test g_var == "TEST"

    @test_throws JSONRPC.JSONRPCError(-32600, "Our message", nothing) JSONRPC.send(conn2, request2_type, nothing)

    close(conn2)
    close(sock2)
    close(conn)

    fetch(server_task)

    # Now we test a faulty server

    global_socket_name2 = socket_path(2)

    server_is_up2 = Base.Condition()

    server_task2 = @async try
        server = listen(global_socket_name2)
        notify(server_is_up2)
        yield() # don't want to deadlock
        sock = accept(server)
        global conn = JSONRPC.JSONRPCEndpoint(sock, sock)
        msg_dispatcher = JSONRPC.MsgDispatcher()

        msg_dispatcher[request2_type] = (conn, params)->34 # The request type requires a `String` return, so this tests whether we get an error.

        run(conn)

        for msg in conn
            @test_throws ErrorException("The handler for the 'request2' request returned a value of type $Int, which is not a valid return type according to the request definition.") JSONRPC.dispatch_msg(conn, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    wait(server_is_up2)

    sock2 = connect(global_socket_name2)
    conn2 = JSONRPCEndpoint(sock2, sock2)

    run(conn2)

    @test_throws JSONRPC.JSONRPCError(-32603, "The handler for the 'request2' request returned a value of type $Int, which is not a valid return type according to the request definition.", nothing) JSONRPC.send(conn2, request2_type, nothing)

    close(conn2)
    close(sock2)
    close(conn)

    fetch(server_task2)


    # Now we test a wrongly requested method

    global_socket_name3 = socket_path(3)

    server_is_up3 = Base.Condition()

    server_task3 = @async try
        server = listen(global_socket_name3)
        notify(server_is_up3)
        yield() # don't want to deadlock
        sock = accept(server)
        global conn = JSONRPC.JSONRPCEndpoint(sock, sock)
        msg_dispatcher = JSONRPC.MsgDispatcher()

        run(conn)

        for msg in conn
            @test_throws ErrorException("Unknown method 'request2'.") JSONRPC.dispatch_msg(conn, msg_dispatcher, msg)
            flush(conn)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    wait(server_is_up3)

    sock3 = connect(global_socket_name3)
    conn3 = JSONRPCEndpoint(sock3, sock3)

    run(conn3)

    @test_throws JSONRPC.JSONRPCError(-32601, "Unknown method 'request2'.", nothing) JSONRPC.send(conn3, request2_type, nothing)

    close(conn3)
    close(sock3)
    close(conn)
    fetch(server_task3)

end
