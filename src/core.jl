"""
    JSONRPCError

An object representing a JSON-RPC Error.

Fields:
 * code::Int
 * msg::AbstractString
 * data::Any

See [Section 5.1 of the JSON RPC 2.0 specification](https://www.jsonrpc.org/specification#error_object)
for more information.
"""
struct JSONRPCError <: Exception
    code::Int
    msg::AbstractString
    data::Any
end

"""
    SERVER_ERROR_END

The end of the range of server-reserved errors.

These are JSON-RPC server errors that are free for the taking
for JSON-RPC server implementations. Applications making use of
this library should NOT define new errors in this range.
"""
const SERVER_ERROR_END = -32000

"""
    SERVER_ERROR_START

The start of the range of server-reserved errors.

These are JSON-RPC server errors that are free for the taking
for JSON-RPC server implementations. Applications making use of
this library should NOT define new errors in this range.
"""
const SERVER_ERROR_START = -32099

"""
    PARSE_ERROR

Invalid JSON was received by the server.
An error occurred on the server while parsing the JSON text.
"""
const PARSE_ERROR = -32700

"""
    INVALID_REQUEST

The JSON sent is not a valid Request object.
"""
const INVALID_REQUEST = -32600

"""
    METHOD_NOT_FOUND

The method does not exist / is not available.
"""
const METHOD_NOT_FOUND = -32601

"""
    INVALID_PARAMS

Invalid method parameter(s).
"""
const INVALID_PARAMS = -32602

"""
    INTERNAL_ERROR

Internal JSON-RPC error.
"""
const INTERNAL_ERROR = -32603

"""
    REQUEST_CANCELLED

The request was cancelled by the client (via `\$/cancelRequest`).

This error code follows the LSP specification convention.
"""
const REQUEST_CANCELLED = -32800

"""
   RPCErrorStrings

A `Base.IdDict` containing the mapping of JSON-RPC error codes to a short, descriptive string.

Use this to hook into `showerror(io::IO, ::JSONRPCError)` for display purposes. A default fallback to `"Unknown"` exists.
"""
const RPCErrorStrings = Base.IdDict(
    PARSE_ERROR => "ParseError",
    INVALID_REQUEST => "InvalidRequest",
    METHOD_NOT_FOUND => "MethodNotFound",
    INVALID_PARAMS => "InvalidParams",
    INTERNAL_ERROR => "InternalError",
    REQUEST_CANCELLED => "RequestCancelled",
    [ i => "ServerError" for i in SERVER_ERROR_START:SERVER_ERROR_END]...,
    -32002 => "ServerNotInitialized",
    -32001 => "UnknownErrorCode",
)

function Base.showerror(io::IO, ex::JSONRPCError)
    error_code_as_string = get(RPCErrorStrings, ex.code, "Unknown")

    print(io, error_code_as_string)
    print(io, ": ")
    print(io, ex.msg)
    if ex.data !== nothing
        print(io, " (")
        print(io, ex.data)
        print(io, ")")
    end
end

"""
    TransportError

An exception indicating a transport-level failure (broken pipe, parse error, etc.).
Stored in the endpoint and thrown on the next user-facing API call.

Fields:
 * msg::String
 * inner::Union{Nothing,Exception}
"""
struct TransportError <: Exception
    msg::String
    inner::Union{Nothing,Exception}
end

function Base.showerror(io::IO, ex::TransportError)
    print(io, "TransportError: ")
    print(io, ex.msg)
    if ex.inner !== nothing
        print(io, "\n  caused by: ")
        showerror(io, ex.inner)
    end
end

"""
    EndpointStatus

Enum representing the lifecycle state of a `JSONRPCEndpoint`.

 - `status_idle`    — constructed but `start()` has not been called yet
 - `status_running` — read/write tasks are active; the endpoint is usable
 - `status_errored` — a transport-level error occurred; the endpoint is unusable (call `close()` to clean up)
 - `status_closed`  — fully shut down
"""
@enum EndpointStatus status_idle status_running status_errored status_closed

