defmodule Macus.PrivatePath do
  @moduledoc """
  Owner-private path checks for Macus state beneath the selected state
  directory. Checks use `lstat`, so a symbolic link is never followed and
  never accepted. Nothing is created or modified.

  A private directory belongs to the verified owner, has mode 0700 and
  sits below ancestors that only the owner or root can write (root-owned
  sticky directories such as `/private/tmp` are accepted). A private entry
  belongs to the owner and has mode 0600.

  `{:error, :enoent}` is returned only when the checked directory or entry
  itself is absent; every other failure, including an unsafe or missing
  ancestor, is `{:error, :unsafe}`.
  """

  import Bitwise

  @type result :: :ok | {:error, :enoent | :unsafe}

  @doc "Checks that `path` is an owner-private directory with safe ancestors."
  @spec private_dir(String.t(), non_neg_integer()) :: result()
  def private_dir(path, uid) when is_binary(path) and is_integer(uid) do
    path = system_alias(path)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: ^uid, mode: mode}}
      when band(mode, 0o777) == 0o700 ->
        safe_ancestors(Path.dirname(path), uid)

      {:error, :enoent} ->
        {:error, :enoent}

      _ ->
        {:error, :unsafe}
    end
  end

  @doc """
  Checks that `path` is an owner-private entry of `type` (`:regular` or
  `:socket`) with mode 0600. Its directory is not checked; use
  `private_dir/2` for that.
  """
  @spec private_entry(String.t(), non_neg_integer(), :regular | :socket) :: result()
  def private_entry(path, uid, type) when is_binary(path) and is_integer(uid) do
    case File.lstat(system_alias(path)) do
      {:ok, %File.Stat{uid: ^uid, mode: mode}} ->
        if band(mode, 0o170000) == file_type(type) and band(mode, 0o777) == 0o600,
          do: :ok,
          else: {:error, :unsafe}

      {:error, :enoent} ->
        {:error, :enoent}

      _ ->
        {:error, :unsafe}
    end
  end

  defp file_type(:regular), do: 0o100000
  defp file_type(:socket), do: 0o140000

  @doc "Checks every ancestor from `path` up to `/`."
  @spec safe_ancestors(String.t(), non_neg_integer()) :: :ok | {:error, :unsafe}
  def safe_ancestors("/", _uid), do: :ok

  def safe_ancestors(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, uid: owner, mode: mode}} ->
        sticky_system = owner == 0 and band(mode, 0o1000) != 0

        if owner in [0, uid] and (band(mode, 0o022) == 0 or sticky_system),
          do: safe_ancestors(Path.dirname(path), uid),
          else: {:error, :unsafe}

      _ ->
        {:error, :unsafe}
    end
  end

  @doc """
  Rewrites the macOS `/var` and `/tmp` symbolic links to their `/private`
  destinations when the links point exactly there, so `lstat` checks see the
  real directories.
  """
  @spec system_alias(String.t()) :: String.t()
  def system_alias(path) do
    Enum.reduce([{"/var", "/private/var"}, {"/tmp", "/private/tmp"}], path, fn
      {alias_path, destination}, path ->
        if String.starts_with?(path, alias_path <> "/") and alias_to?(alias_path, destination) do
          destination <> String.replace_prefix(path, alias_path, "")
        else
          path
        end
    end)
  end

  defp alias_to?(alias_path, destination) do
    case File.read_link(alias_path) do
      {:ok, target} -> Path.expand(target, Path.dirname(alias_path)) == destination
      _ -> false
    end
  end
end
