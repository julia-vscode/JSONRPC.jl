@testitem "write_transport_layer round-trip" begin
    using CancellationTokens
    # Write a message into a buffer, then read it back via read_transport_layer
    buf = IOBuffer()
    JSONRPC.write_transport_layer(buf, "{\"jsonrpc\":\"2.0\",\"method\":\"test\"}")
    seekstart(buf)
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token)
    @test msg == "{\"jsonrpc\":\"2.0\",\"method\":\"test\"}"
end

@testitem "write_transport_layer Unicode round-trip" begin
    using CancellationTokens
    buf = IOBuffer()
    payload = "{\"text\":\"héllo wörld 🚀\"}"
    JSONRPC.write_transport_layer(buf, payload)
    seekstart(buf)
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token)
    @test msg == payload
end

@testitem "read_transport_layer: missing Content-Length" begin
    using CancellationTokens
    # A header block that has no Content-Length should return nothing
    buf = IOBuffer("X-Custom: value\r\n\r\n{\"a\":1}")
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token)
    @test msg === nothing
end

@testitem "read_transport_layer: empty stream" begin
    using CancellationTokens
    # An empty/closed stream should return nothing (first readline returns "")
    buf = IOBuffer("")
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token)
    @test msg === nothing
end

@testitem "read_transport_layer: truncated payload" begin
    using CancellationTokens
    # Content-Length says 100 bytes, but only a few bytes follow
    header = "Content-Length: 100\r\n\r\n"
    buf = IOBuffer(header * "short")
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token)
    @test msg === nothing
end

@testitem "read_transport_layer: IOError returns nothing" begin
    # Simulate an IOError during read by using a closed PipeEndpoint
    using Sockets, CancellationTokens
    pipe_name = JSONRPC.generate_pipe_name()
    server = listen(pipe_name)
    ready = Channel{Bool}(1)
    @async begin
        sock = accept(server)
        close(sock)  # close immediately
        put!(ready, true)
    end
    client = connect(pipe_name)
    take!(ready)
    sleep(0.05)
    # The client should get nothing (IOError caught internally)
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(client, token)
    @test msg === nothing
    close(client)
    close(server)
end

@testitem "read_transport_layer: extra colons in header value" begin
    using CancellationTokens
    # Header value "Content-Length: 13" has one colon, but what about
    # "X-Custom: foo:bar:baz"? The split(line, ":", limit=2) should handle it.
    payload = "{\"a\":\"hello\"}"
    n = ncodeunits(payload)
    raw = "X-Custom: foo:bar:baz\r\nContent-Length: $n\r\n\r\n$payload"
    buf = IOBuffer(raw)
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token)
    @test msg == payload
end

@testitem "read_transport_layer: header with no colon is skipped" begin
    using CancellationTokens
    # A malformed header line with no colon should be silently skipped
    payload = "{\"ok\":true}"
    n = ncodeunits(payload)
    raw = "BadHeaderNoColon\r\nContent-Length: $n\r\n\r\n$payload"
    buf = IOBuffer(raw)
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token)
    @test msg == payload
end

@testitem "write_transport_layer Content-Length is byte count" begin
    # Verify that Content-Length reflects byte count, not character count for multi-byte chars
    buf = IOBuffer()
    payload = "{\"emoji\":\"🎉\"}"  # 🎉 is 4 bytes in UTF-8
    JSONRPC.write_transport_layer(buf, payload)
    seekstart(buf)
    raw = String(take!(buf))
    # Extract the Content-Length value
    m = match(r"Content-Length: (\d+)", raw)
    @test m !== nothing
    cl = parse(Int, m.captures[1])
    @test cl == ncodeunits(payload)
end

# ── NewlineDelimitedFraming tests ──────────────────────────────────────────────

@testitem "NewlineDelimited: write/read round-trip" begin
    using CancellationTokens
    buf = IOBuffer()
    framing = JSONRPC.NewlineDelimitedFraming()
    JSONRPC.write_transport_layer(buf, "{\"jsonrpc\":\"2.0\",\"method\":\"test\"}", framing)
    seekstart(buf)
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token, framing)
    @test msg == "{\"jsonrpc\":\"2.0\",\"method\":\"test\"}"
end

@testitem "NewlineDelimited: Unicode round-trip" begin
    using CancellationTokens
    buf = IOBuffer()
    framing = JSONRPC.NewlineDelimitedFraming()
    payload = "{\"text\":\"héllo wörld 🚀\"}"
    JSONRPC.write_transport_layer(buf, payload, framing)
    seekstart(buf)
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token, framing)
    @test msg == payload
end