struct Request
    method::String
    params::Union{Nothing,Dict{String,Any},Vector{Any}}
    id::Union{Nothing,String,Int}
    token::Union{CancellationTokens.CancellationToken,Nothing}
end

"""
    FramingMode

Abstract type for message framing modes used by `JSONRPCEndpoint`.

Two built-in modes are provided:
- `ContentLengthFraming()` — LSP-style `Content-Length` header framing (default)
- `NewlineDelimitedFraming()` — newline-delimited JSON, one message per line (used by MCP stdio transport)
"""
abstract type FramingMode end

"""
    ContentLengthFraming()

LSP-style framing where each message is preceded by a `Content-Length` header.
This is the default framing mode and is backward-compatible with all existing usage.
"""
struct ContentLengthFraming <: FramingMode end

"""
    NewlineDelimitedFraming()

Newline-delimited JSON framing where each message is a single line of JSON terminated by `\\n`.
Used by the MCP (Model Context Protocol) stdio transport.
"""
struct NewlineDelimitedFraming <: FramingMode end

mutable struct JSONRPCEndpoint{IOIn<:IO,IOOut<:IO,S<:JSON.Serialization,F<:FramingMode}
    pipe_in::IOIn
    pipe_out::IOOut

    out_msg_queue::Channel{Any}
    in_msg_queue::Channel{Request}

    outstanding_requests::Dict{String,Channel{Any}} # These are requests sent where we are waiting for a response
    cancellation_sources::Dict{Union{String,Int},CancellationTokens.CancellationTokenSource} # These are the cancellation sources for requests that are not finished processing
    no_longer_needed_cancellation_sources::Channel{Union{String,Int}}

    endpoint_cancellation_source::CancellationTokens.CancellationTokenSource

    err::Union{Nothing,TransportError}

    status::EndpointStatus

    read_task::Union{Nothing,Task}
    write_task::Union{Nothing,Task}

    serialization::S

    framing::F
end

JSONRPCEndpoint(pipe_in, pipe_out, serialization::JSON.Serialization=JSON.StandardSerialization(); framing::FramingMode=ContentLengthFraming()) =
    JSONRPCEndpoint(
        pipe_in,
        pipe_out,
        Channel{Any}(Inf),
        Channel{Request}(Inf),
        Dict{String,Channel{Any}}(),
        Dict{Union{String,Int},CancellationTokens.CancellationTokenSource}(),
        Channel{Union{String,Int}}(Inf),
        CancellationTokens.CancellationTokenSource(),
        nothing,
        status_idle,
        nothing,
        nothing,
        serialization,
        framing)

write_transport_layer(stream, response, ::ContentLengthFraming) = write_transport_layer(stream, response)

function write_transport_layer(stream, response)
    response_utf8 = transcode(UInt8, response)
    n = length(response_utf8)
    write(stream, "Content-Length: $n\r\n\r\n")
    write(stream, response_utf8)
    flush(stream)
end

function write_transport_layer(stream, response, ::NewlineDelimitedFraming)
    response_utf8 = transcode(UInt8, response)
    write(stream, response_utf8)
    write(stream, UInt8('\n'))
    flush(stream)
end

read_transport_layer(stream, token::CancellationTokens.CancellationToken, ::ContentLengthFraming) = read_transport_layer(stream, token)

function read_transport_layer(stream, token::CancellationTokens.CancellationToken)
    try
        header_dict = Dict{String,String}()
        line = chomp(readline(stream))
        # Check whether the socket was closed
        if line == ""
            return nothing
        end
        while length(line) > 0
            h_parts = split(line, ":", limit=2)
            if length(h_parts) == 2
                header_dict[chomp(h_parts[1])] = chomp(h_parts[2])
            end
            line = chomp(readline(stream))
        end
        if !haskey(header_dict, "Content-Length")
            return nothing
        end
        message_length = parse(Int, header_dict["Content-Length"])
        message_str = String(read(stream, message_length))
        if ncodeunits(message_str) != message_length
            # Truncated read — the remote process likely crashed mid-write
            return nothing
        end
        return message_str
    catch err
        if err isa Base.IOError
            return nothing
        end

        rethrow(err)
    end
