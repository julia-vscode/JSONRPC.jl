# JSONRPC

An implementation for JSON RPC 2.0. See [the specification](https://www.jsonrpc.org/specification) for details.

Currently, only JSON RPC 2.0 is supported. This package can act as both a client & a server.

## Quick start

```julia
using JSONRPC

endpoint = JSONRPCEndpoint(pipe_in, pipe_out)
start(endpoint)  # starts the read/write tasks

# Send a request
result = send_request(endpoint, "method", params)

# Receive incoming messages
for msg in endpoint
    # handle msg
end

close(endpoint)
```