import { useEffect, useState, useCallback } from 'react';
import { NavLink, useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from '../context/AuthContext.jsx';
import { api } from '../api/client.js';

const POLL_MS = 30_000;






function NotificationBell() {
  const { user } = useAuth();
  const [unreadCount, setUnreadCount] = useState(0);

  const refresh = useCallback(async () => {
    if (!user) return;
    try {
      const { unread } = await api.get('/notifications/unread-count');
      setUnreadCount(unread);
    } catch {
      
    }
  }, [user]);

  useEffect(() => {
    if (!user) {
      setUnreadCount(0);
      return undefined;
    }
    refresh();
    const timer = setInterval(refresh, POLL_MS);
    return () => clearInterval(timer);
  }, [user, refresh]);

  if (!user) return null;

  return (
    <NavLink
      to="/notifications"
      className="bell-button"
      title={`${unreadCount} unread notifications`}
      aria-label={`Notifications, ${unreadCount} unread`}
    >
      <span aria-hidden="true">🔔</span>
      {unreadCount > 0 && (
        <span className="bell-count" aria-hidden="true">
          {unreadCount > 99 ? '99+' : unreadCount}
        </span>
      )}
    </NavLink>
  );
}

export default function Header() {
  const { user, logout } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => {
    setMenuOpen(false);
  }, [location.pathname]);

  function handleLogout() {
    logout();
    navigate('/');
  }

  return (
    <header className="app-header">
      <NavLink to="/" className="app-brand">
        BidHub
      </NavLink>

      <button
        type="button"
        className="nav-toggle"
        aria-label={menuOpen ? 'Close menu' : 'Open menu'}
        aria-expanded={menuOpen}
        onClick={() => setMenuOpen((open) => !open)}
      >
        <span aria-hidden="true">{menuOpen ? '✕' : '☰'}</span>
      </button>

      <div className={`app-nav-collapsible${menuOpen ? ' open' : ''}`}>
        <nav className="app-nav" aria-label="Primary">
          <NavLink to="/" end>
            Home
          </NavLink>
          <NavLink to="/browse">Browse</NavLink>
          <NavLink to="/analytics">Analytics</NavLink>
          {user && <NavLink to="/my-bids">My Bids</NavLink>}
          {user?.role === 'SELLER' && <NavLink to="/create-listing">Sell an item</NavLink>}
        </nav>

        <div className="app-nav-right">
          <NotificationBell />
          {user ? (
            <>
              <span className="page-caption caption-inline">
                {user.full_name}
              </span>
              <button className="btn" onClick={handleLogout}>
                Log out
              </button>
            </>
          ) : (
            <>
              <NavLink to="/login" className="btn">
                Log in
              </NavLink>
              <NavLink to="/register" className="btn btn-primary">
                Register
              </NavLink>
            </>
          )}
        </div>
      </div>
    </header>
  );
}