end

read_transport_layer(stream::Union{Sockets.TCPSocket,Sockets.PipeEndpoint}, token::CancellationTokens.CancellationToken, ::ContentLengthFraming) = read_transport_layer(stream, token)

function read_transport_layer(stream::Union{Sockets.TCPSocket,Sockets.PipeEndpoint}, token::CancellationTokens.CancellationToken)
    try
        header_dict = Dict{String,String}()
        line = chomp(readline(stream, token))
        # Check whether the socket was closed
        if line == ""
            return nothing
        end
        while length(line) > 0
            h_parts = split(line, ":", limit=2)
            if length(h_parts) == 2
                header_dict[chomp(h_parts[1])] = chomp(h_parts[2])
            end
            line = chomp(readline(stream, token))
        end
        if !haskey(header_dict, "Content-Length")
            return nothing
        end
        message_length = parse(Int, header_dict["Content-Length"])
        message_str = String(read(stream, message_length, token))
        if ncodeunits(message_str) != message_length
            # Truncated read — the remote process likely crashed mid-write
            return nothing
        end
        return message_str
    catch err
        if err isa Base.IOError
            return nothing
        end

        rethrow(err)
    end
end

function read_transport_layer(stream, token::CancellationTokens.CancellationToken, ::NewlineDelimitedFraming)
    try
        line = readline(stream)
        if isempty(line)
            return nothing
        end
        return line
    catch err
        if err isa Base.IOError
            return nothing
        end
        rethrow(err)
    end
end

function read_transport_layer(stream::Union{Sockets.TCPSocket,Sockets.PipeEndpoint}, token::CancellationTokens.CancellationToken, ::NewlineDelimitedFraming)
    try
        line = readline(stream, token)
        if isempty(line)
            return nothing
        end
        return line
    catch err
        if err isa Base.IOError
            return nothing
        end
        rethrow(err)
    end
end

Base.isopen(x::JSONRPCEndpoint) = x.status == status_running && isopen(x.pipe_in) && isopen(x.pipe_out)

