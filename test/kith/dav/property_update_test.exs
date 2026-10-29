defmodule Kith.DAV.PropertyUpdateTest do
  use ExUnit.Case, async: true

  alias Kith.DAV.{PropertyUpdate, XMLParser}

  test "a protected failure prevents all other instructions, including earlier no-ops" do
    instructions =
      parse("""
      <remove><prop><x:absent/></prop></remove>
      <set><prop><displayname>Changed book</displayname></prop></set>
      <remove><prop><x:absent/></prop></remove>
      """)

    assert PropertyUpdate.evaluate(instructions) == [
             %{property: {"urn:client", "absent"}, status: 424, error: nil},
             %{property: :displayname, status: 403, error: :cannot_modify_protected_property},
             %{property: {"urn:client", "absent"}, status: 424, error: nil}
           ]
  end

  test "unsupported dead-property storage fails without claiming live protection" do
    instructions =
      parse("""
      <set><prop><x:custom>Client value</x:custom><getetag>forged</getetag></prop></set>
      """)

    assert PropertyUpdate.evaluate(instructions) == [
             %{property: {"urn:client", "custom"}, status: 403, error: nil},
             %{property: :getetag, status: 424, error: nil}
           ]
  end

  test "removing absent dead properties is successful and needs no persistence" do
    instructions = parse("<remove><prop><x:absent/><x:absent/></prop></remove>")

    assert PropertyUpdate.evaluate(instructions) ==
             List.duplicate(%{property: {"urn:client", "absent"}, status: 200, error: nil}, 2)
  end

  test "set and remove cannot change protected protocol properties" do
    for operation <- ["set", "remove"],
        property <- ["getetag", "displayname", "acl", "supported-privilege-set"] do
      [result] =
        parse("<#{operation}><prop><#{property}/></prop></#{operation}>")
        |> PropertyUpdate.evaluate()

      assert result.status == 403
      assert result.error == :cannot_modify_protected_property
    end
  end

  test "a client namespace with a live-property local name is a distinct property" do
    [result] =
      parse("<set><prop><x:getetag>Client value</x:getetag></prop></set>")
      |> PropertyUpdate.evaluate()

    assert result == %{property: {"urn:client", "getetag"}, status: 403, error: nil}
  end

  defp parse(instructions) do
    {:ok, result} =
      XMLParser.parse_proppatch(
        ~s(<propertyupdate xmlns="DAV:" xmlns:x="urn:client">#{instructions}</propertyupdate>)
      )

    result
  end
end
