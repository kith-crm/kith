async function post(path, body) {
  return fetch("/auth/webauthn/authenticate/" + path, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      accept: "application/json, text/html",
      "x-csrf-token": document.querySelector("meta[name='csrf-token']").content,
    },
    body: JSON.stringify(body),
  })
}

export default {
  mounted() {
    this.el.onclick = async () => {
      this.el.disabled = true
      const error = document.getElementById("passkey-error")
      error.textContent = ""
      try {
        const email = document.querySelector("#passkey-email, #login_form input[type=email]")?.value
        const response = await post("challenge", {email})
        if (!response.ok) throw new Error()
        const {publicKey} = await response.json()
        const credential = await navigator.credentials.get({
          publicKey: PublicKeyCredential.parseRequestOptionsFromJSON(publicKey),
        })
        const {rawId, response: assertion} = credential.toJSON()
        const result = await post("complete", {credentialId: rawId, ...assertion})
        if (!result.redirected) throw new Error()
        window.location.assign(result.url)
      } catch {
        error.textContent = "Passkey sign-in did not complete. Please try again."
      } finally {
        this.el.disabled = false
      }
    }
  },
}