function start(x::JSONRPCEndpoint)
    x.status == status_idle || error("Endpoint is not idle.")

    x.status = status_running

    endpoint_token = CancellationTokens.get_token(x.endpoint_cancellation_source)

    x.write_task = @async try
        try
            for msg in x.out_msg_queue
                write_transport_layer(x.pipe_out, msg, x.framing)
            end
        finally
            close(x.out_msg_queue)
        end
    catch err
        if err isa Base.IOError
            if !CancellationTokens.is_cancellation_requested(endpoint_token)
                x.err === nothing && (x.err = TransportError("Write task IOError", err))
            end
        else
            x.err === nothing && (x.err = TransportError("Write task failed", err))
        end
    end

    x.read_task = @async try
        try
            while true
                # First we delete any cancellation sources that are no longer needed. We do it this way to avoid a lock
                while isready(x.no_longer_needed_cancellation_sources)
                    no_longer_needed_cs_id = take!(x.no_longer_needed_cancellation_sources)
                    delete!(x.cancellation_sources, no_longer_needed_cs_id)
                end

                # Now handle new messages
                message = read_transport_layer(x.pipe_in, endpoint_token, x.framing)

                if message === nothing
                    # EOF while there are outstanding requests and the endpoint wasn't
                    # deliberately closed means the remote side dropped unexpectedly.
                    if !isempty(x.outstanding_requests) &&
                       !CancellationTokens.is_cancellation_requested(endpoint_token)
                        x.err === nothing && (x.err = TransportError("Read error: connection lost", nothing))
                    end
                    break
                end

                message_dict = try
                    JSON.parse(message)
                catch parse_err
                    # Corrupted/truncated message (e.g. remote process crashed mid-write).
                    # Treat as broken pipe and exit the read loop.
                    x.err === nothing && (x.err = TransportError("Failed to parse message", parse_err))
                    break
                end

                if !_is_valid(message_dict)
                    x.err === nothing && (x.err = TransportError("Received malformed message", nothing))
                    break
                end

                if _is_request(message_dict)
                    method_name = message_dict["method"]
                    params = get(message_dict, "params", nothing)
                    id = get(message_dict, "id", nothing)
                    cancel_source = id === nothing ? nothing : CancellationTokens.CancellationTokenSource()
                    cancel_token = cancel_source === nothing ? nothing : CancellationTokens.get_token(cancel_source)

                    if method_name == "\$/cancelRequest"
                        # this is a custom protocol extension and as such we should be very
                        # careful to not crash here; a malformed notification may not have
                        # params or params["id"]
                        params === nothing && continue
                        id_of_cancelled_request = get(params, "id", nothing)
                        id_of_cancelled_request === nothing && continue

                        cs = get(x.cancellation_sources, id_of_cancelled_request, nothing) # We might have sent the response already
                        if cs !== nothing
                            CancellationTokens.cancel(cs)
                        end
                    else
                        if id !== nothing
                            x.cancellation_sources[id] = cancel_source
                        end

                        request = Request(method_name, params, id, cancel_token)

                        try
                            put!(x.in_msg_queue, request)
                        catch err
                            if err isa InvalidStateException
                                break
                            else
                                rethrow(err)
                            end
                        end
                    end
                elseif _is_response(message_dict)
                    id_of_request = message_dict["id"]

                    channel_for_response = get(x.outstanding_requests, id_of_request, nothing)
                    if channel_for_response !== nothing
                        try
                            put!(channel_for_response, message_dict)
                        catch err
                            if err isa InvalidStateException
                                # Channel was closed by a client-cancelled send_request (tombstone).
                                # Silently discard the late response and clean up the entry.
                                delete!(x.outstanding_requests, id_of_request)
                            else
                                rethrow(err)
                            end
                        end
                    else
                        x.err === nothing && (x.err = TransportError("Received response for unknown request id=$id_of_request", nothing))
                        break
                    end
                end
            end
        finally
            # Always clean up the endpoint, whether the loop exited normally or via exception.
            # This ensures get_next_message() will throw instead of hanging forever.
            CancellationTokens.cancel(x.endpoint_cancellation_source)

            for cs in values(x.cancellation_sources)
                CancellationTokens.cancel(cs)
            end

            isopen(x.in_msg_queue) && close(x.in_msg_queue)

            for i in values(x.outstanding_requests)
                isopen(i) && close(i)
            end

            x.status = x.err !== nothing ? status_errored : status_closed
        end
    catch err
        if err isa Base.IOError
            if !CancellationTokens.is_cancellation_requested(endpoint_token)
                x.err === nothing && (x.err = TransportError("Read task IOError", err))
                x.status = status_errored
            end
        elseif err isa CancellationTokens.OperationCanceledException
            # Expected during endpoint close — not an error
        elseif !isopen(x.pipe_in)
            # Pipe is closed — the exception is from reading a broken pipe.
            # Different Julia versions/platforms throw different exception types
            # for this scenario, so we check the pipe state instead.
            if !CancellationTokens.is_cancellation_requested(endpoint_token)
                x.err === nothing && (x.err = TransportError("Read task IOError", err))
                x.status = status_errored
            end
        else
            x.err === nothing && (x.err = TransportError("Read task failed", err))
            x.status = status_errored
        end
    end
end

