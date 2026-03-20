# Version v3.0.0
## Breaking changes
- `run(endpoint)` renamed to `start(endpoint)` — now exported as `JSONRPC.start`
- `err_handler` callback removed from `JSONRPCEndpoint` constructor; new signature is `JSONRPCEndpoint(pipe_in, pipe_out, serialization=JSON.StandardSerialization())`
- Transport errors are now stored in the endpoint and thrown on the next user-facing API call as `TransportError`

## New features
- New `TransportError` exception type (exported) distinguishes transport-level failures from JSON-RPC protocol errors (`JSONRPCError`)
- `get_next_message` now accepts an optional `token` keyword argument for caller-controlled cancellation

# Version v2.1.0
## New features
- Add support for custom JSON serialization via a `serialization` argument on `JSONRPCEndpoint`
- Add `server_token` and `client_token` keyword arguments to `send_request` and `send` for cancellation support
- Cancellable `read_transport_layer` for `TCPSocket` and `PipeEndpoint` streams
- Endpoint-level cancellation: closing an endpoint now cancels all outstanding operations
- Improved error handling in request dispatch: proper JSON-RPC error responses are now sent for invalid params, internal errors, and unknown methods

## Other changes
- Add precompile statements for faster load times
- Minimum `CancellationTokens` compat raised to 1.1
- `Sockets` added as a dependency

# Version v2.0.0
## Breaking changes
- All typed request handlers must accept a final `token` argument from the CancellationTokens package
- Static dispatch handlers no longer receive the endpoint as the first argument
- `get_next_message` and iterating over and endpoint returns a new `Request` instance
