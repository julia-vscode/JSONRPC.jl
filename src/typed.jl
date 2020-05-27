abstract type AbstractMessageType end

struct NotificationType{TPARAM} <: AbstractMessageType
    method::String
end

struct RequestType{TPARAM,TR} <: AbstractMessageType
    method::String
end

function NotificationType(method::AbstractString, ::Type{TPARAM}) where TPARAM
    return NotificationType{TPARAM}(method)
end

function RequestType(method::AbstractString, ::Type{TPARAM}, ::Type{TR}) where {TPARAM,TR}
    return RequestType{TPARAM,TR}(method)
end

get_param_type(::NotificationType{TPARAM}) where {TPARAM} = TPARAM
get_param_type(::RequestType{TPARAM,TR}) where {TPARAM,TR} = TPARAM

function send(x::JSONRPCEndpoint, request::RequestType{TPARAM,TR}, params::TPARAM) where {TPARAM,TR}
    res = send_request(x, request.method, params)

    typed_res = res===nothing ? nothing : TR(res)

    return typed_res::TR
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

function Base.setindex!(dispatcher::MsgDispatcher, func::Function, message_type::AbstractMessageType)
    dispatcher._handlers[message_type.method] = Handler(message_type, func)
end

function dispatch_msg(x::JSONRPCEndpoint, dispatcher::MsgDispatcher, msg)
    method_name = msg["method"]
    handler = get(dispatcher._handlers, method_name, nothing)
    if handler !== nothing        
        try
            param_type = get_param_type(handler.message_type)
            params = param_type === Nothing ? nothing : param_type(msg["params"])

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
