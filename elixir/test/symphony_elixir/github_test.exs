defmodule SymphonyElixir.GitHubTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{Adapter, Client}
  alias SymphonyElixir.Linear.Issue

  defmodule FakeGitHubClient do
    def fetch_candidate_issues do
      send(self(), :gh_fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(states) do
      send(self(), {:gh_fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(issue_ids) do
      send(self(), {:gh_fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end

    def rest_request(method, path, body \\ nil) do
      send(self(), {:gh_rest_request, method, path, body})

      case Process.get({__MODULE__, :rest_result}) do
        nil -> {:ok, %{status: 200, body: %{}}}
        result -> result
      end
    end
  end

  setup do
    github_client_module = Application.get_env(:symphony_elixir, :github_client_module)

    on_exit(fn ->
      if is_nil(github_client_module) do
        Application.delete_env(:symphony_elixir, :github_client_module)
      else
        Application.put_env(:symphony_elixir, :github_client_module, github_client_module)
      end
    end)

    :ok
  end

  describe "Config: tracker_kind github" do
    test "validate! succeeds with valid github config" do
      ensure_workflow_store_running()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test123",
        tracker_project_slug: "owner/repo"
      )

      assert :ok = Config.validate!()
    end

    test "validate! fails when github token is missing" do
      ensure_workflow_store_running()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: nil,
        tracker_project_slug: "owner/repo"
      )

      # Clear env var fallback
      prev = System.get_env("GITHUB_TOKEN")
      System.delete_env("GITHUB_TOKEN")

      result = Config.validate!()
      restore_env("GITHUB_TOKEN", prev)

      assert {:error, :missing_github_token} = result
    end

    test "validate! fails when github repo is missing" do
      ensure_workflow_store_running()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test123",
        tracker_project_slug: nil
      )

      assert {:error, :missing_github_repo} = Config.validate!()
    end

    test "validate! fails when github repo has no slash" do
      ensure_workflow_store_running()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test123",
        tracker_project_slug: "just-a-repo"
      )

      assert {:error, :invalid_github_repo} = Config.validate!()
    end

    test "tracker adapter resolves to GitHub.Adapter when kind is github" do
      ensure_workflow_store_running()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test123",
        tracker_project_slug: "owner/repo"
      )

      assert Tracker.adapter() == SymphonyElixir.GitHub.Adapter
    end

    test "github_token resolves from GITHUB_TOKEN env var" do
      ensure_workflow_store_running()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: nil,
        tracker_project_slug: "owner/repo"
      )

      prev = System.get_env("GITHUB_TOKEN")
      System.put_env("GITHUB_TOKEN", "env_token_value")

      token = Config.github_token()
      restore_env("GITHUB_TOKEN", prev)

      assert token == "env_token_value"
    end
  end

  describe "Client: issue normalization" do
    test "normalizes a GitHub issue to Issue struct" do
      raw = %{
        "number" => 42,
        "title" => "Fix the bug",
        "body" => "Something is broken",
        "state" => "open",
        "html_url" => "https://github.com/owner/repo/issues/42",
        "assignee" => %{"login" => "octocat"},
        "labels" => [%{"name" => "Bug"}, %{"name" => "Urgent"}],
        "created_at" => "2025-06-15T10:30:00Z",
        "updated_at" => "2025-06-16T08:00:00Z"
      }

      issue = Client.normalize_issue_for_test(raw, "repo")

      assert %Issue{} = issue
      assert issue.id == "42"
      assert issue.identifier == "repo#42"
      assert issue.title == "Fix the bug"
      assert issue.description == "Something is broken"
      assert issue.state == "open"
      assert issue.url == "https://github.com/owner/repo/issues/42"
      assert issue.assignee_id == "octocat"
      assert issue.labels == ["bug", "urgent"]
      assert issue.priority == nil
      assert issue.blocked_by == []
      assert issue.branch_name == nil
      assert issue.assigned_to_worker == true
      assert %DateTime{} = issue.created_at
      assert %DateTime{} = issue.updated_at
    end

    test "filters out pull requests" do
      pr = %{
        "number" => 10,
        "title" => "A PR",
        "body" => "",
        "state" => "open",
        "html_url" => "https://github.com/owner/repo/pull/10",
        "pull_request" => %{"url" => "https://api.github.com/repos/owner/repo/pulls/10"},
        "assignee" => nil,
        "labels" => [],
        "created_at" => "2025-06-15T10:30:00Z",
        "updated_at" => "2025-06-15T10:30:00Z"
      }

      # PR normalization still works (filtering happens at fetch level, not normalize)
      issue = Client.normalize_issue_for_test(pr, "repo")
      assert %Issue{} = issue
    end

    test "handles nil assignee" do
      raw = %{
        "number" => 1,
        "title" => "Test",
        "body" => nil,
        "state" => "open",
        "html_url" => nil,
        "assignee" => nil,
        "labels" => [],
        "created_at" => nil,
        "updated_at" => nil
      }

      issue = Client.normalize_issue_for_test(raw, "repo")
      assert issue.assignee_id == nil
      assert issue.assigned_to_worker == true
    end

    test "assignee filter correctly marks non-matching assignee" do
      raw = %{
        "number" => 1,
        "title" => "Test",
        "body" => nil,
        "state" => "open",
        "html_url" => nil,
        "assignee" => %{"login" => "alice"},
        "labels" => [],
        "created_at" => nil,
        "updated_at" => nil
      }

      filter = %{configured_assignee: "bob", match_values: MapSet.new(["bob"])}
      issue = Client.normalize_issue_for_test(raw, "repo", filter)
      assert issue.assigned_to_worker == false
    end

    test "assignee filter matches case-insensitively" do
      raw = %{
        "number" => 1,
        "title" => "Test",
        "body" => nil,
        "state" => "open",
        "html_url" => nil,
        "assignee" => %{"login" => "Alice"},
        "labels" => [],
        "created_at" => nil,
        "updated_at" => nil
      }

      filter = %{configured_assignee: "alice", match_values: MapSet.new(["alice"])}
      issue = Client.normalize_issue_for_test(raw, "repo", filter)
      assert issue.assigned_to_worker == true
    end

    test "returns nil when number is missing" do
      raw = %{"title" => "No number", "state" => "open"}
      issue = Client.normalize_issue_for_test(raw, "repo")
      assert is_nil(issue)
    end
  end

  describe "Client: Link header pagination" do
    test "parses next page URL from Link header" do
      link = ~s(<https://api.github.com/repos/owner/repo/issues?page=2>; rel="next", <https://api.github.com/repos/owner/repo/issues?page=5>; rel="last")
      assert Client.parse_next_page_url_for_test(link) == "https://api.github.com/repos/owner/repo/issues?page=2"
    end

    test "returns nil when no next page" do
      link = ~s(<https://api.github.com/repos/owner/repo/issues?page=1>; rel="first")
      assert Client.parse_next_page_url_for_test(link) == nil
    end

    test "returns nil for nil input" do
      assert Client.parse_next_page_url_for_test(nil) == nil
    end
  end

  describe "Adapter: delegation" do
    setup do
      Application.put_env(:symphony_elixir, :github_client_module, FakeGitHubClient)
      :ok
    end

    test "fetch_candidate_issues delegates to client" do
      assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues()
      assert_received :gh_fetch_candidate_issues_called
    end

    test "fetch_issues_by_states delegates to client" do
      assert {:ok, ["open"]} = Adapter.fetch_issues_by_states(["open"])
      assert_received {:gh_fetch_issues_by_states_called, ["open"]}
    end

    test "fetch_issue_states_by_ids delegates to client" do
      assert {:ok, ["42"]} = Adapter.fetch_issue_states_by_ids(["42"])
      assert_received {:gh_fetch_issue_states_by_ids_called, ["42"]}
    end

    test "create_comment calls rest_request with correct path and body" do
      ensure_workflow_store_running()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test123",
        tracker_project_slug: "owner/repo"
      )

      assert :ok = Adapter.create_comment("42", "Nice work!")
      assert_received {:gh_rest_request, :post, "/repos/owner/repo/issues/42/comments", %{"body" => "Nice work!"}}
    end

    test "update_issue_state calls rest_request with closed state" do
      ensure_workflow_store_running()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test123",
        tracker_project_slug: "owner/repo"
      )

      assert :ok = Adapter.update_issue_state("42", "closed")
      assert_received {:gh_rest_request, :patch, "/repos/owner/repo/issues/42", %{"state" => "closed"}}
    end

    test "update_issue_state maps non-closed states to open" do
      ensure_workflow_store_running()

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "github",
        tracker_api_token: "ghp_test123",
        tracker_project_slug: "owner/repo"
      )

      assert :ok = Adapter.update_issue_state("42", "In Progress")
      assert_received {:gh_rest_request, :patch, "/repos/owner/repo/issues/42", %{"state" => "open"}}
    end
  end

  defp ensure_workflow_store_running do
    unless Process.whereis(SymphonyElixir.WorkflowStore) do
      start_supervised!(SymphonyElixir.WorkflowStore)
    end
  end
end
