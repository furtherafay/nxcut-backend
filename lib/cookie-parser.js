/**
 * Parse cookies from cookie header string
 */
export function parseCookies(cookieHeader) {
  const cookies = {};
  if (!cookieHeader) return cookies;

  cookieHeader.split(';').forEach((cookie) => {
    const [name, ...rest] = cookie.trim().split('=');
    const value = rest.join('=');
    if (name) {
      cookies[name] = decodeURIComponent(value);
    }
  });

  return cookies;
}
