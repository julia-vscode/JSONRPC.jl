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
get_return_type(::RequestType{TPARAM,TR}) where {TPARAM,TR} = TR

function send(x::JSONRPCEndpoint, request::RequestType{TPARAM,TR}, params::TPARAM) where {TPARAM,TR}
    res = send_request(x, request.method, params)
    return typed_res(res, TR)::TR
end

# `send_request` must have returned nothing in this case, we pass this on
# so that we get an error in the typecast at the end of `send`
# if that is not the case.
typed_res(res, TR::Type{Nothing}) = res
typed_res(res, TR::Type{<:T}) where {T <: AbstractArray{Any}} = T(res)
typed_res(res, TR::Type{<:AbstractArray{T}}) where T = T.(res)
typed_res(res, TR::Type) = TR(res)

function send(x::JSONRPCEndpoint, notification::NotificationType{TPARAM}, params::TPARAM) where TPARAM
    send_notification(x, notification.method, params)
end

struct Handler
    message_type::AbstractMessageType
    func::Function
    supports_cancel_token::Bool
end

mutable struct MsgDispatcher
    _handlers::Dict{String,Handler}
    _cancel_token_sources::Dict{String,CancellationTokens.CancellationTokenSource}

    function MsgDispatcher()
        new(Dict{String,Handler}(), Dict{String,CancellationTokens.CancellationTokenSource}())
    end
end

function Base.run(endpoint::JSONRPCEndpoint, dispatcher::MsgDispatcher, token=nothing; async=true)
    @async try
        for msg in endpoint
            cts = CancellationToken.CancellationTokenSource()
            token = get_token(cts)
            @async try
                dispatch_msg(endpoint, dispatcher, msg, token)
            catch err
                # TODO Do something here
            end
        end
    catch err
        if error_handler === nothing
            Base.display_error(err, catch_backtrace())
        else
            error_handler(err, Base.catch_backtrace())
        end
    end
end

function Base.setindex!(dispatcher::MsgDispatcher, func::Function, message_type::AbstractMessageType)
    dispatcher._handlers[message_type.method] = Handler(message_type, func, false, false)
end

function dispatch_msg(x::JSONRPCEndpoint, dispatcher::MsgDispatcher, msg, token=nothing)
    method_name = msg["method"]
    handler = get(dispatcher._handlers, method_name, nothing)
    if handler !== nothing
        param_type = get_param_type(handler.message_type)
        params = param_type === Nothing ? nothing : param_type <: NamedTuple ? convert(param_type, (;(Symbol(i[1]) => i[2] for i in msg["params"])...)) : param_type(msg["params"])

        res = handler.supports_cancel_token ? handler.func(x, params, token) : handler.func(x, params)

        if handler.message_type isa RequestType
            if res isa JSONRPCError
                send_error_response(x, msg, res.code, res.msg, res.data)
            elseif res isa get_return_type(handler.message_type)
                send_success_response(x, msg, res)
            else
                error_msg = "The handler for the '$method_name' request returned a value of type $(typeof(res)), which is not a valid return type according to the request definition."
                send_error_response(x, msg, -32603, error_msg, nothing)
                error(error_msg)
            end
        end
    else
        error("Unknown method $method_name.")
    end
end
