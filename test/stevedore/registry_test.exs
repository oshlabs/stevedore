defmodule Stevedore.RegistryTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Digest, MediaType, Reference, Registry}

  @ref %Reference{registry: "registry.test", repository: "library/alpine", tag: "3.20"}
  @index ~s({"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[]})
  @challenge ~s(Bearer realm="https://auth.test/token",service="reg",scope="repository:library/alpine:pull")

  defp run(ref_or_fun, adapter), do: ref_or_fun.(req_options: [adapter: adapter])

  defp bearer?(req), do: match?(["Bearer " <> _], Req.Request.get_header(req, "authorization"))

  defp token_response(req),
    do:
      {req,
       Req.Response.new(
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: ~s({"token":"TKN"})
       )}

  describe "manifest/2" do
    test "performs the 401 -> token -> 200 flow and returns the raw bytes + verified digest" do
      digest = Digest.compute(@index)

      adapter = fn req ->
        case {req.url.host, req.url.path} do
          {"auth.test", "/token"} ->
            token_response(req)

          {"registry.test", "/v2/library/alpine/manifests/3.20"} ->
            if bearer?(req) do
              {req,
               Req.Response.new(
                 status: 200,
                 headers: [
                   {"content-type", MediaType.oci_index()},
                   {"docker-content-digest", to_string(digest)}
                 ],
                 body: @index
               )}
            else
              {req,
               Req.Response.new(
                 status: 401,
                 headers: [{"www-authenticate", @challenge}],
                 body: ""
               )}
            end
        end
      end

      assert {:ok, result} = run(&Registry.manifest(@ref, &1), adapter)
      assert result.media_type == MediaType.oci_index()
      assert result.raw == @index
      assert result.digest == digest
      assert is_map(result.json)
    end

    test "negotiates all manifest media types via Accept" do
      adapter = fn req ->
        assert [accept] = Req.Request.get_header(req, "accept")
        assert accept =~ MediaType.oci_manifest()
        assert accept =~ MediaType.oci_index()

        {req,
         Req.Response.new(
           status: 200,
           headers: [{"content-type", MediaType.oci_index()}],
           body: @index
         )}
      end

      assert {:ok, _} = run(&Registry.manifest(@ref, &1), adapter)
    end

    test "rejects a Docker-Content-Digest that does not match the bytes" do
      adapter = fn req ->
        {req,
         Req.Response.new(
           status: 200,
           headers: [
             {"content-type", MediaType.oci_index()},
             {"docker-content-digest", to_string(Digest.compute("other"))}
           ],
           body: @index
         )}
      end

      assert {:error, %Registry.Error{reason: :manifest_digest_mismatch}} =
               run(&Registry.manifest(@ref, &1), adapter)
    end
  end

  describe "blob/3" do
    test "verifies the blob bytes against the digest" do
      bytes = "layer-bytes"
      digest = Digest.compute(bytes)

      adapter = fn req ->
        {req, Req.Response.new(status: 200, body: bytes)}
      end

      assert {:ok, ^bytes} = run(&Registry.blob(@ref, digest, &1), adapter)
    end

    test "errors when the bytes do not match the digest" do
      adapter = fn req -> {req, Req.Response.new(status: 200, body: "tampered")} end

      assert {:error, %Registry.Error{reason: :digest_mismatch}} =
               run(&Registry.blob(@ref, Digest.compute("real"), &1), adapter)
    end

    test "does not leak the Authorization header across a CDN redirect" do
      bytes = "blob-from-cdn"
      digest = Digest.compute(bytes)

      adapter = fn req ->
        case {req.url.host, req.url.path} do
          {"auth.test", "/token"} ->
            token_response(req)

          {"registry.test", "/v2/library/alpine/blobs/" <> _} ->
            if bearer?(req) do
              {req,
               Req.Response.new(
                 status: 307,
                 headers: [{"location", "https://cdn.test/blob/xyz"}],
                 body: ""
               )}
            else
              {req,
               Req.Response.new(
                 status: 401,
                 headers: [{"www-authenticate", @challenge}],
                 body: ""
               )}
            end

          {"cdn.test", "/blob/xyz"} ->
            # The registry token must not be forwarded off-origin; 403 if it leaks.
            if Req.Request.get_header(req, "authorization") == [] do
              {req, Req.Response.new(status: 200, body: bytes)}
            else
              {req, Req.Response.new(status: 403, body: "leaked")}
            end
        end
      end

      assert {:ok, ^bytes} = run(&Registry.blob(@ref, digest, &1), adapter)
    end
  end

  describe "list_tags/2" do
    test "follows Link pagination and concatenates tags" do
      adapter = fn req ->
        query = req.url.query || ""

        if String.contains?(query, "last=b") do
          {req,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "application/json"}],
             body: ~s({"tags":["c"]})
           )}
        else
          {req,
           Req.Response.new(
             status: 200,
             headers: [
               {"content-type", "application/json"},
               {"link", ~s(</v2/library/alpine/tags/list?last=b>; rel="next")}
             ],
             body: ~s({"tags":["a","b"]})
           )}
        end
      end

      assert {:ok, ["a", "b", "c"]} = run(&Registry.list_tags(@ref, &1), adapter)
    end
  end
end
