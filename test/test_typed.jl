@testitem "Dynamic message dispatcher" setup=[TestStructs] begin
    using Sockets
    using .TestStructs: Foo, Foo2

    global_socket_name1 = JSONRPC.generate_pipe_name()

    request1_type = JSONRPC.RequestType("request1", Foo, String)
    request2_type = JSONRPC.RequestType("request2", Nothing, String)
    notify1_type = JSONRPC.NotificationType("notify1", Vector{String})

    global g_var = ""

    server_is_up = Base.Condition()

    server_task = @async try
        server = listen(global_socket_name1)
        notify(server_is_up)
        sock = accept(server)
        global conn = JSONRPC.JSONRPCEndpoint(sock, sock)
        global msg_dispatcher = JSONRPC.MsgDispatcher()

        msg_dispatcher[request1_type] = (conn, params, token) -> begin
            @test JSONRPC.is_currently_handling_msg(msg_dispatcher)
            params.fieldA == 1 ? "YES" : "NO"
        end
        msg_dispatcher[request2_type] = (conn, params, token) -> JSONRPC.JSONRPCError(-32600, "Our message", nothing)
        msg_dispatcher[notify1_type] = (conn, params) -> global g_var = params[1]

        JSONRPC.start(conn)

        for msg in conn
            JSONRPC.dispatch_msg(conn, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
        Base.flush(stderr)
    end

    wait(server_is_up)

    sock2 = connect(global_socket_name1)
    conn2 = JSONRPCEndpoint(sock2, sock2)

    JSONRPC.start(conn2)

    JSONRPC.send(conn2, notify1_type, ["TEST"])

    res = JSONRPC.send(conn2, request1_type, Foo(fieldA=1, fieldB="FOO"))

    @test res == "YES"
    @test g_var == "TEST"

    @test_throws JSONRPC.JSONRPCError(-32600, "Our message", nothing) JSONRPC.send(conn2, request2_type, nothing)

    close(conn2)
    close(sock2)
    close(conn)

    fetch(server_task)

    # Now we test a faulty server

    global_socket_name2 = JSONRPC.generate_pipe_name()

    server_is_up = Base.Condition()

    server_task2 = @async try
        server = listen(global_socket_name2)
        notify(server_is_up)
        sock = accept(server)
        global conn = JSONRPC.JSONRPCEndpoint(sock, sock)
        global msg_dispatcher = JSONRPC.MsgDispatcher()

        msg_dispatcher[request2_type] = (conn, params, token)->34 # The request type requires a `String` return, so this tests whether we get an error.

        JSONRPC.start(conn)

        for msg in conn
            @test_throws ErrorException("The handler for the 'request2' request returned a value of type $Int, which is not a valid return type according to the request definition.") JSONRPC.dispatch_msg(conn, msg_dispatcher, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
        Base.flush(stderr)
    end

    wait(server_is_up)

    sock2 = connect(global_socket_name2)
    conn2 = JSONRPCEndpoint(sock2, sock2)

    JSONRPC.start(conn2)

    @test_throws JSONRPC.JSONRPCError(-32603, "The handler for the 'request2' request returned a value of type $Int, which is not a valid return type according to the request definition.", nothing) JSONRPC.send(conn2, request2_type, nothing)

    close(conn2)
    close(sock2)
    close(conn)

    fetch(server_task)

end

@testitem "check response type" begin
    using JSONRPC: typed_res
    
    @test typed_res(nothing, Nothing) isa Nothing
    @test typed_res([1,"2",3], Vector{Any}) isa Vector{Any}
    @test typed_res([1,2,3], Vector{Int}) isa Vector{Int}
    @test typed_res([1,2,3], Vector{Float64}) isa Vector{Float64}
    @test typed_res(['f','o','o'], String) isa String
    @test typed_res("foo", String) isa String
end

@testitem "Static message dispatcher" setup=[TestStructs] begin
    using Sockets
    using .TestStructs: Foo, Foo2
    
    global_socket_name1 = JSONRPC.generate_pipe_name()

    request1_type = JSONRPC.RequestType("request1", Foo, String)
    request2_type = JSONRPC.RequestType("request2", Nothing, String)
    notify1_type = JSONRPC.NotificationType("notify1", Vector{String})

    global g_var = ""

    server_is_up = Base.Condition()

    JSONRPC.@message_dispatcher my_dispatcher begin
        request1_type => (params, token) -> begin
            params.fieldA == 1 ? "YES" : "NO"
        end
        request2_type => (params, token) -> JSONRPC.JSONRPCError(-32600, "Our message", nothing)
        notify1_type => (params) -> global g_var = params[1]
    end

    server_task = @async try
        server = listen(global_socket_name1)
        notify(server_is_up)
        sock = accept(server)
        global conn = JSONRPC.JSONRPCEndpoint(sock, sock)
        global msg_dispatcher = JSONRPC.MsgDispatcher()

        JSONRPC.start(conn)

        for msg in conn
            my_dispatcher(conn, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    wait(server_is_up)

    sock2 = connect(global_socket_name1)
    conn2 = JSONRPCEndpoint(sock2, sock2)

    JSONRPC.start(conn2)

    JSONRPC.send(conn2, notify1_type, ["TEST"])

    res = JSONRPC.send(conn2, request1_type, Foo(fieldA=1, fieldB="FOO"))

    @test res == "YES"
    @test g_var == "TEST"

    @test_throws JSONRPC.JSONRPCError(-32600, "Our message", nothing) JSONRPC.send(conn2, request2_type, nothing)

    close(conn2)
    close(sock2)
    close(conn)

    fetch(server_task)

    # Now we test a faulty server

    global_socket_name2 = JSONRPC.generate_pipe_name()

    server_is_up = Base.Condition()

    JSONRPC.@message_dispatcher my_dispatcher2 begin
        request2_type => (params, token) -> 34 # The request type requires a `String` return, so this tests whether we get an error.
    end

    server_task2 = @async try
        server = listen(global_socket_name2)
        notify(server_is_up)
        sock = accept(server)
        global conn = JSONRPC.JSONRPCEndpoint(sock, sock)
        global msg_dispatcher = JSONRPC.MsgDispatcher()

        JSONRPC.start(conn)

        for msg in conn
            @test_throws ErrorException("The handler for the 'request2' request returned a value of type $Int, which is not a valid return type according to the request definition.") my_dispatcher2(conn, msg)
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
    end

    wait(server_is_up)

    sock2 = connect(global_socket_name2)
    conn2 = JSONRPCEndpoint(sock2, sock2)

    JSONRPC.start(conn2)

    @test_throws JSONRPC.JSONRPCError(-32603, "The handler for the 'request2' request returned a value of type $Int, which is not a valid return type according to the request definition.", nothing) JSONRPC.send(conn2, request2_type, nothing)

    close(conn2)
    close(sock2)
    close(conn)

    fetch(server_task)

end

@testitem "dispatch_msg error responses" setup=[TestStructs] begin
    using Sockets
    using .TestStructs: Foo

    request1_type = JSONRPC.RequestType("request1", Foo, String)
    request_throwing_type = JSONRPC.RequestType("throwing_request", Nothing, String)
    request_jsonrpc_err_type = JSONRPC.RequestType("jsonrpc_err_request", Nothing, String)

    global_socket_name = JSONRPC.generate_pipe_name()
    server_is_up = Base.Condition()

    server_task = @async try
        server = listen(global_socket_name)
        notify(server_is_up)
        sock = accept(server)
        conn = JSONRPC.JSONRPCEndpoint(sock, sock)
        msg_dispatcher = JSONRPC.MsgDispatcher()

        msg_dispatcher[request1_type] = (conn, params, token) -> params.fieldA == 1 ? "YES" : "NO"
        msg_dispatcher[request_throwing_type] = (conn, params, token) -> error("handler exploded")
        msg_dispatcher[request_jsonrpc_err_type] = (conn, params, token) -> throw(JSONRPC.JSONRPCError(-32000, "custom server error", "detail"))

        JSONRPC.start(conn)

        for msg in conn
            try
                JSONRPC.dispatch_msg(conn, msg_dispatcher, msg)
            catch
                # Errors are rethrown after sending error response; swallow them here
            end
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
        Base.flush(stderr)
    end

    wait(server_is_up)

    sock2 = connect(global_socket_name)
    conn2 = JSONRPC.JSONRPCEndpoint(sock2, sock2)
    JSONRPC.start(conn2)

    # Test 1: Unknown method → METHOD_NOT_FOUND (-32601)
    unknown_type = JSONRPC.RequestType("nonexistent", Nothing, String)
    try
        JSONRPC.send(conn2, unknown_type, nothing)
        @test false  # should not reach here
    catch err
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32601
    end

    # Test 2: Invalid params → INVALID_PARAMS (-32602)
    # Send raw request with wrong params to trigger param parse failure
    try
        JSONRPC.send_request(conn2, "request1", nothing)
        @test false
    catch err
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32602
    end

    # Test 3: Handler throws → INTERNAL_ERROR (-32603)
    try
        JSONRPC.send(conn2, request_throwing_type, nothing)
        @test false
    catch err
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32603
    end

    # Test 4: Handler throws JSONRPCError → custom error code (-32000)
    try
        JSONRPC.send(conn2, request_jsonrpc_err_type, nothing)
        @test false
    catch err
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32000
        @test err.msg == "custom server error"
        @test err.data == "detail"
    end

    close(conn2)
    close(sock2)

    fetch(server_task)
end

@testitem "Static dispatcher error responses" setup=[TestStructs] begin
    using Sockets
    using .TestStructs: Foo

    request1_type = JSONRPC.RequestType("request1", Foo, String)
    request_throwing_type = JSONRPC.RequestType("throwing_request", Nothing, String)
    jsonrpc_err_type = JSONRPC.RequestType("jsonrpc_err_request", Nothing, String)

    JSONRPC.@message_dispatcher my_err_dispatcher begin
        request1_type => (params, token) -> params.fieldA == 1 ? "YES" : "NO"
        request_throwing_type => (params, token) -> error("handler exploded")
        jsonrpc_err_type => (params, token) -> throw(JSONRPC.JSONRPCError(-32000, "custom server error", "detail"))
    end

    global_socket_name = JSONRPC.generate_pipe_name()
    server_is_up = Base.Condition()

    server_task = @async try
        server = listen(global_socket_name)
        notify(server_is_up)
        sock = accept(server)
        conn = JSONRPC.JSONRPCEndpoint(sock, sock)

        JSONRPC.start(conn)

        for msg in conn
            try
                my_err_dispatcher(conn, msg)
            catch
                # Errors are rethrown after sending error response; swallow them here
            end
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
        Base.flush(stderr)
    end

    wait(server_is_up)

    sock2 = connect(global_socket_name)
    conn2 = JSONRPC.JSONRPCEndpoint(sock2, sock2)
    JSONRPC.start(conn2)

    # Test 1: Unknown method → METHOD_NOT_FOUND (-32601)
    unknown_type = JSONRPC.RequestType("nonexistent", Nothing, String)
    try
        JSONRPC.send(conn2, unknown_type, nothing)
        @test false
    catch err
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32601
    end

    # Test 2: Invalid params → INVALID_PARAMS (-32602)
    try
        JSONRPC.send_request(conn2, "request1", nothing)
        @test false
    catch err
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32602
    end

    # Test 3: Handler throws → INTERNAL_ERROR (-32603)
    try
        JSONRPC.send(conn2, request_throwing_type, nothing)
        @test false
    catch err
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32603
    end

    # Test 4: Handler throws JSONRPCError → custom error code (-32000)
    try
        JSONRPC.send(conn2, jsonrpc_err_type, nothing)
        @test false
    catch err
        @test err isa JSONRPC.JSONRPCError
        @test err.code == -32000
        @test err.msg == "custom server error"
        @test err.data == "detail"
    end

    close(conn2)
    close(sock2)

    fetch(server_task)
end

@testitem "dispatch_msg: send_error_response failure propagates" setup=[TestStructs] begin
    using Sockets
    using .TestStructs: Foo

    request1_type = JSONRPC.RequestType("request1", Foo, String)
    request_throwing_type = JSONRPC.RequestType("throwing_request", Nothing, String)

    global_socket_name = JSONRPC.generate_pipe_name()
    server_is_up = Base.Condition()
    dispatch_error = Channel{Any}(1)

    server_task = @async try
        server = listen(global_socket_name)
        notify(server_is_up)
        sock = accept(server)
        conn = JSONRPC.JSONRPCEndpoint(sock, sock)
        msg_dispatcher = JSONRPC.MsgDispatcher()

        msg_dispatcher[request1_type] = (conn, params, token) -> params.fieldA == 1 ? "YES" : "NO"
        msg_dispatcher[request_throwing_type] = (conn, params, token) -> error("handler exploded")

        JSONRPC.start(conn)

        for msg in conn
            try
                JSONRPC.dispatch_msg(conn, msg_dispatcher, msg)
            catch err
                put!(dispatch_error, err)
            end
        end
    catch err
        Base.display_error(stderr, err, catch_backtrace())
        Base.flush(stderr)
    end

    wait(server_is_up)

    sock2 = connect(global_socket_name)
    conn2 = JSONRPC.JSONRPCEndpoint(sock2, sock2)
    JSONRPC.start(conn2)

    # First send a valid request to ensure things are connected
    res = JSONRPC.send(conn2, request1_type, Foo(fieldA=1, fieldB="FOO"))
    @test res == "YES"

    # Close the client connection so the server can't send responses
    close(conn2)
    close(sock2)

    # Wait for the server loop to exit (EOF), then check the dispatch_error channel
    fetch(server_task)

    # The server should have encountered a transport-level error when trying to send
    # the error response on the now-dead connection. Since we removed try-catch wrappers,
    # error is propagated.
    @test !isready(dispatch_error)
end
