import type { JSX } from 'react';
import { NavLink } from 'react-router-dom';

export default function Sidebar(): JSX.Element {
  const navLinkClass = ({ isActive }: { isActive: boolean }): string =>
    `flex items-center gap-3 px-3.5 py-3 rounded-lg text-sm font-medium transition-all ${
      isActive
        ? 'bg-gray-100 dark:bg-gray-800 text-gray-800 dark:text-gray-100'
        : 'text-gray-500 dark:text-gray-400 hover:bg-gray-50 dark:hover:bg-gray-800/50 hover:text-gray-800 dark:hover:text-gray-200'
    }`;

  return (
    <nav className="w-[220px] bg-white dark:bg-dark-surface border-r border-gray-200 dark:border-dark-border flex flex-col fixed top-0 left-0 bottom-0 max-md:hidden">
      {/* Header */}
      <div className="px-5 py-6 border-b border-gray-200 dark:border-dark-border">
        <div className="flex items-center gap-2">
          <img src="/logo.png" alt="Pluckk" className="w-7 h-7" />
          <h1 className="text-lg font-semibold text-gray-800 dark:text-gray-100 tracking-tight">
            Pluckk
          </h1>
        </div>
      </div>

      {/* Nav Links */}
      <div className="flex-1 p-3 flex flex-col gap-1 overflow-y-auto">
        <NavLink to="/" className={navLinkClass}>
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
          >
            <path d="M9 18h6"></path>
            <path d="M10 22h4"></path>
            <path d="M12 2a7 7 0 0 0-7 7c0 2.38 1.19 4.47 3 5.74V17a1 1 0 0 0 1 1h6a1 1 0 0 0 1-1v-2.26c1.81-1.27 3-3.36 3-5.74a7 7 0 0 0-7-7z"></path>
          </svg>
          <span>Mix Review</span>
        </NavLink>
        <NavLink to="/focus" className={navLinkClass}>
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
          >
            <circle cx="12" cy="12" r="9"></circle>
            <circle cx="12" cy="12" r="4.5"></circle>
            <circle cx="12" cy="12" r="0.5" fill="currentColor"></circle>
          </svg>
          <span>Focused Review</span>
        </NavLink>

        <NavLink to="/cards" className={navLinkClass}>
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
          >
            <rect x="3" y="3" width="7" height="7" rx="1"></rect>
            <rect x="14" y="3" width="7" height="7" rx="1"></rect>
            <rect x="3" y="14" width="7" height="7" rx="1"></rect>
            <rect x="14" y="14" width="7" height="7" rx="1"></rect>
          </svg>
          <span>Cards</span>
        </NavLink>
      </div>

      {/* Feedback & Settings at bottom */}
      <div className="p-3 border-t border-gray-200 dark:border-dark-border flex flex-col gap-1">
        <NavLink to="/info" className={navLinkClass}>
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
          >
            <circle cx="12" cy="12" r="10"></circle>
            <line x1="12" y1="16" x2="12" y2="12"></line>
            <line x1="12" y1="8" x2="12.01" y2="8"></line>
          </svg>
          <span>About</span>
        </NavLink>
        <NavLink to="/profile" className={navLinkClass}>
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
          >
            <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path>
            <circle cx="12" cy="7" r="4"></circle>
          </svg>
          <span>Profile</span>
        </NavLink>
        <NavLink to="/settings" className={navLinkClass}>
          <svg
            width="20"
            height="20"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
          >
            <circle cx="12" cy="12" r="3"></circle>
            <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-2 2 2 2 0 0 1-2-2v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1-2-2 2 2 0 0 1 2-2h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 2-2 2 2 0 0 1 2 2v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 2 2 2 2 0 0 1-2 2h-.09a1.65 1.65 0 0 0-1.51 1z"></path>
          </svg>
          <span>Settings</span>
        </NavLink>
      </div>
    </nav>
  );
}
