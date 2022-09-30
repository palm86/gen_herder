defmodule GenHerderTest do
  use ExUnit.Case

  defmodule TokenGenHerder do
    use GenHerder

    def handle_request(request) do
      # Simulate work
      Process.sleep(2000)

      # Simply encode the request and a random component as the token
      access_token =
        %{request: request, ref: make_ref()} |> :erlang.term_to_binary() |> Base.encode64()

      %{access_token: access_token, expires_in: 2000}
    end

    def time_to_live(%{expires_in: expires_in} = _result) do
      # Make it expire 10% earlier
      trunc(expires_in * 0.9)
    end
  end

  defmodule FailingGenHerder do
    use GenHerder

    def handle_request(_request) do
      raise "failure"
    end

    def time_to_live(_result) do
      :infinity
    end
  end

  defmodule NoCacheGenHerder do
    use GenHerder

    def handle_request(_request) do
      make_ref()
    end

    def time_to_live(_result) do
      0
    end
  end

  defmodule InfinityGenHerder do
    use GenHerder

    def handle_request(_request) do
      make_ref()
    end

    def time_to_live(_result) do
      :infinity
    end
  end

  # doctest GenHerder

  test "subsequent calls with the same request returns the same result" do
    TokenGenHerder.start_link()

    {microseconds1, result1} = :timer.tc(TokenGenHerder, :call, ["some_request"])
    {microseconds2, result2} = :timer.tc(TokenGenHerder, :call, ["some_request"])

    assert microseconds1 > 2000 * 1000
    assert microseconds2 < 2000 * 1000
    assert result1 == result2
  end

  test "subsequent calls with the same request returns different results after the ttl expires" do
    TokenGenHerder.start_link()

    result1 = TokenGenHerder.call("some_request")
    Process.sleep(2000)
    result2 = TokenGenHerder.call("some_request")

    assert result1 != result2
  end

  test "subsequent calls with different requests returns different results" do
    TokenGenHerder.start_link()

    {microseconds1, result1} = :timer.tc(TokenGenHerder, :call, ["some_request"])
    {microseconds2, result2} = :timer.tc(TokenGenHerder, :call, ["other_request"])

    assert microseconds1 > 2000 * 1000
    assert microseconds2 > 2000 * 1000
    assert result1 != result2
  end

  test "calls that exceed the timeout exit" do
    TokenGenHerder.start_link()

    assert catch_exit(TokenGenHerder.call("some_request", 1000))
  end

  test "failure" do
    FailingGenHerder.start_link()

    assert {:error, {exception, _stacktrace}} = FailingGenHerder.call("some_request")
    assert exception.message == "failure"
  end

  test "ttl 0 doesn't cache" do
    NoCacheGenHerder.start_link()

    assert res1 = NoCacheGenHerder.call("some_request")
    assert res2 = NoCacheGenHerder.call("some_request")
    assert res1 != res2
  end

  test "ttl :infinity caches result" do
    InfinityGenHerder.start_link()

    assert res1 = InfinityGenHerder.call("some_request")
    assert res2 = InfinityGenHerder.call("some_request")
    assert res1 == res2
  end

  test "concurrent calls with the same request returns the same result" do
    TokenGenHerder.start_link()

    {micros, results} =
      :timer.tc(fn ->
        tasks =
          for _ <- 0..10 do
            Task.async(fn ->
              TokenGenHerder.call("some request")
            end)
          end

        Task.await_many(tasks)
      end)

    # the results must be the same
    assert results |> Enum.uniq() |> Enum.count() == 1
    # it should take longer than the sleep in the handle_request
    assert 2000 * 1000 < micros
    # it should not take much longer than the sleep in the handle_request
    assert micros < 3000 * 1000
  end

  test "can be started globally" do
    assert {:ok, pid} = TokenGenHerder.start_link(name: {:global, :token})
    assert {:error, {:already_started, ^pid}} = TokenGenHerder.start_link(name: {:global, :token})
  end

  test "README install version check" do
    app = :gen_herder

    app_version = "#{Application.spec(app, :vsn)}"
    readme = File.read!("README.md")
    [_, readme_versions] = Regex.run(~r/{:#{app}, "(.+)"}/, readme)

    assert Version.match?(
             app_version,
             readme_versions
           ),
           """
           Install version constraint in README.md does not match to current app version.
           Current App Version: #{app_version}
           Readme Install Versions: #{readme_versions}
           """
  end
end
