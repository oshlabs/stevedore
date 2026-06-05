defmodule Stevedore.ReferrersTest do
  use ExUnit.Case, async: true

  alias Stevedore.{Archive, Build, Digest, Image, Manifest, MediaType, Reference, Referrers}
  alias Stevedore.Transport.Static

  defp reg(name, content),
    do: %{
      name: name,
      type: :regular,
      mode: 0o644,
      size: byte_size(content),
      linkname: nil,
      content: content
    }

  defp subject_image, do: Build.image([Archive.write!([reg("f", "x")])], %{}) |> elem(1)

  describe "local registry tree (Static)" do
    @tag :tmp_dir
    test "attach sets the subject and list finds the referrer", %{tmp_dir: dir} do
      static = %Static{path: dir, name: "lib/app"}
      image = subject_image()
      {:ok, _} = Stevedore.copy(image, {static, "v1"})
      subject = Image.digest(image)

      sbom = %{
        media_type: "application/spdx+json",
        data: ~s({"spdxVersion":"SPDX-2.3"}),
        artifact_type: "application/spdx+json"
      }

      assert {:ok, artifact_digest} = Referrers.attach(static, subject, sbom)

      assert {:ok, index} = Referrers.list(static, subject)
      assert {:ok, referrers} = Manifest.manifests(index)
      assert Enum.any?(referrers, &(to_string(&1.digest) == to_string(artifact_digest)))
      assert Enum.any?(referrers, &(&1.artifact_type == "application/spdx+json"))
    end

    @tag :tmp_dir
    test "an image with no referrers lists an empty index", %{tmp_dir: dir} do
      static = %Static{path: dir, name: "lib/app"}
      image = subject_image()
      {:ok, _} = Stevedore.copy(image, {static, "v1"})

      assert {:ok, index} = Referrers.list(static, Image.digest(image))
      assert {:ok, []} = Manifest.manifests(index)
    end
  end

  describe "registry client (Registry.referrers via adapter)" do
    @digest Digest.compute("subject")
    @ref %Reference{registry: "reg.test", repository: "lib/app"}

    defp index_body(artifact_type) do
      JSON.encode!(%{
        "schemaVersion" => 2,
        "mediaType" => MediaType.oci_index(),
        "manifests" => [
          %{
            "mediaType" => MediaType.oci_manifest(),
            "size" => 2,
            "digest" => to_string(Digest.compute("art")),
            "artifactType" => artifact_type
          }
        ]
      })
    end

    test "uses the Referrers API when available" do
      adapter = fn req ->
        assert req.url.path == "/v2/lib/app/referrers/#{to_string(@digest)}"

        {req,
         Req.Response.new(
           status: 200,
           headers: [{"content-type", MediaType.oci_index()}],
           body: index_body("application/spdx+json")
         )}
      end

      assert {:ok, %{json: json}} =
               Stevedore.Registry.referrers(@ref, @digest, req_options: [adapter: adapter])

      assert [%{"artifactType" => "application/spdx+json"}] = json["manifests"]
    end

    test "falls back to the tag-schema index when the API 404s" do
      adapter = fn req ->
        cond do
          String.starts_with?(req.url.path, "/v2/lib/app/referrers/") ->
            {req, Req.Response.new(status: 404, body: ~s({"errors":[]}))}

          req.url.path == "/v2/lib/app/manifests/#{@digest.algorithm}-#{@digest.hex}" ->
            {req, Req.Response.new(status: 200, body: index_body("application/vnd.example"))}
        end
      end

      assert {:ok, %{json: json}} =
               Stevedore.Registry.referrers(@ref, @digest, req_options: [adapter: adapter])

      assert [%{"artifactType" => "application/vnd.example"}] = json["manifests"]
    end

    test "returns an empty index when neither API nor fallback exists" do
      adapter = fn req -> {req, Req.Response.new(status: 404, body: "")} end

      assert {:ok, %{json: %{"manifests" => []}}} =
               Stevedore.Registry.referrers(@ref, @digest, req_options: [adapter: adapter])
    end
  end
end
