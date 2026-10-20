defmodule KithWeb.DAV.ReservedNameTest do
  @moduledoc """
  `kith-contact-<id>.vcf` names held by clients (R20). Not async: the test walks
  the global contacts id sequence up to a chosen id, which needs no other test
  inserting contacts at the same time.
  """
  use KithWeb.ConnCase, async: false

  import KithWeb.DAV.TestHelpers

  alias Kith.Contacts

  setup :setup_dav_user

  defp last_contact_id do
    [[v]] = Ecto.Adapters.SQL.query!(Kith.Repo, "SELECT last_value FROM contacts_id_seq").rows
    v
  end

  defp create_until(account_id, n) do
    {:ok, c} = Contacts.create_contact(account_id, %{"first_name" => "Ui"})
    if c.id >= n, do: c, else: create_until(account_id, n)
  end

  describe "CDV-32: client-held kith-contact-N names (R20)" do
    test "CDV-32: a vdirsyncer-style upload at an unissued kith-contact-N.vcf is stored; contact N gets an alternative href",
         %{account_id: account_id} = context do
      n = last_contact_id() + 50
      href = "/dav/addressbooks/default/kith-contact-#{n}.vcf"

      put =
        authed_dav(
          context,
          "PUT",
          href,
          build_vcard("Exported", "Card", uid: "kith-contact-#{n}")
        )

      assert put.status == 201
      get = authed_dav(context, "GET", href)
      assert get.status == 200
      assert get.resp_body =~ "UID:kith-contact-#{n}\r\n"

      contact_n = create_until(account_id, n)
      assert contact_n.id == n
      assert contact_n.dav_resource_name == "kith-contact-#{n}-k.vcf"

      alt = authed_dav(context, "GET", "/dav/addressbooks/default/kith-contact-#{n}-k.vcf")
      assert alt.status == 200
      assert alt.resp_body =~ "FN:Ui\r\n"
      # CDV-38: the client card keeps `kith-contact-N`; contact N needs another UID
      assert alt.resp_body =~ "UID:kith-contact-#{n}-k\r\n"
      refute alt.resp_body =~ "UID:kith-contact-#{n}\r\n"
      assert authed_dav(context, "GET", href).resp_body =~ "Exported"

      listing =
        build_conn()
        |> basic_auth(context.user.email, dav_password())
        |> put_req_header("depth", "1")
        |> dav_request("PROPFIND", "/dav/addressbooks/default/", propfind_body())

      hrefs =
        Regex.scan(~r{<d:href>(/dav/addressbooks/default/[^<]+)</d:href>}, listing.resp_body,
          capture: :all_but_first
        )

      assert hrefs == Enum.uniq(hrefs)
      assert ["/dav/addressbooks/default/kith-contact-#{n}-k.vcf"] in hrefs
      assert [href] in hrefs
    end
  end

  describe "CDV-38: a contact whose default UID a client card already holds" do
    defp uid_line(context, href, accept \\ nil) do
      conn = build_conn() |> basic_auth(context.user.email, dav_password())
      conn = if accept, do: put_req_header(conn, "accept", accept), else: conn
      body = dav_request(conn, "GET", href).resp_body
      [line] = Regex.run(~r/^UID:[^\r]*/m, body)
      line
    end

    test "CDV-38: a <uuid>.vcf carrying UID:kith-contact-N (plain or urn:uuid) leaves contact N a distinct UID",
         %{account_id: account_id} = context do
      n = last_contact_id() + 50
      m = n + 1

      assert authed_dav(
               context,
               "PUT",
               "/dav/addressbooks/default/plain.vcf",
               build_vcard("Plain", "Card", uid: "kith-contact-#{n}")
             ).status == 201

      assert authed_dav(
               context,
               "PUT",
               "/dav/addressbooks/default/urn.vcf",
               build_vcard("Urn", "Card", uid: "urn:uuid:kith-contact-#{m}")
             ).status == 201

      contact_n = create_until(account_id, n)
      contact_m = create_until(account_id, m)
      assert {contact_n.id, contact_m.id} == {n, m}
      # No href clash here: both keep their default names
      assert contact_n.dav_resource_name == nil

      uids =
        for href <- ["plain.vcf", "kith-contact-#{n}.vcf", "urn.vcf", "kith-contact-#{m}.vcf"],
            accept <- [nil, "text/vcard;version=4.0"] do
          uid_line(context, "/dav/addressbooks/default/" <> href, accept)
        end

      # Each resource keeps one UID in both vCard versions, and no two share one
      assert Enum.chunk_every(uids, 2) |> Enum.all?(fn [v3, v4] -> v3 == v4 end)

      assert uids |> Enum.take_every(2) == [
               "UID:kith-contact-#{n}",
               "UID:kith-contact-#{n}-k",
               "UID:urn:uuid:kith-contact-#{m}",
               "UID:kith-contact-#{m}-k"
             ]
    end
  end
end
