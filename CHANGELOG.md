# Version v3.0.2
## Bug fixes
- A write task that fails now marks the endpoint `status_errored`, as the read task already did. Previously only `err` was recorded, so a connection whose outbound half had died still reported `isopen(endpoint) == true`, callers that guard their sends on `isopen` kept writing into it, and the `TransportError` describing the failure was never raised — the next send surfaced a bare `InvalidStateException` from the queue the dying write task had closed.
- The write task no longer records a transport error when a clean `close` drops the pipe under an in-flight write. It only special-cased `Base.IOError`, but Julia 1.0 raises `ArgumentError` from `check_open` for a write to a closed stream, so the error landed in the unguarded branch — and because `send_request` reports `endpoint.err` in preference to "Endpoint closed", a clean shutdown surfaced as a bogus transport failure. It now tests `isopen(pipe_out)` rather than the exception type, mirroring what the read task already did for `pipe_in`.
- `get_next_message` no longer leaks a cancellation registration onto each of its tokens per inbound message. It built a linked `CancellationTokenSource` per call, and a linked source's parent registrations are only released by closing them, which never happened — so closures accumulated for the life of the connection on lists that every later `readline`/`read`/`take!` on those tokens had to walk.

## New features
- `outbound_backlog(endpoint)` reports `(queued, blocked_seconds)` for the outbound half. The outbound queue is unbounded, so a peer that stops reading never makes a send fail; the messages just accumulate undelivered. The endpoint now also warns once when a single transport write has been outstanding for more than a minute.

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
