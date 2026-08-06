import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  // Reads VITE_API_URL from the repo-root .env (same file docker-compose and
  // the server share) instead of requiring a second, duplicate client/.env.
  envDir: '../',
  server: {
    port: 5173,
  },
});