@testitem "NewlineDelimited: empty stream returns nothing" begin
    using CancellationTokens
    buf = IOBuffer("")
    framing = JSONRPC.NewlineDelimitedFraming()
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(buf, token, framing)
    @test msg === nothing
end

@testitem "NewlineDelimited: multiple messages" begin
    using CancellationTokens
    buf = IOBuffer()
    framing = JSONRPC.NewlineDelimitedFraming()
    msgs = ["{\"id\":1}", "{\"id\":2}", "{\"id\":3}"]
    for m in msgs
        JSONRPC.write_transport_layer(buf, m, framing)
    end
    seekstart(buf)
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    for expected in msgs
        got = JSONRPC.read_transport_layer(buf, token, framing)
        @test got == expected
    end
    # After all messages, next read should return nothing
    @test JSONRPC.read_transport_layer(buf, token, framing) === nothing
end

@testitem "NewlineDelimited: write has no Content-Length header" begin
    buf = IOBuffer()
    framing = JSONRPC.NewlineDelimitedFraming()
    JSONRPC.write_transport_layer(buf, "{\"a\":1}", framing)
    seekstart(buf)
    raw = String(take!(buf))
    @test !occursin("Content-Length", raw)
    @test endswith(raw, "\n")
end

@testitem "NewlineDelimited: IOError returns nothing" begin
    using Sockets, CancellationTokens
    pipe_name = JSONRPC.generate_pipe_name()
    server = listen(pipe_name)
    ready = Channel{Bool}(1)
    @async begin
        sock = accept(server)
        close(sock)
        put!(ready, true)
    end
    client = connect(pipe_name)
    take!(ready)
    sleep(0.05)
    framing = JSONRPC.NewlineDelimitedFraming()
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(client, token, framing)
    @test msg === nothing
    close(client)
    close(server)
end

@testitem "NewlineDelimited: named-pipe round-trip" begin
    using Sockets, CancellationTokens
    pipe_name = JSONRPC.generate_pipe_name()
    server = listen(pipe_name)
    ready = Channel{Bool}(1)
    server_sock_ch = Channel{Sockets.PipeEndpoint}(1)
    @async begin
        sock = accept(server)
        put!(ready, true)
        put!(server_sock_ch, sock)
    end
    client = connect(pipe_name)
    take!(ready)
    server_sock = take!(server_sock_ch)

    framing = JSONRPC.NewlineDelimitedFraming()
    payload = "{\"jsonrpc\":\"2.0\",\"method\":\"hello\"}"
    JSONRPC.write_transport_layer(client, payload, framing)
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    msg = JSONRPC.read_transport_layer(server_sock, token, framing)
    @test msg == payload

    close(client)
    close(server_sock)
    close(server)
end

@testitem "JSONRPCEndpoint: constructor with framing kwarg" begin
    # Default framing
    ep_default = JSONRPC.JSONRPCEndpoint(IOBuffer(), IOBuffer())
    @test ep_default.framing isa JSONRPC.ContentLengthFraming

    # Explicit ContentLengthFraming
    ep_cl = JSONRPC.JSONRPCEndpoint(IOBuffer(), IOBuffer(); framing=JSONRPC.ContentLengthFraming())
    @test ep_cl.framing isa JSONRPC.ContentLengthFraming

    # NewlineDelimitedFraming
    ep_nd = JSONRPC.JSONRPCEndpoint(IOBuffer(), IOBuffer(); framing=JSONRPC.NewlineDelimitedFraming())
    @test ep_nd.framing isa JSONRPC.NewlineDelimitedFraming
end

@testitem "NewlineDelimited: full endpoint round-trip over pipes" begin
    using Sockets, CancellationTokens

    pipe_name = JSONRPC.generate_pipe_name()
    server = listen(pipe_name)
    ready = Channel{Bool}(1)
    server_sock_ch = Channel{Sockets.PipeEndpoint}(1)
    @async begin
        sock = accept(server)
        put!(ready, true)
        put!(server_sock_ch, sock)
    end
    client = connect(pipe_name)
    take!(ready)
    server_sock = take!(server_sock_ch)

    framing = JSONRPC.NewlineDelimitedFraming()

    # Write a notification-like message from one end
    msg = "{\"jsonrpc\":\"2.0\",\"method\":\"test/hello\",\"params\":{\"msg\":\"world\"}}"
    JSONRPC.write_transport_layer(client, msg, framing)

    # Read it from the other end
    token = CancellationTokens.get_token(CancellationTokens.CancellationTokenSource())
    received = JSONRPC.read_transport_layer(server_sock, token, framing)
    parsed = JSONRPC.JSON.parse(received)
    @test parsed["method"] == "test/hello"
    @test parsed["params"]["msg"] == "world"

    close(client)
    close(server_sock)
    close(server)
end
