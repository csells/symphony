defmodule SymphonyElixir.DotenvTest do
  use ExUnit.Case

  alias SymphonyElixir.Dotenv

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "dotenv-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  describe "load/1" do
    test "loads KEY=VALUE pairs into system env", %{tmp_dir: tmp_dir} do
      env_file = Path.join(tmp_dir, ".env")
      key = "DOTENV_TEST_BASIC_#{System.unique_integer([:positive])}"
      File.write!(env_file, "#{key}=hello_world\n")

      on_exit(fn -> System.delete_env(key) end)

      assert :ok = Dotenv.load(env_file)
      assert System.get_env(key) == "hello_world"
    end

    test "does not overwrite existing env vars", %{tmp_dir: tmp_dir} do
      env_file = Path.join(tmp_dir, ".env")
      key = "DOTENV_TEST_EXISTING_#{System.unique_integer([:positive])}"
      System.put_env(key, "original")
      File.write!(env_file, "#{key}=overwritten\n")

      on_exit(fn -> System.delete_env(key) end)

      assert :ok = Dotenv.load(env_file)
      assert System.get_env(key) == "original"
    end

    test "returns {:error, :enoent} for missing file" do
      assert {:error, :enoent} = Dotenv.load("/tmp/nonexistent_dotenv_file")
    end

    test "skips blank lines and comments", %{tmp_dir: tmp_dir} do
      env_file = Path.join(tmp_dir, ".env")
      key = "DOTENV_TEST_COMMENTS_#{System.unique_integer([:positive])}"

      content = """
      # This is a comment

      #{key}=value

      # Another comment
      """

      File.write!(env_file, content)

      on_exit(fn -> System.delete_env(key) end)

      assert :ok = Dotenv.load(env_file)
      assert System.get_env(key) == "value"
    end

    test "handles double-quoted values", %{tmp_dir: tmp_dir} do
      env_file = Path.join(tmp_dir, ".env")
      key = "DOTENV_TEST_DQUOTE_#{System.unique_integer([:positive])}"
      File.write!(env_file, ~s(#{key}="hello world"\n))

      on_exit(fn -> System.delete_env(key) end)

      assert :ok = Dotenv.load(env_file)
      assert System.get_env(key) == "hello world"
    end

    test "handles single-quoted values", %{tmp_dir: tmp_dir} do
      env_file = Path.join(tmp_dir, ".env")
      key = "DOTENV_TEST_SQUOTE_#{System.unique_integer([:positive])}"
      File.write!(env_file, "#{key}='hello world'\n")

      on_exit(fn -> System.delete_env(key) end)

      assert :ok = Dotenv.load(env_file)
      assert System.get_env(key) == "hello world"
    end

    test "strips inline comments from unquoted values", %{tmp_dir: tmp_dir} do
      env_file = Path.join(tmp_dir, ".env")
      key = "DOTENV_TEST_INLINE_#{System.unique_integer([:positive])}"
      File.write!(env_file, "#{key}=value # this is a comment\n")

      on_exit(fn -> System.delete_env(key) end)

      assert :ok = Dotenv.load(env_file)
      assert System.get_env(key) == "value"
    end

    test "handles export prefix", %{tmp_dir: tmp_dir} do
      env_file = Path.join(tmp_dir, ".env")
      key = "DOTENV_TEST_EXPORT_#{System.unique_integer([:positive])}"
      File.write!(env_file, "export #{key}=exported_value\n")

      on_exit(fn -> System.delete_env(key) end)

      assert :ok = Dotenv.load(env_file)
      assert System.get_env(key) == "exported_value"
    end

    test "handles multiple variables", %{tmp_dir: tmp_dir} do
      env_file = Path.join(tmp_dir, ".env")
      key1 = "DOTENV_TEST_MULTI1_#{System.unique_integer([:positive])}"
      key2 = "DOTENV_TEST_MULTI2_#{System.unique_integer([:positive])}"

      File.write!(env_file, "#{key1}=first\n#{key2}=second\n")

      on_exit(fn ->
        System.delete_env(key1)
        System.delete_env(key2)
      end)

      assert :ok = Dotenv.load(env_file)
      assert System.get_env(key1) == "first"
      assert System.get_env(key2) == "second"
    end
  end

  describe "load_from_workflow_dir/1" do
    test "loads .env from same directory as workflow file", %{tmp_dir: tmp_dir} do
      key = "DOTENV_TEST_WFDIR_#{System.unique_integer([:positive])}"
      File.write!(Path.join(tmp_dir, ".env"), "#{key}=from_workflow_dir\n")
      workflow_path = Path.join(tmp_dir, "WORKFLOW.md")

      on_exit(fn -> System.delete_env(key) end)

      assert :ok = Dotenv.load_from_workflow_dir(workflow_path)
      assert System.get_env(key) == "from_workflow_dir"
    end

    test "returns :ok when no .env file exists", %{tmp_dir: tmp_dir} do
      workflow_path = Path.join(tmp_dir, "WORKFLOW.md")
      assert :ok = Dotenv.load_from_workflow_dir(workflow_path)
    end
  end
end
