// Real Authentik browser validation. Never enable reporters, traces or screenshots.
import {chromium} from '@playwright/test';
import fs from 'node:fs';
import https from 'node:https';
import {createHmac} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const state='.oidc-local', run=JSON.parse(fs.readFileSync(`${state}/run.json`));
const mode=process.env.KITH_OIDC_PASSWORD!=='false'?'enabled':'disabled';
const results=[];const suffix=process.env.KITH_OIDC_DATABASE_SUFFIX??'';const evidence=`${state}/freshness-${mode}${suffix}.json`;let diagnostics={};
function check(value,message='assertion'){if(!value)throw Error(message);}
const spkis=['authentik.test','kith.test','fixture.test'].map(host=>execFileSync('bash',['-c',`openssl x509 -in '${state}/${host}.pem' -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl base64 -A`],{encoding:'utf8'}));
const browser=await chromium.launch({headless:true,args:['--no-proxy-server','--host-resolver-rules=MAP authentik.test 127.0.0.1, MAP kith.test 127.0.0.1, MAP fixture.test 127.0.0.1',`--ignore-certificate-errors-spki-list=${spkis.join(',')}`]});
process.on('SIGTERM',async()=>{await browser.close();process.exit(143);});
async function control(action,args={}) {return new Promise((resolve,reject)=>{const body=JSON.stringify({action,args});const req=https.request({hostname:'kith.test',port:8464,path:'/__fixture__',method:'POST',ca:fs.readFileSync(`${state}/ca.pem`),lookup:(_h,o,cb)=>o.all?cb(null,[{address:'127.0.0.1',family:4}]):cb(null,'127.0.0.1',4),headers:{authorization:`Bearer ${run.control_token}`,'content-type':'application/json','content-length':Buffer.byteLength(body)}},res=>{let data='';res.on('data',x=>data+=x);res.on('end',()=>{try{check(res.statusCode===200);resolve(JSON.parse(data));}catch{reject(Error('control failed'));}})});req.on('error',()=>reject(Error('control unavailable')));req.end(body);});}
async function scenario(name,fn){try{await fn();results.push({case:name,status:'PASS'});}catch(e){results.push({case:name,status:'FAIL',reason:e.message.startsWith('safe:')?e.message.slice(5):e.name,path:new URL(page.url()).pathname,live:await page.locator('[data-phx-main]').getAttribute('class').catch(()=>null)});}console.log(`${results.at(-1).status} ${name}`);fs.writeFileSync(evidence,JSON.stringify({browser:browser.version(),mode,database_suffix:suffix,diagnostics,results},null,2),{mode:0o600});}
const app='https://kith.test:8464';
async function connected(p){await p.locator('[data-phx-main].phx-connected').waitFor({timeout:10000});}
async function path(p,value){await p.waitForURL(url=>url.hostname==='kith.test'&&url.pathname===value,{timeout:30000});}
async function begin(p){await p.goto(`${app}/users/log-in`);await connected(p);await p.getByRole('link',{name:'Continue with Authentik',exact:true}).click();await p.waitForURL(u=>u.hostname==='authentik.test');}
async function provider(p,user,final){
 let identified=false,passwordEntered=false,identifications=0,passwords=0;
 for(let i=0;i<160;i++){
  const u=new URL(p.url());if(u.hostname==='kith.test'&&!['/auth/oidc','/auth/oidc/complete','/auth/oidc/callback'].includes(u.pathname)){if(final)check(u.pathname===final,`safe:unexpected local path ${u.pathname}`);return {identifications,passwords};}
  if(!identified&&await p.locator('input[name="uidField"]:visible').count()){await p.locator('input[name="uidField"]:visible').fill(user.username);identified=true;passwordEntered=false;identifications++;await p.getByRole('button',{name:/^(Log in|Continue)$/}).first().click();}
  if(!passwordEntered&&await p.getByPlaceholder('Please enter your password',{exact:true}).count()){await p.getByPlaceholder('Please enter your password',{exact:true}).fill(user.password);passwordEntered=true;identified=false;passwords++;await p.getByRole('button',{name:'Continue',exact:true}).click();}
  await p.waitForTimeout(250);
 }diagnostics.provider={path:new URL(p.url()).pathname,identifications,passwords,uid:await p.locator('input[name="uidField"]:visible').count(),password:await p.getByPlaceholder('Please enter your password',{exact:true}).count()};throw Error('safe:provider login did not finish');
}
async function signup(p,user){await begin(p);await provider(p,user,'/users/oidc/register');await connected(p);await p.getByRole('button',{name:'Create account',exact:true}).click();await p.getByRole('alert').filter({hasText:'Please accept the Terms of Service.'}).waitFor();await p.getByLabel('I accept the Terms of Service',{exact:true}).check();await p.getByRole('button',{name:'Create account',exact:true}).click();await path(p,'/dashboard');await connected(p);}
async function logout(p){await p.goto(`${app}/dashboard`);await connected(p);await p.locator('[x-data="userMenu"] > button').click();await p.locator('a[href="/users/log-out"]:visible').click();await path(p,'/users/log-in');}
function uid(user){const db=`kith_local_${run.run_id}${process.env.KITH_OIDC_DATABASE_SUFFIX??''}`;return Number(execFileSync('scripts/oidc-local/compose.sh',['exec','-T','postgresql','psql','-U','authentik','-d',db,'-Atc',`SELECT id FROM users WHERE email='${user.email.replaceAll("'","''")}'`],{encoding:'utf8'}).trim());}
function totp(base32){let bits='';for(const c of base32.replace(/=/g,''))bits+='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'.indexOf(c).toString(2).padStart(5,'0');const bytes=Buffer.from(bits.match(/.{8}/g).map(b=>parseInt(b,2))),counter=Buffer.alloc(8);counter.writeBigUInt64BE(BigInt(Math.floor(Date.now()/30000)));const digest=createHmac('sha1',bytes).update(counter).digest(),offset=digest[19]&15;return ((digest.readUInt32BE(offset)&0x7fffffff)%1000000).toString().padStart(6,'0');}
async function nextTotp(secret){return totp(secret);}
let context=await browser.newContext(),page=await context.newPage(),user=run.users[3],secret,userId;
let credentialRounds=[];let callbackCount=0;
let actual;for(let i=0;i<60;i++){try{actual=await control('environment');break;}catch{await page.waitForTimeout(500);}}check(actual?.database_suffix===suffix&&actual.password===(mode==='enabled'),'safe:isolated app policy/DB mismatch');
page.on('request',r=>{const u=new URL(r.url());if(u.pathname==='/auth/oidc/callback'){diagnostics.callback_port=u.port;callbackCount++;}});
async function mfa(destination){await path(page,'/users/two-factor');await connected(page);await page.getByLabel('Authentication code',{exact:true}).fill(totp(secret));await path(page,destination);await connected(page);}
async function sensitive(expectChallenge){
 await control('stale',{user_id:userId});await page.goto(`${app}/settings/security`);await path(page,'/users/log-in');await connected(page);
 let requestSeen=false;const watch=r=>{const u=new URL(r.url());if(u.hostname==='authentik.test'&&u.pathname==='/application/o/authorize/')requestSeen=u.searchParams.get('max_age')==='0'&&u.searchParams.get('prompt')==='login';};page.on('request',watch);
 const beforeCallback=callbackCount;
 await page.locator('#oidc-reauth-form').getByRole('button').click();
 for(let i=0;i<100&&!requestSeen;i++)await page.waitForTimeout(50);
 for(let i=0;i<200&&new URL(page.url()).hostname!=='authentik.test'&&callbackCount===beforeCallback;i++)await page.waitForTimeout(50);
 const credentials=await provider(page,user);page.off('request',watch);
 const destination=new URL(page.url()).pathname;
 credentialRounds.push({fresh_request:requestSeen,credential_prompt:credentials.passwords>0,identifications:credentials.identifications,password_submissions:credentials.passwords,mfa_destination:destination==='/users/two-factor',unavailable:destination==='/users/log-in'});
 check(requestSeen,'safe:fresh request parameters missing');
 if(expectChallenge){check(credentials.passwords>0,'safe:missing actual provider credential prompt');await mfa('/settings/security');}
 else{check(credentials.passwords===0&&destination==='/users/log-in','safe:expected stale-provider fail-closed reproduction absent');}
 return credentials;
}
try {
 await scenario('freshness setup real signup',async()=>{await signup(page,user);userId=uid(user);check(userId>0);});
 check(results.at(-1).status==='PASS','safe:setup failed');
 await scenario('freshness setup actual MFA enrollment',async()=>{await page.goto(`${app}/users/totp-setup`);await connected(page);secret=(await page.locator('details code').textContent()).trim();await page.getByLabel('6-digit code',{exact:true}).fill(totp(secret));await page.getByRole('button',{name:'Enable two-factor authentication',exact:true}).click();await page.getByRole('heading',{name:'Two-factor authentication enabled',exact:true}).waitFor();});
 check(results.at(-1).status==='PASS','safe:MFA setup failed');
 if(process.env.KITH_FRESHNESS_RED==='1'){
  await scenario('baseline first sensitive round-trip real credentials and MFA',async()=>{await sensitive(true);});
  console.log('Waiting65s with SAME provider cookie jar for baseline delayed repeat');await page.waitForTimeout(65000);
  await scenario('RED repeated delayed provider freshness fails closed without credential prompt',async()=>{await sensitive(false);});
  check(results.at(-1).status==='PASS','safe:actual delayed red not reproduced');
  fs.writeFileSync(`${state}/freshness-red-ready`,JSON.stringify({reproduced:results.at(-1).status==='PASS',cookie_jar_preserved:true,credentialRounds}),{mode:0o600});
  console.log('RED reproduced; awaiting supported provider configuration with same cookie jar retained');
  for(let i=0;i<600&&!fs.existsSync(`${state}/freshness-profile-ready`);i++)await page.waitForTimeout(1000);
  check(fs.existsSync(`${state}/freshness-profile-ready`),'safe:profile configuration timeout');
  await scenario('configured recovery credentials and local MFA',async()=>{await sensitive(true);});
 }
 for(let repetition=1;repetition<=(process.env.KITH_FRESHNESS_LINK_ONLY==='1'?0:2);repetition++){
  console.log(`Waiting65s SAME provider cookie jar; configured repeat${repetition}`);await page.waitForTimeout(65000);
  await scenario(`configured delayed repeat ${repetition} credentials then MFA`,async()=>{await sensitive(true);});
 }
 console.log('Waiting65s SAME provider cookie jar before fresh explicit link');await page.waitForTimeout(65000);
 await scenario('configured link uses genuine new identity credentials then local MFA',async()=>{
  await page.goto(`${app}/settings/security`);await connected(page);
  let requested=false;const watch=r=>{const u=new URL(r.url());if(u.hostname==='authentik.test'&&u.pathname==='/application/o/authorize/')requested=u.searchParams.get('max_age')==='0'&&u.searchParams.get('prompt')==='login';};page.on('request',watch);
  await page.evaluate(()=>{const f=document.createElement('form');f.method='POST';f.action='/users/oidc/link';const i=document.createElement('input');i.name='_csrf_token';i.value=document.querySelector('meta[name="csrf-token"]').content;f.append(i);document.body.append(f);f.submit();});
  await page.waitForURL(u=>u.hostname==='authentik.test');
  const credentials=await provider(page,run.users[1]);check(requested&&credentials.passwords>0,'safe:link lacks fresh credential challenge');
  await mfa('/settings/security');check((await control('snapshot',{user_id:userId})).identities===2,'safe:link identity ownership mismatch');page.off('request',watch);
 });
 diagnostics={same_provider_cookie_jar:true,cookies_cleared:false,credentialRounds};
 fs.writeFileSync(evidence,JSON.stringify({browser:browser.version(),mode,database_suffix:suffix,diagnostics,results},null,2),{mode:0o600});
} catch(e){results.push({case:'runner',status:'FAIL',reason:e.message.startsWith('safe:')?e.message.slice(5):e.name});fs.writeFileSync(evidence,JSON.stringify({mode,diagnostics:{credentialRounds},results},null,2),{mode:0o600});}
finally{await browser.close();}
process.exitCode=results.some(r=>r.status==='FAIL')?1:0;
