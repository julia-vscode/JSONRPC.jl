module JSONRPC

import JSON, UUIDs

export JSONRPCEndpoint, send_notification, send_request, send_success_response, send_error_response

include("core.jl")
include("typed.jl")

end
