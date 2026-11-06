defmodule Kith.Contacts.AvatarProcessorTest do
  use ExUnit.Case, async: true
  alias Kith.Contacts.AvatarProcessor
  import Kith.AvatarFixtures

  test "large portrait and landscape images become bounded square JPEGs" do
    for {width, height} <- [{1600, 900}, {900, 1600}] do
      assert {:ok, result} = AvatarProcessor.prepare(image_binary(width: width, height: height))
      assert byte_size(result.binary) <= 512 * 1024
      assert <<255, 216, 255, _::binary>> = result.binary
      image = Image.from_binary!(result.binary)
      assert Image.width(image) == 512
      assert Image.height(image) == 512
    end
  end

  test "small originals are not upscaled" do
    assert {:ok, result} = AvatarProcessor.prepare(image_binary(width: 30, height: 80))
    assert result.width == 30
    assert result.height == 30
  end

  test "a requested crop changes the represented region" do
    left = Image.new!(100, 100, color: [255, 0, 0])
    right = Image.new!(100, 100, color: [0, 0, 255])
    image = Vix.Vips.Operation.join!(left, right, :VIPS_DIRECTION_HORIZONTAL)
    original = Image.write!(image, :memory, suffix: ".png")
    crop = %{x: 100, y: 0, width: 100, height: 100}
    assert {:ok, result} = AvatarProcessor.prepare(original, crop)
    assert {:ok, [red, _green, blue]} = Image.get_pixel(Image.from_binary!(result.binary), 50, 50)
    assert blue > red + 100
  end

  test "EXIF orientation is applied before the chosen crop" do
    top = Image.new!(100, 100, color: [255, 0, 0])
    bottom = Image.new!(100, 100, color: [0, 0, 255])
    image = Vix.Vips.Operation.join!(top, bottom, :VIPS_DIRECTION_VERTICAL)

    {:ok, rotated} =
      Vix.Vips.Image.mutate(image, fn mutable ->
        Vix.Vips.MutableImage.set(mutable, "orientation", :gint, 6)
      end)

    original = Image.write!(rotated, :memory, suffix: ".jpg")
    # 90 degree clockwise orientation puts the blue bottom half on the left.
    assert {:ok, result} =
             AvatarProcessor.prepare(original, %{x: 0, y: 0, width: 100, height: 100})

    assert {:ok, [red, _green, blue]} = Image.get_pixel(Image.from_binary!(result.binary), 50, 50)
    assert blue > red + 100

    assert {:error, _} =
             Vix.Vips.Image.header_value(Image.from_binary!(result.binary), "exif-data")
  end

  test "transparency is flattened on white" do
    image = Image.new!(60, 60, color: [0, 0, 255]) |> Image.add_alpha!(:transparent)
    original = Image.write!(image, :memory, suffix: ".png")
    assert {:ok, result} = AvatarProcessor.prepare(original)
    assert {:ok, [red, green, blue]} = Image.get_pixel(Image.from_binary!(result.binary), 20, 20)
    assert min(red, min(green, blue)) > 245
  end

  test "only the first frame of an animated GIF is used" do
    first = Image.new!(50, 50, color: [255, 0, 0])
    second = Image.new!(50, 50, color: [0, 0, 255])
    image = Vix.Vips.Operation.join!(first, second, :VIPS_DIRECTION_VERTICAL)

    {:ok, animated} =
      Vix.Vips.Image.mutate(image, fn mutable ->
        Vix.Vips.MutableImage.set(mutable, "page-height", :gint, 50)
      end)

    bytes = Image.write!(animated, :memory, suffix: ".gif")
    assert {:ok, result} = AvatarProcessor.prepare(bytes)
    assert {:ok, [red, _green, blue]} = Image.get_pixel(Image.from_binary!(result.binary), 20, 20)
    assert red > blue + 100
    assert result.width == 50
  end

  test "decoded dimensions are capped even when compressed source is small" do
    original = image_binary(width: 10_000, height: 5_000)
    assert byte_size(original) < 10_000_000
    assert {:error, :image_dimensions_too_large} = AvatarProcessor.prepare(original)
  end

  test "source byte limits are enforced before image decoding" do
    assert {:error, :image_too_large} = AvatarProcessor.prepare(:binary.copy(<<0>>, 10_000_001))
  end

  test "bad bytes and invalid crop coordinates are rejected" do
    assert {:error, :invalid_image} = AvatarProcessor.prepare("not an image")
    original = image_binary(width: 100, height: 80)

    for crop <- [
          %{x: -1, y: 0, width: 20, height: 20},
          %{x: 90, y: 0, width: 20, height: 20},
          %{x: 0, y: 0, width: 20, height: 30},
          %{x: 0.5, y: 0, width: 20, height: 20}
        ] do
      assert {:error, :invalid_crop} = AvatarProcessor.prepare(original, crop)
    end
  end

  test "supported non-JPEG sources produce static JPEGs" do
    for suffix <- [".png", ".webp", ".gif"] do
      assert {:ok, result} = AvatarProcessor.prepare(image_binary(suffix: suffix))
      assert <<255, 216, 255, _::binary>> = result.binary
    end
  end
end
