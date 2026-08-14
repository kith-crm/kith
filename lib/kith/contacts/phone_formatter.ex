defmodule Kith.Contacts.PhoneFormatter do
  @moduledoc """
  Phone number normalization (E.164 for storage) and display formatting.

  Storage form is E.164 when the value can be parsed as a valid international
  number — either because it carries a `+` country-code prefix, or because the
  caller supplies a `default_region` (ISO 3166-1 alpha-2) for bare numbers.
  Unparseable input is returned trimmed-but-otherwise-unchanged so user data
  is never silently destroyed.

  Display formatting (`format/2`) reads the account's `phone_format`
  preference and renders the stored value via the `ExPhoneNumber`
  (libphonenumber) library. The phone's country code (carried in the stored
  E.164 value) determines national-format conventions; the account's region
  is not consulted at display time. Unparseable stored values pass through
  unchanged.

  **Contributors:** any UI surface that displays a phone number for a human
  must call `format/2` with the account's `phone_format` setting, otherwise
  the user's display preference is silently ignored. API/JSON responses are
  exempt — those return the canonical E.164 storage value.
  """

  alias ExPhoneNumber

  @typedoc "ISO 3166-1 alpha-2 region code or `nil` to skip bare-number parsing."
  @type region :: String.t() | nil

  @doc """
  Normalize a phone number for storage.

  Equivalent to `normalize/2` with no default region — bare numbers (without
  a `+` prefix) are returned trimmed-only. Use the 2-arity form from import
  paths that know the user's preferred region.
  """
  @spec normalize(String.t() | nil) :: {:ok, String.t() | nil}
  def normalize(value), do: normalize(value, nil)

  @doc """
  Normalize a phone number to E.164 for storage.

    * `value` — raw user / import input.
    * `default_region` — ISO 3166-1 alpha-2 region (e.g. `"US"`, `"FR"`) used
      to parse bare numbers without a `+` prefix. Pass `nil` to leave bare
      numbers unchanged (only `+`-prefixed input is parsed).

  Returns `{:ok, normalized}` where `normalized` is the canonical E.164 form,
  the original trimmed string if parsing fails, or `nil` for blank input.
  """
  @spec normalize(String.t() | nil, region) :: {:ok, String.t() | nil}
  def normalize(nil, _), do: {:ok, nil}
  def normalize("", _), do: {:ok, nil}

  def normalize(value, default_region) when is_binary(value) do
    trimmed = String.trim(value)
    has_plus = String.starts_with?(trimmed, "+")
    region = if has_plus, do: nil, else: default_region

    cond do
      trimmed == "" ->
        {:ok, nil}

      not has_plus and is_nil(region) ->
        {:ok, trimmed}

      true ->
        parse_to_e164(trimmed, region)
    end
  end

  defp parse_to_e164(trimmed, region) do
    # Format-on-parse, not format-on-valid. libphonenumber's `is_valid_number?`
    # rejects valid-but-uncommon inputs (NANP "555" test prefixes, recently
    # allocated area codes, vanity numbers, region-specific oddities). Users'
    # personal-CRM data is exactly that messy; refusing to canonicalize
    # parseable-but-not-strictly-valid numbers re-introduces the mixed-storage
    # problem detection is supposed to solve. We keep the parse check so that
    # truly malformed input (`"garbage"`, `"+"`) round-trips unchanged.
    case ExPhoneNumber.parse(trimmed, region) do
      {:ok, parsed} -> {:ok, ExPhoneNumber.format(parsed, :e164)}
      {:error, _} -> {:ok, trimmed}
    end
  end

  @doc """
  Map an account `locale` to a best-guess ISO 3166-1 alpha-2 region code.

  Returns `nil` when the locale doesn't map cleanly — callers should treat
  `nil` as "don't normalize bare numbers" and prompt the user to pick.
  """
  @spec region_for_locale(String.t() | nil) :: region
  def region_for_locale(nil), do: nil

  def region_for_locale(locale) when is_binary(locale) do
    locale
    |> String.split(~r/[-_]/)
    |> List.first()
    |> String.downcase()
    |> language_to_region()
  end

  defp language_to_region("en"), do: "US"
  defp language_to_region("fr"), do: "FR"
  defp language_to_region("de"), do: "DE"
  defp language_to_region("es"), do: "ES"
  defp language_to_region("it"), do: "IT"
  defp language_to_region("pt"), do: "PT"
  defp language_to_region("nl"), do: "NL"
  defp language_to_region("ru"), do: "RU"
  defp language_to_region("ja"), do: "JP"
  defp language_to_region("zh"), do: "CN"
  defp language_to_region("ko"), do: "KR"
  defp language_to_region("ar"), do: "SA"
  defp language_to_region(_), do: nil

  @doc """
  List every parser-supported region with its localized country name and
  calling code, sorted by display name.

  Returns `[{region_code, label}]` — e.g.
  `[{"AF", "Afghanistan (+93)"}, {"AL", "Albania (+355)"}, ...]`

  The intersection of `ExPhoneNumber.Metadata.get_supported_regions/0`
  (regions the parser can actually handle) and
  `Cldr.Territory.country_codes/1` (real ISO 3166-1 countries, not
  continents) is computed once per locale and cached via `:persistent_term`
  to keep wizard mounts fast.
  """
  @spec supported_regions(String.t()) :: [{String.t(), String.t()}]
  def supported_regions(locale \\ "en") do
    case :persistent_term.get({__MODULE__, :regions, locale}, :miss) do
      :miss ->
        regions = build_supported_regions(locale)
        :persistent_term.put({__MODULE__, :regions, locale}, regions)
        regions

      regions ->
        regions
    end
  end

  defp build_supported_regions(locale) do
    parser_supported =
      ExPhoneNumber.Metadata.get_supported_regions()
      |> MapSet.new()

    Cldr.Territory.country_codes(as: :binary)
    |> Enum.filter(&MapSet.member?(parser_supported, &1))
    |> Enum.map(&{&1, region_label(&1, locale)})
    |> Enum.sort_by(fn {_code, label} -> label end, :asc)
  end

  defp region_label(code, locale) do
    name =
      case Kith.Cldr.Territory.from_territory_code(
             String.to_atom(code),
             locale: locale,
             style: :standard
           ) do
        {:ok, localized} -> localized
        _ -> code
      end

    calling_code = ExPhoneNumber.Metadata.get_country_code_for_region_code(code)
    "#{name} (+#{calling_code})"
  end

  @doc """
  Format a stored phone number for display according to the account preference.

  ## Formats

    * `"e164"` — E.164 as-is: `+12025550100`
    * `"national"` — US/Canada national: `(202) 555-0100`
    * `"international"` — International: `+1 202-555-0100`
    * `"raw"` — return the stored value unchanged
  """
  def format(nil, _format), do: nil
  def format("", _format), do: nil
  def format(phone, "raw"), do: phone
  def format(phone, "e164"), do: phone
  def format(phone, "national"), do: render(phone, :national)
  def format(phone, "international"), do: render(phone, :international)
  def format(phone, _), do: phone

  defp render(value, phone_number_format) do
    # phone_number_format is an ExPhoneNumber atom: :national or :international.
    case ExPhoneNumber.parse(value, nil) do
      {:ok, parsed} -> ExPhoneNumber.format(parsed, phone_number_format)
      {:error, _} -> value
    end
  end
end
