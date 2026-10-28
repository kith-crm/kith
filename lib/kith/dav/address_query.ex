defmodule Kith.DAV.AddressQuery do
  @moduledoc """
  Evaluates a CardDAV `addressbook-query` filter (RFC 6352 §10.5) against the
  vCard text a member is served as, so any property, parameter and prefix the
  client sees can be filtered on.

  The filter comes from `Kith.DAV.XMLParser.parse_report/1`.
  """

  @match_types ["equals", "contains", "starts-with", "ends-with"]

  # RFC 6352 §8.3: both casemap collations MUST be supported
  @collations ["i;ascii-casemap", "i;unicode-casemap"]

  @doc """
  Checks the filter only uses what this server implements.

  Returns `:ok`, `{:error, :supported_collation}` or `{:error, :supported_filter}`
  (the RFC 6352 §8.6 preconditions).
  """
  def validate(%{test: test, prop_filters: prop_filters}) do
    text_matches =
      Enum.flat_map(prop_filters, fn pf ->
        pf.text_matches ++ for(%{text_match: %{} = tm} <- pf.param_filters, do: tm)
      end)

    cond do
      Enum.any?(text_matches, &(&1.collation not in @collations)) ->
        {:error, :supported_collation}

      test not in ["anyof", "allof"] or
        Enum.any?(prop_filters, &(&1.test not in ["anyof", "allof"] or &1.name == "")) or
        Enum.any?(prop_filters, fn pf -> Enum.any?(pf.param_filters, &(&1.name == "")) end) or
          Enum.any?(text_matches, &(&1.match_type not in @match_types)) ->
        {:error, :supported_filter}

      true ->
        :ok
    end
  end

  @doc "True when the vCard text satisfies the (validated) filter. No prop-filter matches all."
  def matches?(_vcard, %{prop_filters: []}), do: true

  def matches?(vcard, %{test: test, prop_filters: prop_filters}) do
    properties = properties(vcard)
    apply_test(test, prop_filters, &prop_filter_matches?(properties, &1))
  end

  # RFC 6352 §10.5.1: is-not-defined matches an absent property; an empty
  # prop-filter a present one; otherwise some instance of the property must
  # satisfy the prop-filter's text-match and param-filter tests.
  defp prop_filter_matches?(properties, pf) do
    instances = Enum.filter(properties, &(&1.name == pf.name))

    cond do
      pf.is_not_defined ->
        instances == []

      pf.text_matches == [] and pf.param_filters == [] ->
        instances != []

      true ->
        tests =
          Enum.map(pf.text_matches, &{:text, &1}) ++ Enum.map(pf.param_filters, &{:param, &1})

        Enum.any?(instances, fn instance ->
          apply_test(pf.test, tests, &instance_matches?(instance, &1))
        end)
    end
  end

  defp instance_matches?(instance, {:text, tm}), do: text_matches?(instance.value, tm)

  defp instance_matches?(instance, {:param, pf}) do
    values = Map.get(instance.params, pf.name)

    cond do
      pf.is_not_defined -> values == nil
      values == nil -> false
      pf.text_match == nil -> true
      true -> Enum.any?(values, &text_matches?(&1, pf.text_match))
    end
  end

  defp apply_test("allof", items, fun), do: Enum.all?(items, fun)
  defp apply_test(_anyof, items, fun), do: Enum.any?(items, fun)

  defp text_matches?(value, %{text: text, collation: collation, negate: negate} = tm) do
    fold = fn s ->
      if collation == "i;ascii-casemap", do: String.downcase(s, :ascii), else: String.downcase(s)
    end

    result = compare(fold.(value), fold.(text), tm.match_type)
    if negate, do: not result, else: result
  end

  defp compare(value, text, "equals"), do: value == text
  defp compare(value, text, "starts-with"), do: String.starts_with?(value, text)
  defp compare(value, text, "ends-with"), do: String.ends_with?(value, text)
  defp compare(value, text, "contains"), do: String.contains?(value, text)

  # Unfolded content lines as `%{name, params: %{NAME => [values]}, value}`,
  # without the group prefix, values unescaped (RFC 6350 §3.3, §3.4).
  defp properties(vcard) do
    vcard
    |> String.replace(~r/\r?\n[ \t]/, "")
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.flat_map(&property/1)
  end

  defp property(line) do
    case Regex.run(
           ~r/\A(?:[A-Za-z0-9-]+\.)?([A-Za-z0-9-]+)((?:;(?:[^:;"]|"[^"]*")*)*):(.*)\z/s,
           line
         ) do
      [_, name, params, value] ->
        [%{name: String.upcase(name), params: params(params), value: unescape(value)}]

      _ ->
        []
    end
  end

  defp params(""), do: %{}

  defp params(params) do
    ~r/;([A-Za-z0-9-]+)(?:=((?:[^;"]|"[^"]*")*))?/
    |> Regex.scan(params)
    |> Enum.reduce(%{}, fn match, acc ->
      name = match |> Enum.at(1) |> String.upcase()
      values = match |> Enum.at(2, "") |> param_values()
      Map.update(acc, name, values, &(&1 ++ values))
    end)
  end

  defp param_values(raw) do
    ~r/"([^"]*)"|([^,"]+)/
    |> Regex.scan(raw)
    |> Enum.map(fn
      [_, quoted] -> quoted
      [_, "", plain] -> plain
    end)
  end

  defp unescape(value) do
    Regex.replace(~r/\\([\\,;nN])/, value, fn
      _, c when c in ["n", "N"] -> "\n"
      _, c -> c
    end)
  end
end
