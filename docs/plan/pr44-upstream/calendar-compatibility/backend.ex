defmodule CalendarCompatibility.Cldr do
  use Cldr,
    locales: ["en", "fr", "ar"],
    default_locale: "en",
    providers: [Cldr.Number, Cldr.Calendar]
end
