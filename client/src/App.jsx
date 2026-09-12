import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { AuthProvider, RequireAuth } from './context/AuthContext.jsx';
import { ToastProvider } from './context/ToastContext.jsx';
import Header from './components/Header.jsx';
import Home from './pages/Home.jsx';
import Browse from './pages/Browse.jsx';
import AuctionDetail from './pages/AuctionDetail.jsx';
import CreateListing from './pages/CreateListing.jsx';
import MyBids from './pages/MyBids.jsx';
import Notifications from './pages/Notifications.jsx';
import Analytics from './pages/Analytics.jsx';
import Login from './pages/Login.jsx';
import Register from './pages/Register.jsx';

export default function App() {
  return (
    <BrowserRouter>
      <ToastProvider>
        <AuthProvider>
          <div className="app-shell">
            <a href="#main-content" className="skip-link">
              Skip to content
            </a>
            <Header />
            <main className="app-main" id="main-content" tabIndex={-1}>
              <Routes>
                <Route path="/" element={<Home />} />
                <Route path="/browse" element={<Browse />} />
                <Route path="/auctions/:id" element={<AuctionDetail />} />
                <Route path="/analytics" element={<Analytics />} />
                <Route path="/login" element={<Login />} />
                <Route path="/register" element={<Register />} />
                <Route
                  path="/create-listing"
                  element={
                    <RequireAuth>
                      <CreateListing />
                    </RequireAuth>
                  }
                />
                <Route
                  path="/my-bids"
                  element={
                    <RequireAuth>
                      <MyBids />
                    </RequireAuth>
                  }
                />
                <Route
                  path="/notifications"
                  element={
                    <RequireAuth>
                      <Notifications />
                    </RequireAuth>
                  }
                />
                <Route path="*" element={<div className="empty-state">Page not found.</div>} />
              </Routes>
            </main>
          </div>
        </AuthProvider>
      </ToastProvider>
    </BrowserRouter>
  );
}
