@testset "Message dispatcher" begin

if Sys.iswindows()
    global_socket_name = "\\\\.\\pipe\\jsonrpc-testrun"
elseif Sys.isunix()
    global_socket_name = joinpath(tempdir(), "jsonrpc-testrun")
else
    error("Unknown operating system.")
end

request1_type = JSONRPC.RequestType("request1", Foo, String)
notify1_type = JSONRPC.NotificationType("notify1", String)

global g_var = ""

server_is_up = Base.Condition()

server_task = @async begin
    server = listen(global_socket_name)
    notify(server_is_up)
    sock = accept(server)
    global conn = JSONRPC.JSONRPCEndpoint(sock, sock)
    global msg_dispatcher = JSONRPC.MsgDispatcher()

    msg_dispatcher[request1_type] = (conn, params) -> params.fieldA==1 ? "YES" : "NO"
    msg_dispatcher[notify1_type] = (conn, params) -> g_var = params

    run(conn)

    for msg in conn
        JSONRPC.dispatch_msg(conn, msg_dispatcher, msg)
    end
end

wait(server_is_up)

sock2 = connect(global_socket_name)
conn2 = JSONRPCEndpoint(sock2, sock2)

run(conn2)

JSONRPC.send(conn2, notify1_type, "TEST")

res = JSONRPC.send(conn2, request1_type, Foo(fieldA=1, fieldB="FOO"))

@test res=="YES"
@test g_var=="TEST"

VERSION >= v"1.4" && close(conn2)
close(sock2)
VERSION >= v"1.4" && close(conn)

VERSION >= v"1.4" && fetch(server_task)

end
