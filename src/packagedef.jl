export JSONRPCEndpoint, TransportError, EndpointStatus, start, send_notification, send_request, send_success_response, send_error_response
export FramingMode, ContentLengthFraming, NewlineDelimitedFraming

include("pipenames.jl")
include("core.jl")
include("typed.jl")
include("interface_def.jl")

function _precompile_()
    ccall(:jl_generating_output, Cint, ()) == 1 || return nothing

    E = JSONRPCEndpoint{Base.PipeEndpoint, Base.PipeEndpoint, JSON.Serializations.StandardSerialization, ContentLengthFraming}
    precompile(start, (E,))
    precompile(send_notification, (E, String, Any))
    precompile(send_request, (E, String, Any))
    precompile(send_success_response, (E, Request, Any))
    precompile(send_error_response, (E, Request, Any, Any, Any))
    precompile(dispatch_msg, (E, MsgDispatcher, Request))
    precompile(Base.setindex!, (MsgDispatcher, Function, Any))
    precompile(get_next_message, (E,))
end

_precompile_()
