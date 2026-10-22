defmodule KithWeb.API.ContactExportControllerTest do
  use KithWeb.ConnCase, async: true

  import Kith.AccountsFixtures
  import Kith.ContactsFixtures

  alias Kith.Accounts
  alias Kith.VCard.Parser

  setup %{conn: conn} do
    user = user_fixture()
    {raw_token, _} = Accounts.generate_api_token(user)
    %{conn: put_req_header(conn, "authorization", "Bearer #{raw_token}"), user: user}
  end

  defp export(conn, contact) do
    conn = get(conn, ~p"/api/contacts/#{contact.id}/export.vcf")
    assert conn.status == 200
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "text/vcard"
    conn.resp_body
  end

  describe "GET /api/contacts/:id/export.vcf" do
    test "CDV-115: a normal contact exports as a vCard 3.0 with its birthday", %{
      conn: conn,
      user: user
    } do
      contact =
        contact_fixture(user.account_id, %{
          first_name: "Ada",
          last_name: "Export",
          birthdate: ~D[1990-06-15]
        })

      card = export(conn, contact)

      assert card =~ ~r/\ABEGIN:VCARD\r\nVERSION:3\.0\r\n/
      assert card =~ "\r\nFN:Ada Export\r\n"
      assert card =~ "\r\nN:Export;Ada;;;\r\n"
      assert card =~ "\r\nBDAY:1990-06-15\r\n"
      refute card =~ "X-KITH-BDAY"
      refute card =~ "X-APPLE-OMIT-YEAR"
      assert String.ends_with?(card, "END:VCARD\r\n")

      assert {:ok, [parsed]} = Parser.parse(card)
      assert parsed.birthdate == ~D[1990-06-15]
      refute parsed.birthdate_year_unknown
    end

    test "CDV-115: a year-unknown birthday is exported in Apple's 3.0 form and Kith's own", %{
      conn: conn,
      user: user
    } do
      contact =
        contact_fixture(user.account_id, %{
          first_name: "Bea",
          last_name: "Yearless",
          birthdate: ~D[2000-06-15],
          birthdate_year_unknown: true
        })

      card = export(conn, contact)

      # Apple Contacts and DAVx5 read this; a 3.0 BDAY must carry a year.
      assert card =~ "\r\nBDAY;X-APPLE-OMIT-YEAR=1604:1604-06-15\r\n"
      assert card =~ "\r\nX-KITH-BDAY:--0615\r\n"
      refute card =~ "2000"

      # Round trip: the export re-imports as the same year-unknown birthday.
      assert {:ok, [parsed]} = Parser.parse(card)
      assert parsed.birthdate == ~D[2000-06-15]
      assert parsed.birthdate_year_unknown
    end

    test "CDV-115: the export carries client properties retained from CardDAV (R55)", %{
      conn: conn,
      user: user
    } do
      contact = contact_fixture(user.account_id, %{first_name: "Cy", last_name: "Retained"})

      contact
      |> Ecto.Changeset.change(
        dav_vcard: %{
          "properties" => [
            %{"name" => "X-CUSTOM", "head" => "X-CUSTOM", "value" => "kept"}
          ]
        }
      )
      |> Kith.Repo.update!()

      assert export(conn, contact) =~ "\r\nX-CUSTOM:kept\r\nEND:VCARD\r\n"
    end
  end

  describe "GET /api/contacts/export.vcf" do
    test "CDV-116: the bulk export holds every contact, year-unknown birthdays included", %{
      conn: conn,
      user: user
    } do
      dee = contact_fixture(user.account_id, %{first_name: "Dee", birthdate: ~D[1985-01-02]})

      contact_fixture(user.account_id, %{
        first_name: "Eve",
        birthdate: ~D[2000-02-29],
        birthdate_year_unknown: true
      })

      conn = get(conn, ~p"/api/contacts/export.vcf")
      assert conn.status == 200
      body = conn.resp_body

      assert {:ok, parsed} = Parser.parse(body)
      by_name = Map.new(parsed, &{&1.first_name, &1})
      assert by_name["Dee"].birthdate == ~D[1985-01-02]
      refute by_name["Dee"].birthdate_year_unknown
      assert by_name["Eve"].birthdate == ~D[2000-02-29]
      assert by_name["Eve"].birthdate_year_unknown
      assert body =~ "\r\nBDAY;X-APPLE-OMIT-YEAR=1604:1604-02-29\r\n"

      # `ids[]` selects contacts.
      body =
        build_conn()
        |> put_req_header("authorization", hd(get_req_header(conn, "authorization")))
        |> get(~p"/api/contacts/export.vcf?#{[ids: [dee.id]]}")
        |> Map.fetch!(:resp_body)

      assert {:ok, [%{first_name: "Dee"}]} = Parser.parse(body)
    end
  end

  describe "Apple's year-omitted BDAY" do
    test "CDV-115: X-APPLE-OMIT-YEAR and the 1604 year parse as year-unknown" do
      for line <- [
            "BDAY;X-APPLE-OMIT-YEAR=1604:1604-06-15",
            "BDAY;x-apple-omit-year=1604:16040615",
            "BDAY:1604-06-15"
          ] do
        {:ok, [parsed]} =
          Parser.parse("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:A\r\n#{line}\r\nEND:VCARD\r\n")

        assert {parsed.birthdate, parsed.birthdate_year_unknown} == {~D[2000-06-15], true},
               line
      end

      # A real year stays a real year, even with the parameter naming another year.
      {:ok, [parsed]} =
        Parser.parse(
          "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:A\r\nBDAY;X-APPLE-OMIT-YEAR=1604:1990-06-15\r\nEND:VCARD\r\n"
        )

      assert {parsed.birthdate, parsed.birthdate_year_unknown} == {~D[1990-06-15], false}
    end

    test "CDV-115: the DAV adapter keeps 4.0 --MMDD and round-trips the 3.0 form", %{user: user} do
      contact =
        contact_fixture(user.account_id, %{
          first_name: "Flo",
          birthdate: ~D[2000-12-10],
          birthdate_year_unknown: true
        })

      contact = Kith.Repo.get!(Kith.Contacts.Contact, contact.id)
      v40 = Kith.DAV.VCardAdapter.contact_to_vcard(contact, version: :v40)
      assert v40 =~ "\r\nBDAY:--1210\r\n"
      refute v40 =~ "1604"

      v30 = Kith.DAV.VCardAdapter.contact_to_vcard(contact, version: :v30)
      assert v30 =~ "\r\nBDAY;X-APPLE-OMIT-YEAR=1604:1604-12-10\r\n"

      {attrs, _nested} = Kith.DAV.VCardAdapter.vcard_to_attrs(v30)
      assert {attrs["birthdate"], attrs["birthdate_year_unknown"]} == {"2000-12-10", true}
    end
  end
end
