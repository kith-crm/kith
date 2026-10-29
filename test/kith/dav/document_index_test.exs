defmodule Kith.DAV.DocumentIndexTest do
  use ExUnit.Case, async: true
  alias Kith.DAV.DocumentIndex

  test "large alternate queues consume each occurrence once without changing identity" do
    entries = Enum.map(1..50_000, &%{id: &1, value: rem(&1, 7)})

    index =
      DocumentIndex.new(entries, %{
        id: fn entry -> [entry.id] end,
        value: fn entry -> [entry.value] end
      })

    index =
      Enum.reduce(Enum.reverse(entries), index, fn expected, index ->
        {matched, index} =
          DocumentIndex.take_first(index, [{:id, expected.id}, {:value, expected.value}])

        assert matched == expected
        index
      end)

    assert DocumentIndex.remaining(index) == []

    Enum.each(0..6, fn value ->
      assert {nil, _index} = DocumentIndex.take_first(index, [{:value, value}])
    end)
  end

  test "semantic fallback preserves source order and leaves unmatched occurrences ordered" do
    entries = [%{id: 1, kind: "home"}, %{id: 2, kind: "work"}, %{id: 3, kind: "home"}]
    index = DocumentIndex.new(entries, %{kind: fn entry -> [entry.kind] end})

    assert {%{id: 1}, index} =
             DocumentIndex.take_first(index, [{:kind, "missing"}, {:kind, "home"}])

    assert DocumentIndex.remaining(index) == Enum.drop(entries, 1)
    assert {%{id: 3}, index} = DocumentIndex.take_first(index, [{:kind, "home"}])
    assert DocumentIndex.remaining(index) == [%{id: 2, kind: "work"}]
  end
end
