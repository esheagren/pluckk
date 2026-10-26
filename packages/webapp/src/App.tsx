import { lazy, Suspense, type JSX } from 'react';
import { Routes, Route, Navigate, useLocation } from 'react-router-dom';
import { useAuth, AUTH_CALLBACK_PATH, consumeReturnTo } from './hooks/useAuth';
import { useCards } from './hooks/useCards';
import { useFolders } from './hooks/useFolders';
import Layout from './components/Layout';
import ReviewPage from './pages/ReviewPage';
import CardsPage from './pages/CardsPage';
import ProfilePage from './pages/ProfilePage';
import SettingsPage from './pages/SettingsPage';
import FocusPage from './pages/FocusPage';
import LandingPage from './pages/LandingPage';
import InfoPage from './pages/InfoPage';
import PrivacyPage from './pages/PrivacyPage';
import AdminRoute from './pages/admin/AdminRoute';

// Admin pages load only when an admin opens them.
const ArchitecturePage = lazy(() => import('./pages/admin/ArchitecturePage'));

// Loading Screen Component
function LoadingScreen(): JSX.Element {
  return (
    <div className="min-h-screen bg-gray-50 dark:bg-dark-bg flex items-center justify-center">
      <div className="flex flex-col items-center gap-4">
        <div className="spinner w-8 h-8 border-3 border-gray-200 dark:border-gray-700 border-t-gray-800 dark:border-t-gray-200 rounded-full"></div>
        <p className="text-gray-500 dark:text-gray-400 text-sm">Loading...</p>
      </div>
    </div>
  );
}

export default function App(): JSX.Element {
  const location = useLocation();
  const {
    user,
    loading: authLoading,
    signIn,
    signOut,
  } = useAuth();
  const { cards, loading: cardsLoading, updateCard, deleteCard, restoreCard, moveCardToFolder } = useCards(
    user?.id
  );
  const { folders, loading: foldersLoading, createFolder, updateFolder, deleteFolder } =
    useFolders(user?.id);

  // Public pages (no auth required)
  if (location.pathname === '/info') {
    return <InfoPage />;
  }
  if (location.pathname === '/privacy') {
    return <PrivacyPage />;
  }

  // Show loading while checking auth (also covers the /auth/callback exchange)
  if (authLoading) {
    return <LoadingScreen />;
  }
  // Exchange finished: leave the callback route via the router (history.replaceState
  // in the hook doesn't update React Router's location).
  if (location.pathname === AUTH_CALLBACK_PATH) {
    return <Navigate to={consumeReturnTo()} replace />;
  }

  // Show landing page if not authenticated
  if (!user) {
    return <LandingPage onSignIn={signIn} />;
  }

  // Admin pages: full-screen, outside the app layout, and only for admins (the API decides).
  if (location.pathname.startsWith('/admin/')) {
    return (
      <AdminRoute fallback={<LoadingScreen />}>
        <Suspense fallback={<LoadingScreen />}>
          <Routes>
            <Route path="/admin/architecture" element={<ArchitecturePage />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </Suspense>
      </AdminRoute>
    );
  }

  // Authenticated - show main app
  return (
    <>
      <div>
        <Routes>
        <Route element={<Layout />}>
        <Route
          path="/"
          element={
            <ReviewPage
              userId={user?.id}
              onUpdateCard={updateCard}
              onDeleteCard={deleteCard}
            />
          }
        />
        <Route
          path="/cards"
          element={
            <CardsPage
              cards={cards}
              loading={cardsLoading}
              onUpdateCard={updateCard}
              onDeleteCard={deleteCard}
              onRestoreCard={restoreCard}
              onMoveCardToFolder={moveCardToFolder}
              folders={folders}
              foldersLoading={foldersLoading}
              onCreateFolder={createFolder}
              onUpdateFolder={updateFolder}
              onDeleteFolder={deleteFolder}
            />
          }
        />
        <Route path="/profile" element={<ProfilePage user={user} />} />
        <Route
          path="/settings"
          element={
            <SettingsPage user={user} onSignOut={signOut} />
          }
        />
        <Route path="/focus" element={<FocusPage />} />
        <Route path="/activity" element={<Navigate to="/profile" replace />} />
        <Route path="/architecture" element={<Navigate to="/admin/architecture" replace />} />
      </Route>
      </Routes>
      </div>
    </>
  );
}
