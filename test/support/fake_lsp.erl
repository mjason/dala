-module(fake_lsp).
-export([main/0]).

main() -> loop().

loop() ->
    case read_length(undefined) of
        undefined -> halt(0);
        Length ->
            case io:get_chars("", Length) of
                eof -> halt(0);
                Body ->
                    case string:str(Body, "\"method\":\"exit\"") of
                        0 ->
                            Response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":true}}}",
                            %% The OTP console device is line-buffered on Windows. The
                            %% newline is outside Content-Length and only flushes the test
                            %% fixture; real LSP servers write their stdout pipe directly.
                            Payload = iolist_to_binary(io_lib:format("Content-Length: ~B\r\n\r\n~s~n", [length(Response), Response])),
                            ok = file:write(standard_io, Payload),
                            loop();
                        _ -> halt(0)
                    end
            end
    end.

read_length(Length) ->
    case io:get_line("") of
        eof -> undefined;
        "\r\n" -> Length;
        "\n" -> Length;
        Line ->
            case re:run(Line, "^Content-Length:\\s*(\\d+)", [{capture, [1], list}, caseless]) of
                {match, [Value]} -> read_length(list_to_integer(Value));
                nomatch -> read_length(Length)
            end
    end.
