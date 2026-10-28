defmodule KithWeb.DAV.RoundTripIntegrityTest do
  use KithWeb.ConnCase, async: true
  import KithWeb.DAV.TestHelpers
  import Kith.ContactsFixtures
  alias Kith.{Contacts, Repo}
  alias Kith.DAV.{Store, VCardAdapter}

  setup :setup_dav_user

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
      card = Regex.replace(~r/^(?:RELATED|X-KITH-RELATED)[^\r\n]*\r\n/m, card, "")
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
    test "#{operation} invalidates surviving owner conditional GET and rolls back atomically",
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
                 assert authed_dav(c, "GET", path).resp_body != before.resp_body
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

      assert after_delete.status == 200
      assert get_resp_header(after_delete, "etag") != [etag]
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
