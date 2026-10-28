defmodule Kith.Contacts.AvatarProcessor do
  @moduledoc "Validates and renders a bounded, static contact avatar from an original image."

  @max_dimension 512
  @max_bytes 512 * 1024
  @max_source_bytes 10_000_000
  @max_pixels 40_000_000
  @version 1

  def max_bytes, do: @max_bytes

  def signature(binary, crop) do
    :crypto.hash(:sha256, [binary, :erlang.term_to_binary({@version, crop})])
    |> Base.encode16(case: :lower)
  end

  def prepare(binary, crop \\ nil) when is_binary(binary) do
    with :ok <- validate_source(binary),
         {:ok, image} <- Image.from_binary(binary, fail_on: :error),
         :ok <- validate_dimensions(image),
         {:ok, {image, _rotation}} <- Image.autorotate(image),
         {:ok, {x, y, size}} <- crop_box(image, crop),
         {:ok, image} <- Image.crop(image, x, y, size, size),
         {:ok, image} <- Image.resize(image, min(1.0, @max_dimension / size)),
         {:ok, image} <- Image.flatten(image, background: :white),
         {:ok, bytes} <- encode(image, 85) do
      {:ok,
       %{
         binary: bytes,
         signature: signature(binary, crop),
         width: Image.width(image),
         height: Image.height(image)
       }}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :invalid_image}
    end
  rescue
    _error -> {:error, :invalid_image}
  end

  @doc false
  def validate_rendition(binary) do
    with true <- byte_size(binary) <= @max_bytes,
         <<255, 216, 255, _::binary>> <- binary,
         {:ok, image} <- Image.from_binary(binary, fail_on: :error),
         true <-
           Image.width(image) == Image.height(image) and Image.width(image) <= @max_dimension,
         {:ok, _} <- Image.write(image, :memory, suffix: ".jpg") do
      :ok
    else
      _ -> {:error, :invalid_rendition}
    end
  rescue
    _ -> {:error, :invalid_rendition}
  end

  defp validate_source(binary) do
    cond do
      byte_size(binary) > @max_source_bytes -> {:error, :image_too_large}
      supported_image?(binary) -> :ok
      true -> {:error, :invalid_image}
    end
  end

  defp supported_image?(<<0xFF, 0xD8, 0xFF, _::binary>>), do: true
  defp supported_image?(<<137, "PNG", 13, 10, 26, 10, _::binary>>), do: true
  defp supported_image?(<<"GIF87a", _::binary>>), do: true
  defp supported_image?(<<"GIF89a", _::binary>>), do: true
  defp supported_image?(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: true
  defp supported_image?(_), do: false

  defp validate_dimensions(image) do
    if Image.width(image) * Image.height(image) <= @max_pixels,
      do: :ok,
      else: {:error, :image_dimensions_too_large}
  end

  defp crop_box(image, nil) do
    width = Image.width(image)
    height = Image.height(image)
    size = min(width, height)
    {:ok, {div(width - size, 2), div(height - size, 2), size}}
  end

  defp crop_box(image, %{x: x, y: y, width: width, height: height})
       when is_integer(x) and is_integer(y) and is_integer(width) and is_integer(height) do
    if valid_box?(image, x, y, width, height),
      do: {:ok, {x, y, width}},
      else: {:error, :invalid_crop}
  end

  defp crop_box(_image, _crop), do: {:error, :invalid_crop}

  defp valid_box?(image, x, y, width, height) do
    x >= 0 and y >= 0 and width > 0 and width == height and
      x + width <= Image.width(image) and y + height <= Image.height(image)
  end

  defp encode(image, quality) do
    with {:ok, bytes} <-
           Image.write(image, :memory, suffix: ".jpg", quality: quality, strip_metadata: true) do
      cond do
        byte_size(bytes) <= @max_bytes -> {:ok, bytes}
        quality > 45 -> encode(image, quality - 10)
        true -> {:error, :avatar_too_large}
      end
    end
  end
end
