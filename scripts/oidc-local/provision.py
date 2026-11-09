# Run exclusively inside owned Authentik container: ak shell < this file.
import json
from pathlib import Path
from authentik.core.models import Application, User
from authentik.flows.models import Flow
from authentik.crypto.models import CertificateKeyPair
from authentik.providers.oauth2.models import OAuth2Provider, ScopeMapping
run = json.loads(Path('/run/kith-test/run.json').read_text())
key, _ = CertificateKeyPair.objects.update_or_create(name='kith-local-signing', defaults={
    'certificate_data':Path('/run/kith-test/authentik.test.pem').read_text(),
    'key_data':Path('/run/kith-test/authentik.test-key.pem').read_text()})
email, _ = ScopeMapping.objects.update_or_create(name='kith-local-email', defaults={
    'scope_name':'email', 'expression':'return {"email": request.user.email, "email_verified": request.user.attributes.get("kith_verified", False)}'})
provider, _ = OAuth2Provider.objects.update_or_create(name='kith-local', defaults={
    'client_type':'confidential', 'client_id':run['client_id'], 'client_secret':run['client_secret'],
    'grant_types':['authorization_code'], 'signing_key':key,
    'authorization_flow':Flow.objects.get(slug='default-provider-authorization-implicit-consent'),
    'invalidation_flow':Flow.objects.get(slug='default-provider-invalidation-flow'),
    '_redirect_uris':[{'matching_mode':'strict', 'url':run['callback']}]})
provider.property_mappings.set([email, *ScopeMapping.objects.filter(managed__in=[
    'goauthentik.io/providers/oauth2/scope-openid', 'goauthentik.io/providers/oauth2/scope-profile'])])
Application.objects.update_or_create(slug='kith-local', defaults={'name':'Kith isolated validation','provider':provider})
for data in run['users']:
    user, _ = User.objects.update_or_create(username=data['username'], defaults={
        'email':data['email'], 'name':data['username'], 'is_active':True,
        'attributes':{'kith_verified':data['verified']}})
    user.set_password(data['password'])
    user.save()
print('Owned client and four disposable users provisioned')
