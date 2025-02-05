@testitem "Custom JSON serialization" setup=[NamedPipes] begin
    using JSON
    using JSON: StructuralContext, begin_object, show_pair, end_object, show_json, Serializations.StandardSerialization

    struct OurSerialization <: JSON.Serializations.CommonSerialization end

    struct OurStruct
        a::String
        b::String
    end

    function JSON.show_json(io::StructuralContext, s::OurSerialization, f::OurStruct)
        show_json(io, StandardSerialization(), "$(f.a):$(f.b)")
    end

    x = OurStruct("Hello", "World")

    socket1, socket2 = NamedPipes.get_named_pipe()

    task_done = Channel(1)

    messages_back = Channel(Inf)

    @async try
        ep2 = JSONRPCEndpoint(socket1, socket1, nothing, OurSerialization())
        
        run(ep2)

        msg = JSONRPC.get_next_message(ep2)
        put!(messages_back, msg)

        msg2 = JSONRPC.get_next_message(ep2)
        put!(messages_back, msg2)
        send_success_response(ep2, msg2, [x])

        msg3 = JSONRPC.get_next_message(ep2)
        put!(messages_back, msg3)
        send_error_response(ep2, msg3, 5, "Error", [x])

        close(ep2)
    finally
        put!(task_done, true)
    catch err
        Base.display_error(err, catch_backtrace())
    end   

    ep1 = JSONRPCEndpoint(socket2, socket2, nothing, OurSerialization())

    run(ep1)

    send_notification(ep1, "foo", [x])

    response1 = send_request(ep1, "bar", [x])
    try
        send_request(ep1, "bar", [x])
    catch err_msg
        if err_msg isa JSONRPC.JSONRPCError
            @test err_msg.data == Any["Hello:World"]
        else
            rethrow(err_msg)
        end
    end

    close(ep1)
    
    wait(task_done)

    msg1 = take!(messages_back)
    msg2 = take!(messages_back)
    msg3 = take!(messages_back)

    @test msg1.params == ["Hello:World"]
    @test msg2.params == ["Hello:World"]
    @test msg3.params == ["Hello:World"]
end
