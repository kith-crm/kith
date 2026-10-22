defmodule KithWeb.DAV.TestHelpers do
  @moduledoc """
  Shared helpers for CardDAV black-box integration tests.

  Provides HTTP Basic Auth, custom DAV method dispatch, vCard builders,
  and XML body templates used across all DAV test files.
  """

  import Plug.Conn
  import Phoenix.ConnTest

  @endpoint KithWeb.Endpoint
  @password "hello world!!"

  def dav_password, do: @password

  def basic_auth(conn, email, password) do
    encoded = Base.encode64("#{email}:#{password}")
    put_req_header(conn, "authorization", "Basic #{encoded}")
  end

  def dav_request(conn, method, path, body \\ "") do
    content_type =
      case method do
        "PUT" -> "text/vcard"
        _ -> "application/xml"
      end

    conn
    |> put_req_header("content-type", content_type)
    |> dispatch(@endpoint, method, path, body)
  end

  def authed_dav(%{conn: conn, user: user}, method, path, body \\ "") do
    conn
    |> basic_auth(user.email, @password)
    |> dav_request(method, path, body)
  end

  def build_vcard(first_name, last_name, opts \\ []) do
    do_build_vcard(first_name, last_name, "3.0", opts)
  end

  def build_vcard_v40(first_name, last_name, opts \\ []) do
    do_build_vcard(first_name, last_name, "4.0", opts)
  end

  defp do_build_vcard(first_name, last_name, version, opts) do
    middle = opts[:middle_name] || ""

    n_line =
      if middle != "",
        do: "N:#{last_name};#{first_name};#{middle};;",
        else: "N:#{last_name};#{first_name};;;"

    lines = [
      "BEGIN:VCARD",
      "VERSION:#{version}",
      "FN:#{first_name} #{last_name}",
      n_line
    ]

    lines = if opts[:uid], do: lines ++ ["UID:#{opts[:uid]}"], else: lines
    lines = if opts[:nickname], do: lines ++ ["NICKNAME:#{opts[:nickname]}"], else: lines
    lines = if opts[:company], do: lines ++ ["ORG:#{opts[:company]}"], else: lines
    lines = if opts[:occupation], do: lines ++ ["TITLE:#{opts[:occupation]}"], else: lines
    lines = if opts[:birthdate], do: lines ++ ["BDAY:#{opts[:birthdate]}"], else: lines
    lines = if opts[:email], do: lines ++ ["EMAIL;TYPE=HOME:#{opts[:email]}"], else: lines
    lines = if opts[:phone], do: lines ++ ["TEL;TYPE=CELL:#{opts[:phone]}"], else: lines
    lines = if opts[:note], do: lines ++ ["NOTE:#{opts[:note]}"], else: lines

    lines =
      if opts[:categories] do
        lines ++ ["CATEGORIES:" <> Enum.join(opts[:categories], ",")]
      else
        lines
      end

    lines = add_version_specific_fields(lines, version, opts)

    lines =
      if opts[:impp] do
        Enum.reduce(opts[:impp], lines, fn impp, acc ->
          acc ++ ["IMPP:#{impp}"]
        end)
      else
        lines
      end

    lines = lines ++ ["END:VCARD"]
    Enum.join(lines, "\r\n") <> "\r\n"
  end

  defp add_version_specific_fields(lines, "3.0", opts) do
    lines =
      if opts[:gender] do
        lines ++ ["X-GENDER:#{opts[:gender]}"]
      else
        lines
      end

    lines =
      if opts[:photo_b64] do
        lines ++ ["PHOTO;ENCODING=b;TYPE=JPEG:#{opts[:photo_b64]}"]
      else
        lines
      end

    if opts[:related] do
      Enum.reduce(opts[:related], lines, fn rel, acc ->
        acc ++
          [
            "item#{System.unique_integer([:positive])}.X-ABRELATEDNAMES:#{rel.uid}",
            "item#{System.unique_integer([:positive])}.X-ABLabel:#{rel.type}"
          ]
      end)
    else
      lines
    end
  end

  defp add_version_specific_fields(lines, "4.0", opts) do
    lines =
      if opts[:gender] do
        lines ++ ["GENDER:#{opts[:gender]}"]
      else
        lines
      end

    if opts[:related] do
      Enum.reduce(opts[:related], lines, fn rel, acc ->
        acc ++ ["RELATED;TYPE=#{String.downcase(rel.type)}:urn:uuid:#{rel.uid}"]
      end)
    else
      lines
    end
  end

  def contact_uid(contact) do
    Kith.DAV.Store.ensure_rows(contact.account_id)
    Kith.Repo.preload(contact, :dav, force: true).dav.resource_name
  end

  def contact_path(contact),
    do: "/dav/addressbooks/default/#{contact_uid(contact)}"

  def propfind_body do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav" xmlns:cs="http://calendarserver.org/ns/">
      <d:allprop/>
    </d:propfind>
    """
  end

  def multiget_body(hrefs) do
    href_xml = Enum.map_join(hrefs, "\n", fn href -> "<d:href>#{href}</d:href>" end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <card:addressbook-multiget xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
      <d:prop>
        <d:getetag/>
        <card:address-data/>
      </d:prop>
      #{href_xml}
    </card:addressbook-multiget>
    """
  end

  def sync_collection_body do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:sync-collection xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
      <d:sync-token/>
      <d:prop>
        <d:getetag/>
        <card:address-data/>
      </d:prop>
    </d:sync-collection>
    """
  end

  def count_responses(body) do
    Regex.scan(~r/<d:response>/, body) |> length()
  end

  @doc "Standard setup block: creates a user and returns context with conn, user, scope, account_id."
  def setup_dav_user(%{conn: conn}) do
    user = Kith.AccountsFixtures.user_fixture()
    scope = Kith.Accounts.Scope.for_user(user)

    # Ensure global ContactFieldTypes exist for DAV contact field round-trips
    ensure_contact_field_types()

    # Seed genders for gender round-trip tests
    seed_genders()

    %{
      conn: conn,
      user: user,
      scope: scope,
      account_id: user.account.id
    }
  end

  defp seed_genders do
    alias Kith.Contacts.Gender
    alias Kith.Repo
    import Ecto.Query

    for {name, pos} <- [{"Male", 0}, {"Female", 1}] do
      unless Repo.one(
               from(g in Gender, where: is_nil(g.account_id) and g.name == ^name, limit: 1)
             ) do
        Repo.insert!(%Gender{name: name, position: pos, account_id: nil})
      end
    end
  end

  defp ensure_contact_field_types do
    alias Kith.Contacts.ContactFieldType
    alias Kith.Repo
    import Ecto.Query

    # Seeds store protocols with colons ("mailto:", "tel:", "https://").
    # Only insert if no types exist for each protocol scheme.
    for {name, protocol, seeded, vcard_label} <- [
          {"Email", "mailto", "mailto:", "EMAIL"},
          {"Phone", "tel", "tel:", "TEL"},
          {"Website", "https", "https://", nil},
          {"IMPP", "impp", "impp:", "IMPP"}
        ] do
      unless Repo.one(
               from(t in ContactFieldType,
                 where: like(t.protocol, ^"#{protocol}%"),
                 limit: 1
               )
             ) do
        Repo.insert!(%ContactFieldType{
          name: name,
          protocol: seeded,
          vcard_label: vcard_label,
          position: 0
        })
      end
    end
  end
end
