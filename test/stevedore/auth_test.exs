defmodule Stevedore.AuthTest do
  use ExUnit.Case, async: true

  alias Stevedore.Auth

  doctest Auth

  @challenge %{
    realm: "https://auth.test/token",
    service: "reg",
    scope: "repository:library/alpine:pull"
  }

  test "token exchanges a challenge for a bearer token, forwarding query params" do
    adapter = fn req ->
      assert req.url.host == "auth.test"
      params = URI.decode_query(req.url.query || "")
      assert params["service"] == "reg"
      assert params["scope"] == "repository:library/alpine:pull"

      {req,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: ~s({"token":"TKN"})
       )}
    end

    assert {:ok, "TKN"} = Auth.token(@challenge, :anonymous, req_options: [adapter: adapter])
  end

  test "token accepts the access_token alias" do
    adapter = fn req ->
      {req,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: ~s({"access_token":"AT"})
       )}
    end

    assert {:ok, "AT"} = Auth.token(@challenge, :anonymous, req_options: [adapter: adapter])
  end

  test "token sends Basic credentials when provided" do
    adapter = fn req ->
      assert ["Basic " <> b64] = Req.Request.get_header(req, "authorization")
      assert Base.decode64!(b64) == "user:pass"

      {req,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: ~s({"token":"T"})
       )}
    end

    assert {:ok, "T"} =
             Auth.token(@challenge, {:basic, "user", "pass"}, req_options: [adapter: adapter])
  end

  test "token surfaces a non-200 as an error" do
    adapter = fn req -> {req, Req.Response.new(status: 403, body: "denied")} end

    assert {:error, %Auth.Error{status: 403}} =
             Auth.token(@challenge, :anonymous, req_options: [adapter: adapter])
  end

  describe "from_docker_config" do
    @tag :tmp_dir
    test "decodes base64 auth entries", %{tmp_dir: dir} do
      path = Path.join(dir, "config.json")
      auth = Base.encode64("alice:secret")
      File.write!(path, ~s({"auths": {"ghcr.io": {"auth": "#{auth}"}}}))

      assert {:ok, %{"ghcr.io" => {:basic, "alice", "secret"}}} = Auth.from_docker_config(path)
    end

    @tag :tmp_dir
    test "skips malformed entries", %{tmp_dir: dir} do
      path = Path.join(dir, "config.json")
      File.write!(path, ~s({"auths": {"a": {"auth": "!!notbase64"}, "b": {}}}))
      assert {:ok, auths} = Auth.from_docker_config(path)
      assert auths == %{}
    end

    test "a missing file yields an empty map" do
      assert {:ok, %{}} = Auth.from_docker_config("/no/such/docker/config.json")
    end
  end
end
