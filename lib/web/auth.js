import crypto from 'node:crypto';

// Fixed env var names (not per-repo config, unlike everything else in
// e3d-pilot) because a single web instance can span repos with independent
// .e3d-pilot/config.json -- there is no single "the config" to read
// credentials from. No unauthenticated mode: this refuses to start rather
// than serving anything without credentials configured.
export function loadWebCredentials(env = process.env) {
  const user = env.E3D_PILOT_WEB_AUTH_USER;
  const pass = env.E3D_PILOT_WEB_AUTH_PASS;
  if (!user || !pass) {
    throw new Error(
      'e3d-pilot web refused to start: set E3D_PILOT_WEB_AUTH_USER and E3D_PILOT_WEB_AUTH_PASS (private dashboard, never unauthenticated)'
    );
  }
  return { user, pass };
}

function timingSafeStringEqual(a, b) {
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  if (bufA.length !== bufB.length) {
    // Still run a timing-safe compare against a same-length buffer so a
    // length mismatch alone doesn't short-circuit as cheaply as a match.
    crypto.timingSafeEqual(bufA, bufA);
    return false;
  }
  return crypto.timingSafeEqual(bufA, bufB);
}

export function checkBasicAuth(req, credentials) {
  const header = req.headers['authorization'];
  if (typeof header !== 'string' || !header.startsWith('Basic ')) {
    return false;
  }

  let decoded;
  try {
    decoded = Buffer.from(header.slice('Basic '.length), 'base64').toString('utf8');
  } catch {
    return false;
  }

  const separatorIndex = decoded.indexOf(':');
  if (separatorIndex === -1) {
    return false;
  }

  const user = decoded.slice(0, separatorIndex);
  const pass = decoded.slice(separatorIndex + 1);

  return timingSafeStringEqual(user, credentials.user) && timingSafeStringEqual(pass, credentials.pass);
}