_is_response(message_dict::AbstractDict) = haskey(message_dict, "id") && (haskey(message_dict, "result") || haskey(message_dict, "error"))
_is_request(message_dict::AbstractDict) = haskey(message_dict, "method")
_is_valid(message_dict::AbstractDict) = get(message_dict, "jsonrpc", "") == "2.0" && xor(_is_response(message_dict), _is_request(message_dict))

function send_notification(x::JSONRPCEndpoint, method::AbstractString, @nospecialize(params))
    check_dead_endpoint!(x)

    message = Dict("jsonrpc" => "2.0", "method" => method, "params" => params)

    message_json = sprint(JSON.show_json, x.serialization, message)

    put!(x.out_msg_queue, message_json)

    return nothing
end

function send_request(x::JSONRPCEndpoint, method::AbstractString, @nospecialize(params); server_token::Union{Nothing,CancellationTokens.CancellationToken}=nothing, client_token::Union{Nothing,CancellationTokens.CancellationToken}=nothing)
    check_dead_endpoint!(x)

    id = string(UUIDs.uuid4())
    message = Dict("jsonrpc" => "2.0", "method" => method, "params" => params, "id" => id)

    response_channel = Channel{Any}(1)
    x.outstanding_requests[id] = response_channel

    message_json = sprint(JSON.show_json, x.serialization, message)

    put!(x.out_msg_queue, message_json)

    # Set up server token monitoring: when cancelled, send $/cancelRequest but keep waiting
    server_cancel_registration = nothing
    if server_token !== nothing
        server_cancel_registration = CancellationTokens.register(server_token) do
            try
                send_notification(x, "\$/cancelRequest", Dict("id" => id))
            catch
                # Endpoint may already be closed
            end
        end
    end

    # Build the token used for local waiting: combines endpoint token + optional client token
    endpoint_token = CancellationTokens.get_token(x.endpoint_cancellation_source)
    wait_token = if client_token !== nothing
        combined_source = CancellationTokens.CancellationTokenSource(client_token, endpoint_token)
        CancellationTokens.get_token(combined_source)
    else
        endpoint_token
    end

    cancelled_by_client = false
    try
        response = try
            take!(response_channel, wait_token)
        catch err
            if err isa CancellationTokens.OperationCanceledException
                if client_token !== nothing && CancellationTokens.is_cancellation_requested(client_token)
                    cancelled_by_client = true
                    throw(CancellationTokens.OperationCanceledException(client_token))
                else
                    x.err !== nothing && throw(x.err)
                    throw(TransportError("Endpoint closed before response received", nothing))
                end
            elseif err isa InvalidStateException
                x.err !== nothing && throw(x.err)
                throw(TransportError("Endpoint closed before response received", nothing))
            else
                rethrow(err)
            end
        end

        if haskey(response, "result")
            return response["result"]
        elseif haskey(response, "error")
            error_code = response["error"]["code"]
            error_msg = response["error"]["message"]
            error_data = get(response["error"], "data", nothing)
            if error_code == REQUEST_CANCELLED && server_token !== nothing
                throw(CancellationTokens.OperationCanceledException(server_token))
            end
            throw(JSONRPCError(error_code, error_msg, error_data))
        else
            # this should never happen since we guard against it in the reader task
            throw(TransportError("Received malformed response", nothing))
        end
    finally
        if cancelled_by_client
            # Leave a tombstone: close the channel but keep the entry so the read task
            # can silently discard the server's late response instead of erroring.
            isopen(response_channel) && close(response_channel)
        else
            delete!(x.outstanding_requests, id)
        end
        if server_cancel_registration !== nothing
            close(server_cancel_registration)
        end
    end
end

