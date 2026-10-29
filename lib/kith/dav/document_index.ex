defmodule Kith.DAV.DocumentIndex do
  @moduledoc false

  # Each item is consumed once, while stale references in alternate queues are
  # discarded lazily. Matching and ordered leftovers avoid list scans/deletion.
  def new(entries, definitions) do
    indices = Map.new(definitions, fn {name, _key_fun} -> {name, %{}} end)
    initial = %{entries: List.to_tuple(entries), indices: indices, used: MapSet.new()}

    entries
    |> Enum.with_index()
    |> Enum.reduce(initial, &index_entry(&1, &2, definitions))
  end

  def take_first(index, keys) do
    Enum.reduce_while(keys, {nil, index}, fn {name, key}, {_entry, index} ->
      case take(index, name, key) do
        {nil, index} -> {:cont, {nil, index}}
        result -> {:halt, result}
      end
    end)
  end

  def contains?(index, name, key), do: Map.has_key?(index.indices[name], key)

  def remaining(index) do
    index.entries
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reject(fn {_entry, position} -> MapSet.member?(index.used, position) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp index_entry({entry, position}, index, definitions) do
    indices =
      Enum.reduce(definitions, index.indices, fn {name, key_fun}, indices ->
        keys = key_fun.(entry)
        bucket = Enum.reduce(keys, indices[name], &append_key(&1, &2, position))
        Map.put(indices, name, bucket)
      end)

    %{index | indices: indices}
  end

  defp append_key(key, bucket, position),
    do: Map.update(bucket, key, :queue.in(position, :queue.new()), &:queue.in(position, &1))

  defp take(index, name, key) do
    queue = Map.get(index.indices[name], key, :queue.new())

    case :queue.out(queue) do
      {:empty, _} ->
        {nil, index}

      {{:value, position}, rest} ->
        index = put_in(index, [:indices, name, key], rest)
        consume(index, name, key, position)
    end
  end

  defp consume(index, name, key, position) do
    if MapSet.member?(index.used, position) do
      take(index, name, key)
    else
      {elem(index.entries, position), %{index | used: MapSet.put(index.used, position)}}
    end
  end
end
