defmodule Stevedore.RegistryPushTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Digest, Reference, Registry}

  @ref %Reference{registry: "reg.test", repository: "lib/app", tag: "v1"}

  defp opts(adapter), do: [req_options: [adapter: adapter]]

  test "has_blob? maps HEAD 200/404 to true/false" do
    digest = Digest.compute("blob")

    present = fn req -> {req, Req.Response.new(status: 200)} end
    absent = fn req -> {req, Req.Response.new(status: 404)} end

    assert Registry.has_blob?(@ref, digest, opts(present))
    refute Registry.has_blob?(@ref, digest, opts(absent))
  end

  test "put_blob does a monolithic upload (POST then PUT ?digest=)" do
    digest = Digest.compute("payload")

    adapter = fn req ->
      case {req.method, req.url.path} do
        {:post, "/v2/lib/app/blobs/uploads/"} ->
          {req,
           Req.Response.new(status: 202, headers: [{"location", "/v2/lib/app/blobs/uploads/abc"}])}

        {:put, "/v2/lib/app/blobs/uploads/abc"} ->
          assert URI.decode_query(req.url.query)["digest"] == to_string(digest)
          {req, Req.Response.new(status: 201)}
      end
    end

    assert :ok = Registry.put_blob(@ref, digest, "payload", opts(adapter))
  end

  test "mount_blob returns :ok on 201 and :not_mounted on 202" do
    digest = Digest.compute("blob")

    mounted = fn req ->
      assert URI.decode_query(req.url.query)["from"] == "other/repo"
      {req, Req.Response.new(status: 201)}
    end

    declined = fn req ->
      {req, Req.Response.new(status: 202, headers: [{"location", "/up/1"}])}
    end

    assert :ok = Registry.mount_blob(@ref, digest, "other/repo", opts(mounted))
    assert :not_mounted = Registry.mount_blob(@ref, digest, "other/repo", opts(declined))
  end

  test "put_manifest PUTs and returns the digest" do
    raw = ~s({"schemaVersion":2})
    digest = Digest.compute(raw)

    adapter = fn req ->
      assert req.method == :put
      assert req.url.path == "/v2/lib/app/manifests/v1"

      {req,
       Req.Response.new(status: 201, headers: [{"docker-content-digest", to_string(digest)}])}
    end

    assert {:ok, ^digest} =
             Registry.put_manifest(
               @ref,
               raw,
               "application/vnd.oci.image.manifest.v1+json",
               opts(adapter)
             )
  end

  test "delete_manifest issues DELETE" do
    adapter = fn req ->
      assert req.method == :delete
      {req, Req.Response.new(status: 202)}
    end

    assert :ok = Registry.delete_manifest(@ref, "v1", opts(adapter))
  end
end
