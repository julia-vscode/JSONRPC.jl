@testitem "Custom JSON serialization" setup=[NamedPipes] begin
    using JSON

    struct OurStruct
        a::String
        b::String
    end

    @static if isdefined(JSON, :JSONStyle)
        struct OurSerialization <: JSON.JSONStyle end
        JSON.StructUtils.lower(::OurSerialization, f::OurStruct) = "$(f.a):$(f.b)"
    else
        struct OurSerialization <: JSON.Serializations.CommonSerialization end
        function JSON.show_json(io::JSON.StructuralContext, ::OurSerialization, f::OurStruct)
            JSON.show_json(io, JSON.StandardSerialization(), "$(f.a):$(f.b)")
        end
    end

    x = OurStruct("Hello", "World")

    socket1, socket2 = NamedPipes.get_named_pipe()

    task_done = Channel(1)

    messages_back = Channel(Inf)

    ep2 = JSONRPCEndpoint(socket1, socket1, OurSerialization())
    @async try
        JSONRPC.start(ep2)

        msg = JSONRPC.get_next_message(ep2)
        put!(messages_back, msg)

        msg2 = JSONRPC.get_next_message(ep2)
        put!(messages_back, msg2)
        send_success_response(ep2, msg2, [x])

        msg3 = JSONRPC.get_next_message(ep2)
        put!(messages_back, msg3)
        send_error_response(ep2, msg3, 5, "Error", [x])
    finally
        put!(task_done, true)
    catch err
        Base.display_error(err, catch_backtrace())
    end

    ep1 = JSONRPCEndpoint(socket2, socket2, OurSerialization())

    JSONRPC.start(ep1)

    send_notification(ep1, "foo", [x])

    response1 = send_request(ep1, "bar", [x])
    try
        send_request(ep1, "err", [x])
    catch err_msg
        if err_msg isa JSONRPC.JSONRPCError
            @test err_msg.data == Any["Hello:World"]
        else
            rethrow(err_msg)
        end
    end

    close(ep1)
    close(ep2)

    wait(task_done)

    msg1 = take!(messages_back)
    msg2 = take!(messages_back)
    msg3 = take!(messages_back)

    @test msg1.params == ["Hello:World"]
    @test msg2.params == ["Hello:World"]
    @test msg3.params == ["Hello:World"]
end
