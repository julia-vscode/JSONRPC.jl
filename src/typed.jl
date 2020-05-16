abstract type AbstractMessageType end

struct NotificationType{TPARAM} <: AbstractMessageType
    method::String
    dict2param::Function
end

struct RequestType{TPARAM,TR} <: AbstractMessageType
    method::String
    dict2param::Function
    dict2response::Function
end

get_param_type(::NotificationType{TPARAM}) where {TPARAM} = TPARAM
get_param_type(::RequestType{TPARAM,TR}) where {TPARAM,TR} = TPARAM

function send(x::JSONRPCEndpoint, request::RequestType{TPARAM,TR}, params::TPARAM) where {TPARAM, TR}
    res = send_request(x, request.method, params)

    return request.dict2response(res)::TR
end

function send(x::JSONRPCEndpoint, notification::NotificationType{TPARAM}, params::TPARAM) where TPARAM
    send_notification(x, notification.method, params)
end

struct Handler
    message_type::AbstractMessageType
    func::Function
end

struct MsgDispatcher
    _handlers::Dict{String,Handler}

    function MsgDispatcher()
        new(Dict{String,Handler}())
    end
end

function add_handler!(dispatcher::MsgDispatcher, message_type::AbstractMessageType, func::Function)
    dispatcher._handlers[message_type.method] = Handler(message_type, func)
end

function dispatch_msg(x::JSONRPCEndpoint, dispatcher::MsgDispatcher, msg)
    method_name = msg["method"]
    handler = get(dispatcher._handlers, method_name, nothing)
    if handler!==nothing
        try
            params = handler.data2param(msg["params"])

            res = handler.func(x, params)

            if handler.message_type isa RequestType
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
