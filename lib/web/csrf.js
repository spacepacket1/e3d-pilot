import crypto from 'node:crypto';

export const CSRF_COOKIE_NAME = 'e3d_pilot_csrf';

export function generateCsrfToken() {
  return crypto.randomBytes(24).toString('hex');
}

export function parseCookies(cookieHeader) {
  const cookies = {};
  if (typeof cookieHeader !== 'string' || cookieHeader.trim() === '') {
    return cookies;
  }
  for (const part of cookieHeader.split(';')) {
    const separatorIndex = part.indexOf('=');
    if (separatorIndex === -1) continue;
    const key = part.slice(0, separatorIndex).trim();
    const value = part.slice(separatorIndex + 1).trim();
    if (!key) continue;
    try {
      cookies[key] = decodeURIComponent(value);
    } catch {
      cookies[key] = value;
    }
  }
  return cookies;
}

// SameSite=Strict is the actual CSRF defense: a cross-site forged request
// never carries this cookie at all, so the browser-enforced same-site policy
// (not a lookup this server has to maintain) is what blocks it. The
// double-submit form field is a second, cheap layer against any client that
// does send the cookie (e.g. a same-site script).
export function csrfCookieHeader(token) {
  return `${CSRF_COOKIE_NAME}=${token}; HttpOnly; SameSite=Strict; Path=/`;
}

export function verifyCsrf(req, formToken) {
  const cookies = parseCookies(req.headers.cookie);
  const cookieToken = cookies[CSRF_COOKIE_NAME];
  if (!cookieToken || !formToken) {
    return false;
  }
  const cookieBuf = Buffer.from(cookieToken, 'utf8');
  const formBuf = Buffer.from(formToken, 'utf8');
  if (cookieBuf.length !== formBuf.length) {
    return false;
  }
  return crypto.timingSafeEqual(cookieBuf, formBuf);
}
