defmodule KithWeb.DAV.ReportConversionTest do
  use KithWeb.ConnCase, async: true
  import KithWeb.DAV.TestHelpers
  import Kith.ContactsFixtures
  alias Kith.Contacts

  setup :setup_dav_user

  test "conversion failures are per member across multiget sync and query REPORT", c do
    unavailable = contact_fixture(c.account_id, %{first_name: "Unconvertible"})
    available = contact_fixture(c.account_id, %{first_name: "Available"})
    body = card("4.0", ["X-CLIENT;X-LABEL=a^'b:preserved"])
    assert authed_dav(c, "PUT", contact_path(unavailable), body).status == 204

    for request <- reports([unavailable, available]) do
      result = authed_dav(c, "REPORT", "/dav/addressbooks/default/", request)
      assert result.status == 207
      assert member(result.resp_body, contact_path(unavailable)) =~ "403 Forbidden"

      assert member(result.resp_body, contact_path(unavailable)) =~
               "supported-address-data-conversion"

      assert member(result.resp_body, contact_path(available)) =~ "200 OK"
      assert member(result.resp_body, contact_path(available)) =~ "FN:Available"
    end

    assert authed_dav(c, "GET", contact_path(unavailable)).status == 403

    assert get_v4(c, unavailable).status == 200
  end

  test "metadata-only multiget never converts an unrequested address body", c do
    unavailable = contact_fixture(c.account_id)

    assert authed_dav(
             c,
             "PUT",
             contact_path(unavailable),
             card("4.0", ["X-CLIENT;X-LABEL=a^'b:value"])
           ).status == 204

    for request <- reports([unavailable]) do
      body = Regex.replace(~r/<card:address-data[^>]*\/>/, request, "")
      result = authed_dav(c, "REPORT", "/dav/addressbooks/default/", body)
      assert result.status == 207
      assert result.resp_body =~ "200 OK"
      refute result.resp_body =~ "403 Forbidden"
      refute result.resp_body =~ "supported-address-data-conversion"
    end
  end

  test "unavailable selected avatar returns a member503 while healthy cards remain available",
       c do
    unavailable = contact_fixture(c.account_id, %{first_name: "Missing avatar"})
    available = contact_fixture(c.account_id, %{first_name: "Available"})
    photo = photo_fixture(unavailable)
    bytes = Image.new!(32, 32, color: :blue) |> Image.write!(:memory, suffix: ".png")
    {:ok, _} = Kith.Storage.upload_binary(bytes, photo.storage_key)
    {:ok, selected} = Contacts.set_avatar(unavailable, photo)

    on_exit(fn ->
      Kith.Storage.delete(photo.storage_key)
      Kith.Storage.delete(selected.avatar)
    end)

    :ok = Kith.Storage.delete(selected.avatar)

    for request <- reports([unavailable, available]) do
      result = authed_dav(c, "REPORT", "/dav/addressbooks/default/", request)
      assert result.status == 207
      assert member(result.resp_body, contact_path(unavailable)) =~ "503 Service Unavailable"
      assert member(result.resp_body, contact_path(available)) =~ "200 OK"
    end
  end

  test "source lexical changes publish a new validator when either version's bytes change", c do
    contact = contact_fixture(c.account_id)
    body = card("3.0", [~s(eMaIl;X-P="plain":shared@example.org)])
    assert authed_dav(c, "PUT", contact_path(contact), body).status == 204
    before = authed_dav(c, "GET", contact_path(contact))
    native_ids = Contacts.list_contact_fields(contact.id) |> Enum.map(& &1.id)
    assert before.resp_body =~ ~s(eMaIl;X-P="plain":shared@example.org)
    v4 = get_v4(c, contact)
    assert v4.status == 200
    assert authed_dav(c, "PUT", contact_path(contact), v4.resp_body).status == 204
    after_get = authed_dav(c, "GET", contact_path(contact))
    refute after_get.resp_body == before.resp_body
    refute get_resp_header(after_get, "etag") == get_resp_header(before, "etag")
    assert Contacts.list_contact_fields(contact.id) |> Enum.map(& &1.id) == native_ids
  end

  defp get_v4(context, contact) do
    context = %{context | conn: put_req_header(context.conn, "accept", "text/vcard; version=4.0")}
    authed_dav(context, "GET", contact_path(contact))
  end

  defp reports(contacts) do
    hrefs = Enum.map_join(contacts, "", &"<d:href>#{contact_path(&1)}</d:href>")

    [
      ~s(<card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop><d:getetag/><card:address-data version="3.0"/></d:prop>#{hrefs}</card:addressbook-multiget>),
      ~s(<d:sync-collection xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:sync-token/><d:sync-level>1</d:sync-level><d:prop><d:getetag/><card:address-data version="3.0"/></d:prop></d:sync-collection>),
      ~s(<card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop><d:getetag/><card:address-data version="3.0"/></d:prop><card:filter/></card:addressbook-query>)
    ]
  end

  defp member(xml, href),
    do:
      Enum.find(Regex.scan(~r/<d:response>.*?<\/d:response>/s, xml), fn [response] ->
        response =~ href
      end)
      |> hd()

  defp card(version, props),
    do:
      Enum.join(
        ["BEGIN:VCARD", "VERSION:" <> version, "FN:Owner", "N:;Owner;;;" | props] ++
          ["END:VCARD", ""],
        "\r\n"
      )
end
