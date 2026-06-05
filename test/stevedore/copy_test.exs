defmodule Stevedore.CopyTest.CountingSource do
  @moduledoc false
  # A transport wrapper that counts get_blob calls, to prove blob-skip avoids re-download.
  @behaviour Stevedore.Transport

  alias Stevedore.Transport

  defstruct [:inner, :counter]

  @impl true
  def get_manifest(t, ref), do: Transport.get_manifest(t.inner, ref)
  @impl true
  def put_manifest(t, ref, raw, mt), do: Transport.put_manifest(t.inner, ref, raw, mt)
  @impl true
  def get_blob(t, digest) do
    Agent.update(t.counter, &(&1 + 1))
    Transport.get_blob(t.inner, digest)
  end

  @impl true
  def put_blob(t, digest, data), do: Transport.put_blob(t.inner, digest, data)
  @impl true
  def has_blob?(t, digest), do: Transport.has_blob?(t.inner, digest)
  @impl true
  def list_tags(t), do: Transport.list_tags(t.inner)
  @impl true
  def delete(t, ref), do: Transport.delete(t.inner, ref)
end

defmodule Stevedore.CopyTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Digest, MediaType}
  alias Stevedore.Transport.{Archive, Dir, OCILayout, Static}

  @moduletag :tmp_dir

  # --- fixtures ---

  defp build_image(layers) do
    layer_descs =
      Enum.map(layers, fn bytes ->
        d = Digest.compute(bytes)

        {d, bytes,
         %{
           "mediaType" => MediaType.oci_layer_gzip(),
           "size" => byte_size(bytes),
           "digest" => to_string(d)
         }}
      end)

    config_raw =
      JSON.encode!(%{
        "architecture" => "amd64",
        "os" => "linux",
        "rootfs" => %{
          "type" => "layers",
          "diff_ids" => Enum.map(layer_descs, fn {d, _, _} -> to_string(d) end)
        }
      })

    config_digest = Digest.compute(config_raw)

    manifest =
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => MediaType.oci_manifest(),
        "config" => %{
          "mediaType" => MediaType.oci_config(),
          "size" => byte_size(config_raw),
          "digest" => to_string(config_digest)
        },
        "layers" => Enum.map(layer_descs, fn {_, _, desc} -> desc end)
      })

    %{
      manifest_raw: manifest,
      manifest_digest: Digest.compute(manifest),
      config: {config_digest, config_raw},
      layers: Enum.map(layer_descs, fn {d, b, _} -> {d, b} end)
    }
  end

  defp seed(layout, tag, img) do
    {cd, cr} = img.config
    :ok = OCILayout.put_blob(layout, cd, cr)
    Enum.each(img.layers, fn {d, b} -> :ok = OCILayout.put_blob(layout, d, b) end)
    {:ok, _} = OCILayout.put_manifest(layout, tag, img.manifest_raw, MediaType.oci_manifest())
  end

  defp oci(dir, sub), do: %OCILayout{path: Path.join(dir, sub)}

  # --- round-trips ---

  test "oci -> dir -> oci preserves the manifest and all blob digests", %{tmp_dir: dir} do
    img = build_image([Stevedore.Archive.gzip("layer-one")])
    a = oci(dir, "a")
    seed(a, "v1", img)

    flat = %Dir{path: Path.join(dir, "flat")}
    c = oci(dir, "c")

    assert {:ok, %{digest: d1}} = Stevedore.copy({a, "v1"}, {flat, nil})
    assert d1 == img.manifest_digest
    assert {:ok, %{digest: d2}} = Stevedore.copy({flat, nil}, {c, "v1"})
    assert d2 == img.manifest_digest

    assert {:ok, fetched} = OCILayout.get_manifest(c, "v1")
    assert fetched.raw == img.manifest_raw
    {cd, _} = img.config
    assert OCILayout.has_blob?(c, cd)
    assert Enum.all?(img.layers, fn {ld, _} -> OCILayout.has_blob?(c, ld) end)
  end

  test "oci -> oci-archive -> oci preserves the manifest digest", %{tmp_dir: dir} do
    img = build_image([Stevedore.Archive.gzip("arc-layer")])
    a = oci(dir, "a")
    seed(a, "v1", img)

    tar = Path.join(dir, "image.oci.tar")
    sink = %Archive{path: tar, format: :oci, work: Path.join(dir, "w-sink")}
    assert {:ok, %{digest: d0}} = Stevedore.copy({a, "v1"}, {sink, "v1"})
    assert d0 == img.manifest_digest
    assert File.regular?(tar)

    src = %Archive{path: tar, format: :oci, work: Path.join(dir, "w-src")}
    c = oci(dir, "c")
    assert {:ok, %{digest: d}} = Stevedore.copy({src, nil}, {c, "v1"})
    assert d == img.manifest_digest
  end

  test "oci -> docker-archive -> oci preserves blob digests (manifest is reformatted)", %{
    tmp_dir: dir
  } do
    img = build_image([Stevedore.Archive.gzip("dsave-layer")])
    a = oci(dir, "a")
    seed(a, "v1", img)

    tar = Path.join(dir, "image.docker.tar")
    sink = %Archive{path: tar, format: :docker, work: Path.join(dir, "w-sink")}
    assert {:ok, _} = Stevedore.copy({a, "v1"}, {sink, "v1"})
    assert File.regular?(tar)

    src = %Archive{path: tar, format: :docker, work: Path.join(dir, "w-src")}
    c = oci(dir, "c")
    assert {:ok, _} = Stevedore.copy({src, nil}, {c, "v1"})

    {cd, _} = img.config
    assert OCILayout.has_blob?(c, cd)
    assert Enum.all?(img.layers, fn {ld, _} -> OCILayout.has_blob?(c, ld) end)
  end

  # --- multi-arch index ---

  defp build_index(children) do
    manifests =
      Enum.map(children, fn {img, platform} ->
        %{
          "mediaType" => MediaType.oci_manifest(),
          "size" => byte_size(img.manifest_raw),
          "digest" => to_string(img.manifest_digest),
          "platform" => platform
        }
      end)

    raw =
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => MediaType.oci_index(),
        "manifests" => manifests
      })

    %{raw: raw, digest: Digest.compute(raw)}
  end

  defp seed_index(layout, tag, children, index) do
    Enum.each(children, fn {img, _platform} ->
      {cd, cr} = img.config
      :ok = OCILayout.put_blob(layout, cd, cr)
      Enum.each(img.layers, fn {d, b} -> :ok = OCILayout.put_blob(layout, d, b) end)
      {:ok, _} = OCILayout.put_manifest(layout, nil, img.manifest_raw, MediaType.oci_manifest())
    end)

    {:ok, _} = OCILayout.put_manifest(layout, tag, index.raw, MediaType.oci_index())
  end

  test "copy --all preserves the whole index and every child", %{tmp_dir: dir} do
    amd = build_image([Stevedore.Archive.gzip("amd-layer")])
    arm = build_image([Stevedore.Archive.gzip("arm-layer")])

    children = [
      {amd, %{"os" => "linux", "architecture" => "amd64"}},
      {arm, %{"os" => "linux", "architecture" => "arm64"}}
    ]

    index = build_index(children)

    a = oci(dir, "a")
    seed_index(a, "multi", children, index)

    b = oci(dir, "b")
    assert {:ok, %{digest: d}} = Stevedore.copy({a, "multi"}, {b, "multi"}, all: true)
    assert d == index.digest

    assert {:ok, fetched} = OCILayout.get_manifest(b, "multi")
    assert fetched.digest == index.digest
    assert {:ok, _} = OCILayout.get_manifest(b, amd.manifest_digest)
    assert {:ok, _} = OCILayout.get_manifest(b, arm.manifest_digest)
  end

  test "copy with a single platform writes that child as a plain manifest", %{tmp_dir: dir} do
    amd = build_image([Stevedore.Archive.gzip("amd-layer")])
    arm = build_image([Stevedore.Archive.gzip("arm-layer")])

    children = [
      {amd, %{"os" => "linux", "architecture" => "amd64"}},
      {arm, %{"os" => "linux", "architecture" => "arm64"}}
    ]

    index = build_index(children)

    a = oci(dir, "a")
    seed_index(a, "multi", children, index)

    c = oci(dir, "c")

    assert {:ok, %{digest: d}} =
             Stevedore.copy({a, "multi"}, {c, "linux-arm"}, platform: "linux/arm64")

    assert d == arm.manifest_digest

    assert {:ok, fetched} = OCILayout.get_manifest(c, "linux-arm")
    assert fetched.raw == arm.manifest_raw
  end

  # --- blob-skip ---

  test "blob-skip: a second copy re-downloads nothing", %{tmp_dir: dir} do
    img = build_image([Stevedore.Archive.gzip("l1"), Stevedore.Archive.gzip("l2")])
    inner = oci(dir, "src")
    seed(inner, "v1", img)

    counter = start_supervised!({Agent, fn -> 0 end})
    src = %Stevedore.CopyTest.CountingSource{inner: inner, counter: counter}
    dst = oci(dir, "dst")

    assert {:ok, _} = Stevedore.copy({src, "v1"}, {dst, "v1"})
    # config + 2 layers fetched on the first copy.
    assert Agent.get(counter, & &1) == 3

    Agent.update(counter, fn _ -> 0 end)
    assert {:ok, _} = Stevedore.copy({src, "v1"}, {dst, "v1"})
    assert Agent.get(counter, & &1) == 0
  end

  # --- registry source via fake adapter ---

  test "docker:// source copies into an oci layout, digests preserved", %{tmp_dir: dir} do
    img = build_image([Stevedore.Archive.gzip("reg-layer")])
    {cd, cr} = img.config
    [{ld, lb}] = img.layers

    challenge =
      ~s(Bearer realm="https://auth.test/token",service="r",scope="repository:lib/app:pull")

    adapter = fn req ->
      bearer? = match?(["Bearer " <> _], Req.Request.get_header(req, "authorization"))

      cond do
        req.url.host == "auth.test" ->
          {req,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", "application/json"}],
             body: ~s({"token":"T"})
           )}

        not bearer? ->
          {req,
           Req.Response.new(status: 401, headers: [{"www-authenticate", challenge}], body: "")}

        req.url.path == "/v2/lib/app/manifests/v1" ->
          {req,
           Req.Response.new(
             status: 200,
             headers: [{"content-type", MediaType.oci_manifest()}],
             body: img.manifest_raw
           )}

        req.url.path == "/v2/lib/app/blobs/#{to_string(cd)}" ->
          {req, Req.Response.new(status: 200, body: cr)}

        req.url.path == "/v2/lib/app/blobs/#{to_string(ld)}" ->
          {req, Req.Response.new(status: 200, body: lb)}
      end
    end

    c = oci(dir, "c")

    assert {:ok, %{digest: d}} =
             Stevedore.copy("docker://reg.test/lib/app:v1", {c, "v1"},
               req_options: [adapter: adapter]
             )

    assert d == img.manifest_digest
    assert {:ok, fetched} = OCILayout.get_manifest(c, "v1")
    assert fetched.raw == img.manifest_raw
    assert OCILayout.has_blob?(c, cd) and OCILayout.has_blob?(c, ld)
  end

  # --- static tree ---

  test "static sink writes the v2 directory tree", %{tmp_dir: dir} do
    img = build_image([Stevedore.Archive.gzip("static-layer")])
    a = oci(dir, "a")
    seed(a, "v1", img)

    pub = Path.join(dir, "pub")
    static = %Static{path: pub, name: "lib/app"}
    assert {:ok, %{digest: d}} = Stevedore.copy({a, "v1"}, {static, "v1"})
    assert d == img.manifest_digest

    assert File.regular?(Path.join([pub, "v2", "lib/app", "manifests", "v1"]))
    {cd, _} = img.config
    assert File.regular?(Path.join([pub, "v2", "lib/app", "blobs", to_string(cd)]))
  end

  # --- sync + delete ---

  test "sync copies multiple jobs", %{tmp_dir: dir} do
    img = build_image([Stevedore.Archive.gzip("sync-layer")])
    a = oci(dir, "a")
    seed(a, "v1", img)

    jobs = [{{a, "v1"}, {oci(dir, "b"), "v1"}}, {{a, "v1"}, {oci(dir, "c"), "v1"}}]
    assert {:ok, results} = Stevedore.sync(jobs)
    assert Enum.all?(results, fn {_job, result} -> match?({:ok, _}, result) end)
  end

  test "delete removes a tag from an oci layout", %{tmp_dir: dir} do
    img = build_image([Stevedore.Archive.gzip("del-layer")])
    a = oci(dir, "a")
    seed(a, "v1", img)

    assert {:ok, ["v1"]} = OCILayout.list_tags(a)
    assert :ok = Stevedore.delete({a, "v1"})
    assert {:ok, []} = OCILayout.list_tags(a)
  end
end
