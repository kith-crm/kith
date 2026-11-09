# Owned provider control only, invoked through compose.sh and ak shell.
# Policy denial is Authentik's real application authorization decision.
import os
from authentik.core.models import Application
from authentik.flows.models import Flow
from authentik.providers.oauth2.models import OAuth2Provider
from authentik.policies.expression.models import ExpressionPolicy
from authentik.policies.models import PolicyBinding
mode=os.environ['KITH_CONSENT']
assert mode in ('deny','implicit','explicit')
p=OAuth2Provider.objects.get(name='kith-local')
flow_mode='explicit' if mode=='explicit' else 'implicit'
p.authorization_flow=Flow.objects.get(slug=f'default-provider-authorization-{flow_mode}-consent')
p.save(update_fields=['authorization_flow'])
policy,_=ExpressionPolicy.objects.update_or_create(name='kith-local-denial-validation',defaults={'expression':'return False'})
PolicyBinding.objects.update_or_create(target=Application.objects.get(slug='kith-local'),policy=policy,defaults={'order':0,'enabled':mode=='deny'})
print('PASS owned provider authorization policy updated')
