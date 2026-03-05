defmodule SymphonyElixir.GitHub.Adapter do
  @moduledoc """
  GitHub Issues tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, GitHub.Client}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    {owner, repo} = parse_repo!()
    path = "/repos/#{owner}/#{repo}/issues/#{issue_id}/comments"

    case client_module().rest_request(:post, path, %{"body" => body}) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status}} -> {:error, {:github_comment_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    {owner, repo} = parse_repo!()
    github_state = map_to_github_state(state_name)
    path = "/repos/#{owner}/#{repo}/issues/#{issue_id}"

    case client_module().rest_request(:patch, path, %{"state" => github_state}) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status}} -> {:error, {:github_state_update_failed, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :github_client_module, Client)
  end

  defp parse_repo! do
    [owner, repo] = String.split(Config.github_repo(), "/", parts: 2)
    {owner, repo}
  end

  defp map_to_github_state(state_name) do
    case String.downcase(String.trim(state_name)) do
      "closed" -> "closed"
      _ -> "open"
    end
  end
end
