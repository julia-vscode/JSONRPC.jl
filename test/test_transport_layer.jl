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
