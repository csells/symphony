defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub REST API client for polling issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 100

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    with {:ok, {owner, repo}} <- parse_repo(),
         {:ok, assignee_filter} <- routing_assignee_filter() do
      do_fetch_issues(owner, repo, Config.linear_active_states(), assignee_filter)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized = state_names |> Enum.map(&String.trim/1) |> Enum.uniq()

    if normalized == [] do
      {:ok, []}
    else
      with {:ok, {owner, repo}} <- parse_repo() do
        do_fetch_issues(owner, repo, normalized, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      _ ->
        with {:ok, {owner, repo}} <- parse_repo(),
             {:ok, assignee_filter} <- routing_assignee_filter() do
          fetch_issues_by_numbers(owner, repo, ids, assignee_filter)
        end
    end
  end

  @spec rest_request(atom(), String.t(), map() | nil) :: {:ok, Req.Response.t()} | {:error, term()}
  def rest_request(method, path, body \\ nil) do
    url = endpoint() <> path

    headers = [
      {"Authorization", "Bearer #{Config.github_token()}"},
      {"Accept", "application/vnd.github+json"},
      {"X-GitHub-Api-Version", "2022-11-28"}
    ]

    opts = [
      headers: headers,
      connect_options: [timeout: 30_000]
    ]

    opts = if body, do: Keyword.put(opts, :json, body), else: opts

    case method do
      :get -> Req.get(url, opts)
      :post -> Req.post(url, opts)
      :patch -> Req.patch(url, opts)
    end
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t()) :: Issue.t() | nil
  def normalize_issue_for_test(issue, repo_name) when is_map(issue) do
    normalize_issue(issue, repo_name, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t(), map() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, repo_name, assignee_filter) when is_map(issue) do
    normalize_issue(issue, repo_name, assignee_filter)
  end

  @doc false
  @spec parse_next_page_url_for_test(String.t() | nil) :: String.t() | nil
  def parse_next_page_url_for_test(link_header), do: parse_next_page_url(link_header)

  # -- Private --

  defp do_fetch_issues(owner, repo, state_names, assignee_filter) do
    github_states =
      state_names
      |> Enum.map(&normalize_github_state/1)
      |> Enum.uniq()

    github_states
    |> Enum.reduce_while({:ok, []}, fn state, {:ok, acc} ->
      case fetch_all_pages(owner, repo, state, assignee_filter) do
        {:ok, issues} -> {:cont, {:ok, acc ++ issues}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp fetch_all_pages(owner, repo, state, assignee_filter) do
    fetch_page(owner, repo, state, assignee_filter, 1, [])
  end

  defp fetch_page(owner, repo, state, assignee_filter, page, acc) do
    path = "/repos/#{owner}/#{repo}/issues?state=#{state}&per_page=#{@page_size}&page=#{page}&sort=created&direction=asc"

    case rest_request(:get, path) do
      {:ok, %{status: 200, body: body, headers: headers}} when is_list(body) ->
        issues =
          body
          |> Enum.reject(&pull_request?/1)
          |> Enum.map(&normalize_issue(&1, repo, assignee_filter))
          |> Enum.reject(&is_nil/1)

        updated_acc = acc ++ issues

        link_header = get_link_header(headers)

        case parse_next_page_url(link_header) do
          nil -> {:ok, updated_acc}
          _next_url -> fetch_page(owner, repo, state, assignee_filter, page + 1, updated_acc)
        end

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub API request failed status=#{status} body=#{inspect(body, limit: 200)}")
        {:error, {:github_api_status, status}}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")
        {:error, {:github_api_request, reason}}
    end
  end

  defp fetch_issues_by_numbers(owner, repo, issue_ids, assignee_filter) do
    results =
      Enum.reduce_while(issue_ids, {:ok, []}, fn id, {:ok, acc} ->
        fetch_single_issue(owner, repo, id, assignee_filter, acc)
      end)

    case results do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp fetch_single_issue(owner, repo, id, assignee_filter, acc) do
    path = "/repos/#{owner}/#{repo}/issues/#{id}"

    case rest_request(:get, path) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        issue = normalize_issue(body, repo, assignee_filter)
        if issue, do: {:cont, {:ok, [issue | acc]}}, else: {:cont, {:ok, acc}}

      {:ok, %{status: 404}} ->
        {:cont, {:ok, acc}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("GitHub API request failed status=#{status} body=#{inspect(body, limit: 200)}")
        {:halt, {:error, {:github_api_status, status}}}

      {:error, reason} ->
        Logger.error("GitHub API request failed: #{inspect(reason)}")
        {:halt, {:error, {:github_api_request, reason}}}
    end
  end

  defp normalize_issue(raw, repo_name, assignee_filter) when is_map(raw) do
    number = raw["number"]
    assignee = raw["assignee"]

    if is_nil(number) do
      nil
    else
      %Issue{
        id: to_string(number),
        identifier: "#{repo_name}##{number}",
        title: raw["title"],
        description: raw["body"],
        priority: nil,
        state: raw["state"],
        branch_name: nil,
        url: raw["html_url"],
        assignee_id: assignee_login(assignee),
        blocked_by: [],
        labels: extract_labels(raw),
        assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
        created_at: parse_datetime(raw["created_at"]),
        updated_at: parse_datetime(raw["updated_at"])
      }
    end
  end

  defp normalize_issue(_raw, _repo_name, _assignee_filter), do: nil

  defp pull_request?(%{"pull_request" => _}), do: true
  defp pull_request?(_), do: false

  defp assignee_login(%{"login" => login}) when is_binary(login), do: login
  defp assignee_login(_), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{"login" => login}, %{match_values: match_values})
       when is_binary(login) do
    MapSet.member?(match_values, String.downcase(login))
  end

  defp assigned_to_worker?(_assignee, _filter), do: false

  defp routing_assignee_filter do
    case Config.github_assignee() do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case String.trim(assignee) do
      "" ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([String.downcase(normalized)])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case rest_request(:get, "/user") do
      {:ok, %{status: 200, body: %{"login" => login}}} when is_binary(login) ->
        {:ok, %{configured_assignee: "me", match_values: MapSet.new([String.downcase(login)])}}

      {:ok, _} ->
        {:error, :missing_github_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} when is_binary(name) -> String.downcase(name)
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_labels(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp normalize_github_state(state) do
    case String.downcase(String.trim(state)) do
      "closed" -> "closed"
      _ -> "open"
    end
  end

  defp get_link_header(headers) when is_map(headers) do
    case Map.get(headers, "link") do
      [value | _] when is_binary(value) -> value
      _ -> nil
    end
  end

  defp get_link_header(_), do: nil

  defp parse_next_page_url(nil), do: nil

  defp parse_next_page_url(link_header) when is_binary(link_header) do
    link_header
    |> String.split(",")
    |> Enum.filter(&String.contains?(&1, "rel=\"next\""))
    |> Enum.find_value(&extract_link_url/1)
  end

  defp extract_link_url(part) do
    case Regex.run(~r/<([^>]+)>/, part) do
      [_, url] -> url
      _ -> nil
    end
  end

  defp endpoint do
    Config.github_endpoint()
  end

  defp parse_repo do
    case Config.github_repo() do
      nil ->
        {:error, :missing_github_repo}

      repo when is_binary(repo) ->
        case String.split(repo, "/", parts: 2) do
          [owner, name] when owner != "" and name != "" -> {:ok, {owner, name}}
          _ -> {:error, :invalid_github_repo}
        end
    end
  end
end
