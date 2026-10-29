defmodule Kith.DAV.DocumentType do
  @moduledoc """
  Lossless compact PostgreSQL representation with a rich map at the app boundary.

  Old rich JSON documents remain readable. Packing is a storage codec only;
  readers and writers never maintain a second authoritative document.
  """
  use Ecto.Type
  alias Kith.DAV.Document

  def type, do: :map
  def cast(value) when is_map(value), do: {:ok, value}
  def cast(_), do: :error
  def load(value) when is_map(value), do: {:ok, Document.unpack(value)}
  def load(_), do: :error
  def dump(value) when is_map(value), do: {:ok, Document.pack(value)}
  def dump(_), do: :error
end
