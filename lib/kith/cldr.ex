defmodule Kith.Cldr do
  @moduledoc """
  CLDR backend for locale-aware formatting.
  Provides date/time and number formatting across locales.
  """

  use Cldr,
    locales: ["en", "ar", "fr", "de", "es", "pt", "ja", "zh"],
    default_locale: "en",
    providers: [Cldr.Number, Cldr.DateTime, Cldr.Calendar, Cldr.Territory]
end
