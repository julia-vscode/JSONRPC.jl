abstract type AbstractRequestParams{RESPONSE_T} end
abstract type AbstractNotificationParams end

function parse_response end

function send(x::JSONRPCEndpoint, method::AbstractString, params::AbstractRequestParams{RESPONSE_T}) where RESPONSE_T
    res = send_request(x, method, params)

    return parse_response(RESPONSE_T, res)
end

function send(x::JSONRPCEndpoint, method::AbstractString, params::AbstractNotificationParams)
    send_notification(x, method, params)
end

struct MsgDispatcher
    _handlers

    function MsgDispatcher()
        new(Dict())
    end
end

struct Handler{T<:Function, PARAM_T<:Union{Nothing,AbstractRequestParams,AbstractNotificationParams}}
    f::T
end

function add_handler!(dispatcher::MsgDispatcher, name::AbstractString, handler::Function, param_type::Union{Nothing,AbstractRequestParams,AbstractNotificationParams}=nothing)
    dispatcher._handlers[name] = (handler = handler, param_type = param_type)
end

function dispatch_msg(x::JSONRPCEndpoint, dispatcher::MsgDispatcher, msg)
    method_name = msg["method"]
    if haskey(dispatcher._handlers, method_name)
        handler = dispatcher._handlers[method_name]
        try
            params = handler.parser===nothing ? msg["params"] : handler.param_type(msg["params"])
            res = handler.handler(x, params)

            if haskey(msg, "id")
                send_success_response(x, msg, res)
            end
        catch err
            if err isa JSONRPCError
                send_error_response(x, msg, err.code, err.message, err.data)
            else
                rethrow(err)
            end
        end
    else
        error("Unknown method.")
    end
end
