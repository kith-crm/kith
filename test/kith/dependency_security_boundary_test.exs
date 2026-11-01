defmodule Kith.DependencySecurityBoundaryTest do
  use ExUnit.Case, async: true

  test "Phoenix rejects injected attribute names including nested attributes" do
    for attributes <- [
          [{"title onmouseover", "alert(1)"}],
          [{"data-x\" onclick=\"alert(1)", "value"}],
          [data: [{"x onfocus", "value"}]],
          [aria: [{"label\n'onclick", "value"}]],
          [phx: [value: [{"id=onclick", "value"}]]]
        ] do
      assert_raise ArgumentError, fn -> Phoenix.HTML.attributes_escape(attributes) end
    end

    assert Phoenix.HTML.attributes_escape(data: [id: "<credential>"], title: "safe")
           |> Phoenix.HTML.safe_to_string() ==
             " data-id=\"&lt;credential&gt;\" title=\"safe\""
  end

  test "certificate hostname verifier rejects cross-label wildcard and IP matches" do
    key = X509.PrivateKey.new_ec(:secp256r1)

    for {pattern, accepted, rejected} <- [
          {"a*.example.com", ~c"api.example.com", ~c"a.evil.example.com"},
          {"*o.example.com", ~c"hello.example.com", ~c"evil.o.example.com"},
          {"*.168.1.1", ~c"host.168.1.1", ~c"192.168.1.1"}
        ] do
      certificate =
        X509.Certificate.self_signed(key, "/CN=unused.example.com",
          extensions: [subject_alt_name: X509.Certificate.Extension.subject_alt_name([pattern])]
        )

      assert {:valid, ^accepted} =
               :ssl_verify_hostname.verify_cert_hostname(certificate, accepted)

      assert {:fail, _} = :ssl_verify_hostname.verify_cert_hostname(certificate, rejected)

      assert {:fail, _} =
               :ssl_verify_hostname.verify_cert_hostname(certificate, ~c"unrelated.example.net")

      assert {:fail, {:bad_cert, :unknown_ca}} =
               :ssl_verify_hostname.verify_fun(certificate, {:bad_cert, :unknown_ca}, [])
    end
  end
end
