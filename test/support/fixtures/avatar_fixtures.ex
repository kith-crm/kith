defmodule Kith.AvatarFixtures do
  @moduledoc false

  def image_binary(opts \\ []) do
    width = Keyword.get(opts, :width, 640)
    height = Keyword.get(opts, :height, 480)
    color = Keyword.get(opts, :color, [180, 40, 30])

    Image.new!(width, height, color: color)
    |> Image.write!(:memory, suffix: Keyword.get(opts, :suffix, ".png"))
  end

  def stored_photo(contact, opts \\ []) do
    binary = image_binary(opts)
    key = Kith.Storage.generate_key(contact.account_id, "photos", "source.png")
    {:ok, _} = Kith.Storage.upload_binary(binary, key)

    {:ok, photo} =
      Kith.Contacts.create_photo(contact, %{
        storage_key: key,
        file_name: "source.png",
        content_type: "image/png",
        file_size: byte_size(binary)
      })

    {photo, binary}
  end
end
