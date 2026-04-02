// nginx njs OIDC handler — authorization code flow against Keycloak.
// Compatible with njs 0.8.x as packaged in Alpine Linux.
//
// Env vars (declared in nginx.conf with `env` directives):
//   KEYCLOAK_INTERNAL_URL  — nginx-to-keycloak URL (e.g. http://keycloak:8080)
//   KEYCLOAK_BROWSER_URL   — browser-facing base URL  (e.g. http://localhost)
//   KEYCLOAK_REALM         — Keycloak realm name
//   OIDC_CLIENT_ID         — OIDC client id registered in Keycloak
//   OIDC_CLIENT_SECRET     — OIDC client secret
//   OIDC_REDIRECT_URI      — callback URI (must match Keycloak client config)

function cfg() {
    var internal = process.env.KEYCLOAK_INTERNAL_URL;
    var browser  = process.env.KEYCLOAK_BROWSER_URL;
    var realm    = process.env.KEYCLOAK_REALM;
    var base     = '/auth/realms/' + realm + '/protocol/openid-connect';
    // browserHost is the Host header value Keycloak expects when validating
    // the token's `iss` claim (stripped of protocol and trailing slash).
    var browserHost = browser.replace(/^https?:\/\//, '').replace(/\/$/, '');
    return {
        clientId:         process.env.OIDC_CLIENT_ID,
        clientSecret:     process.env.OIDC_CLIENT_SECRET,
        redirectUri:      process.env.OIDC_REDIRECT_URI,
        authEndpoint:     browser + base + '/auth',
        tokenEndpoint:    internal + base + '/token',
        userinfoEndpoint: internal + base + '/userinfo',
        browserHost:      browserHost,
    };
}

// Parse a named cookie from the Cookie request header.
function getCookie(r, name) {
    var header = r.headersIn['Cookie'] || '';
    var parts = header.split(';');
    for (var i = 0; i < parts.length; i++) {
        var eq = parts[i].indexOf('=');
        if (eq < 0) continue;
        if (parts[i].slice(0, eq).trim() === name) {
            return parts[i].slice(eq + 1).trim();
        }
    }
    return null;
}

// Build application/x-www-form-urlencoded body from a plain object.
function formEncode(obj) {
    var entries = Object.entries(obj);
    var pairs = [];
    for (var i = 0; i < entries.length; i++) {
        pairs.push(encodeURIComponent(entries[i][0]) + '=' + encodeURIComponent(entries[i][1]));
    }
    return pairs.join('&');
}

// auth_request subrequest target — validates session cookie against userinfo endpoint.
async function checkAuth(r) {
    var token = getCookie(r, 'vscode_session');
    if (!token) {
        r.return(401);
        return;
    }
    try {
        var c = cfg();
        var resp = await ngx.fetch(c.userinfoEndpoint, {
            headers: {
                Authorization: 'Bearer ' + token,
                // Set Host to the browser-facing hostname so Keycloak validates
                // the token's `iss` claim against the correct realm URL.
                Host: c.browserHost,
            },
        });
        r.return(resp.status === 200 ? 204 : 401);
    } catch (_) {
        r.return(401);
    }
}

// Callback handler — exchanges authorization code for tokens and sets session cookie.
async function handleCallback(r) {
    var code = r.args.code;
    if (!code) {
        r.return(400, 'Missing authorization code\n');
        return;
    }
    var c = cfg();
    try {
        var resp = await ngx.fetch(c.tokenEndpoint, {
            method:  'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body:    formEncode({
                grant_type:    'authorization_code',
                code:           code,
                redirect_uri:   c.redirectUri,
                client_id:      c.clientId,
                client_secret:  c.clientSecret,
            }),
        });
        if (resp.status !== 200) {
            r.return(502, 'Token exchange failed\n');
            return;
        }
        var data = await resp.json();
        r.headersOut['Set-Cookie'] =
            'vscode_session=' + data.access_token + '; Path=/; HttpOnly; SameSite=Lax';
        r.return(302, '/');
    } catch (e) {
        r.return(502, 'Token exchange error: ' + e.message + '\n');
    }
}

// js_set target — computes the Keycloak login URL for the @oidc_login named location.
// Returns a plain string; nginx issues the 302 natively via `return 302 $oidc_login_url`.
function loginUrl(r) {
    var c = cfg();
    var params = formEncode({
        response_type: 'code',
        client_id:     c.clientId,
        redirect_uri:  c.redirectUri,
        scope:         'openid profile email',
    });
    return c.authEndpoint + '?' + params;
}

export default { checkAuth, handleCallback, loginUrl };
