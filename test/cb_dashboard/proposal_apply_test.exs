defmodule CBDashboard.ProposalApplyTest do
  use ExUnit.Case, async: false

  alias CBDashboard.ProposalApply

  # Each test points the dashboard's data_root + collections registry at a temp
  # dir, then restores the prior config.
  setup %{tmp_dir: dir} do
    prior = %{
      data_root: Application.get_env(:cb_dashboard, :data_root),
      sources_file: Application.get_env(:cb_dashboard, :sources_file)
    }

    on_exit(fn ->
      put_or_delete(:data_root, prior.data_root)
      put_or_delete(:sources_file, prior.sources_file)
    end)

    registry_path = Path.join(dir, "collections.json")
    File.write!(registry_path, Jason.encode!(%{"collections" => %{"foo" => "foo/beliefs.json"}}))

    sources_path = Path.join(dir, "sources.json")
    File.write!(sources_path, Jason.encode!(%{"registries" => [registry_path]}))

    foo_dir = Path.join(dir, "foo")
    File.mkdir_p!(foo_dir)

    File.write!(
      Path.join(foo_dir, "manifest.json"),
      Jason.encode!(%{"namespace" => "foo", "depends_on" => []})
    )

    File.write!(
      Path.join(foo_dir, "beliefs.json"),
      Jason.encode!([
        %{"id" => "foo:a001", "type" => "primitive", "status" => "active", "claim" => "x"}
      ])
    )

    File.mkdir_p!(Path.join(dir, "ops/dag-proposals"))
    write_manifest(dir, "p1")

    Application.put_env(:cb_dashboard, :data_root, dir)
    Application.put_env(:cb_dashboard, :sources_file, sources_path)

    {:ok, dir: dir, foo_beliefs: Path.join(foo_dir, "beliefs.json")}
  end

  @tag :tmp_dir
  test "applies mutations to the manifest's target collection, not the default graph",
       %{dir: dir, foo_beliefs: foo_beliefs} do
    assert {:ok, %{count: 1, namespace: "foo", commit: :skipped}} =
             ProposalApply.apply_approved("p1", commit?: false, broadcast?: false)

    # The collection's own beliefs.json was rewritten with the new name.
    [belief] = Jason.decode!(File.read!(foo_beliefs))
    assert belief["id"] == "foo:a001"
    assert belief["name"] == "renamed"

    # The manifest mutation is stamped applied.
    manifest = Jason.decode!(File.read!(Path.join(dir, "ops/dag-proposals/p1.json")))
    [mutation] = manifest["mutations"]
    assert mutation["applied_at"] != nil
  end

  @tag :tmp_dir
  test "nothing-to-apply when no mutation is queued", %{dir: dir} do
    # A manifest whose only mutation is already landed (applied_at set).
    write_manifest(dir, "p2", applied_at: "2026-01-01")

    assert {:error, :nothing_to_apply} =
             ProposalApply.apply_approved("p2", commit?: false, broadcast?: false)
  end

  @tag :tmp_dir
  test "commits the touched files in their git repo", %{dir: dir, foo_beliefs: foo_beliefs} do
    git(dir, ["init", "-q"])
    git(dir, ["config", "user.email", "test@example.com"])
    git(dir, ["config", "user.name", "Test"])
    git(dir, ["add", "-A"])
    git(dir, ["commit", "-q", "-m", "baseline"])

    assert {:ok, %{commit: :ok}} =
             ProposalApply.apply_approved("p1", commit?: true, broadcast?: false)

    {log, 0} = System.cmd("git", ["log", "-1", "--pretty=%s"], cd: dir)
    assert log =~ "dag: p1 — apply 1 mutation"

    # The commit actually contains the collection beliefs.json change.
    {show, 0} = System.cmd("git", ["show", "--stat", "--pretty=", "HEAD"], cd: dir)
    assert show =~ "foo/beliefs.json"
    assert foo_beliefs |> File.read!() |> Jason.decode!() |> hd() |> Map.get("name") == "renamed"
  end

  # --- helpers ---

  defp write_manifest(dir, slug, opts \\ []) do
    manifest = %{
      "slug" => slug,
      "title" => "Test #{slug}",
      "created" => "2026-06-08",
      "status" => "pending",
      "namespace" => "foo",
      "mutations" => [
        %{
          "id" => "m1",
          "type" => "set-name",
          "belief_id" => "foo:a001",
          "status" => "applied",
          "applied_at" => opts[:applied_at],
          "rationale" => "rename it",
          "after" => %{"name" => "renamed"}
        }
      ]
    }

    File.write!(Path.join(dir, "ops/dag-proposals/#{slug}.json"), Jason.encode!(manifest))
  end

  defp git(dir, args) do
    {_out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:cb_dashboard, key)
  defp put_or_delete(key, value), do: Application.put_env(:cb_dashboard, key, value)
end
