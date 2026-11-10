# Supported Authentik2026.8.5 models only. Feed through ownership-gated ak shell.
# No token claims, session values, upstream source or global sessions are changed.
import json, os
from pathlib import Path
from authentik.flows.models import Flow, FlowStageBinding
from authentik.providers.oauth2.models import OAuth2Provider
from authentik.stages.identification.models import IdentificationStage
from authentik.stages.password.models import PasswordStage
from authentik.stages.user_login.models import UserLoginStage
provider=OAuth2Provider.objects.get(name='kith-local')
action=os.environ.get('KITH_FRESHNESS_ACTION','apply')
if action=='snapshot':
    print('SAFE_ORIGINAL_PROVIDER='+json.dumps({
        'run_id':json.loads(Path('/run/kith-test/run.json').read_text())['run_id'],
        'provider_pk':provider.pk, 'authentication_flow':str(provider.authentication_flow_id) if provider.authentication_flow_id else None,
        'authorization_flow':str(provider.authorization_flow_id), 'invalidation_flow':str(provider.invalidation_flow_id),
        'redirect_uris':provider._redirect_uris}))
elif action=='restore':
    original=json.loads(Path('/run/kith-test/freshness-original-provider.json').read_text())
    assert provider.pk==original['provider_pk']
    assert original['run_id']==json.loads(Path('/run/kith-test/run.json').read_text())['run_id']
    provider.authentication_flow_id=original['authentication_flow']
    provider.authorization_flow_id=original['authorization_flow']
    provider.invalidation_flow_id=original['invalidation_flow']
    provider._redirect_uris=original['redirect_uris']
    provider.save(update_fields=['authentication_flow','authorization_flow','invalidation_flow','_redirect_uris'])
    print('PASS exact original owned provider flow references/callbacks restored')
else:
    assert action=='apply'
    flow,_=Flow.objects.update_or_create(slug='kith-local-always-authenticate',defaults={
        'name':'Kith local validation: credentials on every authorization',
        'title':'Authenticate to Kith local validation', 'designation':'authorization',
        'authentication':'require_authenticated'})
    identify,_=IdentificationStage.objects.update_or_create(name='kith-local-fresh-identification',defaults={
        'user_fields':['username','email'], 'password_stage':None, 'show_matched_user':False,
        'enable_remember_me':False, 'pretend_user_exists':False,
        'captcha_stage':None, 'webauthn_stage':None, 'passwordless_flow':None,
        'enrollment_flow':None, 'recovery_flow':None})
    identify.sources.clear()
    assert flow.policies.count()==0
    password,_=PasswordStage.objects.update_or_create(name='kith-local-fresh-password',defaults={
        'backends':['authentik.core.auth.InbuiltBackend'], 'failed_attempts_before_cancel':5,
        'configure_flow':None, 'allow_show_password':False})
    login,_=UserLoginStage.objects.update_or_create(name='kith-local-fresh-user-login',defaults={
        'session_duration':'hours=1', 'remember_me_offset':'seconds=0',
        'terminate_other_sessions':False, 'remember_device':'seconds=0'})
    # Owned stages have no bound policies or conditional skip rules.
    for order,stage in [(10,identify),(20,password),(100,login)]:
        binding,_=FlowStageBinding.objects.update_or_create(target=flow,order=order,defaults={
            'stage':stage, 'evaluate_on_plan':False, 're_evaluate_policies':True})
        assert binding.policies.count()==0
    assert FlowStageBinding.objects.filter(target=flow).count()==3
    provider.authorization_flow=flow
    provider.save(update_fields=['authorization_flow'])
    print('PASS owned authorization always requires identification/password/userlogin; other sessions retained')
