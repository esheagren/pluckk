import { useEffect, useState, type JSX, type ReactNode } from 'react';
import { Navigate } from 'react-router-dom';
import { api } from '@pluckk/shared/api';

/**
 * Renders its children only for admins; everyone else is sent home. The API decides
 * (`isAdmin` on /api/user/me, from the server-only ADMIN_EMAILS env var), so the allowlist
 * never ships in the public bundle.
 */
export default function AdminRoute({ children, fallback }: { children: ReactNode; fallback: ReactNode }): JSX.Element {
  const [access, setAccess] = useState<'checking' | 'admin' | 'denied'>('checking');

  useEffect(() => {
    let cancelled = false;
    api.user.me()
      .then((me) => { if (!cancelled) setAccess(me.user.isAdmin ? 'admin' : 'denied'); })
      .catch(() => { if (!cancelled) setAccess('denied'); });
    return () => { cancelled = true; };
  }, []);

  if (access === 'checking') return <>{fallback}</>;
  if (access === 'denied') return <Navigate to="/" replace />;
  return <>{children}</>;
}
