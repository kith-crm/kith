defmodule Kith.ConfigHelpers do
  @moduledoc false

  def read_secret(env_var) do
    case System.get_env("#{env_var}_FILE") do
      nil -> System.get_env(env_var)
      file_path -> file_path |> String.trim() |> File.read!() |> String.trim()
    end
  end
end
