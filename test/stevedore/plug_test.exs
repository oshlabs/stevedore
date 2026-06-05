defmodule Stevedore.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Stevedore.{Digest, MediaType}
  alias Stevedore.Server.Uploads

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    up = start_supervised!({Uploads, name: :"u_#{System.unique_integer([:positive])}"})
    opts = Stevedore.Plug.init(store: dir, uploads: up, authorize: fn _, _, _ -> :ok end)
    %{opts: opts, up: up, store: dir}
  end

  defp call(conn, opts), do: Stevedore.Plug.call(conn, opts)

  defp put_blob(opts, name, bytes) do
    digest = Digest.compute(bytes)

    conn =
      call(conn(:post, "/v2/#{name}/blobs/uploads/?digest=#{to_string(digest)}", bytes), opts)

    assert conn.status == 201
    digest
  end

  defp build_image(opts, name) do
    layer = Stevedore.Archive.gzip("a-layer")
    ld = put_blob(opts, name, layer)
    config = ~s({"architecture":"amd64","os":"linux"})
    cd = put_blob(opts, name, config)

    manifest =
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => MediaType.oci_manifest(),
        "config" => %{
          "mediaType" => MediaType.oci_config(),
          "size" => byte_size(config),
          "digest" => to_string(cd)
        },
        "layers" => [
          %{
            "mediaType" => MediaType.oci_layer_gzip(),
            "size" => byte_size(layer),
            "digest" => to_string(ld)
          }
        ]
      })

    %{raw: manifest, digest: Digest.compute(manifest), config: cd, layer: ld}
  end

  test "version check", %{opts: opts} do
    conn = call(conn(:get, "/v2/"), opts)
    assert conn.status == 200
    assert get_resp_header(conn, "docker-distribution-api-version") == ["registry/2.0"]
  end

  test "monolithic blob upload then GET/HEAD", %{opts: opts} do
    bytes = "monolithic-blob"
    digest = put_blob(opts, "lib/app", bytes)

    get = call(conn(:get, "/v2/lib/app/blobs/#{to_string(digest)}"), opts)
    assert get.status == 200
    assert get.resp_body == bytes
    assert get_resp_header(get, "docker-content-digest") == [to_string(digest)]

    head = call(conn(:head, "/v2/lib/app/blobs/#{to_string(digest)}"), opts)
    assert head.status == 200
  end

  test "chunked blob upload (POST, PATCH, PUT)", %{opts: opts} do
    bytes = "chunk-one|chunk-two"
    digest = Digest.compute(bytes)

    start = call(conn(:post, "/v2/lib/app/blobs/uploads/"), opts)
    assert start.status == 202
    [location] = get_resp_header(start, "location")
    assert [_uuid] = get_resp_header(start, "docker-upload-uuid")

    patch = call(conn(:patch, location, "chunk-one|"), opts)
    assert patch.status == 202
    assert get_resp_header(patch, "range") == ["0-9"]

    put = call(conn(:put, location <> "?digest=#{to_string(digest)}", "chunk-two"), opts)
    assert put.status == 201
    assert get_resp_header(put, "docker-content-digest") == [to_string(digest)]

    assert call(conn(:get, "/v2/lib/app/blobs/#{to_string(digest)}"), opts).resp_body == bytes
  end

  test "finalize with a mismatched digest is DIGEST_INVALID", %{opts: opts} do
    start = call(conn(:post, "/v2/lib/app/blobs/uploads/"), opts)
    [location] = get_resp_header(start, "location")
    _ = call(conn(:patch, location, "data"), opts)

    wrong = Digest.compute("something-else")
    put = call(conn(:put, location <> "?digest=#{to_string(wrong)}", ""), opts)
    assert put.status == 400
    assert errors_code(put) == "DIGEST_INVALID"
  end

  test "manifest PUT/GET/HEAD/DELETE round-trip", %{opts: opts} do
    img = build_image(opts, "lib/app")

    put =
      call(
        put_req_header(
          conn(:put, "/v2/lib/app/manifests/v1", img.raw),
          "content-type",
          MediaType.oci_manifest()
        ),
        opts
      )

    assert put.status == 201
    assert get_resp_header(put, "docker-content-digest") == [to_string(img.digest)]

    get = call(conn(:get, "/v2/lib/app/manifests/v1"), opts)
    assert get.status == 200
    assert get.resp_body == img.raw
    assert get_resp_header(get, "content-type") == [MediaType.oci_manifest()]
    assert get_resp_header(get, "docker-content-digest") == [to_string(img.digest)]

    assert call(conn(:head, "/v2/lib/app/manifests/v1"), opts).status == 200

    assert call(conn(:delete, "/v2/lib/app/manifests/v1"), opts).status == 202
    assert call(conn(:get, "/v2/lib/app/manifests/v1"), opts).status == 404
  end

  test "manifest referencing a missing blob is rejected", %{opts: opts} do
    cd = Digest.compute("absent-config")
    ld = Digest.compute("absent-layer")

    manifest =
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => MediaType.oci_manifest(),
        "config" => %{
          "mediaType" => MediaType.oci_config(),
          "size" => 1,
          "digest" => to_string(cd)
        },
        "layers" => [
          %{"mediaType" => MediaType.oci_layer_gzip(), "size" => 1, "digest" => to_string(ld)}
        ]
      })

    conn =
      call(
        put_req_header(
          conn(:put, "/v2/lib/app/manifests/v1", manifest),
          "content-type",
          MediaType.oci_manifest()
        ),
        opts
      )

    assert conn.status == 404
    assert errors_code(conn) == "BLOB_UNKNOWN"
  end

  test "catalog and tags list", %{opts: opts} do
    _ =
      build_image(opts, "lib/app")
      |> then(fn img ->
        call(
          put_req_header(
            conn(:put, "/v2/lib/app/manifests/v1", img.raw),
            "content-type",
            MediaType.oci_manifest()
          ),
          opts
        )
      end)

    catalog = call(conn(:get, "/v2/_catalog"), opts)
    assert catalog.status == 200
    assert "lib/app" in JSON.decode!(catalog.resp_body)["repositories"]

    tags = call(conn(:get, "/v2/lib/app/tags/list"), opts)
    assert JSON.decode!(tags.resp_body) == %{"name" => "lib/app", "tags" => ["v1"]}
  end

  test "missing manifest is MANIFEST_UNKNOWN", %{opts: opts} do
    conn = call(conn(:get, "/v2/lib/app/manifests/nope"), opts)
    assert conn.status == 404
    assert errors_code(conn) == "MANIFEST_UNKNOWN"
  end

  test "referrers endpoint returns an empty index", %{opts: opts} do
    digest = Digest.compute("x")
    conn = call(conn(:get, "/v2/lib/app/referrers/#{to_string(digest)}"), opts)
    assert conn.status == 200
    assert JSON.decode!(conn.resp_body)["manifests"] == []
  end

  describe "authorization (default read-only)" do
    setup %{store: dir, up: up} do
      %{ro: Stevedore.Plug.init(store: dir, uploads: up)}
    end

    test "pull is allowed, push is denied with a challenge", %{ro: ro} do
      assert call(conn(:get, "/v2/lib/app/tags/list"), ro).status == 200

      denied = call(conn(:post, "/v2/lib/app/blobs/uploads/"), ro)
      assert denied.status == 401
      assert [challenge] = get_resp_header(denied, "www-authenticate")
      assert challenge =~ "Bearer realm="
    end
  end

  defp errors_code(conn) do
    conn.resp_body |> JSON.decode!() |> Map.fetch!("errors") |> hd() |> Map.fetch!("code")
  end
end
