defmodule KithWeb.DAV.QueryCountTest do
  @moduledoc """
  Task 8: the number of SQL queries a DAV read issues must not depend on how
  many contacts it returns (no N+1 on multiget, sync-collection,
  addressbook-query or PROPFIND Depth 1).
  """
  use KithWeb.ConnCase, async: true

  import KithWeb.DAV.TestHelpers

  alias Kith.Contacts
  alias Kith.ContactsFixtures

  setup :setup_dav_user

  @book "/dav/addressbooks/default/"

  defp add_contact(account_id, i) do
    contact =
      ContactsFixtures.contact_fixture(account_id, %{first_name: "Qc#{i}", last_name: "Count"})

    types = Contacts.list_contact_field_types(account_id)
    email = Enum.find(types, &(&1.protocol == "mailto:"))
    phone = Enum.find(types, &(&1.protocol == "tel:"))

    {:ok, _} =
      Contacts.create_contact_field(contact, %{
        value: "qc#{i}@example.test",
        contact_field_type_id: email.id
      })

    {:ok, _} =
      Contacts.create_contact_field(contact, %{
        value: "+1555000#{i}",
        contact_field_type_id: phone.id
      })

    {:ok, _} = Contacts.create_address(contact, %{line1: "#{i} Count Street", city: "Qc"})
    {:ok, tag} = Contacts.create_tag(account_id, %{name: "qc-tag-#{i}"})
    Contacts.tag_contact(contact, tag)
    contact
  end

  defp count_queries(fun) do
    parent = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:kith, :repo, :query],
      fn _event, _measure, meta, _config ->
        if self() == parent, do: send(parent, {:query, meta.query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain([])
  end

  defp extra_queries(many, few) do
    (many -- few) |> Enum.map(&String.slice(&1, 0, 60)) |> Enum.frequencies() |> inspect()
  end

  defp drain(acc) do
    receive do
      {:query, q} -> drain([q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp report_body(:multiget, contacts),
    do: multiget_body(Enum.map(contacts, &contact_path/1))

  defp report_body(:sync, _contacts), do: sync_collection_body()

  defp report_body(:sync_etag_only, _contacts) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:sync-collection xmlns:d="DAV:"><d:sync-token/><d:sync-level>1</d:sync-level>
      <d:prop><d:getetag/></d:prop></d:sync-collection>
    """
  end

  defp report_body(:query, _contacts) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
      <d:prop><d:getetag/><card:address-data/></d:prop>
      <card:filter><card:prop-filter name="FN">
        <card:text-match match-type="contains">Count</card:text-match>
      </card:prop-filter></card:filter>
    </card:addressbook-query>
    """
  end

  defp request(context, :propfind, _contacts) do
    body = """
    <?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getcontenttype/></d:prop></d:propfind>
    """

    context.conn
    |> Plug.Conn.put_req_header("depth", "1")
    |> then(&authed_dav(%{context | conn: &1}, "PROPFIND", @book, body))
  end

  defp request(context, kind, contacts) do
    context.conn
    |> Plug.Conn.put_req_header("depth", "1")
    |> then(&authed_dav(%{context | conn: &1}, "REPORT", @book, report_body(kind, contacts)))
  end

  defp queries_for(context, kind, contacts) do
    # warm-up: password cache, session-level one-offs
    assert request(context, kind, contacts).status == 207
    queries = count_queries(fn -> assert request(context, kind, contacts).status == 207 end)
    queries
  end

  for kind <- [:multiget, :sync, :sync_etag_only, :query, :propfind] do
    name =
      if kind == :multiget,
        do: "CDV-106: multiget query count is independent of href count",
        else: "#{kind} query count is independent of the number of contacts"

    test name,
         %{account_id: account_id} = context do
      kind = unquote(kind)
      few = for i <- 1..5, do: add_contact(account_id, i)
      few_queries = queries_for(context, kind, few)

      many = few ++ for i <- 6..50, do: add_contact(account_id, i)
      many_queries = queries_for(context, kind, many)

      assert length(many_queries) == length(few_queries),
             "#{kind}: #{length(few_queries)} queries for 5 contacts, " <>
               "#{length(many_queries)} for 50: #{extra_queries(many_queries, few_queries)}"
    end
  end

  describe "PUT" do
    defp put_card(context, name, lines) do
      body =
        Enum.join(
          ["BEGIN:VCARD", "VERSION:3.0", "FN:Many Values", "N:Values;Many;;;"] ++
            lines ++ ["END:VCARD"],
          "\r\n"
        ) <> "\r\n"

      authed_dav(context, "PUT", @book <> name, body)
    end

    for {kind, line} <- [
          {"EMAIL", "EMAIL:qc@N@example.test"},
          {"TEL", "TEL;TYPE=CELL:+1555000@N@"},
          {"URL", "URL:https://example.test/@N@"}
        ] do
      test "CDV-107: a PUT's query count does not grow with its #{kind} lines", context do
        template = unquote(line)
        line = &String.replace(template, "@N@", to_string(&1))
        kind = unquote(kind)

        queries = fn name, n ->
          assert put_card(context, "warm-#{name}.vcf", []).status == 201

          count_queries(fn ->
            assert put_card(context, name, Enum.map(1..n, line)).status == 201
          end)
        end

        few = queries.("few-#{kind}.vcf", 5)
        many = queries.("many-#{kind}.vcf", 60)

        assert length(many) == length(few),
               "#{kind}: #{length(few)} queries for 5 lines, #{length(many)} for 60: " <>
                 extra_queries(many, few)
      end
    end
  end
end