function get_next_message(endpoint::JSONRPCEndpoint; token::Union{Nothing,CancellationTokens.CancellationToken}=nothing)
    check_dead_endpoint!(endpoint)

    endpoint_token = CancellationTokens.get_token(endpoint.endpoint_cancellation_source)
    wait_token = if token !== nothing
        combined_source = CancellationTokens.CancellationTokenSource(token, endpoint_token)
        CancellationTokens.get_token(combined_source)
    else
        endpoint_token
    end
    try
        msg = take!(endpoint.in_msg_queue, wait_token)
        return msg
    catch err
        if err isa CancellationTokens.OperationCanceledException || err isa InvalidStateException
            if token !== nothing && CancellationTokens.is_cancellation_requested(token) && !CancellationTokens.is_cancellation_requested(endpoint_token)
                throw(CancellationTokens.OperationCanceledException(token))
            end
            endpoint.err !== nothing && throw(endpoint.err)
            throw(TransportError("Endpoint closed", nothing))
        else
            rethrow(err)
        end
    end
end

function Base.iterate(endpoint::JSONRPCEndpoint, state = nothing)
    check_dead_endpoint!(endpoint)

    endpoint_token = CancellationTokens.get_token(endpoint.endpoint_cancellation_source)
    try
        return take!(endpoint.in_msg_queue, endpoint_token), nothing
    catch err
        if err isa InvalidStateException || err isa CancellationTokens.OperationCanceledException
            endpoint.err !== nothing && throw(endpoint.err)
            return nothing
        else
            rethrow(err)
        end
    end
end

function send_success_response(endpoint, original_request::Request, @nospecialize(result))
    check_dead_endpoint!(endpoint)

    original_request.id === nothing && error("Cannot send a response to a notification.")

    put!(endpoint.no_longer_needed_cancellation_sources, original_request.id)

    response = Dict("jsonrpc" => "2.0", "id" => original_request.id, "result" => result)

    response_json = sprint(JSON.show_json, endpoint.serialization, response)

    put!(endpoint.out_msg_queue, response_json)
end

function send_error_response(endpoint, original_request::Request, @nospecialize(code), @nospecialize(message), @nospecialize(data))
    check_dead_endpoint!(endpoint)

    original_request.id === nothing && error("Cannot send a response to a notification.")

    put!(endpoint.no_longer_needed_cancellation_sources, original_request.id)

    response = Dict("jsonrpc" => "2.0", "id" => original_request.id, "error" => Dict("code" => code, "message" => message, "data" => data))

    response_json = sprint(JSON.show_json, endpoint.serialization, response)

    put!(endpoint.out_msg_queue, response_json)
end

function Base.close(endpoint::JSONRPCEndpoint)
    endpoint.status == status_closed && return

    # Signal the read task to stop — this unblocks any cancellation-aware reads
    # (TCPSocket/PipeEndpoint). For non-cancellation-aware streams, the caller
    # must close the underlying IO to unblock the read task.
    CancellationTokens.cancel(endpoint.endpoint_cancellation_source)

    # Wait for the read task to finish — its finally block is the single authority
    # for cleaning up shared state (cancellation_sources, in_msg_queue, outstanding_requests, status)
    if endpoint.read_task !== nothing
        try
            wait(endpoint.read_task)
        catch
        end
    end

    # Now clean up the write side (not touched by the read task's finally block)
    isopen(endpoint.out_msg_queue) && close(endpoint.out_msg_queue)

    if endpoint.write_task !== nothing
        try
            fetch(endpoint.write_task)
        catch
        end
    end

    # Status may be status_errored or status_closed from the read task's finally block.
    # Always set status_closed here — close() is the final cleanup.
    endpoint.status = status_closed
end

function Base.flush(endpoint::JSONRPCEndpoint)
    check_dead_endpoint!(endpoint)

    token = CancellationTokens.get_token(endpoint.endpoint_cancellation_source)

    while isready(endpoint.out_msg_queue)
        istaskdone(endpoint.write_task) && break
        CancellationTokens.is_cancellation_requested(token) && break
        yield()
    end
end

function check_dead_endpoint!(endpoint)
    status = endpoint.status
    status === status_running && return
    endpoint.err !== nothing && throw(endpoint.err)
    error("Endpoint is not running, the current state is $(status).")
end
