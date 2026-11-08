defmodule KithWeb.DAV.RoundTripIntegrityTest do
  use KithWeb.ConnCase, async: true
  import KithWeb.DAV.TestHelpers
  import Kith.ContactsFixtures
  alias Kith.{Contacts, Repo}
  alias Kith.DAV.{Store, VCardAdapter}

  setup :setup_dav_user

  test "DAVx5 discovery advertises editable address-book content", c do
    response =
      authed_dav(
        c,
        "PROPFIND",
        "/dav/addressbooks/default/",
        "<d:propfind xmlns:d=\"DAV:\"><d:prop><d:current-user-privilege-set/></d:prop></d:propfind>"
      )

    assert response.status == 207
    assert response.resp_body =~ "<d:write-content/>"
  end

  for {version, original, replacement} <- [
        {"3.0", "1990-01-02", "1991-02-03"},
        {"4.0", "19900102", "19910203"},
        {"4.0", "19900102", "--0203"},
        {"3.0", "--0102", "--0203"},
        {"4.0", "--0102", "--0203"}
      ] do
    test "DAVx5-style #{version} birthday edit #{original} to #{replacement} survives a conditional PUT and GET",
         c do
      contact =
        contact_fixture(c.account_id, %{
          birthdate: ~D[1990-01-02],
          birthdate_year_unknown: unquote(original) == "--0102"
        })

      path = contact_path(contact)
      conn = put_req_header(c.conn, "accept", "text/vcard; version=#{unquote(version)}")
      downloaded = authed_dav(%{c | conn: conn}, "GET", path)
      assert downloaded.status == 200
      [etag] = get_resp_header(downloaded, "etag")
      assert downloaded.resp_body =~ "BDAY:#{unquote(original)}"

      edited =
        String.replace(
          downloaded.resp_body,
          "BDAY:#{unquote(original)}",
          "BDAY:#{unquote(replacement)}"
        )

      uploaded =
        authed_dav(%{c | conn: put_req_header(conn, "if-match", etag)}, "PUT", path, edited)

      assert uploaded.status == 204
      expected = if unquote(replacement) == "--0203", do: ~D[2000-02-03], else: ~D[1991-02-03]
      updated = Repo.reload!(contact)
      assert updated.birthdate == expected
      assert updated.birthdate_year_unknown == (unquote(replacement) == "--0203")
      refreshed = authed_dav(%{c | conn: conn}, "GET", path)
      assert refreshed.resp_body =~ "BDAY:#{unquote(replacement)}"
      refute get_resp_header(refreshed, "etag") == [etag]
    end
  end

  for {field, before_value, after_value} <- [
        {"NICKNAME", "Before", "After"},
        {"ORG", "Before Inc", "After Inc"},
        {"TITLE", "Engineer", "Designer"},
        {"EMAIL;TYPE=HOME", "before@example.test", "after@example.test"},
        {"TEL;TYPE=CELL", "+15551234567", "+15557654321"},
        {"URL", "https://before.example.test", "https://after.example.test"},
        {"ADR;TYPE=HOME", ";;Old Street;Old City;;12345;US", ";;New Street;New City;;54321;US"},
        {"CATEGORIES", "Before tag", "After tag"},
        {"NOTE", "Before client note", "After client note"}
      ],
      version <- ["3.0", "4.0"] do
    test "#{version} #{field} edit and removal survive conditional upload and download", c do
      contact = contact_fixture(c.account_id)
      path = contact_path(contact)
      conn = put_req_header(c.conn, "accept", "text/vcard; version=#{unquote(version)}")
      initial = authed_dav(%{c | conn: conn}, "GET", path)
      line = "#{unquote(field)}:#{unquote(before_value)}\r\n"
      seeded = String.replace(initial.resp_body, "END:VCARD", line <> "END:VCARD")

      assert authed_dav(
               %{
                 c
                 | conn: put_req_header(conn, "if-match", hd(get_resp_header(initial, "etag")))
               },
               "PUT",
               path,
               seeded
             ).status == 204

      for {old, new} <- [
            {unquote(before_value), unquote(after_value)},
            {unquote(after_value), nil}
          ] do
        downloaded = authed_dav(%{c | conn: conn}, "GET", path)
        assert downloaded.status == 200
        assert downloaded.resp_body =~ old

        edited =
          if new,
            do: String.replace(downloaded.resp_body, old, new),
            else: Regex.replace(~r/^.*#{Regex.escape(old)}.*\r\n/m, downloaded.resp_body, "")

        uploaded =
          authed_dav(
            %{
              c
              | conn: put_req_header(conn, "if-match", hd(get_resp_header(downloaded, "etag")))
            },
            "PUT",
            path,
            edited
          )

        assert uploaded.status == 204
        refreshed = authed_dav(%{c | conn: conn}, "GET", path)
        refute refreshed.resp_body =~ old
        if new, do: assert(refreshed.resp_body =~ new)
        refute get_resp_header(refreshed, "etag") == get_resp_header(downloaded, "etag")
      end
    end
  end

  for version <- ["3.0", "4.0"] do
    test "#{version} structured name edits reach native fields and survive download", c do
      contact = contact_fixture(c.account_id)
      path = contact_path(contact)
      conn = put_req_header(c.conn, "accept", "text/vcard; version=#{unquote(version)}")
      downloaded = authed_dav(%{c | conn: conn}, "GET", path)

      edited =
        downloaded.resp_body
        |> then(&Regex.replace(~r/^N:.*$/m, &1, "N:Changed;Updated;Middle;;\r"))
        |> then(&Regex.replace(~r/^FN:.*$/m, &1, "FN:Updated Middle Changed\r"))

      assert authed_dav(
               %{
                 c
                 | conn: put_req_header(conn, "if-match", hd(get_resp_header(downloaded, "etag")))
               },
               "PUT",
               path,
               edited
             ).status == 204

      updated = Repo.reload!(contact)

      assert {updated.first_name, updated.middle_name, updated.last_name} ==
               {"Updated", "Middle", "Changed"}

      assert authed_dav(%{c | conn: conn}, "GET", path).resp_body =~ "N:Changed;Updated;Middle;;"
    end
  end

  for version <- [:v30, :v40] do
    test "#{version} PUT-back and unrelated edits preserve native visible and hidden relationship ids",
         c do
      owner = contact_fixture(c.account_id)
      visible = contact_fixture(c.account_id)
      hidden = contact_fixture(c.account_id)

      {:ok, type} =
        Contacts.create_relationship_type(c.account_id, %{name: "Friend", reverse_name: "Friend"})

      rels = for target <- [visible, hidden], do: relationship_fixture(owner, target, type.id)
      Contacts.archive_contact(hidden)
      path = contact_path(owner)

      for edit <- [false, true] do
        card = VCardAdapter.contact_to_vcard(owner, version: unquote(version))

        card =
          if edit,
            do: String.replace(card, "END:VCARD", "TEL;TYPE=CELL:+15551234567\r\nEND:VCARD"),
            else: card

        assert authed_dav(c, "PUT", path, card).status == 204

        assert Enum.map(Contacts.list_relationships(owner.id), & &1.id) |> Enum.sort() ==
                 Enum.map(rels, & &1.id) |> Enum.sort()

        assert Store.get_by_resource_name(c.account_id, Path.basename(path)).dav.extras == []
      end

      card = VCardAdapter.contact_to_vcard(owner, version: unquote(version))
      card = Regex.replace(~r/^(RELATED|X-KITH-RELATED)[^\r\n]*\r\n/m, card, "\\1:\r\n")
      assert authed_dav(c, "PUT", path, card).status == 204
      assert Enum.map(Contacts.list_relationships(owner.id), & &1.id) == [List.last(rels).id]
    end

    test "#{version} invalid identities cannot create contacts or inject properties", c do
      for identity <- ["urn:test:hello\\nFN:Injected", "not-a-uuid", "urn:uuid:bad"] do
        href = "/dav/addressbooks/default/#{System.unique_integer([:positive])}.vcf"

        body =
          "BEGIN:VCARD\r\nVERSION:4.0\r\nUID;VALUE=text:#{identity}\r\nFN:Alice\r\nN:;Alice;;;\r\nEND:VCARD\r\n"

        assert authed_dav(c, "PUT", href, body).status == 403
        assert Store.get_by_resource_name(c.account_id, Path.basename(href)) == nil
      end
    end
  end

  for operation <- [:hard_delete_contact, :empty_trash] do
    test "#{operation} advances floor and leaves already-hidden relationship representation stable",
         c do
      target = contact_fixture(c.account_id)
      owner = contact_fixture(c.account_id)
      control = contact_fixture(c.account_id)

      {:ok, type} =
        Contacts.create_relationship_type(c.account_id, %{name: "Friend", reverse_name: "Friend"})

      relationship = relationship_fixture(owner, target, type.id)
      {:ok, target} = Contacts.soft_delete_contact(target)
      path = contact_path(owner)
      before = authed_dav(c, "GET", path)
      [etag] = get_resp_header(before, "etag")
      control_before = authed_dav(c, "GET", contact_path(control))
      floor_before = Store.sync_state(c.account_id)

      deletion = fn ->
        case unquote(operation) do
          :hard_delete_contact -> Contacts.hard_delete_contact(target)
          :empty_trash -> Contacts.empty_trash(c.account_id)
        end
      end

      assert {:error, :cancelled} =
               Repo.transaction(fn ->
                 assert {:ok, _} = deletion.()
                 assert Repo.get(Kith.Contacts.Relationship, relationship.id) == nil
                 assert authed_dav(c, "GET", path).resp_body == before.resp_body
                 Repo.rollback(:cancelled)
               end)

      assert Repo.get!(Kith.Contacts.Relationship, relationship.id)
      restored = authed_dav(c, "GET", path)
      assert restored.resp_body == before.resp_body
      assert get_resp_header(restored, "etag") == [etag]
      assert Store.sync_state(c.account_id) == floor_before
      assert {:ok, _} = deletion.()

      after_delete =
        authed_dav(%{c | conn: put_req_header(c.conn, "if-none-match", etag)}, "GET", path)

      assert after_delete.status == 304
      assert get_resp_header(after_delete, "etag") == [etag]
      assert Store.sync_state(c.account_id).floor > floor_before.floor
      refute after_delete.resp_body =~ "RELATED"
      control_after = authed_dav(c, "GET", contact_path(control))
      assert get_resp_header(control_after, "etag") == get_resp_header(control_before, "etag")
    end
  end

  test "accepted path segments round-trip through advertised href and multiget", c do
    for name <- ["hash#", "query?", "percent%", "a space", "مرحبا"] do
      resource = name <> ".vcf"
      expected = "/dav/addressbooks/default/" <> URI.encode(resource, &URI.char_unreserved?/1)
      assert authed_dav(c, "PUT", expected, build_vcard("Href", "Test")).status == 201

      listing =
        authed_dav(
          %{c | conn: put_req_header(c.conn, "depth", "1")},
          "PROPFIND",
          "/dav/addressbooks/default/",
          propfind_body()
        ).resp_body

      [advertised] =
        Regex.scan(~r/<d:href>([^<]+)<\/d:href>/, listing, capture: :all_but_first)
        |> List.flatten()
        |> Enum.filter(
          &(String.starts_with?(&1, "/dav/addressbooks/default/") and
              &1 != "/dav/addressbooks/default/")
        )

      assert advertised == expected
      assert authed_dav(c, "GET", advertised).status == 200
      multi = authed_dav(c, "REPORT", "/dav/addressbooks/default/", multiget_body([advertised]))
      assert multi.status == 207
      assert multi.resp_body =~ "FN:Href Test"
      assert authed_dav(c, "DELETE", advertised).status == 204
      assert authed_dav(c, "GET", advertised).status == 404
    end
  end
end
