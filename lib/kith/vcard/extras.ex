defmodule Kith.VCard.Extras do
  @moduledoc "Retains unmapped, ungrouped vCard properties without converting their syntax."
  alias Kith.VCard.Parser

  @mapped ~w(BEGIN END VERSION UID REV PHOTO FN N NICKNAME BDAY X-KITH-BDAY ORG TITLE NOTE GENDER X-GENDER CATEGORIES EMAIL TEL ADR URL IMPP RELATED X-KITH-RELATED PRODID X-ABRELATEDNAMES X-ABLABEL X-SOCIALPROFILE X-TWITTER X-INSTAGRAM)

  def extract(raw_vcard) when is_binary(raw_vcard) do
    raw_vcard
    |> String.replace_prefix("\uFEFF", "")
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.replace(~r/\n[ \t]/, "")
    |> String.split("\n", trim: true)
    |> Enum.filter(fn line ->
      {head, value} = Parser.split_line(line)
      name = head |> Parser.split_params() |> hd()
      is_binary(value) and not String.contains?(name, ".") and String.upcase(name) not in @mapped
    end)
  end
end
